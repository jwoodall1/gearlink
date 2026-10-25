import SwiftUI

struct EquipmentDetailView: View {
    @StateObject private var store: EquipmentDetailStore
    @State private var picker: PickerSelection?
    @State private var returnAction: EquipmentAction?
    @State private var showReturn = false
    @State private var editing = false
    private struct PickerSelection: Identifiable { let id = UUID(); let transfer: Bool; let assignment: UUID? }

    init(context: RegistrationContext, snapshot: EquipmentSnapshot) {
        _store = StateObject(wrappedValue: EquipmentDetailStore(context: context, snapshot: snapshot,
            service: EquipmentRegistrationService(context: context),
            journal: FileEquipmentActionJournal(context: context, equipmentID: snapshot.equipment.id)))
    }
    var body: some View {
        Form {
            Section {
                Text(store.snapshot.equipment.name).font(.title2.bold())
                Text(store.snapshot.equipment.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                if store.busy { ProgressView("Updating equipment…") }
                if let notice = store.notice { Label(notice, systemImage: "checkmark.circle") }
                if let error = store.error { Text(error).foregroundStyle(.red) }
                Button("Refresh equipment") { Task { await store.load() } }.disabled(store.busy)
            }
            if let action = store.pendingAction {
                Section("Unconfirmed operation") {
                    Text("\(action.title) has an unresolved result. Retry the same saved request before making another change.")
                    Button("Retry saved request") { Task { await store.perform(action) } }.disabled(store.busy)
                }
            }
            Section("Assignment") {
                if let assignment = store.snapshot.currentAssignment {
                    Text(store.assignedAthlete?.name ?? "Athlete \(assignment.athleteID.uuidString)").font(.headline)
                    if let team = store.assignedAthlete?.team { Text(team).foregroundStyle(.secondary) }
                    Text("Issued \(equipmentDate(assignment.checkedOutAt))").font(.caption)
                    Button("Return equipment") {
                        returnAction = EquipmentAction(kind: .return, equipmentID: store.snapshot.equipment.id, expectedAssignmentID: assignment.id)
                        showReturn = true
                    }.disabled(!store.canReturn)
                    Button("Transfer to another athlete") {
                        picker = PickerSelection(transfer: true, assignment: assignment.id)
                    }.disabled(!store.canTransfer)
                } else {
                    Text("No current assignment").foregroundStyle(.secondary)
                    Button("Assign to athlete") { picker = PickerSelection(transfer: false, assignment: nil) }.disabled(!store.canIssue)
                }
            }
            Section("Equipment details") {
                LabeledContent("Type", value: store.snapshot.equipment.category)
                LabeledContent("Size", value: store.snapshot.equipment.size ?? "—")
                LabeledContent("Color", value: store.snapshot.equipment.color ?? "—")
                LabeledContent("Condition", value: store.snapshot.equipment.condition.rawValue.replacingOccurrences(of: "_", with: " "))
                optional("Brand", store.snapshot.equipment.brand)
                optional("Model", store.snapshot.equipment.model)
                optional("Jersey number", store.snapshot.equipment.jerseyNumber)
                optional("Serial number", store.snapshot.equipment.serialNumber)
                optional("Purchase year", store.snapshot.equipment.purchaseYear.map(String.init))
                optional("Purchase price", store.snapshot.equipment.purchasePrice.map { NSDecimalNumber(decimal: $0).stringValue })
                optional("Notes", store.snapshot.equipment.notes)
                Button("Edit equipment details") { editing = true }.disabled(!store.canAct)
            }
            Section("Identity") {
                Text(store.snapshot.equipment.gearlinkID?.rawValue ?? "No GearLink ID").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("Physical UID: \(store.snapshot.tag?.physicalUID.rawValue ?? "Unavailable")").font(.footnote).textSelection(.enabled)
                Text("Editing details does not change these identifiers or rewrite the tag.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink("Assignment history") {
                    EquipmentHistoryView(context: store.context, equipmentID: store.snapshot.equipment.id)
                }
            }
        }
        .navigationTitle("Equipment").navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .onDisappear { if !editing && picker == nil { store.cancel() } }
        .confirmationDialog("Return \(store.snapshot.equipment.name)?", isPresented: $showReturn, titleVisibility: .visible) {
            Button("Confirm return") { if let action = returnAction { Task { await store.perform(action) } } }
        } message: { Text("This closes the selected assignment and preserves its history. Equipment needing repair will enter maintenance.") }
        .sheet(item: $picker) { selection in
            EquipmentAthletePicker(store: store, transfer: selection.transfer, expectedAssignment: selection.assignment)
        }
        .sheet(isPresented: $editing) { EquipmentEditor(store: store) }
    }
    @ViewBuilder private func optional(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty { LabeledContent(label, value: value) }
    }
}

private struct EquipmentAthletePicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: EquipmentDetailStore
    let transfer: Bool
    let expectedAssignment: UUID?
    @State private var search = ""
    @State private var rows: [EquipmentAthlete] = []
    @State private var offset = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    @State private var selected: EquipmentAthlete?
    @State private var confirm = false
    @State private var generation = UUID()
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(store.snapshot.equipment.name).font(.headline)
                    Text(transfer ? "Choose the athlete receiving this item. The current assignment will close in the same transaction." : "Choose an active athlete from your program.")
                    if loading { ProgressView("Finding athletes…") }
                    if let error { Text(error).foregroundStyle(.red); Button("Retry search") { Task { await load(reset: true) } } }
                    if let error = store.error { Text(error).foregroundStyle(.red) }
                }
                Section("Athletes") {
                    if rows.isEmpty && !loading && error == nil { Text("No matching active athletes.").foregroundStyle(.secondary) }
                    ForEach(rows) { athlete in
                        Button { selected = athlete; confirm = true } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(athlete.name)
                                if let team = athlete.team { Text(team).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.disabled(store.busy || store.pendingAction != nil || (transfer && athlete.id == store.snapshot.currentAssignment?.athleteID))
                    }
                    if hasMore { Button("Load more athletes") { Task { await load(reset: false) } }.disabled(loading) }
                }
            }
            .searchable(text: $search, prompt: "Name or team")
            .navigationTitle(transfer ? "Transfer equipment" : "Assign equipment").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(store.busy) } }
            .onChange(of: search) { _ in
                generation = UUID(); rows = []; hasMore = false; loading = true
            }
            .task(id: search) {
                do { try await Task.sleep(nanoseconds: 250_000_000); try Task.checkCancellation(); await load(reset: true) }
                catch { }
            }
            .confirmationDialog(transfer ? "Confirm transfer?" : "Confirm assignment?", isPresented: $confirm, titleVisibility: .visible) {
                Button(transfer ? "Confirm transfer" : "Confirm assignment") {
                    guard let selected else { return }
                    let action = EquipmentAction(kind: transfer ? .transfer : .assign, equipmentID: store.snapshot.equipment.id,
                        athleteID: selected.id, expectedAssignmentID: expectedAssignment)
                    Task { await store.perform(action); dismiss() }
                }
            } message: { Text("\(store.snapshot.equipment.name) → \(selected?.name ?? "athlete")") }
        }
        .interactiveDismissDisabled(store.busy)
        .onDisappear { generation = UUID() }
    }
    private func load(reset: Bool) async {
        if !reset && loading { return }
        let operation = UUID(); generation = operation; loading = true; error = nil
        let query = search
        if reset { rows = []; offset = 0 }
        defer { if operation == generation { loading = false } }
        do {
            let page = try await EquipmentRegistrationService(context: store.context).athletes(search: query, offset: offset)
            guard generation == operation, search == query, !Task.isCancelled else { return }
            let ids = Set(rows.map(\.id)); rows += page.filter { !ids.contains($0.id) }
            offset += page.count; hasMore = page.count == 50
        } catch { if generation == operation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct EquipmentHistoryView: View {
    let context: RegistrationContext
    let equipmentID: UUID
    @State private var entries: [EquipmentHistoryEntry] = []
    @State private var offset = 0
    @State private var hasMore = false
    @State private var busy = false
    @State private var error: String?
    @State private var generation = UUID()
    var body: some View {
        List {
            if busy { ProgressView("Loading history…") }
            if let error { Text(error).foregroundStyle(.red); Button("Retry") { Task { await load(reset: true) } } }
            if entries.isEmpty && !busy && error == nil { Text("No assignment history yet.").foregroundStyle(.secondary) }
            ForEach(entries) { entry in
                DisclosureGroup {
                    Text("Issued by: \(entry.checked_out_by.uuidString)").font(.caption).textSelection(.enabled)
                    if let actor = entry.returned_by { Text("Returned by: \(actor.uuidString)").font(.caption).textSelection(.enabled) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.athletes?.name ?? "Athlete \(entry.athlete_id.uuidString)")
                        Text("Issued \(equipmentDate(entry.checked_out_at))").font(.caption)
                        Text(entry.returned_at.map { "Returned \(equipmentDate($0))" } ?? "Currently assigned").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if hasMore { Button("Load more history") { Task { await load(reset: false) } }.disabled(busy) }
        }
        .navigationTitle("Assignment history").navigationBarTitleDisplayMode(.inline)
        .task { await load(reset: true) }.refreshable { await load(reset: true) }
        .onDisappear { generation = UUID(); busy = false }
    }
    private func load(reset: Bool) async {
        guard !busy else { return }
        busy = true; error = nil
        let operation = generation
        defer { if operation == generation { busy = false } }
        do {
            let page = try await EquipmentRegistrationService(context: context).history(equipmentID: equipmentID, offset: reset ? 0 : offset)
            guard operation == generation, !Task.isCancelled else { return }
            if reset { entries = []; offset = 0 }
            let ids = Set(entries.map(\.id)); entries += page.filter { !ids.contains($0.id) }
            offset += page.count; hasMore = page.count == 50
        } catch { if operation == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

func equipmentDate(_ value: String) -> String {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = formatter.date(from: value)
    if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: value) }
    return date?.formatted(date: .abbreviated, time: .shortened) ?? value
}
