import Foundation

@MainActor final class FakeWriter: NFCWritingTransport {
    var isAvailable = true
    var uid = EquipmentTagUID(rawValue: "04A382BC119F80")!
    var inspections: [RegistrationScan] = []
    var writes = 0
    var cancels = 0
    var inspectionsCount = 0
    var failWrite = false
    var suspendedWrite: CheckedContinuation<Void, Error>?
    var suspendWrite = false
    var suspended: CheckedContinuation<EquipmentTagUID, Error>?
    var suspend = false
    func connectForWriting() async throws -> EquipmentTagUID {
        if suspend { return try await withCheckedThrowingContinuation { suspended = $0 } }
        return uid
    }
    func inspectForWriting() async throws -> RegistrationScan {
        inspectionsCount += 1
        guard !inspections.isEmpty else { throw NFCWriteError.message("Disconnected") }
        return inspections.removeFirst()
    }
    func writeGearLinkID(_ id: GearLinkEquipmentID) async throws {
        writes += 1
        if suspendWrite { try await withCheckedThrowingContinuation { suspendedWrite = $0 } }
        if failWrite { throw NFCWriteError.message("Disconnected during write") }
    }
    func closeWriting(message: String, failed: Bool) {}
    func cancel() { cancels += 1 }
}

@MainActor final class FakeWritingService: EquipmentWritingServing {
    var current: EquipmentSnapshot!
    var confirmed: EquipmentSnapshot!
    var confirmations = 0
    var recoveries = 0
    var confirmationFails = false
    var suspendConfirmation = false
    var suspendedConfirmation: CheckedContinuation<EquipmentSnapshot, Error>?
    var recoveryFails = false
    var evidence: EquipmentRegistrationEvidence?
    func recover(_ equipment: EquipmentRecord) async throws -> EquipmentSnapshot {
        recoveries += 1
        if recoveryFails { throw RegistrationError.sessionChanged }
        return current
    }
    func confirm(_ evidence: EquipmentRegistrationEvidence) async throws -> EquipmentSnapshot {
        confirmations += 1; self.evidence = evidence
        if suspendConfirmation { return try await withCheckedThrowingContinuation { suspendedConfirmation = $0 } }
        if confirmationFails { throw NFCWriteError.message("Network unavailable") }
        current = confirmed
        return confirmed
    }
}

