import SwiftUI
import UIKit

struct DashboardView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var dashboard = DashboardStore()
    @State private var selectedTab = Tab.overview
    private enum Tab { case overview, roster, settings }
    @StateObject private var roster: RosterStore
    let username: String
    let signingOut: Bool
    let signOutError: String?
    let signOut: () -> Void

    init(userID: UUID, username: String, signingOut: Bool, signOutError: String?, signOut: @escaping () -> Void) {
        _roster = StateObject(wrappedValue: RosterStore(userID: userID))
        self.username = username
        self.signingOut = signingOut
        self.signOutError = signOutError
        self.signOut = signOut
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            overview
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
                .tag(Tab.overview)
            NavigationStack { RosterView(store: roster) }
                .tabItem { Label("Athletes", systemImage: "person.2") }
                .tag(Tab.roster)
            SettingsView(username: username, signingOut: signingOut,
                         savingRoster: roster.isSaving, signOutError: signOutError,
                         signOut: signOut)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Brand.blue)
        .task { await refresh() }
    }

    private var overview: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image("GearLinkLogo").resizable().scaledToFit().frame(width: 190)
                        .accessibilityLabel("GearLink")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR TEAM. YOUR GEAR. CONNECTED.")
                            .font(.caption2.bold()).tracking(1.3).foregroundStyle(Brand.blue)
                        Text(roster.membership?.organizations.name ?? "Welcome back").font(.title.bold())
                        Text("Your equipment and athletes at a glance.")
                            .foregroundStyle(.secondary)
                    }
                    if let error = roster.errorMessage {
                        WorkspaceMessage(title: "Workspace couldn't refresh", message: error,
                                         icon: "wifi.exclamationmark", retry: { Task { await refresh() } }).gearPanel()
                    }
                    if roster.isLoading && !roster.hasLoaded {
                        ProgressView("Loading your workspace…").gearPanel()
                    } else if roster.membership != nil {
                        equipmentOverview
                        LazyVGrid(columns: metricColumns, spacing: 12) {
                            MetricTile(title: "Active athletes", value: roster.activeCount, icon: "person.2.fill")
                            MetricTile(title: "Teams", value: roster.teamCount, icon: "sportscourt.fill")
                        }
                        Button { selectedTab = .roster } label: {
                            actionCard("Team roster", detail: "Find athletes and manage your roster", icon: "person.3.fill")
                        }.buttonStyle(.plain)
                    } else if roster.hasLoaded && roster.errorMessage == nil {
                        WorkspaceMessage(title: "No organization yet",
                                         message: "Set up your organization in the web dashboard or ask an administrator to add you.",
                                         icon: "building.2").gearPanel()
                    }
                    NavigationLink {
                        NFCScannerView()
                    } label: {
                        actionCard("Open scanner", detail: "Read an NFC tag ID and its data", icon: "wave.3.right.circle")
                    }.buttonStyle(.plain)
                    if let updated = dashboard.lastUpdated {
                        Text("Equipment updated \(updated.formatted(date: .omitted, time: .shortened)). Pull down to refresh.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
            }
            .background(Brand.paper)
            .navigationTitle("Overview").navigationBarTitleDisplayMode(.inline)
            .refreshable { await refresh() }
        }.tint(Brand.blue).foregroundStyle(Brand.ink)
    }

    private var metricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), alignment: .top), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    private func refresh() async {
        await roster.load()
        await dashboard.load(organizationID: roster.membership?.organization_id)
    }

    @ViewBuilder private var equipmentOverview: some View {
        if let error = dashboard.errorMessage {
            WorkspaceMessage(title: dashboard.summary == nil ? "Equipment unavailable" : "Showing previous equipment data",
                             message: error, icon: "wifi.exclamationmark",
                             retry: { Task { await dashboard.load(organizationID: roster.membership?.organization_id) } }).gearPanel()
        }
        if dashboard.isLoading && dashboard.summary == nil {
            ProgressView("Loading equipment…").gearPanel()
        }
        if let summary = dashboard.summary {
            LazyVGrid(columns: metricColumns, spacing: 12) {
                MetricTile(title: "Total equipment", value: summary.total, icon: "shippingbox.fill")
                MetricTile(title: "Currently issued", value: summary.issued, icon: "arrow.up.right")
                MetricTile(title: "Available", value: summary.available, icon: "checkmark.circle.fill")
                MetricTile(title: "Needs attention", value: summary.attentionCount, icon: "wrench.and.screwdriver.fill")
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("Needs attention").font(.headline)
                if summary.attention.isEmpty {
                    Text("No equipment is marked for maintenance or repair.").foregroundStyle(.secondary)
                } else {
                    ForEach(summary.attention) { item in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Category: \(item.category)")
                                Text("Status: \(item.status.replacingOccurrences(of: "_", with: " "))")
                                if let size = item.size { Text("Size: \(size)") }
                                if let color = item.color { Text("Color: \(color)") }
                                if let notes = item.notes, !notes.isEmpty { Text(notes) }
                            }.font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).foregroundStyle(Brand.ink)
                                Text(item.attentionLabel).font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }
                    }
                    if summary.attentionCount > summary.attention.count {
                        Text("Showing the 5 most recently updated items. Review all flagged equipment in the web dashboard.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.gearPanel()
        }
    }

    private func actionCard(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.title2).foregroundStyle(Brand.blue)
                .frame(width: 50, height: 50).background(Brand.soft, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(Brand.blue)
        }.gearPanel()
    }
}

