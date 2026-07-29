# Baseball Trainer — On-Device LLM Coach

A SwiftUI app scaffold that uses Apple's **FoundationModels** framework
(the on-device Apple Intelligence LLM) to power a chatbot that:

- Builds multi-week strength programs (push/pull/legs split) filtered to
  the athlete's actual equipment, biased toward baseball transfer
  (rotational power, leg drive, arm-care balance).
- Builds throwing progressions using conservative, phase-based arm-care
  guidelines.
- Answers general arm-care questions, with hard guardrails against
  diagnosing injuries.
- Tracks a completed session's exercises and renders a donut chart of
  which muscle groups got the most volume (`Progress` tab).

## How to turn this into an Xcode project

1. In Xcode 26+, create a new **App** target (SwiftUI interface,
   Swift language), deployment target **iOS 18.1+** (device features
   requiring the live model need an Apple Intelligence–eligible device or
   simulator — see below).
2. Delete the default `ContentView.swift`/`App.swift` Xcode generates.
3. Drag the `BaseballTrainer/` folder (with its `App`, `Models`, `Data`,
   `Tools`, `Services`, `Chat`, `Onboarding`, `Progress` subfolders) into
   the project navigator, keeping the folder structure and adding it to
   your app target.
4. Make sure `import FoundationModels` and `import Charts` resolve —
   both ship with the SDK, no package dependency needed.
5. Build & run on an Apple Intelligence–eligible device or the
   corresponding simulator, with Apple Intelligence turned on in Settings.

## Device requirements for the live model

The on-device model needs:
- iPhone 15 Pro or newer (or Apple Silicon iPad/Mac), and
- Apple Intelligence enabled in Settings, and
- The model finished downloading on-device.

`Services/ModelAvailability.swift` checks `SystemLanguageModel.default.availability`
and `ChatView` shows a clear fallback message instead of crashing when any
of the above isn't true — check that file first if the chat tab shows
"On-device model unavailable."

### If a user's device isn't Apple Intelligence–eligible

This scaffold is on-device only, as requested. If you want a fallback for
unsupported devices without paying for an API, the two realistic
zero-cost paths are:
- **Ollama** running on the user's own Mac, with the app talking to it
  over the local network — still free, but requires a Mac on the same
  network, not fully "in your pocket."
- **A free-tier hosted inference API** (e.g. Hugging Face's Inference
  API) — free within rate limits, but no longer on-device, so it needs
  network access and you'd want to swap out `LanguageModelSession` for an
  HTTP client behind the same `ChatViewModel` interface.

Neither is wired up here since it's a materially different architecture
(network client vs. on-device session) — happy to build one out as a
separate fallback path if you want it.

## Where things live

| File | Purpose |
|---|---|
| `Models/Exercise.swift`, `Data/ExerciseDatabase.swift` | Exercise database with per-exercise muscle activation estimates and baseball coaching notes. Add your own exercises directly to the arrays in `ExerciseDatabase.swift`. |
| `Models/Equipment.swift` | Equipment catalog + gym presets (Full Gym / Home Gym / Bodyweight Only / Custom). |
| `Models/ProgramModels.swift` | `@Generable` structs (`WorkoutProgram`, `ThrowingProgram`) that constrain the model's output to a typed shape instead of free text. |
| `Tools/*.swift` | `Tool` conformances the model calls to ground its answers in the real exercise database and arm-care guidelines instead of hallucinating. |
| `Chat/ChatViewModel.swift` | Owns the `LanguageModelSession`, system instructions (including the arm-care safety rules), and streaming chat logic. |
| `Onboarding/EquipmentSelectionView.swift` | Equipment multi-select + athlete profile (position, experience). |
| `Progress/*.swift` | Session logging + `SectorMark`-based donut chart of muscle volume. |

## Safety notes baked into the system instructions

- The assistant is instructed to never diagnose injuries and to tell the
  athlete to stop and see a sports medicine professional or athletic
  trainer for pain, numbness, tingling, or a sudden drop in
  velocity/control.
- Throwing progressions never combine a distance increase and an
  intensity increase in the same session, and weighted-ball work is
  flagged as needing in-person supervision, not recommended for youth
  athletes.
- The disclaimer footer in `ChatView` ("Not a medical device...") is
  always visible, not just in the system prompt.

Adjust the wording in `ChatViewModel.systemInstructions` if you want a
different tone, but keep the safety rules intact.
