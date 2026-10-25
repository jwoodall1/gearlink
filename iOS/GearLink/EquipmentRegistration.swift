import Foundation
import Security
import Combine

struct RegistrationContext: Equatable, Sendable {
    let userID: UUID
    let organizationID: UUID
}

struct RegistrationPayload: Equatable, Sendable {
    let format: UInt8
    let type: Data
    let identifier: Data
    let payload: Data
}

/// Immutable evidence survives dismissal of the reader session. It never grants
/// write permission: Phase 4 must reconnect, inspect and match the entire UID.
struct RegistrationScan: Sendable {
    let rawUID: Data
    let technology: EquipmentTagTechnology?
    let writable: Bool
    let readComplete: Bool
    let capacity: Int
    let records: [RegistrationPayload]

    var uid: EquipmentTagUID? {
        EquipmentTagUID(rawValue: rawUID.map { String(format: "%02X", $0) }.joined())
    }

    func inspectedIdentity() throws -> GearLinkEquipmentID? {
        guard let uid, uid.rawValue.count >= 6, technology != nil else {
            throw RegistrationError.message("This tag does not provide a supported equipment identity. You can still inspect it in the scanner.")
        }
        guard readComplete else { throw RegistrationError.message("The tag read did not finish. Scan it again before registering equipment.") }
        let emptyRecord = records.count == 1 && records[0].format == 0
            && records[0].type.isEmpty && records[0].identifier.isEmpty && records[0].payload.isEmpty
        if records.isEmpty || emptyRecord {
            guard writable, capacity >= 33 else { throw RegistrationError.message("Use a writable NDEF tag with at least 33 bytes of capacity.") }
            return nil
        }
        // One compact NDEF Text record, UTF-8 or UTF-16 as defined by its flag.
        guard records.count == 1, let record = records.first,
              record.format == 1, record.type == Data([0x54]),
              let status = record.payload.first, status & 0x40 == 0 else {
            throw RegistrationError.message("This tag contains other data. Registration will not overwrite it. Use a blank tag or ask an administrator about replacement.")
        }
        let languageLength = Int(status & 0x3f)
        guard record.payload.count >= 1 + languageLength else { throw RegistrationError.identityConflict }
        let language = record.payload.dropFirst().prefix(languageLength)
        guard language.allSatisfy({ $0 < 128 }), languageLength > 0,
              let text = String(data: record.payload.dropFirst(1 + languageLength), encoding: status & 0x80 == 0 ? .utf8 : .utf16),
              let id = GearLinkEquipmentID(rawValue: text) else { throw RegistrationError.identityConflict }
        return id
    }
}

enum RegistrationError: LocalizedError {
    case message(String), identityConflict, idCollision, sessionChanged, unavailable
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .identityConflict: return "The tag's identity is invalid or conflicts with equipment records. Registration is blocked. Check the tag or use a blank one."
        case .idCollision: return "A unique GearLink ID couldn't be reserved. Try saving again."
        case .sessionChanged: return "Your account changed. Close this screen and reopen registration from your current workspace."
        case .unavailable: return "Equipment registration is not available on this server yet. Contact your administrator. No tag was written."
        }
    }
}

enum GearLinkIDGenerator {
    static func generate(for uid: EquipmentTagUID, randomBytes: () throws -> Data = secureBytes) throws -> GearLinkEquipmentID {
        guard uid.rawValue.count >= 6 else { throw RegistrationError.identityConflict }
        let bytes = try randomBytes()
        guard bytes.count == 8 else { throw RegistrationError.message("Couldn't securely generate an equipment ID. Try again.") }
        let token = bytes.map { String(format: "%02X", $0) }.joined()
        guard let id = GearLinkEquipmentID(rawValue: "GL-\(uid.rawValue.suffix(6))-\(token)") else { throw RegistrationError.identityConflict }
        return id
    }

    private static func secureBytes() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RegistrationError.message("Secure ID generation failed. Try again before saving.")
        }
        return Data(bytes)
    }
}

struct RegistrationForm {
    var category = "Helmet"
    var customCategory = ""
    var size = ""
    var color = ""
    var condition: EquipmentCondition = .good
    var brand = ""
    var model = ""
    var jerseyNumber = ""
    var serialNumber = ""
    var purchaseYear = ""
    var purchasePrice = ""
    var notes = ""

