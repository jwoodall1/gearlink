import SwiftUI
import UIKit

private enum Brand {
    static let blue = adaptive(light: 0x0062FF, dark: 0x6AA5FF)
    static let ink = adaptive(light: 0x122442, dark: 0xE8EFFB)
    static let paper = adaptive(light: 0xF4F7FC, dark: 0x101724)
    static let soft = adaptive(light: 0xEDF4FF, dark: 0x203454)
    static let line = adaptive(light: 0xDFE7F3, dark: 0x34445C)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x1B2638)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

private extension View {
    func panel() -> some View {
        self.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.line, lineWidth: 1))
    }
}

struct DashboardView: View {
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
        TabView {
            overview
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
            SettingsView(username: username, signingOut: signingOut,
                         savingRoster: roster.isSaving, signOutError: signOutError,
                         signOut: signOut)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Brand.blue)
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
                        Text("Welcome back, \(username)").font(.title.bold())
                        Text(roster.membership?.organizations.name ?? "Your workspace")
                            .foregroundStyle(.secondary)
                    }
                    if let error = roster.errorMessage {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(error).foregroundStyle(.red)
                            Button("Try again") { Task { await roster.load() } }
                        }.panel()
                    }
                    if roster.isLoading && !roster.hasLoaded {
                        ProgressView("Loading your workspace…").panel()
                    } else if roster.membership != nil {
                        HStack(spacing: 12) {
                            stat("Active athletes", value: roster.activeCount, icon: "person.2.fill")
                            stat("Teams", value: roster.teamCount, icon: "sportscourt.fill")
                        }
                        NavigationLink {
                            RosterView(store: roster)
                        } label: {
                            actionCard("Team roster", detail: "View athletes and manage your roster", icon: "person.3.fill")
                        }.buttonStyle(.plain)
                    } else if roster.hasLoaded && roster.errorMessage == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No organization yet").font(.headline)
                            Text("Set up your organization in the web dashboard or ask an administrator to add you.")
                                .foregroundStyle(.secondary)
                        }.panel()
                    }
                    NavigationLink {
                        NFCScannerView()
                    } label: {
                        actionCard("Open scanner", detail: "Read an NFC tag ID and its data", icon: "wave.3.right.circle")
                    }.buttonStyle(.plain)
                    Label("Your roster is connected to GearLink.", systemImage: "cloud")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
            }
            .background(Brand.paper)
            .navigationTitle("Overview").navigationBarTitleDisplayMode(.inline)
            .refreshable { await roster.load() }
            .task { await roster.load() }
        }.tint(Brand.blue).foregroundStyle(Brand.ink)
    }

    private func stat(_ label: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Brand.blue)
            Text("\(value)").font(.largeTitle.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.panel()
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
        }.panel()
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
                if let notice = store.notice { Text(notice).foregroundStyle(Brand.blue) }
                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red)
                    Button("Try again") { Task { await store.load() } }
                }
            }
            Section("\(filtered.count) athletes") {
                if store.isLoading { ProgressView("Refreshing roster…") }
                if filtered.isEmpty && !store.isLoading {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(search.isEmpty ? "No athletes to show" : "No matching athletes").font(.headline)
                        Text(search.isEmpty ? "Add an athlete to get started, or include inactive athletes." : "Try a different name or team.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                ForEach(filtered) { athlete in
                    Button { editor = EditorSelection(athlete: athlete) } label: {
                        HStack(spacing: 12) {
                            Text(athlete.initials).font(.caption.bold()).foregroundStyle(Brand.blue)
                                .frame(width: 40, height: 40).background(Brand.soft, in: Circle())
                            VStack(alignment: .leading, spacing: 5) {
                                Text(athlete.name).font(.headline).foregroundStyle(Brand.ink)
                                Text(athlete.team ?? "No team").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !athlete.active { Text("Inactive").font(.caption).foregroundStyle(.secondary) }
                            if store.canEdit { Image(systemName: "pencil").foregroundStyle(Brand.blue) }
                        }.padding(.vertical, 6)
                    }
                    .disabled(!store.canEdit)
                    .accessibilityHint(store.canEdit ? "Edit athlete" : "Read only")
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

    init(store: RosterStore, athlete: Athlete?) {
        self.store = store
        self.athlete = athlete
        _firstName = State(initialValue: athlete?.first_name ?? "")
        _lastName = State(initialValue: athlete?.last_name ?? "")
        _team = State(initialValue: athlete?.team ?? "")
        _active = State(initialValue: athlete?.active ?? true)
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
                    Button("Cancel") { dismiss() }.disabled(store.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            error = nil
                            do {
                                try await store.save(id: athlete?.id, firstName: firstName, lastName: lastName, team: team, active: active)
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
        }.interactiveDismissDisabled(store.isSaving).tint(Brand.blue)
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
