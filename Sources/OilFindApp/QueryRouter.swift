import Foundation

enum QueryRoute {
    case files(String)
    case waiting(WebKeyword)
    case web(WebPaletteItem)
}

struct QueryRouter {
    let keywords: [WebKeyword]
    func route(_ input: String, mode: SearchMode, isComposing: Bool = false, forceFiles: Bool = false) -> QueryRoute {
        guard !forceFiles, !isComposing, mode == .ordinary || mode == .application else { return .files(input) }
        let leadingTrimmed = String(input.drop(while: { $0.isWhitespace }))
        guard let separator = leadingTrimmed.firstIndex(where: { $0.isWhitespace }) else { return .files(input) }
        let key = String(leadingTrimmed[..<separator])
        guard let keyword = keywords.first(where: { $0.enabled && $0.isValid && $0.keyword == key }) else { return .files(input) }
        let argument = String(leadingTrimmed[separator...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if argument.isEmpty { return .waiting(keyword) }
        guard let url = keyword.searchURL(argument) else { return .files(input) }
        return .web(WebPaletteItem(keyword: keyword, text: argument, url: url))
    }
}
