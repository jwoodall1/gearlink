import Foundation
import Supabase

@MainActor
final class EquipmentRegistrationService: EquipmentRegistrationServing, EquipmentWritingServing, EquipmentManagingService {
    let context: RegistrationContext
    private let client: SupabaseClient?
    private let authClient: SupabaseClient?

    init(context: RegistrationContext) {
        self.context = context
        self.authClient = SupabaseClientProvider.client
        self.client = SupabaseClientProvider.registrationClient(userID: context.userID)
    }

    private func authorizedClient() async throws -> SupabaseClient {
        try Task.checkCancellation()
        guard let client, let authClient else { throw RegistrationError.unavailable }
        guard try await authClient.auth.session.user.id == context.userID else { throw RegistrationError.sessionChanged }
        return client
    }

    private func checked<T>(_ operation: (SupabaseClient) async throws -> T) async throws -> T {
        do {
            let client = try await authorizedClient()
            let value = try await operation(client)
            _ = try await authorizedClient()
            return value
        } catch let error as PostgrestError {
            switch error.message {
            case "GL_GEARLINK_ID_COLLISION": throw RegistrationError.idCollision
            case "GL_NOT_AUTHORIZED": throw RegistrationError.message("You no longer have access to this program. Refresh your workspace or contact an administrator.")
            case "GL_LEGACY_TAG_REQUIRES_MIGRATION": throw RegistrationError.message("This tag is linked to existing equipment that needs administrator migration. No new record was created.")
            case "GL_STALE_ASSIGNMENT":
                throw EquipmentOperationError.rejected("The assignment changed. Refresh and review who currently has this item before trying again.")
            case "GL_EQUIPMENT_UNAVAILABLE":
                throw EquipmentOperationError.rejected("This item is no longer available or its condition prevents issuing it. Refresh to review its status.")
            case "GL_ATHLETE_UNAVAILABLE":
                throw EquipmentOperationError.rejected("This athlete is no longer eligible for equipment in your program. Refresh the roster.")
            case "GL_ALREADY_ASSIGNED_TO_ATHLETE":
                throw EquipmentOperationError.rejected("This athlete already has the item. Refresh to review the current assignment.")
            case "GL_REQUEST_CONFLICT":
                throw EquipmentOperationError.rejected("This action conflicts with a previously saved action. Refresh the equipment and review its history before continuing.")
            case "GL_STALE_EQUIPMENT":
                throw EquipmentOperationError.rejected("Someone changed this equipment after you opened it. Reload the latest saved values before editing again.")
            case "GL_EQUIPMENT_RETIRED": throw RegistrationError.message("This equipment is retired. Ask an administrator to review it.")
            case "GL_TAG_UNAVAILABLE", "GL_INACTIVE_TAG", "GL_IDENTITY_CONFLICT", "GL_TAG_CONTENT_MISMATCH", "GL_TAG_UNAVAILABLE_OR_CONFLICT":
                throw RegistrationError.identityConflict
            default:
                if ["PGRST202", "42703", "42883"].contains(error.code ?? "") { throw RegistrationError.unavailable }
                throw RegistrationError.message("The server couldn't complete this equipment request. Check your connection and retry, then refresh to confirm its current state.")
            }
        } catch let error as RegistrationError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            throw RegistrationError.message("Couldn't confirm the server response. Check your connection and retry the pending action or refresh the equipment. Don't create a duplicate item or action to recover.")
        }
    }

    func lookup(uid: EquipmentTagUID, id: GearLinkEquipmentID?) async throws -> EquipmentTagLookup {
        try await checked { client in
            try await client.rpc("lookup_equipment_tag", params: LookupEquipmentTagRequest(
                organizationID: context.organizationID, physicalUID: uid, gearlinkID: id)).execute().value
        }
    }

    func begin(_ request: BeginEquipmentRegistration) async throws -> EquipmentSnapshot {
        guard request.organizationID == context.organizationID else { throw RegistrationError.sessionChanged }
        return try await checked { client in
            try await client.rpc("begin_equipment_registration", params: request).execute().value
        }
    }

    func confirm(_ evidence: EquipmentRegistrationEvidence) async throws -> EquipmentSnapshot {
        try await checked { client in
            try await client.rpc("confirm_equipment_registration", params: evidence).execute().value
        }
    }

    func pending(offset: Int) async throws -> [EquipmentRecord] {
        try await checked { client in
            try await client.from("equipment").select()
                .eq("organization_id", value: context.organizationID)
                .in("registration_status", values: ["pending_write", "write_failed"])
                .order("created_at", ascending: false).order("id")
                .range(from: offset, to: offset + 49).execute().value
        }
    }

    func recover(_ equipment: EquipmentRecord) async throws -> EquipmentSnapshot {
        guard equipment.organizationID == context.organizationID, let id = equipment.gearlinkID else { throw RegistrationError.identityConflict }
        let tags: [EquipmentTagRecord] = try await checked { client in
            try await client.from("equipment_tags").select()
                .eq("organization_id", value: context.organizationID)
                .eq("equipment_id", value: equipment.id).eq("is_active", value: true).limit(2).execute().value
        }
        guard tags.count == 1, let tag = tags.first else { throw RegistrationError.identityConflict }
        let lookup = try await lookup(uid: tag.physicalUID, id: id)
        switch lookup {
        case .pending(let snapshot), .registered(let snapshot):
            guard snapshot.equipment.id == equipment.id, snapshot.equipment.organizationID == context.organizationID,
                  snapshot.equipment.gearlinkID == id, snapshot.tag?.id == tag.id else { throw RegistrationError.identityConflict }
            return snapshot
        case .unregistered: throw RegistrationError.identityConflict
        }
    }
}


