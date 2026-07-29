import Foundation
import Observation

/// Holds the athlete's equipment access and profile info so both the chat UI
/// and the FoundationModels tools can read/filter against the same source of truth.
@Observable
final class UserProfileStore {
    var preset: GymPreset = .fullGym
    var selectedEquipment: Set<EquipmentType> = GymPreset.fullGym.defaultEquipment
    var position: String = "Position Player" // Pitcher, Position Player, Two-Way
    var experienceLevel: String = "Intermediate" // Beginner, Intermediate, Advanced

    func applyPreset(_ preset: GymPreset) {
        self.preset = preset
        if preset != .custom {
            selectedEquipment = preset.defaultEquipment
        }
    }

    func toggle(_ equipment: EquipmentType) {
        if selectedEquipment.contains(equipment) {
            selectedEquipment.remove(equipment)
        } else {
            selectedEquipment.insert(equipment)
        }
        preset = .custom
    }
}
