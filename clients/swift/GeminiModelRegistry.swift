import Foundation

/// Resolves current Gemini model IDs from a public registry so we can react
/// to Google's model deprecations without an App Store release.
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
/// Thread-safe. UserDefaults-backed so reads are O(1) from any queue.
final class GeminiModelRegistry: @unchecked Sendable {
    static let shared = GeminiModelRegistry()

    private static let registryURL = URL(
        string: "https://raw.githubusercontent.com/NSEvent/gemini-model-registry/main/registry.json"
    )!
    private static let cacheKey = "geminiModelRegistry.cached"
    private static let cacheTimestampKey = "geminiModelRegistry.cachedAt"
    private static let cacheTTL: TimeInterval = 24 * 60 * 60

    // Bundled fallback. Used until the first successful fetch. Keep in sync with
    // registry.json when shipping a new build — these are the values the app will
    // use if the registry is unreachable on first launch.
    private static let bundledDefaults: [String: String] = [
        "flash": "gemini-3.5-flash",
        "flash-lite": "gemini-3.1-flash-lite",
        "pro": "gemini-2.5-pro"
    ]

    private init() {
        refreshIfStale()
    }

    var flashModel: String { resolve("flash") }
    var flashLiteModel: String { resolve("flash-lite") }
    var proModel: String { resolve("pro") }

    private func resolve(_ alias: String) -> String {
        if let cached = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: String],
           let value = cached[alias] {
            return value
        }
        return Self.bundledDefaults[alias] ?? Self.bundledDefaults["flash"]!
    }

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

        UserDefaults.standard.set(decoded.models, forKey: cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimestampKey)
    }

    private struct RegistryFile: Decodable {
        let schemaVersion: Int
        let updated: String
        let models: [String: String]
    }
}
