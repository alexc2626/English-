import Foundation
import FoundationModels

// MARK: - Strength program

/// Structured output the on-device model is guided to produce for a
/// multi-week push/pull/legs strength block. Using @Generable means the
/// model's response is constrained to this shape instead of free-form text.
@Generable
struct WorkoutProgram: Equatable {
    @Guide(description: "Program length in weeks, between 4 and 12")
    var weeks: Int

    @Guide(description: "Split style, e.g. 'Push / Pull / Legs'")
    var splitType: String

    @Guide(description: "1-2 sentence summary of how this program serves baseball performance (rotational power, leg drive, arm care balance)")
    var baseballFocusSummary: String

    @Guide(description: "One representative training week, 3 days, that repeats with progressive overload")
    var sampleWeek: [WorkoutDay]
}

@Generable
struct WorkoutDay: Equatable {
    @Guide(description: "e.g. 'Push Day', 'Pull Day', 'Legs Day'")
    var dayLabel: String

    @Guide(description: "4 to 6 exercises for this day, only using equipment the athlete confirmed they have")
    var exercises: [ProgramExercise]
}

@Generable
struct ProgramExercise: Equatable {
    var exerciseName: String

    @Guide(description: "Number of working sets, typically 2-5")
    var sets: Int

    @Guide(description: "Rep range as a string, e.g. '5-8' or '10-12'")
    var reps: String

    @Guide(description: "Rest between sets in seconds")
    var restSeconds: Int

    @Guide(description: "Short coaching cue tying the movement back to baseball performance")
    var coachingNote: String
}

// MARK: - Throwing program

@Generable
struct ThrowingProgram: Equatable {
    @Guide(description: "Program length in weeks, between 2 and 8")
    var weeks: Int

    @Guide(description: "Overall arm-care philosophy for this program, including rest-day guidance and stop signs")
    var armCareNotes: String

    @Guide(description: "Ordered phases, e.g. catch play, long toss build-up, mound progression")
    var phases: [ThrowingPhase]
}

@Generable
struct ThrowingPhase: Equatable {
    @Guide(description: "e.g. 'Phase 1: Catch Play & Arm Wake-Up'")
    var phaseName: String

    var days: [ThrowingDay]
}

@Generable
struct ThrowingDay: Equatable {
    @Guide(description: "e.g. 'Day 1 - Light Catch'")
    var dayLabel: String

    @Guide(description: "Approximate throw count for the day")
    var throwCount: Int

    @Guide(description: "Distance or intensity guidance, e.g. '75 ft, easy' or 'flat ground, 75% effort'")
    var distanceOrIntensity: String

    @Guide(description: "2-4 arm care drills to pair with this day (band work, mobility, etc.)")
    var armCareDrills: [String]
}
