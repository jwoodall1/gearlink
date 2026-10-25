import SwiftUI

struct RegisterEquipmentView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: RegistrationStore
    @State private var discard = false

    init(context: RegistrationContext, scan: RegistrationScan) {
        _store = StateObject(wrappedValue: RegistrationStore(context: context, scan: scan,
            service: EquipmentRegistrationService(context: context)))
    }

    var body: some View {
        NavigationStack {
            Group {
                if case .saved(let snapshot) = store.stage, snapshot.equipment.registrationStatus == .active {
                    EquipmentDetailView(context: store.context, snapshot: snapshot)
                } else {
                    registrationForm
                }
            }
            .navigationTitle(isRegistered ? "Equipment" : "Register equipment").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Close") { if case .form = store.stage { discard = true } else { dismiss() } }.disabled(store.busy)
            } }
            .confirmationDialog("Close registration?", isPresented: $discard, titleVisibility: .visible) {
                Button("Close form", role: .destructive) { dismiss() }
            } message: { Text("Unsaved entries will be lost. Saved pending records can be recovered by scanning this tag again.") }
        }
        .interactiveDismissDisabled(isEditing || store.busy)
        .task { await store.inspect() }
        .onDisappear { store.cancel() }
    }

    private var registrationForm: some View {
            Form {
                switch store.stage {
                case .checking:
                    Section { ProgressView("Checking equipment records…") }
                case .blocked:
                    Section { Text("Registration couldn't continue").font(.headline) }
                case .form:
                    equipmentFields
                case .saved(let snapshot):
                    RegistrationSummary(snapshot: snapshot, context: store.context)
                }
                if let error = store.error {
                    Section {
                        Text(error).foregroundStyle(.red).accessibilityLabel("Registration error: \(error)")
                        if case .blocked = store.stage {
                            Button("Check again") { Task { await store.inspect() } }.disabled(store.busy)
                        }
                    }
                }
                if case .form = store.stage {
                    Section {
                        Button { Task { await store.save() } } label: {
                            if store.busy { ProgressView("Saving pending equipment…") }
                            else { Text("Save pending equipment").frame(maxWidth: .infinity) }
                        }.disabled(store.busy)
                        Text("This saves the equipment to your program. It stays unavailable for issue until its NFC tag is written and verified.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
    }

    private var isRegistered: Bool { if case .saved(let snapshot) = store.stage { return snapshot.equipment.registrationStatus == .active }; return false }

    private var isEditing: Bool { if case .form = store.stage { return true }; return false }

    private var equipmentFields: some View {
        Group {
            Section("Original tag") {
                Text(store.scan.uid?.rawValue ?? "Unknown UID").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("Keep this tag with the equipment. The full UID will be checked again before writing.").font(.footnote).foregroundStyle(.secondary)
            }
            EquipmentFormFields(form: $store.form)
        }.disabled(store.busy)
    }
}

/// The handoff remains pending until the writing workflow confirms read-back.
struct RegistrationSummary: View {
    let snapshot: EquipmentSnapshot
    var context: RegistrationContext? = nil
    @State private var confirmedSnapshot: EquipmentSnapshot?
    private var current: EquipmentSnapshot { confirmedSnapshot ?? snapshot }
    private var isPending: Bool { current.equipment.registrationStatus != .active }
    var body: some View {
        Section {
            Label(isPending ? "Saved — awaiting tag verification" : "Equipment already registered",
                  systemImage: isPending ? "clock" : "checkmark.circle")
                .font(.headline)
            if isPending {
                Text("This record is saved in your program and can be recovered after closing the app. It is not available for issue.")
                Text("Scan the same physical tag to write its GearLink ID and verify it before activation.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No new equipment record was created. This tag already belongs to the equipment below.")
            }
        }
        if let context {
            Section {
                if isPending {
                    NavigationLink("Write or verify tag") { WriteTagView(context: context, snapshot: current) { confirmedSnapshot = $0 } }
                } else {
                    NavigationLink("View equipment and assignments") { EquipmentDetailView(context: context, snapshot: current) }
                }
            }
        }
        Section("Equipment") {
            LabeledContent("Type", value: current.equipment.category)
            LabeledContent("Size", value: current.equipment.size ?? "—")
            LabeledContent("Color", value: current.equipment.color ?? "—")
            LabeledContent("Condition", value: current.equipment.condition.rawValue.replacingOccurrences(of: "_", with: " "))
            VStack(alignment: .leading, spacing: 6) {
                Text("GearLink ID").font(.caption).foregroundStyle(.secondary)
                Text(current.equipment.gearlinkID?.rawValue ?? "Unavailable").font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Expected physical UID").font(.caption).foregroundStyle(.secondary)
                Text(current.tag?.physicalUID.rawValue ?? "Unavailable").font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}

struct EquipmentRegistrationHome: View {
    let context: RegistrationContext
    @State private var pending: [EquipmentRecord] = []
    @State private var busy = false
    @State private var error: String?
    @State private var hasMore = false
    @State private var nextOffset = 0
    @State private var hasLoaded = false
    @State private var selection: RecoverySelection?
    @State private var generation = UUID()
    private struct RecoverySelection: Identifiable { let id = UUID(); let snapshot: EquipmentSnapshot }

    var body: some View {
        List {
            Section {
                NavigationLink { NFCScannerView(registrationContext: context) } label: {
                    Label("Scan tag to register equipment", systemImage: "sensor.tag.radiowaves.forward")
                }
                Text("Start with a blank, writable NFC tag. Saving creates a pending record. Then scan the same tag again to write and verify its ID.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Pending registrations") {
                if busy { ProgressView("Loading equipment…") }
                if let error { Text(error).foregroundStyle(.red) }
                if pending.isEmpty && hasLoaded && error == nil && !busy {
                    Text("No pending equipment. Scan a tag to begin.").foregroundStyle(.secondary)
                }
                ForEach(pending) { item in
                    Button { Task { await recover(item) } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.name).foregroundStyle(.primary)
                            Text(item.gearlinkID?.rawValue ?? "Pending registration").font(.caption).foregroundStyle(.secondary)
                            Text(item.registrationStatus == .writeFailed ? "Write needs recovery" : "Awaiting tag verification").font(.caption)
                        }.padding(.vertical, 4)
                    }.disabled(busy)
                }
                if hasMore { Button("Load more") { Task { await load(reset: false) } }.disabled(busy) }
                Button("Refresh pending registrations") { Task { await load(reset: true) } }.disabled(busy)
            }
        }
        .navigationTitle("Register equipment").navigationBarTitleDisplayMode(.inline)
        .task { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .onDisappear { generation = UUID(); busy = false }
        .sheet(item: $selection) { selection in
            NavigationStack {
                Form { RegistrationSummary(snapshot: selection.snapshot, context: context) }
                    .navigationTitle("Equipment registration").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { self.selection = nil } } }
            }
        }
    }

    private func load(reset: Bool) async {
        guard !busy else { return }
        busy = true; error = nil
        let operation = generation
        defer { if generation == operation { busy = false } }
        do {
            let page = try await EquipmentRegistrationService(context: context).pending(offset: reset ? 0 : nextOffset)
            guard operation == generation, !Task.isCancelled else { return }
            if reset { pending = [] }
            let existing = Set(pending.map(\.id))
            pending += page.filter { !existing.contains($0.id) }
            nextOffset = (reset ? 0 : nextOffset) + page.count
            hasMore = page.count == 50; hasLoaded = true
        } catch {
            guard operation == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func recover(_ item: EquipmentRecord) async {
        guard !busy else { return }
        busy = true; error = nil
        let operation = generation
        defer { if generation == operation { busy = false } }
        do {
            let snapshot = try await EquipmentRegistrationService(context: context).recover(item)
            guard operation == generation, !Task.isCancelled else { return }
            selection = RecoverySelection(snapshot: snapshot)
        } catch {
            guard operation == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
