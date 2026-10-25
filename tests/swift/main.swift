import Foundation

var count = 0
func check(_ condition: @autoclosure () -> Bool) {
    precondition(condition())
    count += 1
}
let decoder = JSONDecoder()
let encoder = JSONEncoder()
let uid = EquipmentTagUID(rawValue: "00:01:02:ab:cd:ef")!
check(uid.rawValue == "000102ABCDEF")
check(uid != EquipmentTagUID(rawValue: "FFFFFFABCDEF"))
for invalid in ["", "ABC", "0xABCDEF", "AB\nCD", "GGAA", "ﬀaa", String(repeating: "AA", count: 33)] {
    check(EquipmentTagUID(rawValue: invalid) == nil)
}
let id = GearLinkEquipmentID(rawValue: "GL-ABCDEF-0123456789ABCDEF")!
check(GearLinkEquipmentID(rawValue: id.rawValue.lowercased()) == nil)
check(GearLinkEquipmentID(rawValue: id.rawValue + "\n") == nil)
let roundTripUID = try decoder.decode(EquipmentTagUID.self, from: encoder.encode(uid))
check(roundTripUID == uid)
let record = """
{"id":"11111111-1111-1111-1111-111111111111","organization_id":"22222222-2222-2222-2222-222222222222",
"name":"Helmet","category":"Helmet","condition":"good","status":"available",
"created_at":"2026-10-24T10:00:00.123456+00:00","updated_at":"2026-10-24T10:00:00.123456+00:00"}
"""
let legacy = try decoder.decode(EquipmentRecord.self, from: Data(record.utf8))
check(legacy.isLegacy)
check(legacy.updatedAt == "2026-10-24T10:00:00.123456+00:00")
check(legacy.size == nil)
let registered = record.dropLast() + ",\"gearlink_id\":\"\(id.rawValue)\",\"original_tag_uid\":\"\(uid.rawValue)\",\"registration_status\":\"active\",\"purchase_price\":125.50}"
let equipment = try decoder.decode(EquipmentRecord.self, from: Data(registered.utf8))
check(!equipment.isLegacy && equipment.gearlinkID == id)
check(equipment.purchasePrice == Decimal(string: "125.50"))
let request = BeginEquipmentRegistration(organizationID: UUID(), equipmentID: UUID(), gearlinkID: id, physicalUID: uid,
    technology: .mifare, details: EquipmentDetails(category: "Helmet", size: "L", color: "Blue", condition: .good))
let encoded = try JSONSerialization.jsonObject(with: encoder.encode(request)) as! [String: Any]
check(encoded["p_physical_uid"] as? String == uid.rawValue)
check(encoded["p_gearlink_id"] as? String == id.rawValue)
check((encoded["p_details"] as? [String: Any])?["condition"] as? String == "good")
for malformed in ["{\"resolution\":\"unknown\"}", "{\"resolution\":\"registered\"}"] {
    check((try? decoder.decode(EquipmentTagLookup.self, from: Data(malformed.utf8))) == nil)
}
if case .unregistered = try decoder.decode(EquipmentTagLookup.self, from: Data("{\"resolution\":\"unregistered\"}".utf8)) { count += 1 } else { fatalError() }
let snapshot = "{\"equipment\":\(registered),\"tag\":null,\"current_assignment\":null,\"resolution\":\"pending\"}"
if case .pending(let value) = try decoder.decode(EquipmentTagLookup.self, from: Data(snapshot.utf8)) {
    check(value.equipment.id == legacy.id)
} else { fatalError() }
print("PASS: \(count) Swift model assertions")
