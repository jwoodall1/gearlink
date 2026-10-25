import SwiftUI
import CoreNFC
import Combine

struct NFCScannerView: View {
    @StateObject private var scanner = NFCScanner()
    var registrationContext: RegistrationContext? = nil
    @State private var registrationScan: ScanSelection?
    private struct ScanSelection: Identifiable { let id = UUID(); let scan: RegistrationScan }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Scan an NFC tag", systemImage: "wave.3.right.circle.fill")
                        .font(.title2.bold())
                    Text(NFCScanner.isEnabled ? "Hold the top of your iPhone close to a single tag until the scan finishes." : "NFC scanning is temporarily disabled in this build.")
                        .foregroundStyle(.secondary)
                    Button {
                        scanner.start()
                    } label: {
                        Label(scanner.isScanning ? "Scanning…" : "Scan tag", systemImage: "sensor.tag.radiowaves.forward")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(scanner.isScanning || !scanner.isAvailable)
                }.padding(.vertical, 8)
                if NFCScanner.isEnabled && !scanner.isAvailable {
                    Text("NFC scanning requires a compatible physical iPhone. It isn't available in Simulator or on this device.")
                        .foregroundStyle(.secondary)
                }
                Text(scanner.status).font(.callout)
            }

            if let result = scanner.result {
                if let context = registrationContext, let evidence = result.registrationScan, !scanner.isScanning {
                    Section {
                        Button("Use tag for equipment") {
                            registrationScan = ScanSelection(scan: evidence)
                        }
                        Text("Check this tag against your program before entering equipment details.").font(.footnote).foregroundStyle(.secondary)
                    }.id(context.organizationID)
                }
                Section("Tag details") {
                    detail("Tag ID (hex)", result.identifier)
                    detail("Tag type", result.tagType)
                    detail("NDEF status", result.ndefStatus)
                    if let capacity = result.capacity { detail("NDEF capacity", "\(capacity) bytes") }
                    detail("Read at", result.date.formatted(date: .abbreviated, time: .standard))
                }
                if let note = result.note {
                    Section { Text(note).foregroundStyle(.secondary) }
                }
                ForEach(Array(result.records.enumerated()), id: \.offset) { index, record in
                    Section("Record \(index + 1)") {
                        detail("Format", record.format)
                        detail("Type", record.type)
                        if !record.identifier.isEmpty { detail("Record ID (hex)", record.identifier) }
                        if let content = record.content { detail("Decoded content", content) }
                        DisclosureGroup("Raw payload · \(record.byteCount) bytes") {
                            Text(record.hex.isEmpty ? "Empty payload" : record.hex)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            Section {
                Text("Reads the tag ID and accessible NDEF records. Protected data and proprietary tag memory may not be readable. This scanner does not write to tags.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("NFC scanner")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { scanner.cancel() }
        .onChange(of: scanner.isScanning) { scanning in
            if !scanning, registrationContext != nil, let evidence = scanner.result?.registrationScan {
                registrationScan = ScanSelection(scan: evidence)
            }
        }
        .sheet(item: $registrationScan) { selection in
            if let context = registrationContext { RegisterEquipmentView(context: context, scan: selection.scan) }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }.padding(.vertical, 3)
    }
}

struct NFCScanResult {
    let identifier: String
    let tagType: String
    let date = Date()
    var ndefStatus = "Checking…"
    var capacity: Int?
    var records: [NFCRecord] = []
    var note: String?
    var registrationScan: RegistrationScan?
}

struct NFCRecord {
    let format: String
    let type: String
    let identifier: String
    let content: String?
    let hex: String
    let byteCount: Int

    init(_ record: NFCNDEFPayload) {
        switch record.typeNameFormat {
        case .empty: format = "Empty"
        case .nfcWellKnown: format = "NFC well-known"
        case .media: format = "MIME media"
        case .absoluteURI: format = "Absolute URI"
        case .nfcExternal: format = "NFC external"
        case .unknown: format = "Unknown"
        case .unchanged: format = "Unchanged"
        @unknown default: format = "Unrecognized"
        }
        type = String(data: record.type, encoding: .utf8) ?? record.type.nfcHex
        identifier = record.identifier.nfcHex
        byteCount = record.payload.count
        hex = record.payload.nfcHex
        if let url = record.wellKnownTypeURIPayload() {
            content = url.absoluteString
        } else if let text = record.wellKnownTypeTextPayload().0 {
            content = text
        } else if record.typeNameFormat == .media,
                  let mime = String(data: record.type, encoding: .utf8),
                  mime.hasPrefix("text/") || mime == "application/json" {
            content = String(data: record.payload, encoding: .utf8)
        } else {
            content = nil
        }
    }
}

private extension Data {
    var nfcHex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

@MainActor
final class NFCScanner: NSObject, ObservableObject, NFCTagReaderSessionDelegate, NFCWritingTransport {
    // Debug and Release include GearLink.entitlements for NFC Tag Reading.
    static let isEnabled = true

    @Published private(set) var isScanning = false
    @Published private(set) var status = NFCScanner.isEnabled ? "Ready to scan." : "You can continue using the dashboard and roster."
    @Published private(set) var result: NFCScanResult?
    var isAvailable: Bool { Self.isEnabled && NFCTagReaderSession.readingAvailable }
    private var readerSession: NFCTagReaderSession?
    private var isReading = false
    // A single lease covers diagnostic and writing instances. Release only after
    // Core NFC invalidates the session, not when a sheet starts dismissing.
    private static var sessionOwner: NFCScanner?
    private var leaseSession: NFCTagReaderSession?
    private var writeContinuation: CheckedContinuation<EquipmentTagUID, Error>?
    private var writingConnection: WritingConnection?
    private var writingMode = false
    private struct WritingConnection {
        let session: NFCTagReaderSession
        let tag: any NFCNDEFTag
        let rawUID: Data
        let technology: EquipmentTagTechnology
    }

    func start() {
        guard !isScanning, isAvailable, Self.sessionOwner == nil else {
            status = "Another NFC operation is active. Finish or cancel it before scanning."
            return
        }
        result = nil
        status = "Hold your iPhone near a tag."
        let session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: nil)
        guard let session else {
            status = "Couldn't start NFC scanning. Please try again."
            return
        }
        Self.sessionOwner = self
        leaseSession = session
        readerSession = session
        isScanning = true
        session.alertMessage = "Hold the top of your iPhone near a single NFC tag."
        session.begin()
    }

    func cancel() {
        guard let session = readerSession else { return }
        readerSession = nil
        isScanning = false
        isReading = false
        writingConnection = nil
        writingMode = false
        writeContinuation?.resume(throwing: CancellationError())
        writeContinuation = nil
        status = "Scan cancelled."
        session.invalidate()
    }

    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            if self.leaseSession === session, Self.sessionOwner === self {
                Self.sessionOwner = nil
                self.leaseSession = nil
            }
            guard self.readerSession === session else { return }
            self.writingConnection = nil
            self.writingMode = false
            self.writeContinuation?.resume(throwing: NFCWriteError.message("NFC scanning stopped or timed out. Scan the same tag again to recover."))
            self.writeContinuation = nil
            self.readerSession = nil
            self.isScanning = false
            self.isReading = false
            if let nfcError = error as? NFCReaderError {
                switch nfcError.code {
                case .readerSessionInvalidationErrorUserCanceled:
                    self.status = "Scan cancelled."
                case .readerSessionInvalidationErrorSessionTimeout:
                    self.status = "Scan timed out. Tap Scan tag to try again."
                case .readerErrorSecurityViolation:
                    self.status = "NFC permission is missing from this build. Enable NFC Tag Reading in Xcode and rebuild with a matching signing profile."
                default:
                    self.status = "Scanning stopped: \(nfcError.localizedDescription)"
                }
            } else {
                self.status = "Scanning stopped. Please try again."
            }
            if self.result?.ndefStatus == "Checking…" {
                self.result?.ndefStatus = "Read interrupted"
                self.result?.note = "The ID was detected, but the NDEF read did not finish. Scan again."
            }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Task { @MainActor in
            guard self.readerSession === session, !self.isReading else { return }
            guard tags.count == 1, let tag = tags.first else {
                session.alertMessage = "More than one tag found. Move other tags away and hold one tag near your iPhone."
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard self.readerSession === session else { return }
                session.restartPolling()
                return
            }
            self.isReading = true
            if self.writingMode { await self.connectWritingTag(tag, session: session) }
            else { await self.read(tag, session: session) }
        }
    }

    private func read(_ tag: NFCTag, session: NFCTagReaderSession) async {
        let ndefTag: any NFCNDEFTag
        var scan: NFCScanResult
        let rawUID: Data
        let technology: EquipmentTagTechnology?
        switch tag {
        case .miFare(let tag):
            ndefTag = tag
            rawUID = tag.identifier; technology = tag.mifareFamily == .ultralight ? .mifare : nil
            scan = NFCScanResult(identifier: tag.identifier.nfcHex, tagType: "MIFARE / ISO 14443")
        case .iso15693(let tag):
            ndefTag = tag
            rawUID = tag.identifier; technology = .iso15693
            scan = NFCScanResult(identifier: tag.identifier.nfcHex, tagType: "ISO 15693")
        case .iso7816(let tag):
            ndefTag = tag
            rawUID = tag.identifier; technology = nil
            scan = NFCScanResult(identifier: tag.identifier.nfcHex, tagType: "ISO 7816")
        case .feliCa(let tag):
            ndefTag = tag
            rawUID = tag.currentIDm; technology = nil
            scan = NFCScanResult(identifier: tag.currentIDm.nfcHex, tagType: "FeliCa")
        @unknown default:
            finish(session, message: "This tag type isn't supported.")
            return
        }
        result = scan
        var writable = false
        var queriedCapacity = 0
        do {
            try await session.connect(to: tag)
            guard readerSession === session else { return }
            let (ndefStatus, capacity) = try await ndefTag.queryNDEFStatus()
            guard readerSession === session else { return }
            scan.capacity = capacity
            writable = ndefStatus == .readWrite
            queriedCapacity = capacity
            switch ndefStatus {
            case .notSupported:
                scan.ndefStatus = "Not supported"
                scan.note = "Tag ID detected. No accessible NDEF storage was reported; the tag may contain other data this scanner cannot read."
                result = scan
                finish(session, message: "Tag ID read. NDEF data is not supported.")
                return
            case .readOnly: scan.ndefStatus = "Read only"
            case .readWrite: scan.ndefStatus = "Read/write capable (read only in this app)"
            @unknown default: scan.ndefStatus = "Unknown"
            }
            let message = try await ndefTag.readNDEF()
            guard readerSession === session else { return }
            scan.records = message.records.map(NFCRecord.init)
            scan.registrationScan = RegistrationScan(rawUID: rawUID, technology: technology, writable: writable,
                readComplete: true, capacity: capacity, records: message.records.map {
                    RegistrationPayload(format: $0.typeNameFormat.rawValue, type: $0.type, identifier: $0.identifier, payload: $0.payload)
                })
            if scan.records.isEmpty { scan.note = "No NDEF records are stored on this tag." }
            result = scan
            finish(session, message: "Tag read successfully.")
        } catch {
            guard readerSession === session else { return }
            if (error as? NFCReaderError)?.code == .ndefReaderSessionErrorZeroLengthMessage {
                scan.note = "No NDEF message is stored on this tag."
                scan.registrationScan = RegistrationScan(rawUID: rawUID, technology: technology, writable: writable,
                    readComplete: true, capacity: queriedCapacity, records: [])
                result = scan
                finish(session, message: "Tag ID read. No NDEF message found.")
            } else {
                if scan.ndefStatus == "Checking…" { scan.ndefStatus = "Unable to read" }
                scan.note = "Tag ID detected, but its data couldn't be read. Keep the tag still and try again. It may be protected or unsupported."
                result = scan
                finish(session, message: "Tag ID read; data read failed. Try scanning again.", failed: true)
            }
        }
    }

    func connectForWriting() async throws -> EquipmentTagUID {
        guard isAvailable, Self.sessionOwner == nil else {
            throw NFCWriteError.message("NFC is unavailable or another scan is still closing. Wait a moment and try again on a compatible iPhone.")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled,
                      let session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: nil) else {
                    continuation.resume(throwing: CancellationError()); return
                }
                writeContinuation = continuation
                writingMode = true
                writingConnection = nil
                isReading = false
                isScanning = true
                readerSession = session
                Self.sessionOwner = self
                leaseSession = session
                session.alertMessage = "Scan the same tag used for this equipment. Keep it still until verification finishes."
                session.begin()
            }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    private func connectWritingTag(_ tag: NFCTag, session: NFCTagReaderSession) async {
        do {
            let ndefTag: any NFCNDEFTag
            let rawUID: Data
            let technology: EquipmentTagTechnology
            switch tag {
            case .miFare(let value) where value.mifareFamily == .ultralight:
                ndefTag = value; rawUID = value.identifier; technology = .mifare
            case .iso15693(let value):
                ndefTag = value; rawUID = value.identifier; technology = .iso15693
            default:
                throw NFCWriteError.message("Writing is supported only for NDEF-capable MIFARE Ultralight/NTAG and ISO 15693 tags. This tag remains read-only in GearLink.")
            }
            try await session.connect(to: tag)
            guard readerSession === session, writingMode else { throw CancellationError() }
            let uid = EquipmentTagUID(rawValue: rawUID.map { String(format: "%02X", $0) }.joined())
            guard let uid, uid.rawValue.count >= 6 else { throw RegistrationError.identityConflict }
            writingConnection = WritingConnection(session: session, tag: ndefTag, rawUID: rawUID, technology: technology)
            writeContinuation?.resume(returning: uid)
            writeContinuation = nil
        } catch {
            guard readerSession === session else { return }
            writeContinuation?.resume(throwing: error)
            writeContinuation = nil
            finish(session, message: "This tag couldn't be connected for registration.", failed: true)
        }
    }

    private func checkedWritingConnection(expected: NFCTagReaderSession? = nil) throws -> WritingConnection {
        try Task.checkCancellation()
        guard let connection = writingConnection, readerSession === connection.session,
              writingMode, (expected == nil || connection.session === expected), connection.tag.isAvailable else {
            throw NFCWriteError.message("The tag disconnected or the scan stopped. Its write outcome may be unknown. Scan the same tag again.")
        }
        return connection
    }

    func inspectForWriting() async throws -> RegistrationScan {
        let connection = try checkedWritingConnection()
        let (state, capacity) = try await connection.tag.queryNDEFStatus()
        _ = try checkedWritingConnection(expected: connection.session)
        guard state == .readWrite || state == .readOnly else {
            throw NFCWriteError.message("This tag does not support NDEF. No equipment identity can be written.")
        }
        let records: [NFCNDEFPayload]
        do { records = try await connection.tag.readNDEF().records }
        catch {
            if (error as? NFCReaderError)?.code == .ndefReaderSessionErrorZeroLengthMessage { records = [] }
            else { throw error }
        }
        _ = try checkedWritingConnection(expected: connection.session)
        return RegistrationScan(rawUID: connection.rawUID, technology: connection.technology,
            writable: state == .readWrite, readComplete: true, capacity: capacity,
            records: records.map { RegistrationPayload(format: $0.typeNameFormat.rawValue,
                type: $0.type, identifier: $0.identifier, payload: $0.payload) })
    }

    func writeGearLinkID(_ id: GearLinkEquipmentID) async throws {
        let connection = try checkedWritingConnection()
        guard let record = NFCNDEFPayload.wellKnownTypeTextPayload(string: id.rawValue, locale: Locale(identifier: "en")) else {
            throw RegistrationError.identityConflict
        }
        let message = NFCNDEFMessage(records: [record])
        let (state, capacity) = try await connection.tag.queryNDEFStatus()
        _ = try checkedWritingConnection(expected: connection.session)
        guard state == .readWrite, capacity >= message.length else {
            throw NFCWriteError.message("The tag is read-only or too small for the equipment ID. Nothing was written.")
        }
        // Inspect again after the database round trip. Content may have changed
        // since the first inspection; normal registration never overwrites it.
        let fresh = try await inspectForWriting()
        let existing = try fresh.inspectedIdentity()
        if existing == id { return }
        guard existing == nil else { throw RegistrationError.identityConflict }
        _ = try checkedWritingConnection(expected: connection.session)
        try await connection.tag.writeNDEF(message)
        _ = try checkedWritingConnection(expected: connection.session)
    }

    func closeWriting(message: String, failed: Bool) {
        guard let session = readerSession else { return }
        writeContinuation?.resume(throwing: CancellationError())
        writeContinuation = nil
        finish(session, message: message, failed: failed)
    }

    private func finish(_ session: NFCTagReaderSession, message: String, failed: Bool = false) {
        guard readerSession === session else { return }
        readerSession = nil
        isScanning = false
        isReading = false
        writingConnection = nil
        writingMode = false
        status = message
        if failed {
            session.invalidate(errorMessage: message)
        } else {
            session.alertMessage = message
            session.invalidate()
        }
    }
}
