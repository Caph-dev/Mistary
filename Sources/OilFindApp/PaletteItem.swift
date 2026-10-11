import Foundation

struct WebPaletteItem {
    let keyword: WebKeyword
    let text: String
    let url: URL
}

struct ApplicationPaletteItem {
    static func normalizedURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: false)
    }
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let available: Bool
    var usageGroup: String? = nil
}

/// File rows retain their presentation, including source and supplementary details.
enum PaletteItem {
    case file(SearchPresentation, row: Int)
    case application(ApplicationPaletteItem)
    case web(WebPaletteItem)
    var identity: String {
        switch self {
        case .file(let presentation, let row):
            guard let hit = presentation.row(row) else { return "file:invalid" }
            return "file:\(hit.source.id):\(ObjectIdentifier(hit.source.store)):\(hit.id)"
        case .application(let app): return "app:" + ApplicationPaletteItem.normalizedURL(app.url).absoluteString
        case .web(let web): return "web:" + web.url.absoluteString
        }
    }
    var actions: [FileAction] {
        switch self {
        case .file: return FileAction.allCases
        case .application: return [.open, .reveal, .copyFile, .copyPath, .copyName]
        case .web: return [.open]
        }
    }
}