extension EquipmentRegistrationService {
    func athlete(id: UUID) async throws -> EquipmentAthlete? {
        let rows: [EquipmentAthlete] = try await checked { client in
            try await client.from("athletes").select().eq("organization_id", value: context.organizationID)
                .eq("id", value: id).limit(1).execute().value
        }
        return rows.first
    }
    func athletes(search: String, offset: Int) async throws -> [EquipmentAthlete] {
        try await checked { client in
            var query = client.from("athletes").select().eq("organization_id", value: context.organizationID).eq("active", value: true)
            if let expression = AthleteSearch.expression(search) { query = query.or(expression) }
            return try await query.order("last_name").order("first_name").order("id")
                .range(from: offset, to: offset + 49).execute().value
        }
    }
    func history(equipmentID: UUID, offset: Int) async throws -> [EquipmentHistoryEntry] {
        try await checked { client in
            try await client.from("equipment_assignments").select("*, athletes(*)")
                .eq("organization_id", value: context.organizationID).eq("equipment_id", value: equipmentID)
                .order("checked_out_at", ascending: false).order("id")
                .range(from: offset, to: offset + 49).execute().value
        }
    }
    func perform(_ action: EquipmentAction) async throws -> EquipmentOperationReceipt {
        guard action.isValid else { throw RegistrationError.identityConflict }
        return try await checked { client in
            switch action.kind {
            case .assign:
                guard let athlete = action.athleteID else { throw RegistrationError.identityConflict }
                return try await client.rpc("assign_equipment", params: AssignEquipmentRequest(
                    equipmentID: action.equipmentID, athleteID: athlete, requestID: action.requestID)).execute().value
            case .return:
                guard let assignment = action.expectedAssignmentID else { throw RegistrationError.identityConflict }
                return try await client.rpc("return_equipment_checked", params: ReturnEquipmentRequest(
                    assignmentID: assignment, requestID: action.requestID)).execute().value
            case .transfer:
                guard let athlete = action.athleteID, let assignment = action.expectedAssignmentID else { throw RegistrationError.identityConflict }
                return try await client.rpc("transfer_equipment", params: TransferEquipmentRequest(
                    equipmentID: action.equipmentID, athleteID: athlete, expectedAssignmentID: assignment, requestID: action.requestID)).execute().value
            }
        }
    }
    func edit(_ request: UpdateEquipmentDetailsRequest) async throws -> EquipmentSnapshot {
        try await checked { client in
            try await client.rpc("update_equipment_details", params: request).execute().value
        }
    }
}
