import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class ProductIsolationTests: XCTestCase {
    func testIdentityAndIndexNeverFallBackToUpstream() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryIsolation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Library/Application Support/Oil Find/index.oilfind")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = Data("upstream sentinel".utf8)
        try marker.write(to: old)
        let index = ProductIdentity.indexURL(home: root)
        XCTAssertEqual(index.path, root.path + "/Library/Application Support/Mistary/index.oilfind")
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("personal index".utf8).write(to: index)
        XCTAssertEqual(try Data(contentsOf: old), marker)
        XCTAssertEqual(ProductIdentity.displayName, "Mistary")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "me.caph.mistary")
        XCTAssertEqual(ProductIdentity.urlScheme, "mistary")
        XCTAssertEqual(ProductIdentity.showRequest.rawValue, "me.caph.mistary.show")
        XCTAssertEqual(AppDelegate.dbURL, ProductIdentity.indexURL())
    }

    func testInjectedPreferenceDomainsDoNotReadOrMutateUpstream() throws {
        let suffix = UUID().uuidString
        let oldName = "com.oiloil.find.tests." + suffix
        let newName = ProductIdentity.bundleIdentifier + ".tests." + suffix
        let old = try XCTUnwrap(UserDefaults(suiteName: oldName))
        let personal = try XCTUnwrap(UserDefaults(suiteName: newName))
        defer { old.removePersistentDomain(forName: oldName); personal.removePersistentDomain(forName: newName) }
        old.set("en", forKey: AppLanguage.preferenceKey)
        old.set(false, forKey: "pinyinEnabled")
        old.set("legacy sentinel", forKey: "trialStartedAt")
        let before = old.persistentDomain(forName: oldName)!
        SettingsPreferences.register(in: personal)
        XCTAssertEqual(AppLanguage.load(from: personal), .system)
        XCTAssertTrue(SettingsPreferences.searchOptions(in: personal).pinyin)
        let language = L10n.language
        defer { L10n.setLanguage(language, in: personal) }
        L10n.setLanguage(.chinese, in: personal)
        XCTAssertEqual(AppLanguage.load(from: personal), .chinese)
        XCTAssertEqual(old.persistentDomain(forName: oldName)! as NSDictionary, before as NSDictionary)
    }

    func testUpdateOperationsStayDisabledDespitePersistedOptInAndRestart() throws {
        let name = ProductIdentity.bundleIdentifier + ".updates.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "automaticUpdates")
        defaults.set("old", forKey: "skippedUpdateVersion")
        let before = defaults.persistentDomain(forName: name)!
        for _ in 0..<2 {
            let model = UpdateManager(preferences: UpdatePreferences(defaults: defaults))
            var changes = 0
            model.onChange = { changes += 1 }
            model.automatic = true
            model.start(); model.check(); model.check(manual: false)
            model.present(); model.install(); model.skip(); model.openWebsite()
            model.reportLaunchFailure(.signature); model.stop()
            XCTAssertFalse(model.isEnabled)
            XCTAssertFalse(model.automatic)
            XCTAssertFalse(model.canCheck)
            XCTAssertFalse(model.preventsTermination)
            XCTAssertEqual(model.state, .idle)
            XCTAssertNil(model.manifest)
            XCTAssertEqual(changes, 0)
        }
        XCTAssertEqual(defaults.persistentDomain(forName: name)! as NSDictionary, before as NSDictionary)
    }

    func testMenuReopenAndURLDoNotEnableUpdates() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let menu = delegate.makeMenu()
        XCTAssertFalse(menu.items.contains { $0.title == L10n.text("update.check") })
        delegate.application(NSApplication.shared, open: [URL(string: "oilfind://update")!, URL(string: "mistary://update")!])
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        // Reopening only displays the search panel; it does not start an updater.
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertFalse(UpdateManager.shared.canCheck)
        XCTAssertEqual(UpdateManager.shared.state, .idle)
        NSApplication.shared.windows.forEach { $0.orderOut(nil) }
    }

    func testUpdateArgumentsAreRejectedBeforeLaunchInEveryConfiguration() {
        XCTAssertNoThrow(try Application.validateArguments([]))
        for flag in ["--update-exercise", "--update-launch", "--update-manifest", "--update-notes"] {
            XCTAssertThrowsError(try Application.validateArguments([flag, "unused"]))
        }
        #if DEBUG
        XCTAssertThrowsError(try Snapshot.run(["--snapshot", "/unused.png", "--state", "update-available"]))
        #endif
    }
}
