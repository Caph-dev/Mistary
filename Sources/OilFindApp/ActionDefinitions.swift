import Foundation
import Combine

// Configuration declares requirements; it does not sandbox user-selected executables.
enum ActionItemType: String, Codable { case file, application, web }
enum ActionPermission: String, Codable { case fileRead, processExecution }
enum ActionExecution: Codable, Equatable {
    case application(URL)
    case urlTemplate(String)
    case command(executable: URL, arguments: [String], currentDirectory: String?)
    case terminal(URL)
}

struct ActionBinding {
    let type: ActionItemType
    let url: URL
    let name: String
    let directory: URL?
    var values: [String: String] {
        var values = ["{url}": url.absoluteString, "{name}": name]
        if url.isFileURL { values["{path}"] = url.path }
        if let directory { values["{directory}"] = directory.path }
        return values
    }
    // Walk the template once: substituted data must never be interpreted again.
    func substitute(_ template: String, encoded: Bool = false) throws -> String {
        var output = "", remaining = template[...]
        while let start = remaining.firstIndex(of: "{") {
            output += remaining[..<start]
            guard let end = remaining[start...].firstIndex(of: "}"),
                  let value = values[String(remaining[start...end])] else { throw ActionConfigurationError.invalidDefinition }
            if encoded {
                let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                output += value.addingPercentEncoding(withAllowedCharacters: safe) ?? ""
            } else { output += value }
            remaining = remaining[remaining.index(after: end)...]
        }
        output += remaining
        return output
    }
}

enum ActionConfigurationError: Error { case invalidDefinition, invalidDocument }
struct ActionDefinition: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var itemTypes: [ActionItemType]
    var modes: [String]
    var permissions: [ActionPermission]
    var enabled: Bool
    var execution: ActionExecution
    // Custom actions emit events but do not feed usage ranking until plan 008.
    var recordsUsage: Bool = false
    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 256,
              !itemTypes.isEmpty, Set(itemTypes).count == itemTypes.count,
              !modes.isEmpty, modes.allSatisfy({ SearchMode(rawValue: $0) != nil }),
              !recordsUsage else { return false }
        let binding = ActionBinding(type: .file, url: URL(fileURLWithPath: "/tmp/test"), name: "test", directory: URL(fileURLWithPath: "/tmp"))
        func validTemplate(_ value: String) -> Bool {
            !value.utf8.contains(0) && value.count <= 16_384 && (try? binding.substitute(value)) != nil
        }
        switch execution {
        case .application(let url), .terminal(let url):
            return itemTypes.allSatisfy { $0 != .web } && permissions.contains(.fileRead)
                && url.isFileURL && url.path.hasPrefix("/") && url.pathExtension.lowercased() == "app"
        case .urlTemplate(let template):
            guard validTemplate(template), let c = URLComponents(string: template), c.scheme == "https",
                  let host = c.host, !host.isEmpty, !host.contains("{"), c.user == nil, c.password == nil,
                  !(c.scheme ?? "").contains("{") else { return false }
            return true
        case .command(let url, let arguments, let directory):
            return permissions.contains(.processExecution) && url.isFileURL && url.path.hasPrefix("/")
                && !url.path.utf8.contains(0) && arguments.count <= 128 && arguments.allSatisfy(validTemplate)
                && (directory == nil || validTemplate(directory!))
                && (!itemTypes.contains(.web) || (!arguments.contains(where: { $0.contains("{path}") || $0.contains("{directory}") }) && directory == nil))
        }
    }
    func unavailableReason(binding: ActionBinding, mode: SearchMode, permission: (ActionPermission) -> Bool,
                           application: (URL) -> Bool, executable: (URL) -> Bool) -> ActionFailure? {
        guard isValid, enabled, itemTypes.contains(binding.type), modes.contains(mode.rawValue) else { return .unsupportedAction }
        guard permissions.allSatisfy(permission) else { return .permissionDenied }
        switch execution {
        case .terminal: return .terminalUnsupported
        case .application(let url): return application(url) ? nil : .applicationUnavailable
        case .command(let url, _, _): return executable(url) ? nil : .executableUnavailable
        case .urlTemplate: return (try? boundURL(binding)) == nil ? .invalidURL : nil
        }
    }
    func boundURL(_ binding: ActionBinding) throws -> URL {
        guard case .urlTemplate(let template) = execution,
              let initial = URLComponents(string: template),
              let url = URL(string: try binding.substitute(template, encoded: true)),
              let final = URLComponents(url: url, resolvingAgainstBaseURL: false), final.scheme == "https",
              final.host == initial.host, final.user == nil, final.password == nil else { throw ActionConfigurationError.invalidDefinition }
        return url
    }
}

final class ActionDefinitions: ObservableObject {
    static let shared = ActionDefinitions(url: ProductIdentity.dataDirectory().appendingPathComponent("actions.json"))
    private struct Document: Codable { let version: Int; let actions: [ActionDefinition] }
    @Published private(set) var actions: [ActionDefinition] = []
    @Published private(set) var error: Error?
    private let url: URL?
    private var writable = true
    init(url: URL?) {
        self.url = url
        guard let url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576 else { throw ActionConfigurationError.invalidDocument }
            let doc = try JSONDecoder().decode(Document.self, from: data)
            guard doc.version == 1, Self.valid(doc.actions) else { throw ActionConfigurationError.invalidDocument }
            actions = doc.actions
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError { self.error = error; writable = false }
        }
    }
    private static func valid(_ actions: [ActionDefinition]) -> Bool {
        actions.count <= 128 && Set(actions.map(\.id)).count == actions.count && actions.allSatisfy(\.isValid)
    }
    func set(_ updated: [ActionDefinition]) throws {
        guard writable, Self.valid(updated) else { throw ActionConfigurationError.invalidDocument }
        do {
            if let url {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(Document(version: 1, actions: updated)).write(to: url, options: .atomic)
            }
            actions = updated; error = nil
        } catch { self.error = error; throw error }
    }
}

extension SearchMode {
    static let allActionModes = ["ordinary", "application", "finder", "open", "save"]
}
