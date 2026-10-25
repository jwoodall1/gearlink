import Foundation

/// Test-only Unix-socket adapter. Uses production Codable request/response types
/// and real authenticated-role SQL; it does not emulate hosted Auth/PostgREST.
@MainActor final class LocalEquipmentDatabase: EquipmentRegistrationServing, EquipmentWritingServing, EquipmentManagingService {
    let arguments: [String]
    let context: RegistrationContext
    var loseBegin = false, loseConfirm = false, loseAction = false
    init(arguments: [String], context: RegistrationContext) { self.arguments = arguments; self.context = context }
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    func query<T: Decodable>(_ sql: String, as type: T.Type = T.self) throws -> T {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["psql", "-X", "-h", arguments[1], "-p", arguments[2], "-d", arguments[3], "-Atq", "-v", "ON_ERROR_STOP=1"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        let statement = "set role authenticated; set request.jwt.claim.sub=\(quote(context.userID.uuidString)); set statement_timeout='5s'; \(sql);"
        input.fileHandleForWriting.write(Data(statement.utf8)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EquipmentOperationError.rejected(String(decoding: error, as: UTF8.self)) }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func rpc<T: Decodable, P: Encodable>(_ name: String, _ params: P) throws -> T {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as! [String: Any]
        let named = try object.keys.sorted().map { key -> String in
            let value = object[key]!
            let argument: String
            if value is NSNull { argument = "null" }
            else if let string = value as? String { argument = quote(string) }
            else { argument = quote(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)) }
            return "\(key) => \(argument)"
        }.joined(separator: ",")
        return try query("select public.\(name)(\(named))")
    }
    func lookup(uid: EquipmentTagUID, id: GearLinkEquipmentID?) async throws -> EquipmentTagLookup {
        try rpc("lookup_equipment_tag", LookupEquipmentTagRequest(organizationID: context.organizationID, physicalUID: uid, gearlinkID: id))
    }
    func begin(_ request: BeginEquipmentRegistration) async throws -> EquipmentSnapshot {
        let result: EquipmentSnapshot = try rpc("begin_equipment_registration", request)
        if loseBegin { loseBegin = false; throw EquipmentOperationError.uncertain("Simulated response loss after committed registration") }
        return result
    }
    func confirm(_ request: EquipmentRegistrationEvidence) async throws -> EquipmentSnapshot {
        let result: EquipmentSnapshot = try rpc("confirm_equipment_registration", request)
        if loseConfirm { loseConfirm = false; throw EquipmentOperationError.uncertain("Simulated response loss after committed confirmation") }
        return result
    }
    func pending(offset: Int) async throws -> [EquipmentRecord] {
        try query("select coalesce(jsonb_agg(p),'[]') from (select * from equipment where organization_id=\(quote(context.organizationID.uuidString)) and registration_status in ('pending_write','write_failed') order by created_at desc,id offset \(offset) limit 50) p")
    }
    func recover(_ equipment: EquipmentRecord) async throws -> EquipmentSnapshot {
        let tags: [EquipmentTagRecord] = try query("select coalesce(jsonb_agg(t),'[]') from equipment_tags t where equipment_id=\(quote(equipment.id.uuidString)) and organization_id=\(quote(context.organizationID.uuidString)) and is_active")
        guard tags.count == 1 else { throw RegistrationError.identityConflict }
        switch try await lookup(uid: tags[0].physicalUID, id: equipment.gearlinkID) {
        case .pending(let value), .registered(let value): return value
        case .unregistered: throw RegistrationError.identityConflict
        }
    }
    func athlete(id: UUID) async throws -> EquipmentAthlete? {
        try query("select (select row_to_json(a) from athletes a where id=\(quote(id.uuidString)) and organization_id=\(quote(context.organizationID.uuidString)))")
    }
    func athletes(search: String, offset: Int) async throws -> [EquipmentAthlete] {
        try query("select coalesce(jsonb_agg(a),'[]') from (select * from athletes where organization_id=\(quote(context.organizationID.uuidString)) and active and (first_name || ' ' || last_name || ' ' || coalesce(team,'')) ilike \(quote("%"+search+"%")) order by last_name,first_name,id offset \(offset) limit 50) a")
    }
    func history(equipmentID: UUID, offset: Int) async throws -> [EquipmentHistoryEntry] {
        try query("select coalesce(jsonb_agg(h),'[]') from (select a.*, row_to_json(p) as athletes from equipment_assignments a join athletes p on p.id=a.athlete_id and p.organization_id=a.organization_id where a.organization_id=\(quote(context.organizationID.uuidString)) and a.equipment_id=\(quote(equipmentID.uuidString)) order by a.checked_out_at desc,a.id offset \(offset) limit 50) h")
    }
    func perform(_ action: EquipmentAction) async throws -> EquipmentOperationReceipt {
        let result: EquipmentOperationReceipt
        switch action.kind {
        case .assign: result = try rpc("assign_equipment", AssignEquipmentRequest(equipmentID: action.equipmentID, athleteID: action.athleteID!, requestID: action.requestID))
        case .return: result = try rpc("return_equipment_checked", ReturnEquipmentRequest(assignmentID: action.expectedAssignmentID!, requestID: action.requestID))
        case .transfer: result = try rpc("transfer_equipment", TransferEquipmentRequest(equipmentID: action.equipmentID, athleteID: action.athleteID!, expectedAssignmentID: action.expectedAssignmentID!, requestID: action.requestID))
        }
        if loseAction { loseAction = false; throw EquipmentOperationError.uncertain("Simulated response loss after committed operation") }
        return result
    }
    func edit(_ request: UpdateEquipmentDetailsRequest) async throws -> EquipmentSnapshot { try rpc("update_equipment_details", request) }
}

@MainActor final class IntegrationTag: NFCWritingTransport {
    var isAvailable = true
    var bytes = Data([4, 0xA3, 0x82, 0xBC, 0xFE, 0xED, 0x70])
    var records: [RegistrationPayload] = []
    var writes = 0
    func connectForWriting() async throws -> EquipmentTagUID { scan.uid! }
    var scan: RegistrationScan { RegistrationScan(rawUID: bytes, technology: .mifare, writable: true, readComplete: true, capacity: 144, records: records) }
    func inspectForWriting() async throws -> RegistrationScan { scan }
    func writeGearLinkID(_ id: GearLinkEquipmentID) async throws {
        writes += 1
        records = [RegistrationPayload(format: 1, type: Data([0x54]), identifier: Data(), payload: Data([2,0x65,0x6e]) + Data(id.rawValue.utf8))]
    }
    func closeWriting(message: String, failed: Bool) {}
    func cancel() {}
}

@main struct DatabaseIntegrationTests {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        precondition(args.count == 8 && args[1].hasPrefix("/") && args[3].hasPrefix("gearlink_nfc_test_"), "Disposable local database only")
        let context = RegistrationContext(userID: UUID(uuidString: args[4])!, organizationID: UUID(uuidString: args[5])!)
        let athlete = UUID(uuidString: args[6])!, second = UUID(uuidString: args[7])!
        let db = LocalEquipmentDatabase(arguments: args, context: context)
        let tag = IntegrationTag()
        var count = 0
        func check(_ value: Bool) { precondition(value); count += 1 }
        // Register through the production store; lose the committed response.
        let register = RegistrationStore(context: context, scan: tag.scan, service: db)
        await register.inspect(); register.form.size = "L"; register.form.color = "Blue"; register.form.purchasePrice = "125.50"
        db.loseBegin = true; await register.save()
        check(register.error != nil)
        let pending = try await db.pending(offset: 0).first { $0.originalTagUID == tag.scan.uid }!
        check(pending.status == .pendingRegistration && pending.purchasePrice == Decimal(string: "125.50"))
        // Fresh view after process interruption recovers the original identifiers.
        let restored = RegistrationStore(context: context, scan: tag.scan, service: db)
        await restored.inspect()
        guard case .saved(let saved) = restored.stage else { fatalError("Pending registration lost") }
        check(saved.equipment.id == pending.id && saved.equipment.gearlinkID == pending.gearlinkID)
        let writes = NFCWriteStore(context: context, snapshot: saved, transport: tag, service: db)
        db.loseConfirm = true; await writes.start()
        check(writes.stage == .confirmationFailed && tag.writes == 1)
        await writes.retryConfirmation()
        check(writes.stage == .complete && tag.writes == 1)
        let verifiedEvents: Int = try db.query("select count(*) from equipment_events where equipment_id=\(db.quote(pending.id.uuidString)) and event_type='registered'")
        check(verifiedEvents == 1)
        let recognition = RegistrationStore(context: context, scan: tag.scan, service: db)
        await recognition.inspect()
        guard case .saved(let active) = recognition.stage else { fatalError("Recognition failed") }
        check(active.equipment.registrationStatus == .active)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func journal() -> FileEquipmentActionJournal { FileEquipmentActionJournal(context: context, equipmentID: pending.id, directory: directory) }
        func detail() -> EquipmentDetailStore { EquipmentDetailStore(context: context, snapshot: active, service: db, journal: journal()) }
        let first = detail(); await first.load()
        check(first.canIssue)
        let issue = EquipmentAction(kind: .assign, equipmentID: pending.id, athleteID: athlete)
        db.loseAction = true; await first.perform(issue)
        check(first.pendingAction == issue && !first.canAct)
        let reopened = detail(); await reopened.load()
        check(reopened.pendingAction == issue && reopened.snapshot.currentAssignment?.athleteID == athlete)
        await reopened.perform(issue)
        check(reopened.pendingAction == nil && reopened.canReturn && reopened.assignedAthlete?.id == athlete)
        let firstAssignment = reopened.snapshot.currentAssignment!.id
        let transfer = EquipmentAction(kind: .transfer, equipmentID: pending.id, athleteID: second, expectedAssignmentID: firstAssignment)
        db.loseAction = true; await reopened.perform(transfer)
        check(reopened.pendingAction == transfer)
        let afterTransfer = detail(); await afterTransfer.load(); await afterTransfer.perform(transfer)
        check(afterTransfer.assignedAthlete?.id == second && afterTransfer.snapshot.currentAssignment?.id != firstAssignment)
        let history = try await db.history(equipmentID: pending.id, offset: 0)
        check(history.count == 2 && history.filter { $0.returned_at == nil }.count == 1 && history.allSatisfy { $0.athletes != nil })
        // A stale return cannot close the new athlete's assignment.
        await afterTransfer.perform(EquipmentAction(kind: .return, equipmentID: pending.id, expectedAssignmentID: firstAssignment))
        check(afterTransfer.error != nil && afterTransfer.pendingAction == nil)
        await afterTransfer.load()
        check(afterTransfer.snapshot.currentAssignment?.athleteID == second)
        var form = RegistrationForm(equipment: afterTransfer.snapshot.equipment)
        form.condition = .needsRepair; form.notes = "Inspection required"
        let details = try form.validatedEdit(name: "Integration helmet")
        let oldVersion = afterTransfer.snapshot.equipment.updatedAt
        try await afterTransfer.edit(expectedUpdatedAt: oldVersion, details: details)
        check(afterTransfer.snapshot.equipment.gearlinkID == active.equipment.gearlinkID && !afterTransfer.canTransfer && afterTransfer.canReturn)
        do { _ = try await db.edit(UpdateEquipmentDetailsRequest(equipmentID: pending.id, expectedUpdatedAt: oldVersion, details: details)); fatalError("Stale edit accepted") }
        catch { count += 1 }
        let returned = EquipmentAction(kind: .return, equipmentID: pending.id, expectedAssignmentID: afterTransfer.snapshot.currentAssignment!.id)
        db.loseAction = true; await afterTransfer.perform(returned)
        let afterReturn = detail(); await afterReturn.load(); await afterReturn.perform(returned)
        check(afterReturn.snapshot.currentAssignment == nil && afterReturn.snapshot.equipment.status == .maintenance && afterReturn.pendingAction == nil)
        let finalHistory = try await db.history(equipmentID: pending.id, offset: 0)
        check(finalHistory.count == 2 && finalHistory.allSatisfy { $0.returned_at != nil })
        let receiptCount: Int = try db.query("select count(*) from equipment_events where equipment_id=\(db.quote(pending.id.uuidString)) and event_type in ('checkout','return','transfer')")
        check(receiptCount == 3)
        // More than the usual API row limit: page the eligible roster, ensure
        // inactive rows are excluded and deterministic pages do not duplicate.
        var rosterIDs = Set<UUID>(), offset = 0
        while true {
            let page = try await db.athletes(search: "Scale", offset: offset)
            check(page.allSatisfy { $0.active && $0.organization_id == context.organizationID })
            for row in page { precondition(rosterIDs.insert(row.id).inserted) }
            offset += page.count
            if page.count < 50 { break }
        }
        check(rosterIDs.count == 1080)
        let totalEquipment: Int = try db.query("select count(*) from equipment where organization_id=\(db.quote(context.organizationID.uuidString))")
        check(totalEquipment > 5000)
        // History pagination with real issue/return transactions, then a fresh
        // recognition to ensure inventory scale has not changed UID resolution.
        var repaired = RegistrationForm(equipment: afterReturn.snapshot.equipment)
        repaired.condition = .good
        _ = try await db.edit(UpdateEquipmentDetailsRequest(equipmentID: pending.id, expectedUpdatedAt: afterReturn.snapshot.equipment.updatedAt, details: repaired.validatedEdit(name: "Integration helmet")))
        // Maintenance deliberately stays maintenance after metadata editing.
        let maintained = try await db.recover(pending)
        check(maintained.equipment.status == .maintenance)
        let historyTag = IntegrationTag(); historyTag.bytes = Data([4,0xA3,0x82,0xBC,0xFE,0xED,0x71])
        let historyID = try GearLinkIDGenerator.generate(for: historyTag.scan.uid!)
        let historyItem = try await db.begin(BeginEquipmentRegistration(organizationID: context.organizationID, equipmentID: UUID(), gearlinkID: historyID,
            physicalUID: historyTag.scan.uid!, technology: .mifare, details: EquipmentDetails(category: "Helmet", size: "M", color: "Navy", condition: .good)))
        let historyWrite = NFCWriteStore(context: context, snapshot: historyItem, transport: historyTag, service: db)
        await historyWrite.start(); check(historyWrite.stage == .complete)
        for _ in 0..<55 {
            let receipt = try await db.perform(EquipmentAction(kind: .assign, equipmentID: historyItem.equipment.id, athleteID: athlete))
            _ = try await db.perform(EquipmentAction(kind: .return, equipmentID: historyItem.equipment.id, expectedAssignmentID: receipt.assignmentID))
        }
        let historyPage1 = try await db.history(equipmentID: historyItem.equipment.id, offset: 0)
        let historyPage2 = try await db.history(equipmentID: historyItem.equipment.id, offset: 50)
        check(historyPage1.count == 50 && historyPage2.count == 5)
        check(Set((historyPage1 + historyPage2).map(\.id)).count == 55)
        check((historyPage1 + historyPage2).allSatisfy { $0.returned_at != nil && $0.returned_by == context.userID })
        let scaledRecognition = RegistrationStore(context: context, scan: historyTag.scan, service: db)
        await scaledRecognition.inspect()
        if case .saved(let found) = scaledRecognition.stage { check(found.equipment.id == historyItem.equipment.id) } else { fatalError("Scale recognition failed") }
        print("PASS: \(count) Swift → PostgreSQL integration assertions (mock NFC radio)")
    }
}
