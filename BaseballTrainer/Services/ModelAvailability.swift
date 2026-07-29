import FoundationModels

/// Wraps SystemLanguageModel's availability check so the UI can show a clear
/// message instead of a crash when the on-device model can't run.
///
/// Requirements as of the FoundationModels framework: a device with Apple
/// Intelligence support (iPhone 15 Pro or newer, M-series iPad/Mac), Apple
/// Intelligence turned on in Settings, and the model finished downloading.
enum ModelAvailability {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    /// A user-facing explanation when the model can't be used, or nil if it's ready.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support the on-device model. You'll need an iPhone 15 Pro or newer, or an Apple Silicon iPad/Mac."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings > Apple Intelligence & Siri to use the on-device coach."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Try again in a few minutes."
        case .unavailable:
            return "The on-device model isn't available right now."
        }
    }
}