@main struct NFCWritingTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool) { precondition(value); count += 1 }
        let org = UUID(), equipment = UUID(), tag = UUID()
        let uid = EquipmentTagUID(rawValue: "04A382BC119F80")!
        let id = GearLinkEquipmentID(rawValue: "GL-119F80-7C92D4A18F20B6E3")!
        let context = RegistrationContext(userID: UUID(), organizationID: org)
        func snapshot(active: Bool = false, tagID: UUID = tag, physicalUID: EquipmentTagUID? = nil) throws -> EquipmentSnapshot {
            let value: [String:Any] = [
                "equipment":["id":equipment.uuidString,"organization_id":org.uuidString,"gearlink_id":id.rawValue,
                             "original_tag_uid":uid.rawValue,"registration_status":active ? "active" : "pending_write",
                             "name":"Helmet","category":"Helmet","size":"L","color":"Blue","condition":"good",
                             "status":active ? "available" : "pending_registration","created_at":"2026-10-24","updated_at":"2026-10-24"],
                "tag":["id":tagID.uuidString,"organization_id":org.uuidString,"equipment_id":equipment.uuidString,
                       "uid":(physicalUID ?? uid).rawValue,"physical_uid":(physicalUID ?? uid).rawValue,"technology":"mifare","is_active":true,
                       "registered_at":"2026-10-24","activation_status":"available",
                       "write_verified_at":active ? "2026-10-24" as Any : NSNull()],
                "current_assignment":NSNull()]
            return try JSONDecoder().decode(EquipmentSnapshot.self, from: JSONSerialization.data(withJSONObject:value))
        }
        func scan(text: String? = nil, uidBytes: [UInt8] = [4,0xA3,0x82,0xBC,0x11,0x9F,0x80], writable: Bool = true, capacity: Int = 144) -> RegistrationScan {
            let records = text.map { [RegistrationPayload(format:1,type:Data([0x54]),identifier:Data(),payload:Data([2,0x65,0x6e])+Data($0.utf8))] } ?? []
            return RegistrationScan(rawUID:Data(uidBytes),technology:.mifare,writable:writable,readComplete:true,capacity:capacity,records:records)
        }
        let pending = try snapshot(), active = try snapshot(active:true)
        func setup(_ inspections: [RegistrationScan]) -> (NFCWriteStore, FakeWriter, FakeWritingService) {
            let transport=FakeWriter(); transport.inspections=inspections
            let service=FakeWritingService(); service.current=pending; service.confirmed=active
            return (NFCWriteStore(context:context,snapshot:pending,transport:transport,service:service),transport,service)
        }
        // A: exact full UID writes once, verifies and confirms once.
        let (good, radio, backend)=setup([scan(),scan(),scan(text:id.rawValue)])
        await good.start()
        check(good.stage == .complete && radio.writes == 1 && backend.confirmations == 1)
        check(backend.evidence?.physicalUID == uid && backend.evidence?.gearlinkID == id && backend.evidence?.tagID == tag)
        await good.start(); check(radio.writes == 1)
        // B/C: wrong UID, including a shared six-character suffix, never writes.
        for wrong in ["04A382BC119F81","049977BC119F80"] {
            let (store,t,s)=setup([]); t.uid=EquipmentTagUID(rawValue:wrong)!
            await store.start()
            check(store.stage == .failed && t.writes == 0 && s.confirmations == 0)
            check(store.message.contains(wrong) && store.message.contains(uid.rawValue))
        }
        // D: other identity, third-party content, readonly and insufficient space.
        for unsafe in [scan(text:"GL-119F80-1111111111111111"),scan(text:"Third-party data"),scan(writable:false),scan(capacity:32)] {
            let (store,t,s)=setup([unsafe]); await store.start()
            check(store.stage == .failed && t.writes == 0 && s.confirmations == 0)
        }
        // Recheck catches content changes while fetching server authorization.
        let (changed,tChanged,sChanged)=setup([scan(),scan(text:"Do not erase")])
        await changed.start(); check(changed.stage == .failed && tChanged.writes == 0 && sChanged.confirmations == 0)
        // Matching existing ID (even readonly) is verified without a rewrite.
        let matching=scan(text:id.rawValue,writable:false)
        let (existing,tExisting,sExisting)=setup([matching,matching,matching])
        await existing.start(); check(existing.stage == .complete && tExisting.writes == 0 && sExisting.confirmations == 1)
        // F: disconnect during/after writing is ambiguous and must not activate.
        let (interrupted,tInterrupted,sInterrupted)=setup([scan(),scan()]); tInterrupted.failWrite=true
        await interrupted.start(); check(interrupted.stage == .failed && tInterrupted.writes == 1 && sInterrupted.confirmations == 0)
        check(interrupted.message.contains("may have reached"))
        tInterrupted.failWrite=false; tInterrupted.inspections=[matching,matching,matching]
        await interrupted.start(); check(interrupted.stage == .complete && tInterrupted.writes == 1 && sInterrupted.confirmations == 1)
        let (lost,tLost,sLost)=setup([scan(),scan()])
        await lost.start(); check(lost.stage == .failed && tLost.writes == 1 && sLost.confirmations == 0)
        // Wrong read-back ID or full UID cannot activate.
        for wrongRead in [scan(text:"GL-119F80-1111111111111111"),scan(text:id.rawValue,uidBytes:[4,0x99,0x77,0xBC,0x11,0x9F,0x80])] {
            let (store,_,s)=setup([scan(),scan(),wrongRead]); await store.start()
            check(store.stage == .failed && s.confirmations == 0)
        }
        // Database-only retries keep physical success separate and do not rewrite.
        let (offline,tOffline,sOffline)=setup([scan(),scan(),scan(text:id.rawValue)]); sOffline.confirmationFails=true
        await offline.start(); check(offline.stage == .confirmationFailed && tOffline.writes == 1)
        sOffline.confirmationFails=false; await offline.retryConfirmation()
        check(offline.stage == .complete && tOffline.writes == 1 && sOffline.confirmations == 2)
        // Authorization or association changes abort before physical writes.
        let (unauthorized,tUnauthorized,sUnauthorized)=setup([]); sUnauthorized.recoveryFails=true
        await unauthorized.start(); check(unauthorized.stage == .failed && tUnauthorized.writes == 0 && sUnauthorized.confirmations == 0)
        let (replaced,tReplaced,sReplaced)=setup([]); sReplaced.current=try snapshot(tagID:UUID())
        await replaced.start(); check(replaced.stage == .failed && tReplaced.writes == 0)
        // Cancellation and duplicate taps during a suspended connection.
        let (cancelled,tCancelled,sCancelled)=setup([scan(),scan(),scan(text:id.rawValue)]); tCancelled.suspend=true
        let task=Task { await cancelled.start() }
        while tCancelled.suspended == nil { await Task.yield() }
        await cancelled.start(); check(sCancelled.recoveries == 1)
        cancelled.cancel(); tCancelled.suspended?.resume(returning:uid); await task.value
        check(cancelled.stage == .failed && tCancelled.writes == 0 && sCancelled.confirmations == 0)
        // An active database record with blank content must not be rewritten.
        let (activeBlank,tActive,sActive)=setup([scan(),scan()]); sActive.current=active
        await activeBlank.start(); check(activeBlank.stage == .failed && tActive.writes == 0)
        // Cancellation after the write started must not advance stale callbacks.
        let (cancelWrite,tCancelWrite,sCancelWrite)=setup([scan(),scan(),scan(text:id.rawValue)])
        tCancelWrite.suspendWrite=true
        let writingTask=Task { await cancelWrite.start() }
        while tCancelWrite.suspendedWrite == nil { await Task.yield() }
        cancelWrite.cancel(); tCancelWrite.suspendedWrite?.resume(); await writingTask.value
        check(cancelWrite.stage == .failed && sCancelWrite.confirmations == 0)
        // Cancellation during backend confirmation retains verified evidence, but
        // never publishes a late success. A deliberate retry can reconcile it.
        let (cancelConfirm,tCancelConfirm,sCancelConfirm)=setup([scan(),scan(),scan(text:id.rawValue)])
        sCancelConfirm.suspendConfirmation=true
        let confirmTask=Task { await cancelConfirm.start() }
        while sCancelConfirm.suspendedConfirmation == nil { await Task.yield() }
        cancelConfirm.cancel(); sCancelConfirm.suspendedConfirmation?.resume(returning:active); await confirmTask.value
        check(cancelConfirm.stage == .confirmationFailed)
        sCancelConfirm.suspendConfirmation=false
        await cancelConfirm.retryConfirmation()
        check(cancelConfirm.stage == .complete && tCancelConfirm.writes == 1)
        // A replacement tag keeps the original GearLink ID suffix. Match the
        // current full association UID, never that immutable historical suffix.
        let replacementUID=EquipmentTagUID(rawValue:"001122AABBCCDD")!
        let replacement=try snapshot(physicalUID:replacementUID)
        let replacementActive=try snapshot(active:true,physicalUID:replacementUID)
        let replacementRadio=FakeWriter(); replacementRadio.uid=replacementUID
        let bytes: [UInt8]=[0,0x11,0x22,0xAA,0xBB,0xCC,0xDD]
        replacementRadio.inspections=[scan(uidBytes:bytes),scan(uidBytes:bytes),scan(text:id.rawValue,uidBytes:bytes)]
        let replacementService=FakeWritingService(); replacementService.current=replacement; replacementService.confirmed=replacementActive
        let replacementStore=NFCWriteStore(context:context,snapshot:replacement,transport:replacementRadio,service:replacementService)
        await replacementStore.start()
        check(replacementStore.stage == .complete && replacementService.evidence?.physicalUID == replacementUID)
        print("PASS: \(count) NFC writing assertions (mock radio, real coordinator)")
    }
}