private struct RosterView: View {
    @ObservedObject var store: RosterStore
    @State private var search = ""
    @State private var showInactive = false
    @State private var editor: EditorSelection?

    private struct EditorSelection: Identifiable {
        let id = UUID()
        let athlete: Athlete?
    }
    private var filtered: [Athlete] {
        store.athletes.filter {
            (showInactive || $0.active) && (search.isEmpty || "\($0.name) \($0.team ?? "")".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("Include inactive athletes", isOn: $showInactive)
                if !store.canEdit && !store.isLoading {
                    Text("Only organization administrators can edit the roster.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let notice = store.notice {
                    HStack {
                        Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Brand.blue)
                        Spacer()
                        Button { store.notice = nil } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Dismiss confirmation").frame(minWidth: 44, minHeight: 44)
                    }
                }
                if let error = store.errorMessage {
                    WorkspaceMessage(title: "Roster unavailable", message: error, icon: "wifi.exclamationmark", retry: { Task { await store.load() } })
                }
            }
            Section("\(filtered.count) athletes") {
                if store.isLoading { ProgressView("Refreshing roster…") }
                if filtered.isEmpty && !store.isLoading && store.errorMessage == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(search.isEmpty ? "No athletes to show" : "No matching athletes").font(.headline)
                        Text(search.isEmpty ? (store.canEdit ? "Add an athlete to get started, or include inactive athletes." : "Ask your administrator to add athletes, or include inactive athletes.") : "Try a different name or team.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                ForEach(filtered) { athlete in
                    if store.canEdit {
                        Button { editor = EditorSelection(athlete: athlete) } label: {
                            AthleteSummaryRow(athlete: athlete, editable: true)
                        }.accessibilityHint("Edit athlete")
                    } else {
                        AthleteSummaryRow(athlete: athlete, editable: false)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden).background(Brand.paper)
        .navigationTitle("Team roster")
        .searchable(text: $search, prompt: "Search names or teams")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.membership?.role == "admin" {
                    Button { editor = EditorSelection(athlete: nil) } label: { Label("Add athlete", systemImage: "plus") }
                        .disabled(!store.canEdit)
                }
            }
        }
        .refreshable { await store.load() }
        .sheet(item: $editor) { selection in
            AthleteEditor(store: store, athlete: selection.athlete)
        }
    }
}

private struct AthleteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RosterStore
    let athlete: Athlete?
    @State private var firstName: String
    @State private var lastName: String
    @State private var team: String
    @State private var active: Bool
    @State private var error: String?
    @State private var showDiscard = false

    init(store: RosterStore, athlete: Athlete?) {
        self.store = store
        self.athlete = athlete
        _firstName = State(initialValue: athlete?.first_name ?? "")
        _lastName = State(initialValue: athlete?.last_name ?? "")
        _team = State(initialValue: athlete?.team ?? "")
        _active = State(initialValue: athlete?.active ?? true)
    }

    private var hasChanges: Bool {
        firstName != (athlete?.first_name ?? "") || lastName != (athlete?.last_name ?? "")
            || team != (athlete?.team ?? "") || active != (athlete?.active ?? true)
    }

    private var valid: Bool {
        (1...80).contains(firstName.trimmingCharacters(in: .whitespacesAndNewlines).count)
            && (1...80).contains(lastName.trimmingCharacters(in: .whitespacesAndNewlines).count)
            && team.trimmingCharacters(in: .whitespacesAndNewlines).count <= 120
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("First name", text: $firstName).textContentType(.givenName)
                    TextField("Last name", text: $lastName).textContentType(.familyName)
                    TextField("Team (optional)", text: $team)
                } header: { Text("Athlete details") } footer: {
                    Text("Names can be up to 80 characters each. Team can be up to 120 characters.")
                }
                Section {
                    Toggle("Active on roster", isOn: $active)
                } footer: {
                    Text("Inactive athletes stay in your records but are hidden from the active roster.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if store.isSaving { ProgressView("Saving athlete…") }
            }
            .disabled(store.isSaving)
            .navigationTitle(athlete == nil ? "Add athlete" : "Edit athlete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { showDiscard = true } else { dismiss() }
                    }.disabled(store.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            error = nil
                            do {
                                try await store.save(id: athlete?.id, firstName: firstName, lastName: lastName, team: team, active: active)
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                dismiss()
                            } catch let failure as RosterError {
                                error = failure.localizedDescription
                            } catch {
                                self.error = "Couldn't save this athlete. Check your connection and administrator access, then try again. Your changes are still here."
                            }
                        }
                    }.disabled(!valid || store.isSaving || !store.canEdit)
                }
            }
        }
        .interactiveDismissDisabled(store.isSaving || hasChanges)
        .confirmationDialog("Discard unsaved changes?", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) { }
        }
        .tint(Brand.blue)
    }
}

private struct SettingsView: View {
    @AppStorage("appAppearance") private var appearance: AppAppearance = .system
    let username: String
    let signingOut: Bool
    let savingRoster: Bool
    let signOutError: String?
    let signOut: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: username)
                }
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows your device’s appearance, including automatic changes. Your choice is saved on this device.")
                }
                Section {
                    Button(role: .destructive, action: signOut) {
                        HStack {
                            Label(signingOut ? "Signing out…" : "Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            if signingOut { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(signingOut || savingRoster)
                    if let signOutError {
                        Text(signOutError).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.paper)
            .navigationTitle("Settings")
        }
    }
}
