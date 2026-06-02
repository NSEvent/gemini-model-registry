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

## Consumer apps

- Stock Inventory
- VoicePad
- WhisperCaptions (iOS app + CLI)
- MemeReact
- PocketDocs
- ScanPlan

When wiring a new app, also update bundled defaults in the copied Swift client so the first launch / offline case uses a known-good value.
