import Foundation

/// UID identity is byte-aligned hexadecimal, never an integer or a suffix.
struct EquipmentTagUID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.utf8.allSatisfy({ "0123456789abcdefABCDEF :-".utf8.contains($0) }) else { return nil }
        let normalized = rawValue.uppercased().filter { !" :-".contains($0) }
        guard (4...64).contains(normalized.count), normalized.count.isMultiple(of: 2),
              normalized.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        self.rawValue = normalized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let uid = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid full tag UID")
        }
        self = uid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The suffix describes the original tag, not a replacement tag's identity.
struct GearLinkEquipmentID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.range(of: "^GL-[0-9A-F]{6}-[0-9A-F]{16}$", options: .regularExpression) != nil,
              rawValue.utf8.count == 26 else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let id = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid GearLink ID")
        }
        self = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum EquipmentRegistrationStatus: String, Codable, Sendable {
    case pendingWrite = "pending_write", active, writeFailed = "write_failed", retired
}

enum EquipmentInventoryStatus: String, Codable, Sendable {
    case available, checkedOut = "checked_out", maintenance, retired
    case pendingRegistration = "pending_registration"
}

enum EquipmentCondition: String, Codable, Sendable {
    case new, good, fair, needsRepair = "needs_repair", retired
}

enum EquipmentTagTechnology: String, Codable, Sendable {
    case mifare, iso15693
}

/// Explicit snake-case keys: use JSONDecoder's default key strategy.
/// Timestamps remain exact server strings, preserving microseconds for edit checks.
struct EquipmentRecord: Decodable, Identifiable, Sendable {
    let id: UUID
    let organizationID: UUID
    let gearlinkID: GearLinkEquipmentID?
    let originalTagUID: EquipmentTagUID?
    let registrationStatus: EquipmentRegistrationStatus?
    let name: String
    let category: String
    let size: String?
    let color: String?
    let condition: EquipmentCondition
    let status: EquipmentInventoryStatus
    let brand: String?
    let model: String?
    let jerseyNumber: String?
    let serialNumber: String?
    let purchaseYear: Int?
    let purchasePrice: Decimal?
    let notes: String?
    let createdAt: String
    let updatedAt: String

    var isLegacy: Bool { gearlinkID == nil && registrationStatus == nil }

    enum CodingKeys: String, CodingKey {
        case id, name, category, size, color, condition, status, brand, model, notes
        case organizationID = "organization_id", gearlinkID = "gearlink_id"
        case originalTagUID = "original_tag_uid", registrationStatus = "registration_status"
        case jerseyNumber = "jersey_number", serialNumber = "serial_number"
        case purchaseYear = "purchase_year", purchasePrice = "purchase_price"
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

struct EquipmentTagRecord: Decodable, Identifiable, Sendable {
    let id: UUID
    let organizationID: UUID
    let equipmentID: UUID
    let uid: String
    let physicalUID: EquipmentTagUID
    let technology: EquipmentTagTechnology?
    let isActive: Bool
    let registeredAt: String
    let disabledAt: String?
    let writeVerifiedAt: String?
    let activationStatus: EquipmentInventoryStatus

    enum CodingKeys: String, CodingKey {
        case id, uid, technology
        case organizationID = "organization_id", equipmentID = "equipment_id"
        case physicalUID = "physical_uid", isActive = "is_active"
        case registeredAt = "registered_at", disabledAt = "disabled_at"
        case writeVerifiedAt = "write_verified_at", activationStatus = "activation_status"
    }
}

struct EquipmentAssignmentRecord: Decodable, Identifiable, Sendable {
    let id: UUID
    let organizationID: UUID
    let equipmentID: UUID
    let athleteID: UUID
    let checkedOutBy: UUID
    let checkedOutAt: String
    let returnedBy: UUID?
    let returnedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case organizationID = "organization_id", equipmentID = "equipment_id", athleteID = "athlete_id"
        case checkedOutBy = "checked_out_by", checkedOutAt = "checked_out_at"
        case returnedBy = "returned_by", returnedAt = "returned_at"
    }
}

struct EquipmentSnapshot: Decodable, Sendable {
    let equipment: EquipmentRecord
    let tag: EquipmentTagRecord?
    let currentAssignment: EquipmentAssignmentRecord?
    enum CodingKeys: String, CodingKey {
        case equipment, tag, currentAssignment = "current_assignment"
    }
}

/// A registered/pending result must contain a complete snapshot; never treat a
/// malformed response as an unregistered tag that is safe to claim.
enum EquipmentTagLookup: Decodable, Sendable {
    case unregistered
    case pending(EquipmentSnapshot)
    case registered(EquipmentSnapshot)

    private enum CodingKeys: String, CodingKey { case resolution }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .resolution) {
        case "unregistered": self = .unregistered
        case "pending": self = .pending(try EquipmentSnapshot(from: decoder))
        case "registered": self = .registered(try EquipmentSnapshot(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .resolution, in: container, debugDescription: "Unknown tag resolution")
        }
    }
}

