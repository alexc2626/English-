import Foundation
import FoundationModels

/// General-purpose lookup so the chatbot can answer free-form questions
/// ("what does a face pull work?", "what's a bodyweight alternative to
/// hip thrusts?") by grounding in the real database instead of guessing.
struct ExerciseLookupTool: Tool {
    let name = "lookUpExerciseDetails"
    let description = "Searches the exercise database by name or keyword and returns muscle activation and baseball-specific coaching notes."

    @Generable
    struct Arguments {
        @Guide(description: "Exercise name or keyword to search for, e.g. 'face pull' or 'hamstring'")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let needle = arguments.query.lowercased()
        let matches = ExerciseDatabase.all.filter { exercise in
            exercise.name.lowercased().contains(needle)
                || exercise.muscleActivation.keys.contains { $0.displayName.lowercased().contains(needle) }
        }

        guard !matches.isEmpty else {
            return "No exercises in the database matched '\(arguments.query)'."
        }

        let summary = matches.prefix(8).map { exercise in
            let muscles = exercise.muscleActivation
                .sorted { $0.value > $1.value }
                .map { "\($0.key.displayName) \(Int($0.value * 100))%" }
                .joined(separator: ", ")
            return "- \(exercise.name) (\(exercise.splitDay.rawValue)): [\(muscles)]. \(exercise.baseballNote)"
        }.joined(separator: "\n")

        return summary
    }
}
