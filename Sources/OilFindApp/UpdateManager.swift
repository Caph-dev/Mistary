import AppKit
import OilFindCore

enum UpdateState: Equatable {
    case idle, checking, available, downloading(Double), installing, latest, failed(UpdateFailure)
    var busy: Bool {
        switch self { case .checking, .downloading, .installing: return true; default: return false }
    }
    var installing: Bool {
        switch self { case .downloading, .installing: return true; default: return false }
    }
}

// Mistary has no update source. No production network, installer or receipt handling lives here.
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    static var current: UpdateVersion {
        UpdateVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4.1",
                      build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "9") ?? 9)
            ?? UpdateVersion("1.4.1", build: 9)!
    }
    let isEnabled = ProductIdentity.supportsUpdates
    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var manifest: UpdateManifest?
    @Published var automatic = false { didSet { if automatic { automatic = false } } }
    var onChange: (() -> Void)?
    let runningVersion: UpdateVersion
    private let snapshot: Bool
    var preventsTermination: Bool { false }
    var canCheck: Bool { false }

    init(snapshot: Bool = false, preferences: UpdatePreferences = UpdatePreferences(), current: UpdateVersion = UpdateManager.current) {
        self.snapshot = snapshot
        runningVersion = current
        // Deliberately do not read or write update preferences, even when automaticUpdates is true.
    }
    func start() {}
    func stop() {}
    func check(manual: Bool = true) {}
    func present() {}
    func dismiss() {}
    func skip() {}
    func install() {}
    func openWebsite() {}
    func reportLaunchFailure(_ failure: UpdateFailure) {}
    var menuTitle: String { L10n.text("update.disabled") }
    static func percent(_ fraction: Double) -> String { "\(Int(fraction * 100))%" }
    #if DEBUG
    // Retained only for existing UI unit fixtures; launch arguments cannot reach update snapshots.
    func prepareSnapshot(_ state: UpdateState, manifest: UpdateManifest?) {
        guard snapshot else { return }
        self.manifest = manifest; self.state = state; onChange?()
    }
    #endif
}
