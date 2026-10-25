import SwiftUI

struct EquipmentFormFields: View {
    @Binding var form: RegistrationForm
    var editing = false
    var body: some View {
        Group {
            Section("Required details") {
                Picker("Equipment type", selection: $form.category) {
                    ForEach(RegistrationForm.categories, id: \.self) { Text($0).tag($0) }
                }
                if form.category == "Other" { EquipmentTextField(title: "Custom equipment type", text: $form.customCategory) }
                EquipmentTextField(title: "Size (required)", text: $form.size)
                if !form.sizes.isEmpty {
                    Menu("Choose a suggested size") {
                        ForEach(form.sizes, id: \.self) { size in Button(size) { form.size = size } }
                    }
                }
                EquipmentTextField(title: "Color (required)", text: $form.color)
                Picker("Condition", selection: $form.condition) {
                    Text("New").tag(EquipmentCondition.new)
                    Text("Good").tag(EquipmentCondition.good)
                    Text("Fair").tag(EquipmentCondition.fair)
                    Text("Needs repair").tag(EquipmentCondition.needsRepair)
                }
            }
            Section("Optional details") {
                EquipmentTextField(title: "Brand", text: $form.brand)
                if editing || ["Helmet", "Shoulder Pads", "Other"].contains(form.category) { EquipmentTextField(title: "Model", text: $form.model) }
                if editing || form.category == "Jersey" { EquipmentTextField(title: "Jersey number", text: $form.jerseyNumber) }
                EquipmentTextField(title: "Serial number", text: $form.serialNumber).textInputAutocapitalization(.never).autocorrectionDisabled()
                EquipmentTextField(title: "Purchase year", text: $form.purchaseYear).keyboardType(.numberPad)
                EquipmentTextField(title: "Purchase price", text: $form.purchasePrice).keyboardType(.decimalPad)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Notes", text: $form.notes, axis: .vertical).lineLimit(3...8)
                }
            }
        }
    }
}

/// Persistent labels keep filled edit forms understandable, including when
/// values such as model, brand and size look similar.
struct EquipmentTextField: View {
    let title: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(title, text: $text)
        }.padding(.vertical, 2)
    }
}
