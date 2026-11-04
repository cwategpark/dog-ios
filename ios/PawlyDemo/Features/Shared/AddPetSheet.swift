import SwiftUI

struct AddPetSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.pawly) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var species = "dog"
    @State private var dogSize = "medium"
    @State private var ageText = "24"
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let sizes = ["small", "medium", "large", "unknown"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.t("addPet.name"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.muted)
                        TextField(state.t("addPet.namePlaceholder"), text: $name)
                            .font(.system(size: 16))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.t("addPet.species"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.muted)
                        HStack(spacing: 10) {
                            ForEach(["cat", "dog"], id: \.self) { code in
                                SelectableChip(title: L10n.speciesLabel(code, state.language),
                                               isSelected: species == code) {
                                    species = code
                                }
                            }
                        }
                    }

                    if species == "dog" {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(state.t("addPet.dogSize"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.muted)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(sizes, id: \.self) { code in
                                        SelectableChip(title: L10n.dogSizeLabel(code, state.language),
                                                       isSelected: dogSize == code) {
                                            dogSize = code
                                        }
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.t("addPet.age"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.muted)
                        TextField("24", text: $ageText)
                            .keyboardType(.numberPad)
                            .font(.system(size: 16, design: .rounded))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.danger)
                    }
                }
                .padding(20)
            }
            .background(theme.background)
            .navigationTitle(state.t("addPet.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(state.t("action.cancel")) { dismiss() }
                        .foregroundStyle(theme.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().tint(theme.primary)
                        } else {
                            Text(state.t("action.save")).fontWeight(.semibold)
                        }
                    }
                    .foregroundStyle(theme.primary)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = state.t("addPet.error.name")
            return
        }
        isSaving = true
        defer { isSaving = false }
        let age = Int(ageText)
        let pet = await state.createPet(name: trimmed,
                                        species: species,
                                        dogSize: species == "dog" ? dogSize : nil,
                                        ageMonths: age)
        if pet != nil {
            dismiss()
        }
    }
}
