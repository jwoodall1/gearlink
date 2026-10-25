import Foundation
import Combine

@MainActor
protocol NFCWritingTransport: AnyObject {
    var isAvailable: Bool { get }
    func connectForWriting() async throws -> EquipmentTagUID
    func inspectForWriting() async throws -> RegistrationScan
    func writeGearLinkID(_ id: GearLinkEquipmentID) async throws
    func closeWriting(message: String, failed: Bool)
    func cancel()
}

@MainActor
protocol EquipmentWritingServing {
    func recover(_ equipment: EquipmentRecord) async throws -> EquipmentSnapshot
    func confirm(_ evidence: EquipmentRegistrationEvidence) async throws -> EquipmentSnapshot
}

enum NFCWriteError: LocalizedError {
    case wrongTag(expected: String, observed: String)
    case message(String)
    var errorDescription: String? {
        switch self {
        case .wrongTag(let expected, let observed):
            return "Incorrect NFC tag. Scan the original tag. Expected UID: \(expected). Observed UID: \(observed). Nothing was written."
        case .message(let text): return text
        }
    }
}

/// Coordinates radio and database outcomes separately. The backend is never
/// confirmed until the same connected tag has returned the exact NDEF identity.
@MainActor
final class NFCWriteStore: ObservableObject {
    enum Stage { case ready, checking, scanning, inspecting, writing, verifying, confirming, confirmationFailed, failed, complete }
    @Published private(set) var stage: Stage = .ready
    @Published private(set) var message = "Keep the original tag with this equipment."
    @Published private(set) var snapshot: EquipmentSnapshot
    let context: RegistrationContext
    private let initial: EquipmentSnapshot
    private let transport: any NFCWritingTransport
    private let service: any EquipmentWritingServing
    private var generation = UUID()
    private var readBackVerified = false
    var isAvailable: Bool { transport.isAvailable }
    var busy: Bool { [.checking, .scanning, .inspecting, .writing, .verifying, .confirming].contains(stage) }

    init(context: RegistrationContext, snapshot: EquipmentSnapshot, transport: any NFCWritingTransport, service: any EquipmentWritingServing) {
        self.context = context; self.initial = snapshot; self.snapshot = snapshot
        self.transport = transport; self.service = service
    }

    func cancel() {
        generation = UUID()
        transport.cancel()
        if busy {
            stage = readBackVerified ? .confirmationFailed : .failed
            message = readBackVerified ? "The tag was verified, but server confirmation may be incomplete. Retry confirmation or rescan to recover." : "Stopped. If writing had begun, its outcome is unknown. Scan the same tag again to inspect it before retrying."
        }
    }

