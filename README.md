# gemini-model-registry

A tiny JSON file that maps logical Gemini model tier names (`flash`, `pro`, `flash-lite`) to the current generally-available model IDs.

Apps fetch this file at runtime so a Gemini deprecation can be patched without an App Store release.

## Usage

```
https://raw.githubusercontent.com/NSEvent/gemini-model-registry/main/registry.json
```

Consumers call the alias (`flash`, `pro`, `flash-lite`) and the registry resolves to the current model ID. Apps ship bundled defaults as a fallback so they work offline and on first launch.

## Schema

```json
{
  "schemaVersion": 1,
  "updated": "YYYY-MM-DD",
  "models": {
    "flash":      "gemini-3.5-flash",
    "flash-lite": "gemini-3.1-flash-lite",
    "pro":        "gemini-2.5-pro"
  }
}
```

- `schemaVersion` — bump only on breaking changes to the JSON shape.
- `updated` — ISO date of last change. Informational.
- `models` — alias → live model ID. Aliases are stable; values change as Google deprecates.

## Updating

When a model is deprecated:

1. Edit `registry.json`. Bump the value for the affected alias. Bump `updated`.
2. Commit and push to `main`.
3. Within 24h every consumer app picks up the new ID on its next launch (clients refresh on a 24h TTL).

That's it. No App Store release required.

## Clients

- Swift: [`clients/swift/GeminiModelRegistry.swift`](clients/swift/GeminiModelRegistry.swift) — singleton with UserDefaults caching, 24h TTL, bundled fallback.

Copy the client file into each app rather than depending on this repo via SPM. Keeps the dependency surface zero.

### Deprecation recovery

The Swift client also handles the case where Google deprecates a model mid-flight (between the user opening the app and making an API call, or before the 24h cache rolls over):

1. `GeminiModelRegistry.isDeprecationError(statusCode:body:)` — static classifier. Returns `true` if the Gemini response body indicates the requested model is no longer available. Matches Google's wording today; tolerant to drift.
2. `recoverFromDeprecation(failedModel:alias:)` — async. Force-refreshes the registry, then returns either `.retry(newModel:)` (registry now resolves the alias to a different ID, caller retries once) or `.giveUp` (no successor available, caller throws `ModelUnavailableError`).
3. `ModelUnavailableError` — a `LocalizedError` whose `errorDescription` is "This app's AI model is no longer available. Please update the app to the latest version." Designed to flow through existing per-app error UIs without per-app changes.

Call-site pattern:

```swift
let alias = "flash"
var model = GeminiModelRegistry.shared.flashModel

func send(model: String) async throws -> (Data, HTTPURLResponse) { /* … */ }

var (data, http) = try await send(model: model)
if GeminiModelRegistry.isDeprecationError(statusCode: http.statusCode, body: data) {
    switch await GeminiModelRegistry.shared.recoverFromDeprecation(failedModel: model, alias: alias) {
    case .retry(let newModel):
        model = newModel
        (data, http) = try await send(model: model)
        if GeminiModelRegistry.isDeprecationError(statusCode: http.statusCode, body: data) {
            throw GeminiModelRegistry.ModelUnavailableError()
        }
    case .giveUp:
        throw GeminiModelRegistry.ModelUnavailableError()
    }
}
```

Silent when the registry has a fix. User-visible message only when recovery genuinely can't help.

## Consumer apps

- Stock Inventory
- VoicePad
- WhisperCaptions (iOS app + CLI)
- MemeReact
- PocketDocs
- ScanPlan

When wiring a new app, also update bundled defaults in the copied Swift client so the first launch / offline case uses a known-good value.
