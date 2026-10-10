#if DEBUG
import AppKit

/// This entry point is intentionally absent from release builds and normal launch.
enum AXProbe {
    struct Options {
        let operation: String
        let pid: Int32?
        let mode: DialogMode?
        let directory: URL?
        let file: URL?
        let profile: AXControlProfile?
        let prompt: Bool
        let timeout: TimeInterval
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var values: [String: String] = [:], prompt = false, index = 0
        let allowed: Set<String> = ["--ax-probe", "--pid", "--mode", "--directory", "--file", "--panel-token",
                                    "--path-token", "--browser-token", "--filename-token", "--timeout"]
        while index < arguments.count {
            let name = arguments[index]
            if name == "--request-permission", !prompt { prompt = true; index += 1; continue }
            guard allowed.contains(name), values[name] == nil, index + 1 < arguments.count else { throw DialogFailure.invalidControl }
            values[name] = arguments[index + 1]; index += 2
        }
        guard let operation = values["--ax-probe"], ["permissions", "fixtures", "inspect", "navigate"].contains(operation),
              let timeout = Double(values["--timeout"] ?? "20"), timeout.isFinite, (0.5...30).contains(timeout) else {
            throw DialogFailure.invalidControl
        }
        let pid = values["--pid"].flatMap(Int32.init)
        let mode = values["--mode"].flatMap(DialogMode.init(rawValue:))
        var profile: AXControlProfile?
        if operation == "inspect" {
            guard let pid, pid > 0, values.keys.allSatisfy({ ["--ax-probe", "--pid", "--timeout"].contains($0) }), !prompt else {
                throw DialogFailure.invalidControl
            }
        } else if operation == "navigate" {
            let keys = ["--panel-token", "--path-token", "--browser-token"] + (mode == .save ? ["--filename-token"] : [])
            guard let pid, pid > 0, let mode, values["--directory"] != nil, !prompt,
                  mode != .save || values["--file"] == nil,
                  keys.allSatisfy({ validToken(values[$0]) }) else { throw DialogFailure.invalidControl }
            profile = AXControlProfile(panel: values["--panel-token"]!, pathField: values["--path-token"]!,
                                       directoryBrowser: values["--browser-token"]!, filenameField: values["--filename-token"])
        } else {
            guard values.count == 1, !prompt || operation == "permissions" else { throw DialogFailure.invalidControl }
        }
        return Options(operation: operation, pid: pid, mode: mode,
                       directory: values["--directory"].map { URL(fileURLWithPath: $0) },
                       file: values["--file"].map { URL(fileURLWithPath: $0) }, profile: profile, prompt: prompt, timeout: timeout)
    }

