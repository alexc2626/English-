import Foundation

/// Everything an athlete might have access to. Used to filter which exercises
/// the program generator is allowed to select.
enum EquipmentType: String, CaseIterable, Codable, Identifiable, Hashable {
    case bodyweightOnly = "Bodyweight"
    case barbell = "Barbell"
    case dumbbell = "Dumbbell"
    case kettlebell = "Kettlebell"
    case cableMachine = "Cable Machine"
    case latPulldownMachine = "Lat Pulldown Machine"
    case legPressMachine = "Leg Press Machine"
    case smithMachine = "Smith Machine"
    case squatRack = "Squat Rack"
    case bench = "Flat / Adjustable Bench"
    case pullUpBar = "Pull-Up Bar"
    case resistanceBands = "Resistance Bands"
    case medicineBall = "Medicine Ball"
    case weightedBalls = "Weighted Baseballs (Plyo / Sock)"
    case plyoBox = "Plyo Box"
    case trapBar = "Trap Bar"
    case landmine = "Landmine / Cable Rotational Tower"
    case suspensionTrainer = "Suspension Trainer (TRX)"
    case foamRoller = "Foam Roller"
    case stabilityBall = "Stability Ball"

    var id: String { rawValue }
}

/// Quick-start presets so the user isn't forced to hand-pick everything.
enum GymPreset: String, CaseIterable, Identifiable, Hashable {
    case fullGym = "Full Commercial Gym"
    case homeGym = "Home Gym"
    case bodyweightOnly = "Bodyweight Only"
    case custom = "Custom Selection"

    var id: String { rawValue }

    var defaultEquipment: Set<EquipmentType> {
        switch self {
        case .fullGym:
            return Set(EquipmentType.allCases)
        case .homeGym:
            return [
                .bodyweightOnly, .dumbbell, .kettlebell, .pullUpBar, .bench,
                .resistanceBands, .medicineBall, .plyoBox, .foamRoller,
                .suspensionTrainer, .stabilityBall, .weightedBalls
            ]
        case .bodyweightOnly:
            return [.bodyweightOnly, .resistanceBands, .foamRoller]
        case .custom:
            return []
        }
    }
}
