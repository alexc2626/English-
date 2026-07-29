import SwiftUI

struct EquipmentSelectionView: View {
    @Bindable var profileStore: UserProfileStore

    var body: some View {
        Form {
            Section("Quick Start") {
                Picker("Setup", selection: Binding(
                    get: { profileStore.preset },
                    set: { profileStore.applyPreset($0) }
                )) {
                    ForEach(GymPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Available Equipment") {
                ForEach(EquipmentType.allCases) { equipment in
                    Toggle(equipment.rawValue, isOn: Binding(
                        get: { profileStore.selectedEquipment.contains(equipment) },
                        set: { _ in profileStore.toggle(equipment) }
                    ))
                }
            }

            Section("Athlete Profile") {
                Picker("Position", selection: $profileStore.position) {
                    Text("Pitcher").tag("Pitcher")
                    Text("Position Player").tag("Position Player")
                    Text("Two-Way").tag("Two-Way")
                }
                Picker("Experience", selection: $profileStore.experienceLevel) {
                    Text("Beginner").tag("Beginner")
                    Text("Intermediate").tag("Intermediate")
                    Text("Advanced").tag("Advanced")
                }
            }
        }
        .navigationTitle("Your Setup")
    }
}

#Preview {
    NavigationStack {
        EquipmentSelectionView(profileStore: UserProfileStore())
    }
}
