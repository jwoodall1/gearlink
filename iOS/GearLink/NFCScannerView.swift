import SwiftUI
import CoreNFC
import Combine

struct NFCScannerView: View {
    @StateObject private var scanner = NFCScanner()

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
final class NFCScanner: NSObject, ObservableObject, NFCTagReaderSessionDelegate {
    // Re-enable only after restoring NFC signing entitlements (see iOS/README.md).
    static let isEnabled = false

    @Published private(set) var isScanning = false
    @Published private(set) var status = NFCScanner.isEnabled ? "Ready to scan." : "You can continue using the dashboard and roster."
    @Published private(set) var result: NFCScanResult?
    var isAvailable: Bool { Self.isEnabled && NFCTagReaderSession.readingAvailable }
    private var readerSession: NFCTagReaderSession?
    private var isReading = false

    func start() {
        guard !isScanning, isAvailable else { return }
        result = nil
        status = "Hold your iPhone near a tag."
        let session = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: nil)
        guard let session else {
            status = "Couldn't start NFC scanning. Please try again."
            return
        }
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
        status = "Scan cancelled."
        session.invalidate()
    }

    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            guard self.readerSession === session else { return }
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
            await self.read(tag, session: session)
        }
    }

    private func read(_ tag: NFCTag, session: NFCTagReaderSession) async {
        let ndefTag: any NFCNDEFTag
        var scan: NFCScanResult
        switch tag {
        case .miFare(let tag):
            ndefTag = tag
            scan = NFCScanResult(identifier: tag.identifier.nfcHex, tagType: "MIFARE / ISO 14443")
        case .iso15693(let tag):
            ndefTag = tag
            scan = NFCScanResult(identifier: tag.identifier.nfcHex, tagType: "ISO 15693")
        case .iso7816(let tag):
            ndefTag = tag
            scan = NFCScanResult(identifier: tag.identifier.nfcHex, tagType: "ISO 7816")
        case .feliCa(let tag):
            ndefTag = tag
            scan = NFCScanResult(identifier: tag.currentIDm.nfcHex, tagType: "FeliCa")
        @unknown default:
            finish(session, message: "This tag type isn't supported.")
            return
        }
        result = scan
        do {
            try await session.connect(to: tag)
            guard readerSession === session else { return }
            let (ndefStatus, capacity) = try await ndefTag.queryNDEFStatus()
            guard readerSession === session else { return }
            scan.capacity = capacity
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
            if scan.records.isEmpty { scan.note = "No NDEF records are stored on this tag." }
            result = scan
            finish(session, message: "Tag read successfully.")
        } catch {
            guard readerSession === session else { return }
            if (error as? NFCReaderError)?.code == .ndefReaderSessionErrorZeroLengthMessage {
                scan.note = "No NDEF message is stored on this tag."
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

    private func finish(_ session: NFCTagReaderSession, message: String, failed: Bool = false) {
        guard readerSession === session else { return }
        readerSession = nil
        isScanning = false
        isReading = false
        status = message
        if failed {
            session.invalidate(errorMessage: message)
        } else {
            session.alertMessage = message
            session.invalidate()
        }
    }
}
