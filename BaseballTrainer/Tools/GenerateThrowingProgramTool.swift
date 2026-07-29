import Foundation
import FoundationModels

/// Grounds throwing-program generation in a fixed set of accepted arm-care
/// phases rather than letting the model freely invent volume/intensity
/// jumps. The model still writes the final structured `ThrowingProgram`.
struct GenerateThrowingProgramTool: Tool {
    let name = "lookUpThrowingProgressionGuidelines"
    let description = "Returns conservative, phase-based throwing progression guidelines (catch play, long toss, mound work) and arm care principles. Call this before writing a ThrowingProgram."

    @Generable
    struct Arguments {
        @Guide(description: "Athlete role: 'Pitcher', 'Position Player', or 'Two-Way'")
        var position: String
    }

    func call(arguments: Arguments) async throws -> ToolOutput {
        let guidelines = """
        General arm-care-first throwing progression principles:

        Phase 1 - Catch Play & Arm Wake-Up (short toss, easy intent, focus on mechanics)
        Phase 2 - Long Toss Build-Up (gradually increase distance while intent stays controlled)
        Phase 3 - Compression / Pull-Down Throws (bring distance back in at higher intent)
        Phase 4 - \(arguments.position == "Pitcher" ? "Mound Progression (flat ground to bullpen, gradually increasing pitch count and intensity)" : "Game-Speed Reps (fielding-specific throws at competition intent)")

        Non-negotiable arm care rules:
        - Never increase distance and intensity in the same session.
        - Build in at least one full rest day between high-intensity throwing days.
        - Any report of pain, tightness, numbness, tingling, or a sudden drop in velocity/control means STOP throwing that day and see a sports medicine professional or athletic trainer before continuing.
        - Weighted-ball work should only be added under in-person supervision from a qualified coach or therapist, and is not recommended for youth or early-adolescent athletes.
        - This app does not diagnose injuries. It only sequences volume and intensity conservatively.
        """
        return ToolOutput(guidelines)
    }
}
