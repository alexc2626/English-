import Foundation
import FoundationModels
import Observation

@Observable
final class ChatViewModel {
    struct Message: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    private(set) var messages: [Message] = []
    var inputText = ""
    var isResponding = false
    var errorMessage: String?

    private let profileStore: UserProfileStore
    private var session: LanguageModelSession?

    init(profileStore: UserProfileStore) {
        self.profileStore = profileStore
        if ModelAvailability.isAvailable {
            rebuildSession()
            messages.append(Message(role: .assistant, text: Self.welcomeMessage))
        } else {
            errorMessage = ModelAvailability.unavailableReason
        }
    }

    /// (Re)creates the session with a fresh equipment snapshot for its
    /// tools. Call this after the athlete changes their equipment
    /// selection — note this starts a new conversation transcript, since
    /// a session's tools can't be swapped after creation.
    func rebuildSession() {
        let tools: [any Tool] = [
            GenerateWorkoutProgramTool(availableEquipment: profileStore.selectedEquipment),
            GenerateThrowingProgramTool(),
            ExerciseLookupTool()
        ]
        session = LanguageModelSession(tools: tools, instructions: Self.systemInstructions)
    }

    private static let welcomeMessage = """
    Hey — I'm your baseball performance coach. I can build a strength program around your split (push/pull/legs), put together a throwing progression, or answer arm care questions. What do you want to start with?
    """

    private static let systemInstructions = """
    You are an on-device assistant for baseball players covering three things: (1) strength program generation, (2) throwing program generation, and (3) general arm care questions.

    Strength programs:
    - Always call lookUpStrengthExercises for each split day (push, pull, legs) before writing a WorkoutProgram. Only include exercises it returns — never invent exercises or assume equipment the athlete doesn't have.
    - Bias exercise selection and coaching notes toward baseball transfer: rotational power, leg drive, deceleration/arm-care balance, and correcting the left/right asymmetry from throwing.

    Throwing programs:
    - Always call lookUpThrowingProgressionGuidelines before writing a ThrowingProgram, and follow its progression order and rules exactly.
    - Keep volume and intensity increases conservative and never combine a distance increase with an intensity increase in the same session.

    Arm care questions (safety-critical):
    - You are not a doctor, physical therapist, or athletic trainer, and you cannot diagnose injuries. Never state or imply a diagnosis (e.g. never say "you have a UCL tear" or "that's tendinitis").
    - If the athlete describes pain, numbness, tingling, swelling, clicking with pain, or a sudden drop in velocity or control, tell them clearly to stop throwing and see a sports medicine professional or licensed athletic trainer before continuing any program.
    - You can explain general arm care concepts, exercises, and warm-up/cooldown structure, but always frame program changes as conservative and reversible, not medical treatment.

    Use lookUpExerciseDetails whenever the athlete asks about a specific exercise or muscle group so your answer is grounded in the real database.

    Keep responses conversational and concise. Ask a clarifying question if you're missing the athlete's equipment, position, experience level, or desired program length before generating a full program.
    """

    @MainActor
    func send() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session else { return }

        messages.append(Message(role: .user, text: trimmed))
        inputText = ""
        isResponding = true
        defer { isResponding = false }

        let assistantIndex = messages.count
        messages.append(Message(role: .assistant, text: ""))

        do {
            let stream = session.streamResponse(to: trimmed)
            for try await partial in stream {
                messages[assistantIndex].text = partial.content
            }
        } catch {
            messages[assistantIndex].text = "Sorry, I ran into a problem generating that: \(error.localizedDescription)"
        }
    }

    /// Runs the structured generator directly (e.g. from a "Build my program"
    /// button) instead of free-form chat, so the UI gets a typed WorkoutProgram.
    func generateWorkoutProgram(weeks: Int) async throws -> WorkoutProgram {
        guard let session else { throw ChatError.modelUnavailable }
        let prompt = """
        Build a \(weeks)-week baseball strength program for a \(profileStore.experienceLevel.lowercased()) \(profileStore.position.lowercased()) using a push/pull/legs split. Equipment available: \(profileStore.selectedEquipment.map(\.rawValue).joined(separator: ", ")).
        """
        let response = try await session.respond(to: prompt, generating: WorkoutProgram.self)
        return response.content
    }

    func generateThrowingProgram(weeks: Int) async throws -> ThrowingProgram {
        guard let session else { throw ChatError.modelUnavailable }
        let prompt = """
        Build a \(weeks)-week throwing program for a \(profileStore.experienceLevel.lowercased()) \(profileStore.position.lowercased()), following conservative arm care progression.
        """
        let response = try await session.respond(to: prompt, generating: ThrowingProgram.self)
        return response.content
    }

    enum ChatError: LocalizedError {
        case modelUnavailable
        var errorDescription: String? { "The on-device model isn't available." }
    }
}