struct EquipmentOperationReceipt: Decodable, Sendable {
    enum Operation: String, Decodable, Sendable { case assign, `return`, transfer }
    let operation: Operation
    let equipmentID: UUID
    let assignmentID: UUID
    let previousAssignmentID: UUID?
    let requestID: UUID
    enum CodingKeys: String, CodingKey {
        case operation, equipmentID = "equipment_id", assignmentID = "assignment_id"
        case previousAssignmentID = "previous_assignment_id", requestID = "request_id"
    }
}

/// Complete form replacement, not a patch. Omitted optional values clear fields
/// because the server canonicalizes missing keys to null.
struct EquipmentDetails: Codable, Sendable {
    var category: String
    var size: String
    var color: String
    var condition: EquipmentCondition
    var name: String? = nil
    var brand: String? = nil
    var model: String? = nil
    var jerseyNumber: String? = nil
    var serialNumber: String? = nil
    var purchaseYear: Int? = nil
    var purchasePrice: Decimal? = nil
    var notes: String? = nil

    enum CodingKeys: String, CodingKey {
        case category, size, color, condition, name, brand, model, notes
        case jerseyNumber = "jersey_number", serialNumber = "serial_number"
        case purchaseYear = "purchase_year", purchasePrice = "purchase_price"
    }
}

struct BeginEquipmentRegistration: Encodable, Sendable {
    let organizationID: UUID
    let equipmentID: UUID
    let gearlinkID: GearLinkEquipmentID
    let physicalUID: EquipmentTagUID
    let technology: EquipmentTagTechnology
    let details: EquipmentDetails
    enum CodingKeys: String, CodingKey {
        case organizationID = "p_organization_id", equipmentID = "p_equipment_id"
        case gearlinkID = "p_gearlink_id", physicalUID = "p_physical_uid"
        case technology = "p_technology", details = "p_details"
    }
}

/// Used for both confirmation and recording a failed physical write.
struct EquipmentRegistrationEvidence: Encodable, Sendable {
    let equipmentID: UUID
    let tagID: UUID
    let physicalUID: EquipmentTagUID
    let gearlinkID: GearLinkEquipmentID
    enum CodingKeys: String, CodingKey {
        case equipmentID = "p_equipment_id", tagID = "p_tag_id"
        case physicalUID = "p_physical_uid", gearlinkID = "p_gearlink_id"
    }
}

struct AssignEquipmentRequest: Encodable, Sendable {
    let equipmentID: UUID
    let athleteID: UUID
    let requestID: UUID
    enum CodingKeys: String, CodingKey {
        case equipmentID = "p_equipment_id", athleteID = "p_athlete_id", requestID = "p_request_id"
    }
}

struct ReturnEquipmentRequest: Encodable, Sendable {
    let assignmentID: UUID
    let requestID: UUID
    enum CodingKeys: String, CodingKey {
        case assignmentID = "p_assignment_id", requestID = "p_request_id"
    }
}

struct TransferEquipmentRequest: Encodable, Sendable {
    let equipmentID: UUID
    let athleteID: UUID
    let expectedAssignmentID: UUID
    let requestID: UUID
    enum CodingKeys: String, CodingKey {
        case equipmentID = "p_equipment_id", athleteID = "p_athlete_id"
        case expectedAssignmentID = "p_expected_assignment_id", requestID = "p_request_id"
    }
}

struct LookupEquipmentTagRequest: Encodable, Sendable {
    let organizationID: UUID
    let physicalUID: EquipmentTagUID
    let gearlinkID: GearLinkEquipmentID?
    enum CodingKeys: String, CodingKey {
        case organizationID = "p_organization_id", physicalUID = "p_physical_uid", gearlinkID = "p_gearlink_id"
    }
}

struct UpdateEquipmentDetailsRequest: Encodable, Sendable {
    let equipmentID: UUID
    let expectedUpdatedAt: String
    let details: EquipmentDetails
    enum CodingKeys: String, CodingKey {
        case equipmentID = "p_equipment_id", expectedUpdatedAt = "p_expected_updated_at", details = "p_details"
    }
}

struct ReplaceEquipmentTagRequest: Encodable, Sendable {
    let equipmentID: UUID
    let expectedTagID: UUID
    let physicalUID: EquipmentTagUID
    let technology: EquipmentTagTechnology
    enum CodingKeys: String, CodingKey {
        case equipmentID = "p_equipment_id", expectedTagID = "p_expected_tag_id"
        case physicalUID = "p_physical_uid", technology = "p_technology"
    }
}

struct RetireEquipmentRequest: Encodable, Sendable {
    let equipmentID: UUID
    enum CodingKeys: String, CodingKey { case equipmentID = "p_equipment_id" }
}
