import Foundation
import Combine

struct EquipmentAthlete: Decodable, Identifiable, Sendable {
    let id: UUID
    let organization_id: UUID
    let first_name: String
    let last_name: String
    let team: String?
    let active: Bool
    var name: String { "\(first_name) \(last_name)" }
}

struct EquipmentHistoryEntry: Decodable, Identifiable, Sendable {
    let id: UUID
    let equipment_id: UUID
    let athlete_id: UUID
    let checked_out_by: UUID
    let checked_out_at: String
    let returned_by: UUID?
    let returned_at: String?
    let athletes: EquipmentAthlete?
}

struct EquipmentAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case assign, `return`, transfer }
    let kind: Kind
    let equipmentID: UUID
    let athleteID: UUID?
    let expectedAssignmentID: UUID?
    let requestID: UUID

    init(kind: Kind, equipmentID: UUID, athleteID: UUID? = nil, expectedAssignmentID: UUID? = nil, requestID: UUID = UUID()) {
        self.kind = kind; self.equipmentID = equipmentID; self.athleteID = athleteID
        self.expectedAssignmentID = expectedAssignmentID; self.requestID = requestID
    }
    var isValid: Bool {
        switch kind {
        case .assign: return athleteID != nil && expectedAssignmentID == nil
        case .return: return athleteID == nil && expectedAssignmentID != nil
        case .transfer: return athleteID != nil && expectedAssignmentID != nil
        }
    }
    var title: String { switch kind { case .assign: return "Issue equipment"; case .return: return "Return equipment"; case .transfer: return "Transfer equipment" } }
}

enum EquipmentOperationError: LocalizedError {
    /// The server explicitly rejected the transaction; no operation was committed
    /// for these arguments. Transport/decoding failures never use this case.
    case rejected(String)
    case uncertain(String)
    var errorDescription: String? {
        switch self { case .rejected(let text), .uncertain(let text): return text }
    }
}

@MainActor protocol EquipmentManagingService {
    func recover(_ equipment: EquipmentRecord) async throws -> EquipmentSnapshot
    func athlete(id: UUID) async throws -> EquipmentAthlete?
    func athletes(search: String, offset: Int) async throws -> [EquipmentAthlete]
    func history(equipmentID: UUID, offset: Int) async throws -> [EquipmentHistoryEntry]
    func perform(_ action: EquipmentAction) async throws -> EquipmentOperationReceipt
    func edit(_ request: UpdateEquipmentDetailsRequest) async throws -> EquipmentSnapshot
}

@MainActor protocol EquipmentActionJournal {
    func read() throws -> EquipmentAction?
    func write(_ action: EquipmentAction) throws
    func clear(_ action: EquipmentAction) throws
}

