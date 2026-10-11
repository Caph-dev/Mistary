import XCTest
@testable import OilFindApp

final class QueryRouterTests: XCTestCase {
    let router = QueryRouter(keywords: WebKeyword.defaults)
    func assertFiles(_ input: String, mode: SearchMode = .ordinary, composing: Bool = false, force: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        guard case .files(let raw) = router.route(input, mode: mode, isComposing: composing, forceFiles: force) else { XCTFail("Expected file query", file: file, line: line); return }
        XCTAssertEqual(raw, input, file: file, line: line)
    }
    func testOnlyCompleteRegisteredKeywordWithWhitespaceRoutes() {
        for input in ["g", "wiki", "google hello", "greeting.txt", "G hello", "wik hello", "regex:g.*", "path:/tmp/g", "\"g hello\"", "/tmp/g file", "file:///tmp/g%20file"] { assertFiles(input) }
        for input in ["g hello", "  g\thello  ", "wiki 中文"] {
            guard case .web = router.route(input, mode: .ordinary) else { XCTFail(input); continue }
        }
        guard case .web(let command) = router.route("g kind:pdf", mode: .ordinary) else { return XCTFail() }
        XCTAssertEqual(command.text, "kind:pdf")
    }
    func testEmptyArgumentWaitsWithoutCreatingURL() {
        for input in ["g ", "wiki\t", "  g \n"] {
            guard case .waiting = router.route(input, mode: .ordinary) else { XCTFail(input); continue }
        }
    }
    func testURLParameterRoundTripsChineseAndReservedCharacters() throws {
        let argument = "中文 \"hello\" # & % + / ?\nnext"
        guard case .web(let result) = router.route("g " + argument, mode: .ordinary) else { return XCTFail() }
        let components = try XCTUnwrap(URLComponents(url: result.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "www.google.com")
        XCTAssertNil(components.fragment)
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: argument)])
        XCTAssertFalse(result.url.absoluteString.contains("#"))
        XCTAssertTrue(result.url.absoluteString.contains("%2B"))
        let formValue = try XCTUnwrap(components.percentEncodedQuery?.split(separator: "=", maxSplits: 1).last)
        XCTAssertEqual(String(formValue).replacingOccurrences(of: "+", with: " ").removingPercentEncoding, argument)
    }
    func testSaveOpenFinderAndCompositionKeepOriginalInput() {
        for mode in [SearchMode.save, .open, .finder] { assertFiles("g hello", mode: mode) }
        assertFiles("g hello", composing: true)
        assertFiles("g hello", force: true)
        guard case .web = router.route("g hello", mode: .application) else { return XCTFail() }
    }
    func testDisabledKeywordAndInvalidEndpointNeverRoute() {
        var keyword = WebKeyword.defaults[0]; keyword.enabled = false
        guard case .files = QueryRouter(keywords: [keyword]).route("g hello", mode: .ordinary) else { return XCTFail() }
        for endpoint in ["http://example.com", "https://user:password@example.com", "https://example.com/#fragment", "https://example.com/?q=old"] {
            keyword.endpoint = URL(string: endpoint)!; keyword.enabled = true
            XCTAssertFalse(keyword.isValid)
            XCTAssertNil(keyword.searchURL("hello"))
        }
    }
    func testConfigurationPersistsExactInstallPathsAndRecoversCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("launcher.json")
        var system = LauncherSystem(); system.isApplication = { $0.pathExtension == "app" }; system.bundleIdentifier = { _ in "same.bundle" }
        let store = LauncherPreferences(url: url, system: system)
        try store.add(root.appendingPathComponent("One.app"), alias: "一")
        try store.add(root.appendingPathComponent("Other/One.app"), alias: "二")
        try store.add(root.appendingPathComponent("./One.app"), alias: "更新")
        XCTAssertEqual(store.aliases.count, 2)
        var keywords = store.keywords; keywords[0].keyword = "gg"; try store.setKeywords(keywords)
        let loaded = LauncherPreferences(url: url, system: system)
        XCTAssertEqual(loaded.aliases, store.aliases); XCTAssertEqual(loaded.keywords, keywords)
        XCTAssertThrowsError(try loaded.add(URL(fileURLWithPath: "/tmp/file.txt"), alias: "bad"))
        XCTAssertThrowsError(try loaded.rename(loaded.aliases[0].id, alias: "  "))
        XCTAssertThrowsError(try loaded.setKeywords([keywords[0], keywords[0]]))
        let broken = Data("broken document".utf8); try broken.write(to: url)
        let corrupt = LauncherPreferences(url: url, system: system)
        XCTAssertNotNil(corrupt.error)
        XCTAssertThrowsError(try corrupt.add(root.appendingPathComponent("One.app"), alias: "one"))
        XCTAssertEqual(try Data(contentsOf: url), broken)
        try corrupt.reset()
        XCTAssertNil(corrupt.error)
        XCTAssertEqual(corrupt.keywords, WebKeyword.defaults)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension.hasPrefix("recovery-") })
        XCTAssertEqual(try Data(contentsOf: backup), broken)
    }
}
