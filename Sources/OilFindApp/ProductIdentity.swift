import Foundation

// App-layer identity. Bundle metadata and shell scripts are checked against this in tests.
enum ProductIdentity {
    static let displayName = "Mistary"
    static let bundleIdentifier = "me.caph.mistary"
    static let urlScheme = "mistary"
    static let supportsUpdates = false
    static let showRequest = Notification.Name(bundleIdentifier + ".show")

    static func dataDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/" + displayName, isDirectory: true)
    }
    static func indexURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        dataDirectory(home: home).appendingPathComponent("index.oilfind")
    }
}