/// Only operation UUIDs/arguments are retained, scoped to user + organization +
/// equipment. Write atomically before making the network request. No offline
/// operation is presented as synchronized; the server receipt is authoritative.
@MainActor final class FileEquipmentActionJournal: EquipmentActionJournal {
    private let url: URL
    init(context: RegistrationContext, equipmentID: UUID, directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        url = root.appendingPathComponent("EquipmentRequests", isDirectory: true)
            .appendingPathComponent("\(context.userID)-\(context.organizationID)-\(equipmentID).json")
    }
    func read() throws -> EquipmentAction? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(EquipmentAction.self, from: Data(contentsOf: url))
    }
    func write(_ action: EquipmentAction) throws {
        if let existing = try read(), existing != action {
            throw RegistrationError.message("Another unresolved request exists for this equipment. Reopen its detail screen to recover it.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(action).write(to: url, options: options)
        var resourceURL = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
    func clear(_ action: EquipmentAction) throws {
        if let existing = try read(), existing != action { throw RegistrationError.identityConflict }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

@MainActor final class EquipmentDetailStore: ObservableObject {
    let context: RegistrationContext
    @Published private(set) var snapshot: EquipmentSnapshot
    @Published private(set) var assignedAthlete: EquipmentAthlete?
    @Published private(set) var busy = false
    @Published private(set) var fresh = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var pendingAction: EquipmentAction?
    private let service: any EquipmentManagingService
    private let journal: any EquipmentActionJournal
    private var generation = UUID()
    private var journalHealthy = true

    init(context: RegistrationContext, snapshot: EquipmentSnapshot, service: any EquipmentManagingService, journal: any EquipmentActionJournal) {
        self.context = context; self.snapshot = snapshot; self.service = service; self.journal = journal
        do {
            let saved = try journal.read()
            if let saved, (!saved.isValid || saved.equipmentID != snapshot.equipment.id) { throw RegistrationError.identityConflict }
            pendingAction = saved
        } catch {
            journalHealthy = false
            self.error = "The saved operation could not be read. Actions are blocked to avoid duplicate changes. Contact support before clearing app data."
        }
    }
    var canAct: Bool { fresh && !busy && pendingAction == nil && journalHealthy }
    var canIssue: Bool { canAct && snapshot.equipment.status == .available && snapshot.currentAssignment == nil && eligible }
    var canReturn: Bool { canAct && snapshot.currentAssignment != nil }
    var canTransfer: Bool { canReturn && eligible }
    private var eligible: Bool {
        snapshot.equipment.registrationStatus == .active && snapshot.tag?.writeVerifiedAt != nil
            && [.new, .good, .fair].contains(snapshot.equipment.condition)
    }
    func cancel() { generation = UUID(); busy = false; fresh = false }
    func load() async {
        guard !busy, journalHealthy else { return }
        busy = true; error = nil; fresh = false
        let operation = generation
        defer { if operation == generation { busy = false } }
        do { try await refresh(operation) }
        catch { if operation == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func refresh(_ operation: UUID) async throws {
        let result = try await service.recover(snapshot.equipment)
        try validate(result)
        let athlete = try await result.currentAssignment.mapAsync { try await service.athlete(id: $0.athleteID) }
        guard operation == generation, !Task.isCancelled else { throw CancellationError() }
        if let athlete, athlete.organization_id != context.organizationID { throw RegistrationError.identityConflict }
        snapshot = result; assignedAthlete = athlete; fresh = true
    }
    func perform(_ action: EquipmentAction) async {
        guard !busy, journalHealthy, action.isValid, action.equipmentID == snapshot.equipment.id,
              pendingAction == nil || pendingAction == action else { return }
        guard pendingAction != nil || canAct else { return }
        busy = true; error = nil; notice = nil; fresh = false
        let operation = generation
        defer { if operation == generation { busy = false } }
        do {
            try journal.write(action)
            pendingAction = action
        } catch {
            // A partial journal failure must block new requests until restart can
            // reconcile the file. No network call has been dispatched.
            journalHealthy = false
            self.error = "Couldn't safely retain this request. No request was sent. Reopen this screen before retrying."
            return
        }
        do {
            let receipt = try await service.perform(action)
            guard operation == generation, !Task.isCancelled else { return }
            guard receipt.requestID == action.requestID, receipt.equipmentID == action.equipmentID,
                  receipt.operation.rawValue == action.kind.rawValue,
                  (action.kind != .return || receipt.assignmentID == action.expectedAssignmentID),
                  (action.kind != .transfer || receipt.previousAssignmentID == action.expectedAssignmentID) else { throw RegistrationError.identityConflict }
            try journal.clear(action); pendingAction = nil
            notice = "\(action.title) confirmed by the server."
            do { try await refresh(operation) }
            catch { if operation == generation { self.error = "The operation succeeded, but current details couldn't refresh. Refresh before making another change." } }
        } catch let failure as EquipmentOperationError {
            guard operation == generation, !Task.isCancelled else { return }
            if case .rejected = failure {
                do { try journal.clear(action); pendingAction = nil } catch { journalHealthy = false }
            }
            self.error = failure.localizedDescription
        } catch {
            guard operation == generation, !Task.isCancelled else { return }
            self.error = "The result is unconfirmed. Retry the saved request to recover its original result; don't create another operation. \(error.localizedDescription)"
        }
    }
    func edit(expectedUpdatedAt: String, details: EquipmentDetails) async throws {
        guard canAct else { throw RegistrationError.message("Refresh this item and resolve any pending operation before editing.") }
        busy = true; fresh = false; error = nil
        let operation = generation
        defer { if operation == generation { busy = false } }
        let result = try await service.edit(UpdateEquipmentDetailsRequest(equipmentID: snapshot.equipment.id, expectedUpdatedAt: expectedUpdatedAt, details: details))
        guard operation == generation, !Task.isCancelled else { throw CancellationError() }
        try validate(result)
        snapshot = result; fresh = true; notice = "Equipment changes saved. The tag identity is unchanged."
    }
    private func validate(_ result: EquipmentSnapshot) throws {
        guard result.equipment.id == snapshot.equipment.id, result.equipment.organizationID == context.organizationID,
              result.equipment.gearlinkID == snapshot.equipment.gearlinkID,
              result.tag?.id == snapshot.tag?.id, result.tag?.physicalUID == snapshot.tag?.physicalUID,
              result.tag?.isActive == true, result.tag?.organizationID == context.organizationID,
              result.tag?.equipmentID == result.equipment.id, result.tag?.writeVerifiedAt != nil,
              result.equipment.registrationStatus == .active, result.equipment.status != .retired,
              result.currentAssignment == nil || (result.currentAssignment?.organizationID == context.organizationID && result.currentAssignment?.equipmentID == result.equipment.id) else { throw RegistrationError.identityConflict }
    }
}

private extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T?) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}

/// Restricted input avoids raw PostgREST expression injection while allowing
/// Unicode names, team names and hyphenated/apostrophized names.
enum AthleteSearch {
    static func expression(_ search: String) -> String? {
        let text = String(search.filter { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "-" || $0 == "'" }.prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var expressions = ["first_name.ilike.\"*\(text)*\"", "last_name.ilike.\"*\(text)*\"", "team.ilike.\"*\(text)*\""]
        if terms.count >= 2 {
            expressions.append("and(first_name.ilike.\"*\(terms[0])*\",last_name.ilike.\"*\(terms.dropFirst().joined(separator: " "))*\")")
        }
        return expressions.joined(separator: ",")
    }
}

extension RegistrationForm {
    init(equipment: EquipmentRecord) {
        self.init()
        if Self.categories.contains(equipment.category), equipment.category != "Other" { category = equipment.category }
        else { category = "Other"; customCategory = equipment.category }
        size = equipment.size ?? ""; color = equipment.color ?? ""; condition = equipment.condition
        brand = equipment.brand ?? ""; model = equipment.model ?? ""; jerseyNumber = equipment.jerseyNumber ?? ""
        serialNumber = equipment.serialNumber ?? ""; notes = equipment.notes ?? ""
        purchaseYear = equipment.purchaseYear.map(String.init) ?? ""
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.usesGroupingSeparator = false; formatter.maximumFractionDigits = 2
        purchasePrice = equipment.purchasePrice.flatMap { formatter.string(from: NSDecimalNumber(decimal: $0)) } ?? ""
    }
    func validatedEdit(name: String) throws -> EquipmentDetails {
        var details = try validated()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.unicodeScalars.count <= 120 else { throw RegistrationError.message("Enter an equipment name of up to 120 characters.") }
        details.name = cleanName
        // Editing exposes all metadata, including historical values outside the
        // initial category's suggested registration fields. Never silently erase it.
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanJersey = jerseyNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        details.model = cleanModel.isEmpty ? nil : cleanModel
        details.jerseyNumber = cleanJersey.isEmpty ? nil : cleanJersey
        return details
    }
}
