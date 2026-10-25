import Foundation

@MainActor
final class RegistrationFake: EquipmentRegistrationServing {
    var lookupResult: EquipmentTagLookup = .unregistered
    var calls: [BeginEquipmentRegistration] = []
    var response: EquipmentSnapshot!
    var failures: [RegistrationError] = []
    var suspended: CheckedContinuation<EquipmentSnapshot, Error>?
    var suspend = false
    func lookup(uid: EquipmentTagUID, id: GearLinkEquipmentID?) async throws -> EquipmentTagLookup { lookupResult }
    func begin(_ request: BeginEquipmentRegistration) async throws -> EquipmentSnapshot {
        calls.append(request)
        if !failures.isEmpty { throw failures.removeFirst() }
        if suspend { return try await withCheckedThrowingContinuation { suspended = $0 } }
        return response
    }
    func pending(offset: Int) async throws -> [EquipmentRecord] { [] }
    func recover(_ equipment: EquipmentRecord) async throws -> EquipmentSnapshot { response }
}

@main
struct RegistrationTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool) { precondition(value); count += 1 }
        let uid = EquipmentTagUID(rawValue: "000102ABCDEF")!
        let deterministic = try GearLinkIDGenerator.generate(for: uid, randomBytes: { Data([0,1,2,3,4,5,6,7]) })
        check(deterministic.rawValue == "GL-ABCDEF-0001020304050607")
        check((try? GearLinkIDGenerator.generate(for: uid, randomBytes: { Data([1]) })) == nil)
        check((try? GearLinkIDGenerator.generate(for: uid, randomBytes: { throw RegistrationError.idCollision })) == nil)
        var ids = Set<GearLinkEquipmentID>()
        for _ in 0..<1000 { ids.insert(try GearLinkIDGenerator.generate(for: uid)) }
        check(ids.count == 1000)
        let context = RegistrationContext(userID: UUID(), organizationID: UUID())
        func scan(_ records: [RegistrationPayload] = [], writable: Bool = true, complete: Bool = true, capacity: Int = 144) -> RegistrationScan {
            RegistrationScan(rawUID: Data([0,1,2,0xAB,0xCD,0xEF]), technology: .mifare,
                             writable: writable, readComplete: complete, capacity: capacity, records: records)
        }
        func payload(_ value: String) -> RegistrationPayload {
            RegistrationPayload(format: 1, type: Data([0x54]), identifier: Data(), payload: Data([2,0x65,0x6E]) + Data(value.utf8))
        }
        check(try scan().inspectedIdentity() == nil)
        check(try scan([RegistrationPayload(format: 0, type: Data(), identifier: Data(), payload: Data())]).inspectedIdentity() == nil)
        check(try scan([payload(deterministic.rawValue)]).inspectedIdentity() == deterministic)
        check(try scan([payload(deterministic.rawValue)], writable: false).inspectedIdentity() == deterministic)
        for bad in [scan(writable: false), scan(complete: false), scan(capacity: 32),
                    scan([payload("Other data")]), scan([payload(deterministic.rawValue),payload(deterministic.rawValue)]),
                    scan([RegistrationPayload(format: 1,type: Data([0x55]),identifier: Data(),payload: Data([0]))]),
                    scan([RegistrationPayload(format: 1,type: Data([0x54]),identifier: Data(),payload: Data([63]))])] {
            do { _ = try bad.inspectedIdentity(); fatalError("Unsafe scan accepted") } catch { count += 1 }
        }
        var form = RegistrationForm()
        check((try? form.validated()) == nil)
        form.size = "Custom 7½"; form.color = " Blue "
        check(try form.validated().color == "Blue")
        form.purchasePrice = "125,50"
        check(try form.validated(locale: Locale(identifier: "de_DE")).purchasePrice == Decimal(string: "125.50"))
        for invalid in ["-1", "1.234", "$20", "1,000", "NaN", "1e2"] {
            form.purchasePrice = invalid
            check((try? form.validated(locale: Locale(identifier: "en_US"))) == nil)
        }
        form.purchasePrice = ""; form.purchaseYear = "1899"
        check((try? form.validated()) == nil)
        form.purchaseYear = "2026"; form.category = "Other"
        check((try? form.validated()) == nil)
        form.customCategory = "Practice equipment"
        check(try form.validated().category == "Practice equipment")
        form.category = "Jersey"; form.jerseyNumber = "007"
        check(try form.validated().jerseyNumber == "007")
        form.category = "Helmet"
        check(try form.validated().jerseyNumber == nil)

        func fixture(org: UUID = context.organizationID, active: Bool = false, verified: Bool = true, physicalUID: String = uid.rawValue) throws -> EquipmentSnapshot {
            let equipmentID = UUID()
            let object: [String: Any] = [
                "equipment": ["id":equipmentID.uuidString,"organization_id":org.uuidString,"gearlink_id":deterministic.rawValue,
                              "original_tag_uid":uid.rawValue,"registration_status":active ? "active" : "pending_write","name":"Helmet", "category":"Helmet",
                              "size":"L","color":"Blue","condition":"good","status":active ? "available" : "pending_registration","created_at":"2026-10-24","updated_at":"2026-10-24"],
                "tag":["id":UUID().uuidString,"organization_id":org.uuidString,"equipment_id":equipmentID.uuidString,"uid":uid.rawValue,
                       "physical_uid":physicalUID,"write_verified_at":active && verified ? "2026-10-24" as Any : NSNull(),"technology":"mifare","is_active":true,"registered_at":"2026-10-24","activation_status":"available"],
                "current_assignment":NSNull()]
            return try JSONDecoder().decode(EquipmentSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let fake = RegistrationFake(); fake.response = try fixture()
        let store = RegistrationStore(context: context, scan: scan(), service: fake)
        await store.inspect(); store.form = form
        if case .form = store.stage { count += 1 } else { fatalError() }
        fake.failures = [.message("Network response lost")]
        await store.save()
        check(store.error != nil && fake.calls.count == 1)
        await store.save()
        check(fake.calls.count == 2 && fake.calls[0].equipmentID == fake.calls[1].equipmentID && fake.calls[0].gearlinkID == fake.calls[1].gearlinkID)
        if case .saved(let snapshot) = store.stage { check(snapshot.equipment.gearlinkID == deterministic) } else { fatalError() }
        await store.save(); check(fake.calls.count == 2)
        // Fresh process/view recovers server IDs and bypasses a new form.
        fake.lookupResult = .pending(fake.response)
        let restored = RegistrationStore(context: context, scan: scan(), service: fake)
        await restored.inspect()
        if case .saved(let snapshot) = restored.stage { check(snapshot.equipment.id == fake.response.equipment.id) } else { fatalError() }
        // Collision retries are bounded and use a fresh token only for collisions.
        fake.lookupResult = .unregistered; fake.calls = []; fake.failures = [.idCollision,.idCollision,.idCollision]
        let collision = RegistrationStore(context: context, scan: scan(), service: fake)
        await collision.inspect(); collision.form = form; await collision.save()
        check(fake.calls.count == 3 && Set(fake.calls.map(\.gearlinkID)).count == 3 && collision.error != nil)
        // A delayed completion after navigation/account teardown cannot publish state.
        fake.calls = []; fake.suspend = true
        let cancelled = RegistrationStore(context: context, scan: scan(), service: fake)
        await cancelled.inspect(); cancelled.form = form
        let saveTask = Task { await cancelled.save() }
        while fake.suspended == nil { await Task.yield() }
        await cancelled.save(); check(fake.calls.count == 1)
        cancelled.cancel(); fake.suspended?.resume(returning: fake.response); await saveTask.value
        if case .form = cancelled.stage { count += 1 } else { fatalError() }
        // Even a buggy API response cannot switch organization or tag identity.
        fake.suspend = false; fake.lookupResult = .pending(try fixture(org: UUID()))
        let foreign = RegistrationStore(context: context, scan: scan(), service: fake)
        await foreign.inspect()
        if case .blocked = foreign.stage { count += 1 } else { fatalError() }
        check(foreign.error != nil)
        // Phase 5: registered recognition requires the actual NDEF identity,
        // complete full UID match and server verification, not merely a label.
        fake.lookupResult = .registered(try fixture(active: true))
        let recognized = RegistrationStore(context: context, scan: scan([payload(deterministic.rawValue)], writable: false), service: fake)
        await recognized.inspect()
        if case .saved(let snapshot) = recognized.stage { check(snapshot.equipment.registrationStatus == .active) } else { fatalError() }
        for unsafe in [try fixture(), try fixture(active: true, verified: false), try fixture(active: true, physicalUID: "FFFFFFABCDEF")] {
            fake.lookupResult = .registered(unsafe)
            let recognition = RegistrationStore(context: context, scan: scan([payload(deterministic.rawValue)]), service: fake)
            await recognition.inspect()
            if case .blocked = recognition.stage { count += 1 } else { fatalError() }
        }
        fake.lookupResult = .registered(try fixture(active: true))
        let missingContent = RegistrationStore(context: context, scan: scan(), service: fake)
        await missingContent.inspect()
        if case .blocked = missingContent.stage { count += 1 } else { fatalError() }
        fake.lookupResult = .unregistered
        let unknownID = RegistrationStore(context: context, scan: scan([payload(deterministic.rawValue)]), service: fake)
        await unknownID.inspect()
        if case .blocked = unknownID.stage { count += 1 } else { fatalError() }
        print("PASS: \(count) registration assertions (identity, form, retries, recovery, cancellation)")
    }
}