    static let categories = ["Helmet", "Shoulder Pads", "Jersey", "Pants", "Other"]
    var sizes: [String] {
        switch category {
        case "Helmet": return ["Youth S", "Youth M", "Youth L", "S", "M", "L", "XL"]
        case "Shoulder Pads": return ["Youth S", "Youth M", "Youth L", "S", "M", "L", "XL", "XXL"]
        case "Jersey", "Pants": return ["YS", "YM", "YL", "S", "M", "L", "XL", "XXL", "XXXL"]
        default: return []
        }
    }
    func validated(locale: Locale = .current) throws -> EquipmentDetails {
        func cleaned(_ value: String) -> String? {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let type = cleaned(category == "Other" ? customCategory : category),
              let size = cleaned(size), let color = cleaned(color) else {
            throw RegistrationError.message("Enter an equipment type, size and color.")
        }
        let values = [type, size, color, brand, model, serialNumber]
        guard values.allSatisfy({ ($0.trimmingCharacters(in: .whitespacesAndNewlines)).unicodeScalars.count <= 120 }),
              jerseyNumber.unicodeScalars.count <= 20, notes.unicodeScalars.count <= 4000,
              condition != .retired else { throw RegistrationError.message("Keep equipment fields within 120 characters, jersey number within 20 and notes within 4,000.") }
        var details = EquipmentDetails(category: type, size: size, color: color, condition: condition)
        details.brand = cleaned(brand)
        details.model = ["Helmet", "Shoulder Pads", "Other"].contains(category) ? cleaned(model) : nil
        details.jerseyNumber = category == "Jersey" ? cleaned(jerseyNumber) : nil
        details.serialNumber = cleaned(serialNumber)
        details.notes = cleaned(notes)
        if let text = cleaned(purchaseYear) {
            guard text.utf8.count == 4, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let year = Int(text), (1900...9999).contains(year) else {
                throw RegistrationError.message("Enter a four-digit purchase year from 1900 to 9999, or leave it blank.")
            }
            details.purchaseYear = year
        }
        if let text = cleaned(purchasePrice) {
            let separator = locale.decimalSeparator ?? "."
            let normalized = text.replacingOccurrences(of: separator, with: ".")
            guard normalized.range(of: "^[0-9]{1,10}([.][0-9]{1,2})?$", options: .regularExpression) != nil,
                  let price = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else {
                throw RegistrationError.message("Enter a nonnegative price with up to two decimal places and no currency symbol or grouping separators.")
            }
            details.purchasePrice = price
        }
        return details
    }
}

@MainActor
protocol EquipmentRegistrationServing {
    func lookup(uid: EquipmentTagUID, id: GearLinkEquipmentID?) async throws -> EquipmentTagLookup
    func begin(_ request: BeginEquipmentRegistration) async throws -> EquipmentSnapshot
    func pending(offset: Int) async throws -> [EquipmentRecord]
    func recover(_ equipment: EquipmentRecord) async throws -> EquipmentSnapshot
}

@MainActor
final class RegistrationStore: ObservableObject {
    enum Stage { case checking, form, saved(EquipmentSnapshot), blocked }
    @Published private(set) var stage: Stage = .checking
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published var form = RegistrationForm()
    let context: RegistrationContext
    let scan: RegistrationScan
    private let service: any EquipmentRegistrationServing
    private let generateID: (EquipmentTagUID) throws -> GearLinkEquipmentID
    private var proposal: (UUID, GearLinkEquipmentID)?
    private var generation = UUID()

    init(context: RegistrationContext, scan: RegistrationScan, service: any EquipmentRegistrationServing,
         generateID: @escaping (EquipmentTagUID) throws -> GearLinkEquipmentID = { try GearLinkIDGenerator.generate(for: $0) }) {
        self.context = context; self.scan = scan; self.service = service; self.generateID = generateID
    }

    func cancel() { generation = UUID(); busy = false }

    func inspect() async {
        guard !busy else { return }
        busy = true; error = nil; stage = .checking
        let operation = generation
        defer { if operation == generation { busy = false } }
        do {
            let identity = try scan.inspectedIdentity()
            guard let uid = scan.uid else { throw RegistrationError.identityConflict }
            let result = try await service.lookup(uid: uid, id: identity)
            guard operation == generation, !Task.isCancelled else { return }
            switch result {
            case .unregistered:
                guard identity == nil else { throw RegistrationError.identityConflict }
                stage = .form
            case .pending(let snapshot):
                try validate(snapshot)
                guard [.pendingWrite, .writeFailed].contains(snapshot.equipment.registrationStatus), snapshot.equipment.status == .pendingRegistration else { throw RegistrationError.identityConflict }
                stage = .saved(snapshot)
            case .registered(let snapshot):
                try validate(snapshot)
                guard identity == snapshot.equipment.gearlinkID, identity != nil,
                      snapshot.equipment.registrationStatus == .active, snapshot.tag?.writeVerifiedAt != nil,
                      snapshot.equipment.status != .retired else { throw RegistrationError.identityConflict }
                stage = .saved(snapshot)
            }
        } catch {
            guard operation == generation, !Task.isCancelled else { return }
            stage = .blocked; self.error = error.localizedDescription
        }
    }

    func save() async {
        guard case .form = stage, !busy else { return }
        busy = true; error = nil
        let operation = generation
        defer { if operation == generation { busy = false } }
        do {
            let details = try form.validated()
            guard let uid = scan.uid, let technology = scan.technology else { throw RegistrationError.identityConflict }
            for attempt in 0..<3 {
                if proposal == nil { proposal = (UUID(), try generateID(uid)) }
                guard let proposal else { throw RegistrationError.identityConflict }
                do {
                    let snapshot = try await service.begin(BeginEquipmentRegistration(
                        organizationID: context.organizationID, equipmentID: proposal.0, gearlinkID: proposal.1,
                        physicalUID: uid, technology: technology, details: details))
                    guard operation == generation, !Task.isCancelled else { return }
                    try validate(snapshot)
                    stage = .saved(snapshot)
                    return
                } catch RegistrationError.idCollision {
                    guard operation == generation, !Task.isCancelled else { return }
                    self.proposal = nil // Only a confirmed uniqueness collision permits regeneration.
                    if attempt == 2 { throw RegistrationError.idCollision }
                }
            }
        } catch {
            guard operation == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func validate(_ snapshot: EquipmentSnapshot) throws {
        if let observedID = try scan.inspectedIdentity(), snapshot.equipment.gearlinkID != observedID {
            throw RegistrationError.identityConflict
        }
        guard snapshot.equipment.organizationID == context.organizationID,
              snapshot.equipment.gearlinkID != nil,
              let tag = snapshot.tag, tag.organizationID == context.organizationID,
              tag.equipmentID == snapshot.equipment.id, tag.isActive, tag.physicalUID == scan.uid,
              [.pendingWrite, .writeFailed, .active].contains(snapshot.equipment.registrationStatus) else {
            throw RegistrationError.identityConflict
        }
    }
}