    static func run(_ arguments: [String]) throws {
        let options = try parse(arguments)
        guard Bundle.main.bundleIdentifier == ProductIdentity.bundleIdentifier else { throw DialogFailure.invalidControl }
        let permission = SystemAccessibilityPermission()
        if options.operation == "permissions" {
            if options.prompt { permission.requestTrust() }
            let status = Permissions.status(accessibility: permission)
            try emit(["fullDiskAccess": status.fullDiskAccess, "accessibility": status.accessibility,
                      "automation": status.automation, "promptRequested": options.prompt])
            return
        }
        if options.operation == "fixtures" {
            let root = try makeFixtures()
            try emit(["fixture": root.path, "directory": root.appendingPathComponent("space 中文").path,
                      "symlink": root.appendingPathComponent("linked folder").path])
            return
        }
        guard permission.isTrusted() else { throw DialogFailure.permissionDenied }
        let client = SystemAccessibilityClient(hostPID: options.pid!, profile: options.profile)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var finished = false, failure: Error?
        if options.operation == "inspect" {
            DispatchQueue(label: "me.caph.mistary.ax.inspect").async {
                do {
                    let context = DialogCallContext(deadline: ProcessInfo.processInfo.systemUptime + options.timeout,
                                                    now: { ProcessInfo.processInfo.systemUptime }, cancellation: {
                        NSWorkspace.shared.frontmostApplication?.processIdentifier == options.pid ? nil : .unexpectedFocus
                    })
                    let capabilities = try client.inspect(context: context)
                    let roles: Set<String> = [kAXApplicationRole, kAXWindowRole, kAXSheetRole, kAXTextFieldRole,
                                             kAXComboBoxRole, kAXBrowserRole, kAXButtonRole, kAXGroupRole,
                                             kAXScrollAreaRole, kAXOutlineRole, kAXTableRole, kAXRowRole,
                                             kAXColumnRole, kAXStaticTextRole, kAXPopUpButtonRole, kAXCheckBoxRole,
                                             kAXImageRole, kAXSplitGroupRole, kAXToolbarRole]
                    try emit(["hostPID": options.pid!, "controls": capabilities.map { c -> [String: Any] in
                        ["token": c.token ?? "none", "role": roles.contains(c.role) ? c.role : "custom",
                         "valueWritable": c.valueWritable, "hasURL": c.hasURL, "actions": c.actions,
                         "accessibilityPID": c.processID, "depth": c.depth]
                    }])
                    DispatchQueue.main.async { finished = true }
                } catch {
                    DispatchQueue.main.async { failure = error; finished = true }
                }
            }
            // Keep AppKit responsive while the serial AX worker performs IPC.
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        } else {
            try validateFixture(directory: options.directory!, file: options.file)
            let navigator = DialogNavigation(client: client, permissions: permission, stepTimeout: options.timeout)
            fputs("Manually confirm Go to Folder after the path field changes. Open/Save will not be submitted.\n", stderr)
            navigator.start(directory: options.directory!, file: options.file, mode: options.mode!) { result in
                do {
                    try emit(["state": String(describing: result.state), "history": result.history.map { String(describing: $0) },
                              "hostPID": result.target?.hostPID ?? options.pid!,
                              "accessibilityPID": result.target?.accessibilityPID ?? -1,
                              "mode": options.mode!.rawValue, "assistance": "manual path-sheet open and confirmation",
                              "fileSelected": result.fileSelection,
                              "selectionFailure": result.selectionFailure?.rawValue ?? "none",
                              "writeMayHaveCompleted": result.writeMayHaveCompleted,
                              "submissionActionsSent": 0])
                    switch result.state {
                    case .failed(let reason), .cancelled(let reason): failure = reason
                    case .verified: break
                    default: failure = DialogFailure.directoryNotVerified
                    }
                } catch { failure = error }
                finished = true
            }
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        if let failure { throw failure }
    }

    static func makeFixtures() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mistary-AX-" + UUID().uuidString)
        let directory = root.appendingPathComponent("space 中文")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("AX probe temporary sample\n".utf8).write(to: directory.appendingPathComponent("sample # 文档.txt"))
        try Data("mistary-ax-fixture-v1".utf8).write(to: root.appendingPathComponent(".mistary-ax-fixture"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked folder"), withDestinationURL: directory)
        return root
    }

    static func validateFixture(directory: URL, file: URL?) throws {
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(temp.path + "/") else { throw DialogFailure.invalidControl }
        var root = resolved
        while root != temp && root.path != "/" {
            if root.lastPathComponent.hasPrefix("Mistary-AX-"),
               (try? Data(contentsOf: root.appendingPathComponent(".mistary-ax-fixture"))) == Data("mistary-ax-fixture-v1".utf8) {
                if let file {
                    guard file.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == resolved.path else {
                        throw DialogFailure.invalidControl
                    }
                }
                return
            }
            root.deleteLastPathComponent()
        }
        throw DialogFailure.invalidControl
    }

    private static func validToken(_ token: String?) -> Bool {
        guard let token, token.count == 64 else { return false }
        return token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
#endif
