import AppKit
import OilFindCore

public enum Application {
    public static func run(appExtension: ApplicationExtension? = nil, arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
    do { try validateArguments(arguments) }
    catch { fputs("\(error)\n", stderr); exit(2) }
#if DEBUG
    var arguments = arguments
    do { try appExtension?.prepareArguments(&arguments) }
    catch { fputs("\(ProductIdentity.displayName) arguments: \(error)\n", stderr); exit(1) }
    if arguments.contains("--ax-probe") {
        do { try AXProbe.run(arguments); exit(0) }
        catch { fputs("\(ProductIdentity.displayName) AX probe: \(error)\n", stderr); exit(1) }
    }
    if arguments.contains("--snapshot") {
        do { try Snapshot.run(arguments, appExtension: appExtension); exit(0) }
        catch { fputs("\(ProductIdentity.displayName) snapshot: \(error)\n", stderr); exit(1) }
    }
#endif
    let app = NSApplication.shared
    SettingsPreferences.register()
    let delegate = AppDelegate(appExtension: appExtension)
    app.delegate = delegate
    app.run()
    }
    enum ArgumentError: Error, CustomStringConvertible {
        case updatesDisabled
        case unsupportedDebugArgument
        var description: String {
            switch self {
            case .updatesDisabled: return ProductIdentity.displayName + " does not support updates."
            case .unsupportedDebugArgument: return "Unsupported debug argument."
            }
        }
    }
    static func validateArguments(_ arguments: [String]) throws {
        if arguments.contains(where: { $0.hasPrefix("--update") }) { throw ArgumentError.updatesDisabled }
#if !DEBUG
        if arguments.contains(where: { $0.hasPrefix("--ax-") }) { throw ArgumentError.unsupportedDebugArgument }
#endif
    }
}
