import Foundation

/// Muscle groups tracked for the post-session activation summary (donut chart).
enum MuscleGroup: String, CaseIterable, Codable, Identifiable, Hashable {
    case chest
    case lats
    case upperBack
    case lowerBack
    case shoulders
    case biceps
    case triceps
    case forearms
    case core
    case obliques
    case glutes
    case quads
    case hamstrings
    case calves
    case rotatorCuff
    case hipFlexors
    case adductors

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chest: return "Chest"
        case .lats: return "Lats"
        case .upperBack: return "Upper Back"
        case .lowerBack: return "Lower Back"
        case .shoulders: return "Shoulders"
        case .biceps: return "Biceps"
        case .triceps: return "Triceps"
        case .forearms: return "Forearms"
        case .core: return "Core / Abs"
        case .obliques: return "Obliques"
        case .glutes: return "Glutes"
        case .quads: return "Quads"
        case .hamstrings: return "Hamstrings"
        case .calves: return "Calves"
        case .rotatorCuff: return "Rotator Cuff"
        case .hipFlexors: return "Hip Flexors"
        case .adductors: return "Adductors / Groin"
        }
    }
}
