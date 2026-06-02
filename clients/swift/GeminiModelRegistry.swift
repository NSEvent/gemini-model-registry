import Foundation

/// Resolves current Gemini model IDs from a public registry so we can react
/// to Google's model deprecations without an App Store release.
///
/// Registry: https://github.com/NSEvent/gemini-model-registry
///
/// Usage:
///   let model = GeminiModelRegistry.shared.flashModel
///   // call GeminiModelRegistry.shared.refreshIfStale() once on app launch
@MainActor
final class GeminiModelRegistry: ObservableObject {
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

    @Published private var models: [String: String]

    private init() {
        if let cached = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: String],
           !cached.isEmpty {
            self.models = cached
        } else {
            self.models = Self.bundledDefaults
        }
        refreshIfStale()
    }

    var flashModel: String { models["flash"] ?? Self.bundledDefaults["flash"]! }
    var flashLiteModel: String { models["flash-lite"] ?? Self.bundledDefaults["flash-lite"]! }
    var proModel: String { models["pro"] ?? Self.bundledDefaults["pro"]! }

    func refreshIfStale() {
        let lastFetch = UserDefaults.standard.double(forKey: Self.cacheTimestampKey)
        let age = Date().timeIntervalSince1970 - lastFetch
        guard age >= Self.cacheTTL else { return }
        Task { await Self.fetch() }
    }

    func refresh() {
        Task { await Self.fetch() }
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

        await MainActor.run {
            UserDefaults.standard.set(decoded.models, forKey: cacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimestampKey)
            shared.models = decoded.models
        }
    }

    private struct RegistryFile: Decodable {
        let schemaVersion: Int
        let updated: String
        let models: [String: String]
    }
}
