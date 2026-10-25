import SwiftUI

struct EquipmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: EquipmentDetailStore
    @State private var form: RegistrationForm
    @State private var name: String
    @State private var timestamp: String
    @State private var error: String?
    @State private var discard = false
    @State private var reload = false

    init(store: EquipmentDetailStore) {
        self.store = store
        _form = State(initialValue: RegistrationForm(equipment: store.snapshot.equipment))
        _name = State(initialValue: store.snapshot.equipment.name)
        _timestamp = State(initialValue: store.snapshot.equipment.updatedAt)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    EquipmentTextField(title: "Equipment name", text: $name)
                    Text("Your equipment ID and tag association stay unchanged.").font(.footnote).foregroundStyle(.secondary)
                }
                EquipmentFormFields(form: $form, editing: true).disabled(store.busy)
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Reload latest saved values") { reload = true }.disabled(store.busy)
                    }
                }
                Section {
                    Button("Save equipment changes") { Task { await save() } }.disabled(store.busy || !store.canAct)
                    if store.busy { ProgressView("Saving…") }
                }
            }
            .navigationTitle("Edit equipment").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { discard = true }.disabled(store.busy) } }
            .confirmationDialog("Discard unsaved changes?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
            }
            .confirmationDialog("Replace this form with the latest saved values?", isPresented: $reload, titleVisibility: .visible) {
                Button("Reload and discard edits", role: .destructive) {
                    Task {
                        await store.load()
                        if store.fresh {
                            form = RegistrationForm(equipment: store.snapshot.equipment)
                            name = store.snapshot.equipment.name; timestamp = store.snapshot.equipment.updatedAt; error = nil
                        } else { error = store.error }
                    }
                }
            }
        }.interactiveDismissDisabled()
    }
    private func save() async {
        do {
            let details = try form.validatedEdit(name: name)
            try await store.edit(expectedUpdatedAt: timestamp, details: details)
            dismiss()
        } catch { self.error = "\(error.localizedDescription) Your edits are still in the form. Reload saved values before retrying if the result is uncertain." }
    }
}
