import Foundation

@MainActor final class MemoryActionJournal: EquipmentActionJournal {
    var value: EquipmentAction?
    var fail = false
    func read() throws -> EquipmentAction? { value }
    func write(_ action: EquipmentAction) throws { if fail { throw RegistrationError.unavailable }; value = action }
    func clear(_ action: EquipmentAction) throws { if fail { throw RegistrationError.unavailable }; precondition(value == action); value = nil }
}
@MainActor final class OperationsFake: EquipmentManagingService {
    var current: EquipmentSnapshot!
    var after: EquipmentSnapshot!
    var actions: [EquipmentAction] = []
    var fail = false
    var reject = false
    var failRefresh = false
    var suspend = false
    var continuation: CheckedContinuation<EquipmentOperationReceipt, Error>?
    var editRequest: UpdateEquipmentDetailsRequest?
    func recover(_ equipment: EquipmentRecord) async throws -> EquipmentSnapshot { if failRefresh { throw RegistrationError.unavailable }; return current }
    func athlete(id: UUID) async throws -> EquipmentAthlete? { nil }
    func athletes(search: String, offset: Int) async throws -> [EquipmentAthlete] { [] }
    func history(equipmentID: UUID, offset: Int) async throws -> [EquipmentHistoryEntry] { [] }
    func perform(_ action: EquipmentAction) async throws -> EquipmentOperationReceipt {
        actions.append(action)
        if reject { throw EquipmentOperationError.rejected("Stale assignment") }
        if fail { throw EquipmentOperationError.uncertain("Response lost") }
        current = after
        let receipt = EquipmentOperationReceipt(operation: EquipmentOperationReceipt.Operation(rawValue: action.kind.rawValue)!,
            equipmentID: action.equipmentID, assignmentID: action.kind == .return ? action.expectedAssignmentID! : UUID(),
            previousAssignmentID: action.expectedAssignmentID, requestID: action.requestID)
        if suspend { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return receipt
    }
    func edit(_ request: UpdateEquipmentDetailsRequest) async throws -> EquipmentSnapshot {
        editRequest = request
        if reject { throw EquipmentOperationError.rejected("Stale edit") }
        return current
    }
}

@main struct EquipmentOperationsTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool) { precondition(value); count += 1 }
        let org=UUID(), equipment=UUID(), tag=UUID(), athlete=UUID(), assignment=UUID()
        let context=RegistrationContext(userID:UUID(),organizationID:org)
        func fixture(issued: Bool = false, damaged: Bool = false) throws -> EquipmentSnapshot {
            let value: [String:Any] = [
                "equipment":["id":equipment.uuidString,"organization_id":org.uuidString,"gearlink_id":"GL-119F80-7C92D4A18F20B6E3",
                    "original_tag_uid":"04A382BC119F80","registration_status":"active","name":"Custom helmet","category":"Helmet","size":"L","color":"Blue",
                    "condition":damaged ? "needs_repair" : "good","status":issued ? "checked_out" : damaged ? "maintenance" : "available",
                    "model":"Legacy model","jersey_number":"007","purchase_price":125.50,"created_at":"2026-10-24","updated_at":"2026-10-24T12:30:00.123456Z"],
                "tag":["id":tag.uuidString,"organization_id":org.uuidString,"equipment_id":equipment.uuidString,"uid":"04A382BC119F80","physical_uid":"04A382BC119F80",
                    "technology":"mifare","is_active":true,"registered_at":"2026-10-24","activation_status":"available","write_verified_at":"2026-10-24"],
                "current_assignment":issued ? ["id":assignment.uuidString,"organization_id":org.uuidString,"equipment_id":equipment.uuidString,
                    "athlete_id":athlete.uuidString,"checked_out_by":context.userID.uuidString,"checked_out_at":"2026-10-24"] as Any : NSNull()]
            return try JSONDecoder().decode(EquipmentSnapshot.self,from:JSONSerialization.data(withJSONObject:value))
        }
        let available=try fixture(), issued=try fixture(issued:true)
        let fake=OperationsFake(); fake.current=available; fake.after=issued
        let journal=MemoryActionJournal()
        func store(_ snapshot: EquipmentSnapshot = available) -> EquipmentDetailStore {
            EquipmentDetailStore(context:context,snapshot:snapshot,service:fake,journal:journal)
        }
        let detail=store(); check(!detail.canAct); await detail.load(); check(detail.canIssue && !detail.canReturn)
        let action=EquipmentAction(kind:.assign,equipmentID:equipment,athleteID:athlete)
        fake.fail=true; await detail.perform(action)
        check(detail.pendingAction == action && journal.value == action && !detail.canAct)
        // Restart must reuse the persisted request, never create another assignment.
        let restarted=store(); await restarted.load(); check(restarted.pendingAction == action)
        fake.fail=false; await restarted.perform(action)
        check(fake.actions.count == 2 && fake.actions[0].requestID == fake.actions[1].requestID)
        check(journal.value == nil && restarted.canReturn && restarted.canTransfer && !restarted.canIssue)
        let oldAssignment=EquipmentAction(kind:.return,equipmentID:equipment,expectedAssignmentID:assignment)
        fake.reject=true; await restarted.perform(oldAssignment)
        check(journal.value == nil && restarted.pendingAction == nil && !restarted.fresh && restarted.error != nil)
        fake.reject=false; fake.current=try fixture(issued:true,damaged:true)
        let damaged=store(fake.current); await damaged.load()
        check(damaged.canReturn && !damaged.canTransfer)
        fake.after=try fixture(damaged:true); await damaged.perform(oldAssignment)
        check(damaged.snapshot.equipment.status == .maintenance && !damaged.canIssue)
        // Transfer carries the exact selected assignment, and retry arguments
        // remain stable even when the caller's visible data later changes.
        fake.current=issued; fake.after=issued
        let transferStore=store(issued); await transferStore.load()
        let transfer=EquipmentAction(kind:.transfer,equipmentID:equipment,athleteID:UUID(),expectedAssignmentID:assignment)
        await transferStore.perform(transfer)
        check(fake.actions.last == transfer && transferStore.notice != nil && journal.value == nil)
        // Local persistence failure sends no request.
        fake.current=available; let blocked=store(); await blocked.load(); journal.fail=true
        let before=fake.actions.count; await blocked.perform(action)
        check(fake.actions.count == before && !blocked.canAct)
        journal.fail=false; journal.value=nil
        // Failed refresh after confirmed mutation must report success separately.
        fake.current=available; fake.after=issued; let refreshFailure=store(); await refreshFailure.load()
        fake.failRefresh=true; await refreshFailure.perform(action)
        check(refreshFailure.notice != nil && refreshFailure.error != nil && journal.value == nil && !refreshFailure.canAct)
        fake.failRefresh=false
        // Late completion after navigation cannot clear the durable receipt journal.
        fake.current=available; let cancelled=store(); await cancelled.load(); fake.suspend=true
        let task=Task { await cancelled.perform(action) }
        while fake.continuation == nil { await Task.yield() }
        let sent=fake.actions.count; await cancelled.perform(action); check(fake.actions.count == sent)
        cancelled.cancel()
        fake.continuation?.resume(returning:EquipmentOperationReceipt(operation:.assign,equipmentID:equipment,assignmentID:assignment,previousAssignmentID:nil,requestID:action.requestID))
        await task.value
        check(journal.value == action && cancelled.notice == nil)
        fake.suspend=false; journal.value=nil
        // Edit uses precise version and retains legacy metadata outside suggested fields.
        fake.current=available; let editable=store(); await editable.load()
        var form=RegistrationForm(equipment:available.equipment)
        let edits=try form.validatedEdit(name:"Updated helmet")
        check(edits.jerseyNumber == "007" && edits.model == "Legacy model")
        try await editable.edit(expectedUpdatedAt:available.equipment.updatedAt,details:edits)
        check(fake.editRequest?.expectedUpdatedAt == "2026-10-24T12:30:00.123456Z" && fake.editRequest?.details.name == "Updated helmet")
        fake.reject=true
        do { try await editable.edit(expectedUpdatedAt:"old",details:edits); fatalError() } catch { count += 1 }
        check(!editable.canAct)
        form.jerseyNumber=""; form.model=""
        check(try form.validatedEdit(name:"Helmet").jerseyNumber == nil)
        check((try? form.validatedEdit(name:"")) == nil)
        // Real atomic journal round trip, context isolation and conflicting requests.
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let disk=FileEquipmentActionJournal(context:context,equipmentID:equipment,directory:directory)
        try disk.write(action)
        let reopened=FileEquipmentActionJournal(context:context,equipmentID:equipment,directory:directory)
        check(try reopened.read() == action)
        let other=FileEquipmentActionJournal(context:RegistrationContext(userID:UUID(),organizationID:org),equipmentID:equipment,directory:directory)
        check(try other.read() == nil)
        do { try disk.write(oldAssignment); fatalError() } catch { count += 1 }
        do { try disk.clear(oldAssignment); fatalError() } catch { count += 1 }
        try disk.clear(action); check(try disk.read() == nil)
        check(AthleteSearch.expression("Alex Smith")!.contains("and(first_name"))
        check(AthleteSearch.expression("%(),\"*") == nil)
        check(AthleteSearch.expression("O'Neil")!.contains("O'Neil"))
        check(!EquipmentAction(kind:.transfer,equipmentID:equipment,athleteID:athlete).isValid)
        print("PASS: \(count) equipment operation assertions")
    }
}
