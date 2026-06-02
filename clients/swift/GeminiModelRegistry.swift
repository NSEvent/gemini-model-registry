import Foundation

/// Resolves current Gemini model IDs and tier metadata from a public registry
/// so we can react to Google's model deprecations (or update display labels for
/// the user-facing picker) without an App Store release.
///
/// Registry: https://github.com/NSEvent/gemini-model-registry
///
/// Usage at call site:
///   let model = GeminiModelRegistry.shared.flashModel
///   // Make request. If Gemini returns a deprecation error, recover:
///   if GeminiModelRegistry.isDeprecationError(statusCode: status, body: data) {
///       switch await GeminiModelRegistry.shared.recoverFromDeprecation(failedModel: model, alias: "flash") {
///       case .retry(let newModel): // rebuild request with newModel, send once more
///       case .giveUp: throw GeminiModelRegistry.ModelUnavailableError()
///       }
///   }
///
/// Usage in UI (provider picker):
///   ForEach(GeminiModelRegistry.shared.tiers) { tier in
///       Text(tier.displayName).tag(tier.alias)
///   }
///   // Observe .didUpdate notification to rebuild the picker when the registry refreshes:
///   .onReceive(NotificationCenter.default.publisher(for: GeminiModelRegistry.didUpdate)) { _ in /* refresh */ }
///
/// Thread-safe. UserDefaults-backed so reads are O(1) from any queue.
final class GeminiModelRegistry: @unchecked Sendable {
    static let shared = GeminiModelRegistry()

    /// Notification posted on the main queue whenever a registry fetch succeeds
    /// and the cached values change. UI surfaces that show tier names should
    /// listen for this and rebuild.
    static let didUpdate = Notification.Name("GeminiModelRegistry.didUpdate")

    private static let registryURL = URL(
        string: "https://raw.githubusercontent.com/NSEvent/gemini-model-registry/main/registry.json"
    )!
    private static let modelsKey = "geminiModelRegistry.cached"
    private static let tiersKey = "geminiModelRegistry.cachedTiers"
    private static let cacheTimestampKey = "geminiModelRegistry.cachedAt"
    private static let cacheTTL: TimeInterval = 24 * 60 * 60

    // Bundled fallback for model IDs. Used until the first successful fetch.
    // Keep in sync with registry.json when shipping a new build.
    private static let bundledDefaults: [String: String] = [
        "flash": "gemini-3.5-flash",
        "flash-lite": "gemini-3.1-flash-lite",
        "pro": "gemini-2.5-pro"
    ]

    // Bundled fallback for tier display info shown in pickers.
    // Order here = display order in the UI.
    private static let bundledTiers: [Tier] = [
        Tier(alias: "flash", displayName: "Gemini 3.5 Flash", description: "Fast, latest model"),
        Tier(alias: "pro", displayName: "Gemini 2.5 Pro", description: "Most capable")
    ]

    struct Tier: Codable, Hashable, Identifiable, Sendable {
        let alias: String
        let displayName: String
        let description: String

        var id: String { alias }
    }

    private init() {
        refreshIfStale()
    }

    // MARK: - Model ID resolution

    var flashModel: String { resolve("flash") }
    var flashLiteModel: String { resolve("flash-lite") }
    var proModel: String { resolve("pro") }

    private func resolve(_ alias: String) -> String {
        if let cached = UserDefaults.standard.dictionary(forKey: Self.modelsKey) as? [String: String],
           let value = cached[alias] {
            return value
        }
        return Self.bundledDefaults[alias] ?? Self.bundledDefaults["flash"]!
    }

    // MARK: - Tier list for UI

    /// Returns the current tier list (cached registry values, or bundled defaults
    /// before the first successful fetch). Pickers should call this each time
    /// they rebuild the option list.
    var tiers: [Tier] {
        if let data = UserDefaults.standard.data(forKey: Self.tiersKey),
           let decoded = try? JSONDecoder().decode([Tier].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return Self.bundledTiers
    }

    /// Find a tier by alias, or nil if no such tier exists in the current list.
    func tier(forAlias alias: String) -> Tier? {
        tiers.first { $0.alias == alias }
    }

    // MARK: - Refresh

    func refreshIfStale() {
        let lastFetch = UserDefaults.standard.double(forKey: Self.cacheTimestampKey)
        let age = Date().timeIntervalSince1970 - lastFetch
        guard age >= Self.cacheTTL else { return }
        Task.detached { await Self.fetch() }
    }

    func refresh() {
        Task.detached { await Self.fetch() }
    }

    // MARK: - Deprecation recovery

    /// Returns true if the given HTTP response from the Gemini REST API indicates
    /// the requested model is deprecated or no longer available. Matches Google's
    /// current error wording; tolerant to phrasing drift.
    static func isDeprecationError(statusCode: Int, body: Data?) -> Bool {
        guard statusCode >= 400, let body, let str = String(data: body, encoding: .utf8) else {
            return false
        }
        let lower = str.lowercased()
        return lower.contains("no longer available")
            || lower.contains("is not found for api version")
            || lower.contains("is not supported")
            || lower.contains("has been deprecated")
    }

    enum RecoveryOutcome {
        /// Registry refresh produced a different model ID for this alias; caller should retry once.
        case retry(newModel: String)
        /// Registry has no different model to offer (already current, or fetch failed); caller should give up.
        case giveUp
    }

    /// Call this when a Gemini API request fails with a deprecation error.
    /// Force-refreshes the registry, then reports whether the alias now resolves
    /// to a different model so the caller can retry.
    func recoverFromDeprecation(failedModel: String, alias: String) async -> RecoveryOutcome {
        await Self.fetch()
        let fresh = resolve(alias)
        return fresh != failedModel ? .retry(newModel: fresh) : .giveUp
    }

    /// Error to throw when recovery fails — the API rejected the model and the
    /// registry has no working replacement. The default localizedDescription is
    /// designed to flow through existing per-app error UIs unchanged.
    struct ModelUnavailableError: LocalizedError {
        var errorDescription: String? {
            "This app's AI model is no longer available. Please update the app to the latest version."
        }
    }

    // MARK: - Fetch implementation

    private static func fetch() async {
        var request = URLRequest(url: registryURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let decoded = try? JSONDecoder().decode(RegistryFile.self, from: data),
            !decoded.models.isEmpty
        else { return }

        var changed = false

        let oldModels = UserDefaults.standard.dictionary(forKey: modelsKey) as? [String: String] ?? [:]
        if oldModels != decoded.models {
            UserDefaults.standard.set(decoded.models, forKey: modelsKey)
            changed = true
        }

        if let tiers = decoded.tiers,
           let encoded = try? JSONEncoder().encode(tiers) {
            let oldEncoded = UserDefaults.standard.data(forKey: tiersKey)
            if oldEncoded != encoded {
                UserDefaults.standard.set(encoded, forKey: tiersKey)
                changed = true
            }
        }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimestampKey)

        if changed {
            await MainActor.run {
                NotificationCenter.default.post(name: didUpdate, object: nil)
            }
        }
    }

    private struct RegistryFile: Decodable {
        let schemaVersion: Int
        let updated: String
        let models: [String: String]
        let tiers: [Tier]?
    }
}
