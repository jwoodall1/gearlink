import SwiftUI
import UIKit

struct WriteTagView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: NFCWriteStore
    private let onConfirmed: (EquipmentSnapshot) -> Void

    init(context: RegistrationContext, snapshot: EquipmentSnapshot, onConfirmed: @escaping (EquipmentSnapshot) -> Void = { _ in }) {
        self.onConfirmed = onConfirmed
        _store = StateObject(wrappedValue: NFCWriteStore(context: context, snapshot: snapshot,
            transport: NFCScanner(), service: EquipmentRegistrationService(context: context)))
    }

    var body: some View {
        Form {
            Section {
                Text(store.stage == .complete ? "Equipment registered successfully" : "Write and verify this tag")
                    .font(.headline)
                Text(store.message)
                    .accessibilityLabel(store.message)
                if store.busy { ProgressView("Registration in progress…") }
                if !store.isAvailable && store.stage != .complete {
                    Text("This step requires a compatible physical iPhone. NFC is unavailable in Simulator.").foregroundStyle(.secondary)
                }
            }
            Section("Expected equipment and tag") {
                LabeledContent("Type", value: store.snapshot.equipment.category)
                LabeledContent("Size", value: store.snapshot.equipment.size ?? "—")
                LabeledContent("Color", value: store.snapshot.equipment.color ?? "—")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Full physical UID").font(.caption).foregroundStyle(.secondary)
                    Text(store.snapshot.tag?.physicalUID.rawValue ?? "Unavailable").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("GearLink ID").font(.caption).foregroundStyle(.secondary)
                    Text(store.snapshot.equipment.gearlinkID?.rawValue ?? "Unavailable").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
            Section {
                if store.stage == .complete {
                    Button("Done") { dismiss() }
                } else if store.busy {
                    Button("Stop", role: .cancel) { store.cancel() }
                } else {
                    if store.stage == .confirmationFailed {
                        Button("Retry server confirmation") { Task { await store.retryConfirmation() } }
                    }
                    Button("Scan same tag to write or verify") { Task { await store.start() } }
                        .disabled(!store.isAvailable)
                    Text("Only the GearLink ID is stored on the tag. Existing unrelated data is never overwritten. Keep the tag still until read-back verification finishes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Verify equipment tag").navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if store.stage == .complete { onConfirmed(store.snapshot) }
            store.cancel()
        }
        .onChange(of: scenePhase) { phase in if phase == .background { store.cancel() } }
        .onChange(of: store.stage) { stage in
            if stage == .complete { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }
}
