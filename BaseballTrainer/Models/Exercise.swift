import Foundation

/// A single exercise in the database. `muscleActivation` is a relative,
/// directional estimate (0.0-1.0 per muscle, primary movers weighted highest) —
/// not clinical EMG data — used to drive the post-session "muscles trained"
/// donut chart.
struct Exercise: Identifiable, Codable, Hashable {
    enum SplitDay: String, Codable, CaseIterable {
        case push
        case pull
        case legs
        case rotationalPower
        case armCare
    }

    let id: String
    let name: String
    let splitDay: SplitDay
    let requiredEquipment: [EquipmentType]
    let muscleActivation: [MuscleGroup: Double]
    let baseballNote: String
    let isCompoundLift: Bool

    /// True if the athlete's selected equipment covers every requirement.
    func isAvailable(given available: Set<EquipmentType>) -> Bool {
        requiredEquipment.allSatisfy { available.contains($0) || $0 == .bodyweightOnly }
    }
}
