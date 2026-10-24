import Foundation
import Supabase
import Combine

struct Athlete: Decodable, Identifiable {
    let id: UUID
    let organization_id: UUID
    let first_name: String
    let last_name: String
    let team: String?
    let active: Bool
    var name: String { "\(first_name) \(last_name)" }
    var initials: String { String(first_name.prefix(1)) + String(last_name.prefix(1)) }
}

struct RosterMembership: Decodable {
    let organization_id: UUID
    let role: String
    let organizations: Organization
    struct Organization: Decodable { let name: String }
}

struct AthleteChanges: Encodable {
    let first_name: String
    let last_name: String
    let team: String?
    let active: Bool

    // Send an explicit null so clearing a team removes the previous value.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(first_name, forKey: .first_name)
        try container.encode(last_name, forKey: .last_name)
        try container.encode(team, forKey: .team)
        try container.encode(active, forKey: .active)
    }
    enum CodingKeys: String, CodingKey { case first_name, last_name, team, active }
}

@MainActor
final class RosterStore: ObservableObject {
    @Published private(set) var athletes: [Athlete] = []
    @Published private(set) var membership: RosterMembership?
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?
    @Published var notice: String?
    let userID: UUID
    private let client = SupabaseClientProvider.client
    var canEdit: Bool { membership?.role == "admin" && !isLoading && errorMessage == nil }
    var activeCount: Int { athletes.filter(\.active).count }
    var teamCount: Int { Set(athletes.filter(\.active).compactMap(\.team).filter { !$0.isEmpty }).count }

    init(userID: UUID) { self.userID = userID }

    func load() async {
        guard let client, !isLoading, !isSaving else { return }
        isLoading = true
        errorMessage = nil
        notice = nil
        defer { isLoading = false; hasLoaded = true }
        do {
            // Membership RLS may return colleagues too; explicitly select this user.
            let memberships: [RosterMembership] = try await client.from("organization_members")
                .select("organization_id, role, organizations(name)")
                .eq("user_id", value: userID).order("created_at").order("organization_id").limit(1).execute().value
            guard let workspace = memberships.first else {
                membership = nil
                athletes = []
                return
            }
            var rows: [Athlete] = []
            var offset = 0
            while true {
                let page: [Athlete] = try await client.from("athletes").select()
                    .eq("organization_id", value: workspace.organization_id)
                    .order("last_name").order("first_name").order("id")
                    .range(from: offset, to: offset + 499).execute().value
                try Task.checkCancellation()
                rows.append(contentsOf: page)
                if page.count < 500 { break }
                offset += page.count
            }
            membership = workspace
            athletes = rows
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Couldn't refresh your roster. Check your connection and try again."
        }
    }

    func save(id: UUID?, firstName: String, lastName: String, team: String, active: Bool) async throws {
        guard let client, let membership, canEdit, !isSaving else {
            throw RosterError.message("Administrator access is required to edit this roster. Refresh and try again.")
        }
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let teamName = team.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(first.count), (1...80).contains(last.count), teamName.count <= 120 else {
            throw RosterError.message("Enter both names (up to 80 characters each) and a team of up to 120 characters.")
        }
        isSaving = true
        defer { isSaving = false }
        let changes = AthleteChanges(first_name: first, last_name: last, team: teamName.isEmpty ? nil : teamName, active: active)
        let saved: Athlete
        if let id {
            saved = try await client.from("athletes").update(changes)
                .eq("id", value: id).eq("organization_id", value: membership.organization_id)
                .select().single().execute().value
        } else {
            struct NewAthlete: Encodable {
                let organization_id: UUID
                let first_name: String
                let last_name: String
                let team: String?
                let active: Bool
            }
            saved = try await client.from("athletes").insert(NewAthlete(
                organization_id: membership.organization_id, first_name: first,
                last_name: last, team: changes.team, active: active
            )).select().single().execute().value
        }
        // Only show success after Supabase returns the saved record.
        athletes.removeAll { $0.id == saved.id }
        athletes.append(saved)
        athletes.sort { ($0.last_name, $0.first_name) < ($1.last_name, $1.first_name) }
        notice = id == nil ? "Athlete added to the roster." : "Athlete changes saved."
    }
}

enum RosterError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