    func start() async {
        guard !busy, stage != .complete else { return }
        let operation = UUID(); generation = operation; readBackVerified = false
        stage = .checking; message = "Checking the saved registration…"
        var attemptedWrite = false
        do {
            try validate(initial)
            let refreshed = try await service.recover(initial.equipment)
            try check(operation); try validate(refreshed)
            snapshot = refreshed
            guard let expectedUID = initial.tag?.physicalUID, let expectedID = initial.equipment.gearlinkID else { throw RegistrationError.identityConflict }
            stage = .scanning; message = "Hold the top of your iPhone near the same tag."
            let observed = try await transport.connectForWriting()
            try check(operation)
            try match(observed, expectedUID)
            stage = .inspecting; message = "Checking tag content and capacity…"
            let evidence = try await transport.inspectForWriting()
            try check(operation)
            guard let inspectedUID = evidence.uid else { throw RegistrationError.identityConflict }
            try match(inspectedUID, expectedUID)
            guard evidence.technology == initial.tag?.technology else { throw RegistrationError.identityConflict }
            var existingID = try evidence.inspectedIdentity()
            if let existingID, existingID != expectedID { throw RegistrationError.identityConflict }
            // Reauthorize after connection/content inspection, just before mutation.
            let current = try await service.recover(initial.equipment)
            try check(operation); try validate(current)
            // Re-read after the network round trip; changed content must pass the
            // same rules instead of relying on stale pre-write inspection.
            let fresh = try await transport.inspectForWriting()
            try check(operation)
            guard let freshUID = fresh.uid else { throw RegistrationError.identityConflict }
            try match(freshUID, expectedUID)
            guard fresh.technology == initial.tag?.technology else { throw RegistrationError.identityConflict }
            existingID = try fresh.inspectedIdentity()
            if let existingID, existingID != expectedID { throw RegistrationError.identityConflict }
            if existingID == nil {
                guard current.equipment.registrationStatus != .active else {
                    throw NFCWriteError.message("This equipment is already active, but the tag content is missing. Ask an administrator to review the tag; no overwrite was attempted.")
                }
                guard fresh.writable else { throw NFCWriteError.message("This tag is read-only. Use the administrator's tag replacement workflow.") }
                stage = .writing; message = "Writing the GearLink ID. Keep the tag still…"
                attemptedWrite = true
                try await transport.writeGearLinkID(expectedID)
                try check(operation)
            }
            stage = .verifying; message = "Reading the tag back to verify its identity…"
            let readBack = try await transport.inspectForWriting()
            try check(operation)
            guard let actualUID = readBack.uid else { throw RegistrationError.identityConflict }
            try match(actualUID, expectedUID)
            guard readBack.technology == initial.tag?.technology,
                  try readBack.inspectedIdentity() == expectedID else {
                throw NFCWriteError.message("Tag verification did not match the expected GearLink ID. Registration remains pending. Scan the same tag again to recover.")
            }
            readBackVerified = true
            transport.closeWriting(message: "Tag verified. Completing registration…", failed: false)
            await confirm(operation: operation)
        } catch {
            guard operation == generation else { return }
            transport.closeWriting(message: "Registration is not complete. Check the app and retry.", failed: true)
            stage = .failed
            message = error.localizedDescription
            if attemptedWrite {
                message += " The write may have reached the tag. Registration was not confirmed. Rescan this same tag; matching data will be verified without rewriting."
            }
        }
    }

    func retryConfirmation() async {
        guard stage == .confirmationFailed, readBackVerified else { return }
        let operation = UUID(); generation = operation
        await confirm(operation: operation)
    }

    private func confirm(operation: UUID) async {
        stage = .confirming; message = "Tag verified. Waiting for the server to confirm registration…"
        do {
            let current = try await service.recover(initial.equipment)
            try check(operation); try validate(current)
            guard let tag = initial.tag, let id = initial.equipment.gearlinkID else { throw RegistrationError.identityConflict }
            let confirmed = try await service.confirm(EquipmentRegistrationEvidence(
                equipmentID: initial.equipment.id, tagID: tag.id, physicalUID: tag.physicalUID, gearlinkID: id))
            try check(operation); try validate(confirmed)
            guard confirmed.equipment.registrationStatus == .active, confirmed.tag?.writeVerifiedAt != nil else { throw RegistrationError.identityConflict }
            snapshot = confirmed
            stage = .complete; message = "Equipment registered successfully."
        } catch {
            guard operation == generation else { return }
            stage = .confirmationFailed
            message = "The NFC tag was read back successfully, but server confirmation was not received. The server may still show this equipment as pending. \(error.localizedDescription)"
        }
    }

    private func check(_ operation: UUID) throws {
        guard operation == generation else { throw CancellationError() }
        try Task.checkCancellation()
    }
    private func match(_ observed: EquipmentTagUID, _ expected: EquipmentTagUID) throws {
        guard observed == expected else { throw NFCWriteError.wrongTag(expected: expected.rawValue, observed: observed.rawValue) }
    }
    private func validate(_ value: EquipmentSnapshot) throws {
        guard let initialTag = initial.tag, let tag = value.tag,
              value.equipment.id == initial.equipment.id, value.equipment.organizationID == context.organizationID,
              value.equipment.gearlinkID != nil, value.equipment.gearlinkID == initial.equipment.gearlinkID,
              tag.id == initialTag.id, tag.equipmentID == value.equipment.id, tag.organizationID == context.organizationID,
              tag.physicalUID == initialTag.physicalUID, tag.technology != nil, tag.technology == initialTag.technology, tag.isActive,
              [.pendingWrite, .writeFailed, .active].contains(value.equipment.registrationStatus), value.equipment.status != .retired else {
            throw RegistrationError.identityConflict
        }
    }
}
