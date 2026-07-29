import Foundation
import FoundationModels

/// Lets the model pull real, equipment-filtered candidate exercises instead
/// of inventing names or gear the athlete doesn't have. The model still
/// composes the final structured `WorkoutProgram` via guided generation —
/// this tool just grounds it in real data.
struct GenerateWorkoutProgramTool: Tool {
    let name = "lookUpStrengthExercises"
    let description = "Returns baseball-relevant strength exercises filtered to the athlete's available equipment, grouped by push/pull/legs, with muscle activation and coaching notes. Call this before writing a WorkoutProgram."

    let profileStore: UserProfileStore

    @Generable
    struct Arguments {
        @Guide(description: "Which split day to fetch candidates for")
        var splitDay: String // "push", "pull", or "legs"
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        let day = Exercise.SplitDay(rawValue: arguments.splitDay.lowercased()) ?? .push
        let available = profileStore.selectedEquipment

        let candidates = ExerciseDatabase.all
            .filter { $0.splitDay == day }
            .filter { $0.isAvailable(given: available) }

        guard !candidates.isEmpty else {
            return ToolOutput("No \(arguments.splitDay) exercises match the athlete's current equipment. Ask them to widen their equipment selection or fall back to bodyweight-only movements.")
        }

        let summary = candidates.map { exercise in
            let muscles = exercise.muscleActivation
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { "\($0.key.displayName) \(Int($0.value * 100))%" }
                .joined(separator: ", ")
            return "- \(exercise.name): primary muscles [\(muscles)]. Baseball note: \(exercise.baseballNote)"
        }.joined(separator: "\n")

        return ToolOutput("Available \(arguments.splitDay) exercises for this athlete:\n\(summary)")
    }
}
