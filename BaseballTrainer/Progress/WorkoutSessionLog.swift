import Foundation

struct CompletedSetEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    let exerciseID: String
    let sets: Int
    let reps: Int
}

struct WorkoutSession: Identifiable, Codable, Hashable {
    var id = UUID()
    let date: Date
    var completedExercises: [CompletedSetEntry]
}

/// Turns a logged session into a per-muscle-group volume breakdown, used to
/// drive the post-session donut chart.
enum MuscleActivationAggregator {
    static func breakdown(for session: WorkoutSession, database: [Exercise] = ExerciseDatabase.all) -> [MuscleGroup: Double] {
        var totals: [MuscleGroup: Double] = [:]
        let byID = Dictionary(uniqueKeysWithValues: database.map { ($0.id, $0) })

        for entry in session.completedExercises {
            guard let exercise = byID[entry.exerciseID] else { continue }
            let volume = Double(entry.sets * entry.reps)
            for (muscle, activation) in exercise.muscleActivation {
                totals[muscle, default: 0] += activation * volume
            }
        }
        return totals
    }
}
