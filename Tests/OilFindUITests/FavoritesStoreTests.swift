import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class FavoritesStoreTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryFavorites-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testAddEditReorderRemoveAndRestartPreserveDirectoryFiles() throws {
        let root = try temporary(), url = root.appendingPathComponent("favorites.json")
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let file = a.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: file)
        let store = FavoritesStore(url: url)
        let first = try store.add(a, sourceID: "disk"), second = try store.add(b)
        XCTAssertEqual(try store.add(a), first)
        try store.rename(first, to: "Work"); try store.move(first, by: 1)
        let restarted = FavoritesStore(url: url)
        XCTAssertEqual(restarted.favorites.map(\.id), [second, first])
        XCTAssertEqual(restarted.favorites[1].name, "Work"); XCTAssertEqual(restarted.favorites[1].sourceID, "disk")
        XCTAssertEqual(restarted.resolve(restarted.favorites[1]).0.path, a.path)
        try restarted.remove(first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
        XCTAssertEqual(FavoritesStore(url: url).favorites.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["a", "b", "favorites.json"])
    }
    func testBrokenAndUnknownVersionDocumentsCannotBeOverwritten() throws {
        let root = try temporary(), url = root.appendingPathComponent("favorites.json")
        for data in [Data("broken".utf8), Data("{\"version\":99,\"favorites\":[]}".utf8)] {
            try data.write(to: url)
            let store = FavoritesStore(url: url)
            XCTAssertNotNil(store.error)
            XCTAssertThrowsError(try store.add(root))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }
    func testMissingAndCorruptBookmarkUseExplicitPathFallback() throws {
        let root = try temporary()
        var system = FavoriteSystem()
        system.bookmark = { _ in Data([1, 2, 3]) }
        system.resolve = { _ in throw FavoritesStore.StoreError.unavailableDirectory }
        let store = FavoritesStore(url: root.appendingPathComponent("favorites.json"), system: system)
        _ = try store.add(root, name: "Fallback")
        let result = store.resolve(store.favorites[0])
        XCTAssertEqual(result.0.path, root.path); XCTAssertEqual(result.1, .available)
        system.check = { _ in .permission }
        let denied = FavoritesStore(url: root.appendingPathComponent("favorites.json"), system: system)
        XCTAssertEqual(denied.resolve(denied.favorites[0]).1, .permission)
        system.check = { _ in .missing }
        let missing = FavoritesStore(url: root.appendingPathComponent("favorites.json"), system: system)
        XCTAssertEqual(missing.resolve(missing.favorites[0]).1, .missing)
        XCTAssertEqual(missing.favorites.count, 1)
    }
    func testResolvedBookmarkCanFollowMoveWithoutChangingFrozenScope() throws {
        let root = try temporary(), moved = root.appendingPathComponent("moved")
        var system = FavoriteSystem(); system.check = { _ in .available }
        system.bookmark = { _ in Data([1]) }; system.resolve = { _ in moved }
        let store = FavoritesStore(url: nil, system: system)
        _ = try store.add(root)
        let session = SearchSession(); session.setDirectoryScope(root)
        XCTAssertEqual(store.resolve(store.favorites[0]).0, moved)
        XCTAssertEqual(session.directoryScope?.path, root.path)
    }
    func testWriteFailureDoesNotCommitInMemoryChanges() throws {
        let root = try temporary(), blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let store = FavoritesStore(url: blocker.appendingPathComponent("favorites.json"))
        XCTAssertThrowsError(try store.add(root)); XCTAssertTrue(store.favorites.isEmpty)
    }
    func testCandidatesKeepUnindexedAndOfflineSeparateFromSearchHits() throws {
        let root = try temporary(), other = try temporary()
        let favorites = FavoritesStore(url: nil)
        _ = try favorites.add(root, name: "Unindexed")
        _ = try favorites.add(other, name: "Offline", sourceID: "disk")
        let config = IndexConfig(rootPath: other.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let finder = FinderDirectory(windowIdentity: UUID(), directoryURL: root, observedAt: Date(), method: .accessibility)
        let candidates = DirectoryCandidates.make(finder: finder, favorites: favorites, sources: [SearchSource(id: "disk", displayName: "Disk", isOnline: false, store: store)])
        XCTAssertEqual(candidates.map(\.origin), [.finder, .favorite, .favorite])
        XCTAssertEqual(candidates.map(\.availability), [.unindexed, .unindexed, .offline])
        XCTAssertEqual(candidates.last?.sourceName, "Disk")
        XCTAssertEqual(candidates.first?.finderDirectory?.windowIdentity, finder.windowIdentity)
    }
    func testEmptyQueryShowsFavoritesAndRecentlyModifiedGroups() throws {
        _ = NSApplication.shared
        let root = try temporary(), favorites = FavoritesStore(url: nil)
        _ = try favorites.add(root, name: "My Folder")
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let controller = SearchViewController(snapshot: true, favorites: favorites)
        try controller.prepareSnapshot(state: "recent", query: "", options: .init(), store: store, selection: 0)
        let stack = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSStackView }.first)
        XCTAssertFalse(stack.isHidden)
        let labels = stack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains(L10n.text("directory.favorites")))
        XCTAssertTrue(labels.contains(L10n.text("directory.recent")))
        XCTAssertTrue(stack.arrangedSubviews.contains { ($0 as? NSButton)?.title.contains("My Folder") == true })
        XCTAssertEqual(controller.directoryCandidates.first?.availability, .available)
        XCTAssertEqual(controller.results.result?.total, 0)
        XCTAssertEqual(controller.directoryMenu().items.filter { $0.submenu != nil }.count, 1)
    }
}
