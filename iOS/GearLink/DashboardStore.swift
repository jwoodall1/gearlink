import Foundation
import Combine
import Supabase

struct AttentionEquipment: Decodable, Identifiable {
    let id: UUID
    let name: String
    let category: String
    let condition: String
    let status: String
    let size: String?
    let color: String?
    let notes: String?
    var attentionLabel: String { condition == "needs_repair" ? "Needs repair" : "Maintenance" }
}

struct EquipmentSummary {
    let total: Int
    let available: Int
    let issued: Int
    let attentionCount: Int
    let attention: [AttentionEquipment]
}

@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var summary: EquipmentSummary?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    private var organizationID: UUID?

    func load(organizationID: UUID?) async {
        guard !isLoading else { return }
        if self.organizationID != organizationID {
            summary = nil
            lastUpdated = nil
            self.organizationID = organizationID
        }
        guard let organizationID, let client = SupabaseClientProvider.client else {
            summary = nil
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let total = client.from("equipment").select("id", head: true, count: .exact)
                .eq("organization_id", value: organizationID).execute()
            async let available = client.from("equipment").select("id", head: true, count: .exact)
                .eq("organization_id", value: organizationID).eq("status", value: "available").execute()
            async let issued = client.from("equipment_assignments").select("id", head: true, count: .exact)
                .eq("organization_id", value: organizationID).is("returned_at", value: nil).execute()
            async let attention: PostgrestResponse<[AttentionEquipment]> = client.from("equipment")
                .select("id, name, category, condition, status, size, color, notes", count: .exact)
                .eq("organization_id", value: organizationID).neq("status", value: "retired")
                .or("status.eq.maintenance,condition.eq.needs_repair")
                .order("updated_at", ascending: false).order("id").limit(5).execute()
            let (all, ready, open, flagged) = try await (total, available, issued, attention)
            try Task.checkCancellation()
            summary = EquipmentSummary(total: all.count ?? 0, available: ready.count ?? 0,
                                       issued: open.count ?? 0, attentionCount: flagged.count ?? 0,
                                       attention: flagged.value)
            lastUpdated = Date()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Couldn't refresh equipment. Check your connection and try again."
        }
    }
}
