import Foundation
import Combine

struct ApplicationAlias: Codable, Equatable, Identifiable {
    let id: UUID
    var alias: String
    let url: URL
    let bundleIdentifier: String?
}

struct WebKeyword: Codable, Equatable, Identifiable {
    var id: String { keyword }
    var keyword: String
    var name: String
    var endpoint: URL
    var parameter: String
    var enabled: Bool
    static let defaults: [WebKeyword] = [
        WebKeyword(keyword: "g", name: "Google", endpoint: URL(string: "https://www.google.com/search")!, parameter: "q", enabled: true),
        WebKeyword(keyword: "wiki", name: "Wikipedia", endpoint: URL(string: "https://zh.wikipedia.org/w/index.php")!, parameter: "search", enabled: true)
    ]
    var isValid: Bool {
        !keyword.isEmpty && keyword.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !parameter.isEmpty
            && Self.validURL(endpoint) && URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.query == nil
    }
    static func validURL(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme == "https" && !(c.host ?? "").isEmpty && c.user == nil && c.password == nil && c.fragment == nil
    }
    func searchURL(_ text: String) -> URL? {
        guard isValid, !text.isEmpty, var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: parameter, value: text)]
        // Search engines decode query values using form semantics, where '+' means space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url, Self.validURL(url), url.host == endpoint.host else { return nil }
        return url
    }
}

struct LauncherSystem {
    var bundleIdentifier: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
    var isApplication: (URL) -> Bool = { url in
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else { return false }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
    }
}

/// A small application-layer configuration; never scanned in index hot loops.
final class LauncherPreferences: ObservableObject {
    static let shared = LauncherPreferences(url: ProductIdentity.dataDirectory().appendingPathComponent("launcher.json"))
    private struct Document: Codable { let version: Int; let aliases: [ApplicationAlias]; let keywords: [WebKeyword] }
    enum ConfigurationError: Error { case invalidDocument, invalidApplication, invalidAlias, invalidKeyword }
    @Published private(set) var aliases: [ApplicationAlias] = []
    @Published private(set) var keywords = WebKeyword.defaults
    @Published private(set) var error: Error?
    private let url: URL?
    let system: LauncherSystem
    private var writable = true
    init(url: URL?, system: LauncherSystem = LauncherSystem()) {
        self.url = url; self.system = system
        guard let url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576 else { throw ConfigurationError.invalidDocument }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1, Self.valid(document.aliases, document.keywords) else { throw ConfigurationError.invalidDocument }
            aliases = document.aliases; keywords = document.keywords
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError { self.error = error; writable = false }
        }
    }
    private static func valid(_ aliases: [ApplicationAlias], _ keywords: [WebKeyword]) -> Bool {
        aliases.count <= 128 && keywords.count <= 16 && Set(aliases.map(\.id)).count == aliases.count
            && Set(aliases.map { ApplicationPaletteItem.normalizedURL($0.url) }).count == aliases.count
            && aliases.allSatisfy { !$0.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.url.isFileURL && $0.url.pathExtension.lowercased() == "app" }
            && Set(keywords.map(\.keyword)).count == keywords.count && keywords.allSatisfy(\.isValid)
    }
    private func save(aliases: [ApplicationAlias], keywords: [WebKeyword]) throws {
        guard writable, Self.valid(aliases, keywords) else { throw ConfigurationError.invalidDocument }
        do {
            if let url {
                let data = try JSONEncoder().encode(Document(version: 1, aliases: aliases, keywords: keywords))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            self.aliases = aliases; self.keywords = keywords; error = nil
        } catch { self.error = error; throw error }
    }
    func add(_ url: URL, alias: String) throws {
        guard url.isFileURL else { throw ConfigurationError.invalidApplication }
        let url = ApplicationPaletteItem.normalizedURL(url), name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ConfigurationError.invalidAlias }
        guard system.isApplication(url) else { throw ConfigurationError.invalidApplication }
        var updated = aliases
        if let i = updated.firstIndex(where: { ApplicationPaletteItem.normalizedURL($0.url) == url }) { updated[i].alias = name }
        else { updated.append(ApplicationAlias(id: UUID(), alias: name, url: url, bundleIdentifier: system.bundleIdentifier(url))) }
        try save(aliases: updated, keywords: keywords)
    }
    func rename(_ id: UUID, alias: String) throws {
        let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ConfigurationError.invalidAlias }
        var updated = aliases
        guard let i = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[i].alias = name; try save(aliases: updated, keywords: keywords)
    }
    func remove(_ id: UUID) throws { try save(aliases: aliases.filter { $0.id != id }, keywords: keywords) }
    func setKeywords(_ updated: [WebKeyword]) throws {
        guard updated.allSatisfy(\.isValid) else { throw ConfigurationError.invalidKeyword }
        try save(aliases: aliases, keywords: updated)
    }
    /// Explicit recovery preserves the original bytes for manual repair.
    func reset() throws {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.copyItem(at: url, to: url.appendingPathExtension("recovery-" + UUID().uuidString))
        }
        let previous = writable; writable = true
        do { try save(aliases: [], keywords: WebKeyword.defaults) }
        catch { writable = previous; throw error }
    }
    func candidates(for input: String) -> [PaletteItem] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return aliases.filter { $0.alias.localizedCaseInsensitiveContains(text) }.map {
            .application(ApplicationPaletteItem(url: $0.url, name: $0.alias, bundleIdentifier: $0.bundleIdentifier, available: system.isApplication($0.url) && ($0.bundleIdentifier == nil || system.bundleIdentifier($0.url) == $0.bundleIdentifier)))
        }
    }
}
