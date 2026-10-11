import AppKit
import Quartz
import Darwin
import OilFindCore
import Combine

private final class SupplementarySearchBox { var hits: [SupplementaryHit] = [] }

private final class SearchGeneration {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func current(_ token: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == token }
}

final class SearchViewController: NSViewController, NSWindowDelegate, NSMenuDelegate {
    let searchField = SearchField(frame: .zero)
    let filters = FilterBar(frame: .zero)
    let results = ResultsView(frame: .zero)
    let footer = FooterBar(frame: .zero)
    let quickLook = QuickLook()
    let session = SearchSession()
    let favorites: FavoritesStore
    let launcher: LauncherPreferences
    let customActions: ActionDefinitions
    let savedFilters: SavedFiltersStore
    let usage: UsageStore
    private var usageObserver: AnyCancellable?
    private var activatedPinyin: Bool?
    private var launcherObserver: AnyCancellable?
    private let modeButton = NSButton(title: "", target: nil, action: nil)
    private let fileSearchButton = NSButton(title: "", target: nil, action: nil)
    private let routeHint = NSTextField(labelWithString: "")
    let dialogHint = NSTextField(labelWithString: "")
    let dialogPath = NSTextField(labelWithString: "")
    let dialogCopyButton = NSButton(title: "", target: nil, action: nil)
    private let dialogOrdinaryButton = NSButton(title: "", target: nil, action: nil)
    private var capturedMode: SearchMode = .ordinary
    private var forcedFileInput: String?
    private(set) var queryRoute: QueryRoute = .files("")
    private let scopeButton = NSButton(title: "", target: nil, action: nil)
    private let directoryButton = NSButton(title: "", target: nil, action: nil)
    private let directoryHint = NSTextField(labelWithString: "")
    private let favoriteRows = NSStackView()
    private var favoritesObserver: AnyCancellable?
    private struct DirectoryMenuRequest { let token: SearchSessionToken; let candidate: DirectoryCandidate }
    private struct ModeMenuRequest { let token: SearchSessionToken; let mode: SearchMode }
    var directoryCandidates: [DirectoryCandidate] {
        DirectoryCandidates.make(finder: session.context.finderDirectory ?? session.context.recentFinderDirectory, favorites: favorites, sources: snapshot ? (results.result?.sources ?? []) : searchSources)
    }

    lazy var actionExecutor: ActionExecutor = {
        var system = ActionSystem()
        system.preview = { [weak self] url in
            guard let self, self.validatedPreviewURL == url else { return false }
            if self.quickLook.isVisible { self.quickLook.refresh() } else { self.quickLook.toggle() }
            return true
        }
        let executor = ActionExecutor(session: session, system: system, sources: { [weak self] in
            guard let self else { return [] }
            return self.snapshot ? self.snapshotSources : self.searchSources
        })
        executor.usage = usage
        executor.query = { [weak self] in self?.results.result?.query.raw ?? self?.searchField.text ?? "" }
        executor.directoryQuery = { [weak self] in Query.normalizePaste(self?.searchField.text ?? "") }
        executor.dialog.onUpdate = { [weak self] in self?.updateDialogControls() }
        executor.onEvent = { [weak self] event in
            self?.actionDidFinish(event); self?.onActionEvent?(event)
        }
        executor.onCustomEvent = { [weak self] event in
            guard let self, self.session.isCurrent(event.request.token) else { return }
            switch event.outcome {
            case .accepted: self.footer.showMessage("custom.accepted", snapshot: self.snapshot)
            case .verified: self.footer.showMessage("custom.finished", snapshot: self.snapshot)
            case .failed(let failure), .cancelled(let failure): self.footer.showMessage("action." + failure.rawValue, snapshot: self.snapshot)
            }
        }
        executor.onPaletteEvent = { [weak self] event in
            self?.paletteActionDidFinish(event); self?.onPaletteActionEvent?(event)
        }
        return executor
    }()
    var onActionEvent: ((ActionEvent) -> Void)?
    var onPaletteActionEvent: ((PaletteActionEvent) -> Void)?
    var animateOpen: ((@escaping () -> Void) -> Void)?
    private var pendingOpen: ActionRequest?
    private var previewRequest: ActionRequest?
    private let topLine = SeparatorView(), bottomLine = SeparatorView()
    private let empty = StateView(.empty), indexing = StateView(.indexing)
    let syntax = SyntaxReference(frame: .zero)
    private(set) var syntaxVisible = false
    private var diagnostics: [QueryDiagnostic] = []
    private var snapshotNoAccess = false
    private let snapshot: Bool
    private let queue: DispatchQueue
    private let generation = SearchGeneration(), cache = SearchCache()
    private var timer: Timer?
    private var stateView: NSView?
    private var languageObserver: NSObjectProtocol?
    private var menuTracking = false, dragging = false
    private var actionModalActive = false
    private var selectionAnchor: (sourceID: String, store: IndexStore, id: UInt32, path: String)?
    private var paletteSelectionAnchor: String?
    private var snapshotSources: [SearchSource] = []
    private var pendingNewSearch: Bool?
    var manager: IndexManager?
    var supplementaryProvider: SupplementarySearchProvider?
    private let supplementQueue = DispatchQueue(label: "com.oiloil.find.supplement", qos: .userInteractive)
    var additionalSources: (() -> [SearchSource])?
    private var sourceCaches: [String: SearchCache] = [:]
    private var sourceCacheStores: [String: ObjectIdentifier] = [:]
    private var searchSources: [SearchSource] {
        let primary = manager?.store.map { SearchSource(id: "startup", displayName: "", isOnline: true, store: $0) }
        return primary.map { [$0] + (additionalSources?() ?? []) } ?? (additionalSources?() ?? [])
    }
    func sourcesChanged() {
        session.invalidateActions(); cancelPendingOpen()
        quickLook.close(); previewRequest = nil
        supplementaryProvider?.sourcesDidChange(searchSources)
        _ = generation.next(); results.cancelPendingRefresh(); results.cancelPress()
        if supplementaryProvider?.isEnabled != true, let result = results.result, result.hasSupplements {
            let base = result.withoutSupplements()
            let row = results.selectedItem.flatMap { base.index(sourceID: $0.source.id, store: $0.source.store, id: $0.id, path: $0.path) } ?? 0
            present(base, selection: row, resetScroll: false)
        }
        // Invalidate displayed actions immediately, including while the panel is hidden.
        if results.selectedItem?.source.isOnline != true { quickLook.close() }
        if let presented = results.result, let multi = presented.multiple {
            let current = Set(searchSources.map(\.id))
            if multi.sources.contains(where: { !current.contains($0.id) }) {
                if let i = multi.sources.firstIndex(where: { $0.id == "startup" }) { present(multi.results[i], resetScroll: false) }
                else {
                    results.clear(); setState(.empty)
                    footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(0))
                }
            }
        }
        results.localize()
        startSearch(preserveSelection: true)
    }
    var hidePanel: (() -> Void)?
    var onSettings: (() -> Void)?
    init(snapshot: Bool, favorites: FavoritesStore? = nil, launcher: LauncherPreferences? = nil, customActions: ActionDefinitions? = nil, savedFilters: SavedFiltersStore? = nil, usage: UsageStore? = nil, searchQueue: DispatchQueue? = nil) {
        self.snapshot = snapshot
        self.queue = searchQueue ?? DispatchQueue(label: "com.oiloil.find.search", qos: .userInteractive)
        self.launcher = launcher ?? (snapshot ? LauncherPreferences(url: nil) : .shared)
        self.customActions = customActions ?? (snapshot ? ActionDefinitions(url: nil) : .shared)
        self.savedFilters = savedFilters ?? (snapshot ? SavedFiltersStore(url: nil) : .shared)
        self.usage = usage ?? (snapshot ? UsageStore(url: nil) : .shared)
        self.favorites = favorites ?? (snapshot ? FavoritesStore(url: nil) : .shared)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = PanelSurface(snapshot: snapshot) }
    override func viewDidLoad() {
        super.viewDidLoad()
        [searchField, topLine, filters, scopeButton, directoryButton, directoryHint, favoriteRows, modeButton, fileSearchButton, routeHint, dialogHint, dialogPath, dialogCopyButton, dialogOrdinaryButton, results, empty, indexing, bottomLine, footer, syntax].forEach(view.addSubview)
        dialogHint.font = .systemFont(ofSize: 11); dialogHint.textColor = .secondaryLabelColor
        dialogHint.lineBreakMode = .byWordWrapping; dialogHint.maximumNumberOfLines = 2
        dialogPath.font = .systemFont(ofSize: 11); dialogPath.lineBreakMode = .byTruncatingMiddle
        dialogCopyButton.target = self; dialogCopyButton.action = #selector(copyDialogPath)
        dialogOrdinaryButton.target = self; dialogOrdinaryButton.action = #selector(exitDialogMode)
        for button in [dialogCopyButton, dialogOrdinaryButton] { button.bezelStyle = .rounded; button.controlSize = .small }
        modeButton.bezelStyle = .rounded; modeButton.controlSize = .small
        modeButton.target = self; modeButton.action = #selector(showModes)
        fileSearchButton.bezelStyle = .rounded; fileSearchButton.controlSize = .small
        fileSearchButton.target = self; fileSearchButton.action = #selector(forceFileSearch)
        routeHint.font = .systemFont(ofSize: 11); routeHint.textColor = .secondaryLabelColor
        routeHint.lineBreakMode = .byTruncatingMiddle
        usageObserver = usage.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            // Immediately reject workers holding the old usage snapshot.
            _ = self.generation.next()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.startSearch(preserveSelection: true)
            }
        }
        launcherObserver = launcher.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.session.invalidateActions()
                self.startSearch(preserveSelection: true)
            }
        }
        scopeButton.bezelStyle = .rounded; scopeButton.controlSize = .small
        scopeButton.target = self; scopeButton.action = #selector(toggleDirectoryScope)
        directoryButton.bezelStyle = .rounded; directoryButton.controlSize = .small
        directoryButton.target = self; directoryButton.action = #selector(showDirectories)
        directoryHint.font = .systemFont(ofSize: 11); directoryHint.textColor = .secondaryLabelColor
        directoryHint.lineBreakMode = .byTruncatingMiddle
        favoriteRows.orientation = .vertical; favoriteRows.alignment = .leading; favoriteRows.spacing = 3
        favoritesObserver = favorites.$favorites.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateDirectoryControls() }
        }
        syntax.isHidden = true
        syntax.onExample = { [weak self] example in
            guard let self else { return }; self.searchField.text = example; self.toggleSyntax(false); self.searchField.focus(); self.startSearch()
        }
        searchField.onSelectionChange = { [weak self] in self?.refreshDiagnostics() }
        searchField.onChange = { [weak self] in self?.startSearch() }
        searchField.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        filters.onChange = { [weak self] in self?.searchField.focus(); self?.startSearch() }
        filters.onSortChange = { [weak self] in
            guard let self, !self.snapshot else { return }
            UserDefaults.standard.set(FilterBar.sortName(self.filters.options.sort), forKey: "sortKey")
            UserDefaults.standard.set(self.filters.options.ascending, forKey: "sortAscending")
        }
        filters.onMenuTracking = { [weak self] tracking in
            self?.menuTracking = tracking
            if !tracking { self?.scheduleHideIfInactive() }
        }
        if !snapshot { results.currentSource = { [weak self] id in self?.searchSources.first { $0.id == id } } }
        results.onOpen = { [weak self] in self?.openSelected() }
        results.onSelection = { [weak self] in
            guard let self else { return }
            self.refreshPreview()
            self.paletteSelectionAnchor = self.results.selectedPaletteItem?.identity
            if let item = self.results.selectedItem {
                self.selectionAnchor = (item.source.id, item.source.store, item.id, item.path)
            } else { self.selectionAnchor = nil }
            self.updateRouteControls()
        }
        results.onUserSelection = { [weak self] in
            guard let self, self.quickLook.isVisible else { return }
            self.performAction(.preview, togglingPreview: false)
        }
        results.onContextMenu = { [weak self] _ in self?.contextMenu() }
        results.onRefreshApplied = { [weak self] result in self?.resultDidChange(result) }
        results.onDragging = { [weak self] active in
            self?.dragging = active
            if !active { self?.hideIfInactive() }
        }
        results.onPasteboardWriter = { [weak self] row in
            guard let self else { return nil }
            if let item = self.results.paletteItem(at: row), case .application(let app) = item,
               let request = self.actionExecutor.capture(.copyFile, paletteItem: item), self.actionExecutor.validate(request) == nil { return app.url as NSURL }
            guard let item = self.results.item(at: row),
                  let request = self.actionExecutor.capture(.copyFile, item: item),
                  self.actionExecutor.validate(request) == nil else { return nil }
            return request.target.url as NSURL
        }
        quickLook.selectedURL = { [weak self] in self?.validatedPreviewURL }
        quickLook.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        searchField.onSettings = { [weak self] in self?.onSettings?() }
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in self?.localize() }
        setState(.indexing)
        if !snapshot {
            filters.options = SettingsPreferences.searchOptions()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refreshProgress() }
        }
        localize()
    }
    deinit {
        timer?.invalidate()
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }
    private func localize() {
        filters.localize(); footer.localize(); empty.localize(); indexing.localize(); syntax.localize(); results.localize()
        searchField.localize()
        footer.contextText = L10n.text("session." + session.context.mode.rawValue)
        updateDirectoryControls(); updateRouteControls()
        if let result = results.result { updateFooter(result) }
        else if stateView === indexing { footer.text = L10n.text("footer.indexing", Presentation.countText(indexing.count)) }
        refreshProgress()
        view.needsLayout = true
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width, h = view.bounds.height, px = Theme.pixel(view)
        searchField.frame = NSRect(x: 0, y: 0, width: w, height: 64)
        topLine.frame = NSRect(x: 0, y: 64, width: w, height: px)
        filters.frame = NSRect(x: 0, y: 64 + px, width: w, height: 40)
        scopeButton.frame = NSRect(x: 18, y: 109 + px, width: 104, height: 24)
        directoryButton.frame = NSRect(x: 128, y: 109 + px, width: 104, height: 24)
        directoryHint.frame = NSRect(x: 242, y: 115 + px, width: max(0, w - 260), height: 16)
        let favoriteHeight: CGFloat = favoriteRows.isHidden ? 0 : CGFloat(favoriteRows.arrangedSubviews.count) * 26
        modeButton.frame = NSRect(x: 18, y: 140 + px, width: 120, height: 24)
        fileSearchButton.frame = NSRect(x: 146, y: 140 + px, width: 180, height: 24)
        routeHint.frame = NSRect(x: 336, y: 145 + px, width: max(0, w - 354), height: 18)
        let dialogHeight: CGFloat = dialogHint.isHidden ? 0 : 82
        dialogHint.frame = NSRect(x: 18, y: 172 + px, width: w - 36, height: 34)
        dialogPath.frame = NSRect(x: 18, y: 210 + px, width: max(0, w - 264), height: 18)
        dialogCopyButton.frame = NSRect(x: w - 238, y: 207 + px, width: 100, height: 24)
        dialogOrdinaryButton.frame = NSRect(x: w - 132, y: 207 + px, width: 114, height: 24)
        favoriteRows.frame = NSRect(x: 22, y: 172 + px + dialogHeight, width: w - 44, height: favoriteHeight)
        let top: CGFloat = 172 + px + favoriteHeight + dialogHeight
        let region = NSRect(x: 0, y: top, width: w, height: max(0, h - top - 34 - px))
        [results, empty, indexing, syntax].forEach { $0.frame = region }
        bottomLine.frame = NSRect(x: 0, y: h - 34 - px, width: w, height: px)
        footer.frame = NSRect(x: 0, y: h - 34, width: w, height: 34)
    }
    func setState(_ state: StateView.State?) {
        _ = view
        let previous: NSView = stateView ?? (results as NSView)
        stateView = state == .empty ? empty : state == .indexing ? indexing : nil
        let target: NSView = stateView ?? (results as NSView)
        footer.actionable = !syntaxVisible && stateView == nil && results.selectedItem != nil
        guard previous !== target else { return }
        let animate = !snapshot && view.window?.isVisible == true && previous !== target
        for item in [results, empty, indexing] as [NSView] {
            let visible = item === target
            if visible { item.isHidden = false }
            Theme.Motion.opacity(item, to: visible ? 1 : 0, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)
            if !visible {
                if animate {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.crossfade) { [weak self, weak item] in
                        guard let self, let item else { return }
                        let current: NSView = self.stateView ?? (self.results as NSView)
                        if item !== current { item.isHidden = true }
                    }
                } else { item.isHidden = true }
            }
        }
    }
    func beginSession(source: PanelSource, context: SearchContext) {
        if results.result == nil || results.result?.directoryScope != nil { results.clear() }
        actionExecutor.dialog.reset()
        capturedMode = context.mode; forcedFileInput = nil
        queryRoute = .files(searchField.text)
        activatedPinyin = nil
        session.begin(source: source, context: context); _ = generation.next()
        cancelPendingOpen(); results.cancelPendingRefresh(); quickLook.close(); previewRequest = nil
        footer.contextText = L10n.text("session." + context.mode.rawValue)
        updateDirectoryControls(); updateRouteControls()
    }
    func endSession() {
        session.end(); actionExecutor.dialog.reset(); _ = generation.next(); cancelPendingOpen()
        quickLook.close(); previewRequest = nil
    }
    private func cancelPendingOpen(reason: ActionFailure = .staleSession) {
        results.cancelPress()
        if let request = pendingOpen { pendingOpen = nil; actionExecutor.cancel(request, reason: reason) }
    }
    func panelWillShow() {
        supplementaryProvider?.userActivity(visible: true, typing: false)
        if case .files = routeInput() {} else { startSearch(preserveSelection: true); return }
        let currentQuery = Query.parse(searchField.text, store: manager?.store)
        let requestedOptions = effectiveOptions
        if let result = results.result, result.usageRevision == usage.revision, result.isCurrent(searchSources), launcher.aliases.isEmpty, result.launcherItems.isEmpty,
           let options = result.single?.options ?? result.multiple?.results.first?.options,
           options.kind == requestedOptions.kind, options.sort == requestedOptions.sort,
           options.ascending == requestedOptions.ascending, options.pinyin == requestedOptions.pinyin,
           result.query.raw == currentQuery.raw, result.directoryScope == requestedOptions.directoryScope, !currentQuery.isTimeDependent,
           Date().timeIntervalSince(result.createdAt) <= 600 { return }
        startSearch(preserveSelection: true)
    }
    func indexChanged() {
        refreshPreview()
        supplementaryProvider?.sourcesDidChange(searchSources)
        if view.window?.isVisible == true { refreshSearch() }
    }
    func managerStateChanged(_ state: IndexManager.State) {
        refreshProgress()
        if manager?.store == nil, results.displayCount == 0, case .files = queryRoute { setState(.indexing) }
    }
    private func refreshProgress() {
        if !searchField.editor.hasMarkedText(), case .files = queryRoute {} else { return }
        if let result = results.result, result.query.isEmpty { updateFooter(result) }
        guard let manager else { return }
        searchField.indexing = manager.state == .scanning || manager.isRescanning
        if manager.store == nil {
            let count = manager.scannedCount
            indexing.updateCount(count); footer.text = L10n.text("footer.indexing", Presentation.countText(count))
        }
    }
    func startSearch(preserveSelection: Bool = false) {
        session.queryChanged(); actionExecutor.dialog.reset(); cancelPendingOpen(); quickLook.close(); previewRequest = nil
        if forcedFileInput != searchField.text { forcedFileInput = nil }
        pendingNewSearch = preserveSelection
        results.cancelPendingRefresh()
        search(refresh: false, preserveSelection: preserveSelection)
    }
    private func refreshSearch() {
        // Index notifications must not turn an uncommitted user query into a refresh.
        if let preserveSelection = pendingNewSearch {
            search(refresh: false, preserveSelection: preserveSelection)
        } else if results.result == nil {
            startSearch()
        } else {
            search(refresh: true, preserveSelection: false)
        }
    }
    private func search(refresh: Bool, preserveSelection: Bool) {
        supplementaryProvider?.userActivity(visible: view.window?.isVisible == true, typing: !refresh && !preserveSelection)
        let token = generation.next(), sessionToken = session.token
        guard !searchField.editor.hasMarkedText() else { return }
        queryRoute = routeInput(); updateRouteControls()
        switch queryRoute {
        case .waiting, .web:
            pendingNewSearch = nil; diagnostics = []
            if case .web(let item) = queryRoute { results.showCommands([.web(item)], preserveSelection: preserveSelection) }
            else { results.showCommands([]) }
            setState(nil); footer.warning = false
            footer.actionable = false
            if case .web(let item) = queryRoute { footer.text = item.keyword.name + " · ↩ " + L10n.text("hint.open") }
            else { footer.text = routeHint.stringValue }
            return
        case .files: break
        }
        let aliases = launcherCandidates()
        let sources = snapshot ? snapshotSources : searchSources
        guard let store = sources.first?.store else {
            pendingNewSearch = nil; results.showCommands(aliases, preserveSelection: preserveSelection)
            setState(aliases.isEmpty ? .indexing : nil); refreshProgress(); return
        }
        let options = effectiveOptions
        let query = editingQuery(store: store), previous = results.result
        let usageRevision = usage.revision, history = usage.enabled ? usage.records : []
        let historySystem = usage.system, context = session.context.mode.rawValue
        let allowsRecentApplications = forcedFileInput == nil && query.isEmpty && options.sort == .relevance && options.directoryScope == nil
            && (session.context.mode == .ordinary || session.context.mode == .application) && (options.kind == nil || options.kind == 2)
        let favoriteEntries = favorites.favorites, favoriteSystem = favorites.system
        updateDirectoryControls()
        let cancelled = { [generation] in !generation.current(token) }
        let supplementary = supplementaryProvider?.prepareSearch(query, options: options, sources: sources, isCancelled: cancelled)
        let group = DispatchGroup()
        let box = SupplementarySearchBox()
        if let supplementary {
            group.enter()
            supplementQueue.async { box.hits = supplementary(); group.leave() }
        }
        let anchor = refresh || preserveSelection ? selectionAnchor : nil
        let paletteAnchor = refresh || preserveSelection ? paletteSelectionAnchor : nil
        queue.async { [weak self] in
            guard let self, self.generation.current(token) else { return }
            let found: SearchPresentation
            if sources.count == 1 && sources[0].id == "startup" {
                if !self.sourceCaches.isEmpty { self.sourceCaches.removeAll(); self.sourceCacheStores.removeAll() }
                if previous?.single?.store !== store { self.cache.removeAll() }
                guard let result = self.cache.lookup(query: query, options: options, store: store)
                    ?? Searcher.search(query, options: options, in: store, previous: previous?.single, isCancelled: { !self.generation.current(token) }), self.generation.current(token) else { return }
                self.cache.insert(result); found = SearchPresentation(result)
            } else {
                if previous?.single != nil { self.cache.removeAll() }
                self.sourceCaches = self.sourceCaches.filter { key, _ in sources.contains { $0.id == key } }
                self.sourceCacheStores = self.sourceCacheStores.filter { key, _ in sources.contains { $0.id == key } }
                for source in sources {
                    let identity = ObjectIdentifier(source.store)
                    if self.sourceCacheStores[source.id] != identity {
                        self.sourceCaches[source.id] = SearchCache(); self.sourceCacheStores[source.id] = identity
                    }
                }
                guard let result = MultiSearcher.search(query, options: options, in: sources, previous: previous?.multiple, caches: self.sourceCaches, isCancelled: { !self.generation.current(token) }), self.generation.current(token) else { return }
                found = SearchPresentation(result)
            }
            let resolved = options.sort == .relevance ? UsageStore.resolve(history, system: historySystem, sources: sources, cancelled: cancelled) : []
            let favoriteURLs: [URL] = options.sort == .relevance && !query.isEmpty ? favoriteEntries.prefix(UsageStore.candidateLimit).compactMap { entry in
                guard !cancelled() else { return nil }
                let url = entry.bookmark.flatMap { try? favoriteSystem.resolve($0) } ?? URL(fileURLWithPath: entry.fallbackPath)
                return favoriteSystem.check(url) == .available ? url : nil
            } : []
            found.usageRevision = usageRevision
            UsageRanker.rank(found, history: resolved, favorites: favoriteURLs, options: options, context: context, cancelled: cancelled)
            let recentApplications: [PaletteItem] = allowsRecentApplications ? resolved.filter {
                $0.record.type == .application && $0.record.launches > 0 && $0.availability == .available
            }.map { value in
                .application(ApplicationPaletteItem(url: value.url, name: value.url.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: nil, available: true, usageGroup: "usage.recent"))
            } : []
            var launcherIDs: Set<String> = []
            found.addAliases((recentApplications + aliases).filter { launcherIDs.insert($0.identity).inserted })
            let anchoredRow = anchor.flatMap { found.index(sourceID: $0.sourceID, store: $0.store, id: $0.id, path: $0.path) }
            let row = anchoredRow.map { $0 + found.launcherItems.count }
                ?? paletteAnchor.flatMap { id in found.launcherItems.firstIndex { $0.identity == id } } ?? 0
            let deferNames = anchor != nil && anchoredRow == nil && supplementary != nil && previous?.query.raw == query.raw
            DispatchQueue.main.async { [weak self] in
                guard let self, self.usage.revision == usageRevision, self.generation.current(token), self.session.isCurrent(sessionToken),
                      found.isCurrent(self.snapshot ? self.snapshotSources : self.searchSources) else { return }
                self.diagnostics = query.diagnostics
                if deferNames { return }
                if refresh {
                    self.results.refresh(found)
                } else {
                    self.pendingNewSearch = nil
                    self.present(found, selection: row, resetScroll: !preserveSelection)
                }
            }
            if supplementary != nil {
                group.notify(queue: self.queue) { [weak self] in
                    guard let self, self.generation.current(token) else { return }
                    if box.hits.isEmpty && !deferNames { return }
                    let combined = box.hits.isEmpty ? found : found.supplement(box.hits, options: options)
                    if combined !== found {
                        combined.usageRevision = usageRevision
                        UsageRanker.rank(combined, history: resolved, favorites: favoriteURLs, options: options, context: context, cancelled: cancelled)
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.usage.revision == usageRevision, self.generation.current(token), self.session.isCurrent(sessionToken), combined.isCurrent(self.snapshot ? self.snapshotSources : self.searchSources) else { return }
                        self.pendingNewSearch = nil
                        self.results.refresh(combined)
                    }
                }
            }
        }
    }
    func present(_ result: SearchResult, selection: Int = 0, resetScroll: Bool = true) { present(SearchPresentation(result), selection: selection, resetScroll: resetScroll) }
    func present(_ result: SearchPresentation, selection: Int = 0, resetScroll: Bool = true) {
        if snapshot { snapshotSources = result.sources }
        results.show(result, selection: selection, resetScroll: resetScroll)
        resultDidChange(result)
    }
    private func editingQuery(store: IndexStore?) -> Query {
        Query.parse(searchField.text, store: store, editingRange: searchField.input.currentEditor() == nil ? nil : searchField.editor.selectedRange(), isComposing: searchField.editor.hasMarkedText(), pathExists: { [self] path in
            if searchSources.contains(where: { source in source.store.read { source.store.containsPath(path) } }) { return true }
            var info = stat(); return path.withCString { stat($0, &info) == 0 }
        })
    }
    private func refreshDiagnostics() {
        guard case .files = queryRoute else { return }
        let query = editingQuery(store: manager?.store ?? results.result?.store)
        guard let result = results.result, result.query.raw == query.raw else { return }
        diagnostics = query.diagnostics
        configureEmpty(result); updateFooter(result)
    }
    private func configureEmpty(_ result: SearchPresentation) {
        empty.configure(diagnostic: diagnostics.first, hasNoAccess: snapshotNoAccess || result.sources.contains { source in source.store.read { source.store.coverage[.noAccess].count > 0 } })
    }
    func toggleSyntax(_ show: Bool? = nil) {
        let visible = show ?? !syntaxVisible
        syntaxVisible = visible
        footer.actionable = !visible && stateView == nil && results.selectedItem != nil
        syntax.isHidden = false
        Theme.Motion.opacity(syntax, to: visible ? 1 : 0, using: snapshot ? nil : Theme.Motion.chip)
        if let layer = syntax.layer { Theme.Motion.animate(layer, "transform.translation.y", to: visible ? 0 : 8, using: snapshot ? nil : Theme.Motion.chip) }
        if !visible {
            if snapshot { syntax.isHidden = true }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.chip.settlingDuration) { [weak self] in if self?.syntaxVisible == false { self?.syntax.isHidden = true } } }
        }
    }
    private func resultDidChange(_ result: SearchPresentation) {
        updateDirectoryControls()
        configureEmpty(result)
        setState(result.displayCount == 0 ? .empty : nil)
        updateFooter(result)
        refreshProgress()
    }
    private func updateFooter(_ result: SearchPresentation) {
        footer.warning = !diagnostics.isEmpty
        if let diagnostic = diagnostics.first { footer.text = L10n.diagnostic(diagnostic); return }
        if result.query.isEmpty {
            footer.text = L10n.text("usage.emptyFooter")
        } else if result.rankingMode == .personalBounded {
            footer.text = L10n.text("usage.footer", Presentation.countText(result.personalPrefixCount), Presentation.countText(result.single?.total ?? result.multiple!.total))
        } else {
            footer.text = L10n.text(result.sortedCount < result.total ? "footer.partial" : "footer.results", Presentation.countText(result.total + result.launcherItems.count), Presentation.elapsedText(result.elapsedMs))
        }
    }
    func prepareSnapshot(state: String, query: String, options: SearchOptions, store: IndexStore?, selection: Int, additionalSources: [SearchSource] = []) throws {
        _ = view
        searchField.text = state == "recent" ? "" : query; filters.options = options
        if state == "indexing" {
            setState(.indexing); indexing.updateCount(1_234_567); searchField.indexing = true
            footer.text = L10n.text("footer.indexing", Presentation.countText(1_234_567)); return
        }
        if state == "results" {
            if let store { snapshotSources = [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] + additionalSources }
            if case .files = routeInput() {} else { startSearch(); return }
        }
        if let store, let supplementaryProvider {
            let sources = [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] + additionalSources
            let query = Query.parse(searchField.text, store: store)
            let hits = supplementaryProvider.prepareSearch(query, options: options, sources: sources, isCancelled: { false })()
            guard let found = MultiSearcher.search(query, options: options, in: sources) else { throw SnapshotError.failed("Cannot search snapshot index") }
            diagnostics = query.diagnostics; present(SearchPresentation(found).supplement(hits, options: options), selection: selection); return
        }
        if let store, !additionalSources.isEmpty, let found = MultiSearcher.search(Query.parse(searchField.text, store: store), options: options, in: [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] + additionalSources) {
            diagnostics = found.query.diagnostics; present(SearchPresentation(found), selection: selection); return
        }
        guard let store, let found = Searcher.search(Query.parse(searchField.text, store: store), options: options, in: store) else { throw SnapshotError.failed("Cannot search snapshot index") }
        diagnostics = Query.parse(searchField.text, store: store).diagnostics
        snapshotNoAccess = state == "no-access"
        present(found, selection: selection)
        if state == "syntax" { toggleSyntax(true) }
        if state == "toast", let item = results.selectedItem { footer.showToast(.copiedPath, value: item.path, snapshot: true) }
        if state == "empty" {
            setState(.empty)
            footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(found.elapsedMs))
        }
    }
    func handleKey(_ event: NSEvent) -> Bool {
        if (view.window as? SearchPanel)?.hiding == true { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command), option = flags.contains(.option)
        if searchField.editor.hasMarkedText() { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // A nonactivating panel has no Edit menu to dispatch text shortcuts.
        if flags.intersection([.command, .control, .option, .shift]) == .command,
           let editor = searchField.input.currentEditor() {
            switch key {
            case "a": editor.selectAll(nil); return true
            case "c" where editor.selectedRange.length > 0: editor.copy(nil); return true
            case "x": editor.cut(nil); return true
            case "v": editor.paste(nil); return true
            default: break
            }
        }
        if command && event.keyCode == 44 { toggleSyntax(); return true }
        if syntaxVisible && event.keyCode == 53 { toggleSyntax(false); return true }
        if syntaxVisible { return false }
        switch event.keyCode {
        case 126: if command { results.select(0, repeatKey: event.isARepeat) } else { results.move(-1, repeatKey: event.isARepeat) }; return true
        case 125: if command { results.select(max(0, results.displayCount - 1), repeatKey: event.isARepeat) } else { results.move(1, repeatKey: event.isARepeat) }; return true
        case 116: results.page(-1, repeatKey: event.isARepeat); return true
        case 121: results.page(1, repeatKey: event.isARepeat); return true
        case 36, 76: if command { revealSelected() } else { openSelected() }; return true
        case 48: filters.cycle(flags.contains(.shift) ? -1 : 1); return true
        case 53: if quickLook.isVisible { quickLook.close() } else { hidePanel?() }; return true
        case 51 where command: trashSelected(); return true
        default: break
        }
        guard command else { return false }
        switch key {
        case "k" where flags == .command:
            let menu = contextMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 22, y: 0), in: footer); return true
        case "y": previewSelected(); return true
        case "c":
            if option { copyName(); return true }
            if searchField.input.currentEditor()?.selectedRange.length ?? 0 > 0 { return false }
            copyPath(); return true
        case "w": hidePanel?(); return true
        case ",": onSettings?(); return true
        case "1"..."9": filters.select((Int(key) ?? 1) - 1); return true
        default: return false
        }
    }
    func requestAction(_ action: FileAction) -> ActionRequest? {
        guard !searchField.editor.hasMarkedText(), results.selectedPaletteItem?.actions.contains(action) == true else { return nil }
        guard stateView == nil, let item = results.selectedItem else { return nil }
        return actionExecutor.capture(action, item: item)
    }
    private var validatedPreviewURL: URL? {
        guard let request = previewRequest, actionExecutor.validate(request) == nil else { return nil }
        return request.target.url
    }
    private func refreshPreview() {
        guard quickLook.isVisible else { return }
        if validatedPreviewURL == nil { quickLook.close(); previewRequest = nil }
        else { quickLook.refresh() }
    }
    private func openSelected() { performAction(.open) }
    private func revealSelected() { performAction(.reveal) }
    private func previewSelected() { performAction(.preview) }
    private func copyPath() { performAction(.copyPath) }
    private func copyName() { performAction(.copyName) }
    private func trashSelected() { performAction(.trash) }
    func performAction(_ action: FileAction, request captured: ActionRequest? = nil, togglingPreview: Bool = true) {
        guard !searchField.editor.hasMarkedText() else { return }
        guard (view.window as? SearchPanel)?.hiding != true else { return }
        if captured == nil, let item = results.selectedPaletteItem, results.selectedItem == nil {
            guard stateView == nil, let request = actionExecutor.capture(action, paletteItem: item) else { return }
            actionExecutor.execute(request); return
        }
        if action == .preview && togglingPreview && quickLook.isVisible {
            quickLook.close(); previewRequest = nil; return
        }
        guard let request = captured ?? requestAction(action) else { return }
        if action == .open {
            cancelPendingOpen(reason: .superseded)
            if actionExecutor.validate(request) != nil { actionExecutor.execute(request); return }
            pendingOpen = request
            let completion = { [weak self] in
                guard let self, self.pendingOpen?.actionID == request.actionID else { return }
                self.pendingOpen = nil; self.actionExecutor.execute(request)
            }
            if let animateOpen { animateOpen(completion) } else { results.pressOpen(completion) }
        } else {
            if action == .preview { previewRequest = request }
            actionExecutor.execute(request)
        }
    }
    private func actionDidFinish(_ event: ActionEvent) {
        // Completion events still reach other consumers after a focus handoff.
        guard session.isCurrent(event.request.token) else { return }
        let request = event.request
        switch event.outcome {
        case .accepted:
            if request.context.mode == .open || request.context.mode == .save {
                if actionExecutor.dialog.isNavigating { (view.window as? SearchPanel)?.hide(endingSession: false) }
            } else if request.action == .open || request.action == .reveal { hidePanel?() }
        case .verified:
            if request.action == .contextNavigation || (request.action == .open && (request.context.mode == .open || request.context.mode == .save)) {
                updateDialogControls(); session.end(); return
            }
            switch request.action {
            case .copyPath: footer.showToast(.copiedPath, value: request.target.url.path)
            case .copyName: footer.showToast(.copiedName, value: request.target.name)
            case .copyFile: footer.showMessage("action.copiedFile", value: request.target.name, snapshot: snapshot)
            case .trash: footer.showToast(.trashed, value: request.target.name)
            case .rename, .createDirectory: footer.showMessage("custom.mutated", snapshot: snapshot)
            default: break
            }
        case .cancelled(let failure), .failed(let failure):
            if failure == .dialogManual || failure == .dialogFailed {
                updateDialogControls(); (view.window as? SearchPanel)?.resumeDialog()
            }
            if failure == .sourceUnavailable {
                footer.warning = true; footer.actionable = false
                footer.text = L10n.text("source.unavailable", request.target.sourceName)
            }
            footer.showMessage("action." + failure.rawValue, snapshot: snapshot)
            if request.action == .preview { quickLook.close(); previewRequest = nil }
        }
    }
    func contextMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        if let paletteItem = results.selectedPaletteItem, results.selectedItem == nil {
            for action in paletteItem.actions {
                let item = NSMenuItem(title: L10n.text("ctx." + action.rawValue), action: #selector(paletteContextAction(_:)), keyEquivalent: "")
                item.target = self
                let request = actionExecutor.capture(action, paletteItem: paletteItem)
                item.representedObject = request
                item.isEnabled = request.map { actionExecutor.validate($0) == nil } ?? false
                menu.addItem(item)
            }
            appendCustomActions(to: menu, paletteItem: paletteItem)
            return menu
        }
        let actions: [FileAction?] = [.open, .reveal, .preview, nil, .copyFile, .copyPath, .copyName, nil, .trash, nil, .contextNavigation]
        for action in actions {
            guard let action else { menu.addItem(.separator()); continue }
            let titleKey = action == .open && session.context.mode == .save ? "dialog.useDirectory" : "ctx." + action.rawValue
            let item = NSMenuItem(title: L10n.text(titleKey), action: #selector(contextAction(_:)), keyEquivalent: "")
            item.target = self
            let request = requestAction(action)
            item.representedObject = request
            item.isEnabled = request.map { actionExecutor.validate($0) == nil } ?? false
            menu.addItem(item)
        }
        let favorite = NSMenuItem(title: L10n.text("directory.favorite"), action: #selector(favoriteSelected), keyEquivalent: "")
        favorite.target = self
        favorite.representedObject = requestAction(.copyFile)
        favorite.isEnabled = results.selectedItem?.kind == 1 && (favorite.representedObject as? ActionRequest).map { actionExecutor.validate($0) == nil } == true
        let position = menu.items.count - 1
        menu.insertItem(favorite, at: position); menu.insertItem(.separator(), at: position + 1)
        let contextNavigation = menu.items.last!
        menu.removeItem(contextNavigation)
        appendCustomActions(to: menu, paletteItem: results.selectedPaletteItem)
        for action in [FileAction.rename, .createDirectory] {
            let item = NSMenuItem(title: L10n.text("ctx." + action.rawValue), action: #selector(mutationAction(_:)), keyEquivalent: "")
            item.target = self
            if let request = requestAction(action) {
                let mutation = FileMutation(request: request)
                item.representedObject = mutation
                let failure = actionExecutor.validate(request) ?? FileActions.availability(mutation)
                item.isEnabled = failure == nil; item.toolTip = failure.map { L10n.text("action." + $0.rawValue) }
            } else { item.isEnabled = false }
            menu.addItem(item)
        }
        appendSavedFilters(to: menu)
        menu.addItem(.separator()); menu.addItem(contextNavigation)
        return menu
    }
    private func appendCustomActions(to menu: NSMenu, paletteItem: PaletteItem?) {
        let type: ActionItemType
        switch paletteItem {
        case .application: type = .application
        case .web: type = .web
        default: type = .file
        }
        let definitions = customActions.actions.filter { $0.itemTypes.contains(type) }
        guard type == .file || !definitions.isEmpty else { return }
        menu.addItem(.separator())
        if type == .file {
            let open = NSMenuItem(title: L10n.text("ctx.openWith"), action: #selector(chooseApplication(_:)), keyEquivalent: "")
            open.target = self; open.representedObject = requestAction(.custom)
            open.isEnabled = (open.representedObject as? ActionRequest).map { actionExecutor.validate($0) == nil } ?? false
            menu.addItem(open)
            let terminal = NSMenuItem(title: L10n.text("ctx.terminal"), action: nil, keyEquivalent: "")
            terminal.isEnabled = false; terminal.toolTip = L10n.text("action.terminalUnsupported"); menu.addItem(terminal)
        }
        if customActions.error != nil {
            let error = NSMenuItem(title: L10n.text("custom.configError"), action: nil, keyEquivalent: "")
            error.isEnabled = false; menu.addItem(error)
        }
        for definition in definitions {
            let item = NSMenuItem(title: definition.name, action: #selector(customContextAction(_:)), keyEquivalent: "")
            item.target = self
            let request: CustomActionRequest?
            if let file = requestAction(.custom) { request = actionExecutor.captureCustom(definition, file: file) }
            else if let paletteItem { request = actionExecutor.captureCustom(definition, item: paletteItem) }
            else { request = nil }
            item.representedObject = request
            let failure = request.map { actionExecutor.validate($0) } ?? .unsupportedAction
            item.isEnabled = request != nil && failure == nil
            item.toolTip = failure.map { L10n.text("action." + $0.rawValue) }
            menu.addItem(item)
        }
    }
    @objc func customContextAction(_ item: NSMenuItem) {
        guard !searchField.editor.hasMarkedText(), let request = item.representedObject as? CustomActionRequest else { return }
        actionExecutor.execute(request)
    }
    @objc private func chooseApplication(_ item: NSMenuItem) {
        actionModalActive = true; defer { actionModalActive = false }
        guard let request = item.representedObject as? ActionRequest else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let definition = ActionDefinition(id: UUID(), name: url.deletingPathExtension().lastPathComponent,
            itemTypes: [.file], modes: SearchMode.allActionModes, permissions: [.fileRead], enabled: true, execution: .application(url))
        if let custom = actionExecutor.captureCustom(definition, file: request) {
            do { try customActions.set(customActions.actions + [definition]) }
            catch { footer.showMessage("custom.configError", snapshot: snapshot); return }
            actionExecutor.execute(custom)
        }
    }
    @objc private func mutationAction(_ item: NSMenuItem) {
        actionModalActive = true; defer { actionModalActive = false }
        guard let mutation = item.representedObject as? FileMutation else { return }
        let alert = NSAlert(); alert.messageText = L10n.text("ctx." + mutation.request.action.rawValue)
        alert.informativeText = mutation.parent.path
        let input = NSTextField(string: mutation.request.action == .rename ? mutation.request.target.name : "")
        input.frame = NSRect(x: 0, y: 0, width: 340, height: 24); alert.accessoryView = input
        alert.addButton(withTitle: L10n.text("launcher.save")); alert.addButton(withTitle: L10n.text("custom.cancel"))
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        actionExecutor.execute(mutation, name: input.stringValue)
    }
    private func appendSavedFilters(to menu: NSMenu) {
        menu.addItem(.separator())
        let save = NSMenuItem(title: L10n.text("saved.saveCurrent"), action: #selector(saveCurrentFilterMenu), keyEquivalent: "")
        save.target = self
        if case .files = routeInput() { save.isEnabled = !searchField.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        else { save.isEnabled = false }
        menu.addItem(save)
        if savedFilters.error != nil {
            let error = NSMenuItem(title: L10n.text("saved.error"), action: nil, keyEquivalent: "")
            error.isEnabled = false; menu.addItem(error)
        }
        for filter in savedFilters.filters {
            let item = NSMenuItem(title: filter.name, action: #selector(activateFilterMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = filter; menu.addItem(item)
        }
    }
    func saveCurrentFilter(name: String) throws {
        guard case .files = routeInput() else { throw SavedFiltersStore.StoreError.invalidFilter }
        let filter = SavedFilter(name: name, query: searchField.text, options: effectiveOptions)
        try savedFilters.set(savedFilters.filters + [filter])
    }
    @objc private func saveCurrentFilterMenu() {
        actionModalActive = true; defer { actionModalActive = false }
        let alert = NSAlert(); alert.messageText = L10n.text("saved.saveCurrent")
        let input = NSTextField(string: searchField.text); input.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = input; alert.addButton(withTitle: L10n.text("launcher.save")); alert.addButton(withTitle: L10n.text("custom.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try saveCurrentFilter(name: input.stringValue) } catch { footer.showMessage("saved.error", snapshot: snapshot) }
    }
    @objc private func activateFilterMenu(_ item: NSMenuItem) {
        guard let filter = item.representedObject as? SavedFilter else { return }
        do { try activateFilter(filter) } catch { footer.showMessage("saved.unavailable", snapshot: snapshot) }
    }
    func activateFilter(_ filter: SavedFilter) throws {
        let sources = snapshot ? snapshotSources : searchSources
        _ = try filter.parse(store: sources.first?.store)
        guard let options = filter.options else { throw SavedFiltersStore.StoreError.invalidFilter }
        if let scope = options.directoryScope {
            let directory = URL(fileURLWithPath: scope.path, isDirectory: true)
            guard favorites.system.check(directory) == .available,
                  sources.contains(where: { $0.isOnline && Searcher.directoryScopeIsAvailable(scope, in: $0.store) }) else {
                throw SavedFiltersStore.StoreError.unavailableScope
            }
        }
        session.setMode(.ordinary)
        session.setDirectoryScope(options.directoryScope.map { URL(fileURLWithPath: $0.path, isDirectory: true) })
        filters.options = options; activatedPinyin = options.pinyin
        searchField.text = filter.query; forcedFileInput = filter.query
        results.clear(); updateDirectoryControls(); startSearch()
    }
    @objc func contextAction(_ item: NSMenuItem) {
        guard let request = item.representedObject as? ActionRequest else { return }
        performAction(request.action, request: request)
    }
    var isDialogMode: Bool { session.context.mode == .open || session.context.mode == .save }
    private func updateDialogControls() {
        guard isViewLoaded else { return }
        for control in [dialogHint, dialogPath, dialogCopyButton, dialogOrdinaryButton] as [NSView] { control.isHidden = !isDialogMode }
        guard isDialogMode else { view.needsLayout = true; return }
        let adapter = actionExecutor.dialog
        let key = adapter.path == nil ? "dialog.manual" : adapter.status.localizationKey
        if adapter.status == .manual, let file = adapter.fileToSelect { dialogHint.stringValue = L10n.text("dialog.manualFile", file.lastPathComponent) }
        else { dialogHint.stringValue = L10n.text(key) }
        dialogHint.toolTip = dialogHint.stringValue
        dialogPath.stringValue = adapter.path?.path ?? L10n.text(session.context.mode == .save ? "dialog.saveHint" : "dialog.openHint")
        dialogPath.toolTip = dialogPath.stringValue
        dialogCopyButton.title = L10n.text("dialog.copy")
        dialogCopyButton.isEnabled = adapter.path != nil && adapter.token.map(session.isCurrent) == true && !adapter.isNavigating
        dialogOrdinaryButton.title = L10n.text("session.ordinary")
        view.needsLayout = true
    }
    @objc func copyDialogPath() {
        let adapter = actionExecutor.dialog
        guard !adapter.isNavigating, let path = adapter.path, let token = adapter.token, session.isCurrent(token) else { return }
        let request = actionExecutor.captureDirectoryUsage(path)
        if actionExecutor.system.copy(.copyPath, path, path.lastPathComponent) {
            actionExecutor.completeDirectoryUsage(request, activity: .copied)
            footer.showToast(.copiedPath, value: path.path)
        }
        else { footer.showMessage("action.clipboardRejected", snapshot: snapshot) }
    }
    @objc private func exitDialogMode() { setSearchMode(.ordinary); searchField.focus() }

    /// Quick Switch is a user choice, and must revalidate the captured candidate.
    func navigateDirectory(_ candidate: DirectoryCandidate, token: SearchSessionToken) {
        guard isDialogMode, session.isCurrent(token) else { return }
        guard candidate.availability == .available || candidate.availability == .unindexed,
              directoryCandidates.contains(where: { $0.id == candidate.id && $0.url == candidate.url && $0.finderDirectory == candidate.finderDirectory && ($0.availability == .available || $0.availability == .unindexed) }),
              candidate.finderDirectory.map({ Date().timeIntervalSince($0.observedAt) >= 0 && Date().timeIntervalSince($0.observedAt) <= 120 && session.context.finderDirectoryIsCurrent?() == true }) ?? true else {
            footer.showMessage("dialog.staleDirectory", snapshot: snapshot); return
        }
        let request = actionExecutor.captureDirectoryUsage(candidate.url)
        let adapter = actionExecutor.dialog
        let outcome = adapter.navigate(directory: candidate.url, file: nil, context: session.context.dialog,
                                       token: token, host: session.context.target, isCurrent: { [weak self] in self?.session.isCurrent(token) == true }) { [weak self] outcome in
            guard let self, self.session.isCurrent(token) else { return }
            self.updateDialogControls()
            if outcome == .verified {
                self.actionExecutor.completeDirectoryUsage(request, activity: .navigated)
                self.session.end()
            }
            else { (self.view.window as? SearchPanel)?.resumeDialog() }
        }
        if outcome == .accepted { (view.window as? SearchPanel)?.hide(endingSession: false) }
        updateDialogControls()
    }

    private var effectiveOptions: SearchOptions {
        var options = filters.options
        switch session.context.mode {
        case .application: options.kind = 2
        case .save: options.kind = 1
        default: break
        }
        options.directoryScope = session.directoryScope.map { DirectoryScope(path: $0.path) }
        if let activatedPinyin { options.pinyin = activatedPinyin }
        else if !snapshot { options.pinyin = UserDefaults.standard.bool(forKey: "pinyinEnabled") }
        return options
    }
    private func routeInput() -> QueryRoute {
        QueryRouter(keywords: launcher.keywords).route(searchField.text, mode: session.context.mode,
            isComposing: searchField.editor.hasMarkedText(), forceFiles: forcedFileInput == searchField.text)
    }
    private func launcherCandidates() -> [PaletteItem] {
        guard forcedFileInput == nil, session.context.mode == .ordinary || session.context.mode == .application,
              session.directoryScope == nil, effectiveOptions.kind == nil || effectiveOptions.kind == 2 else { return [] }
        let text = searchField.text
        guard !text.contains(where: { ":/\\~*?!|".contains($0) }) else { return [] }
        let query = Query.parse(text)
        guard query.diagnostics.isEmpty, query.clauses.allSatisfy({ clause in
            clause.alternatives.count == 1 && clause.alternatives.allSatisfy { atom in
                if case .name = atom.matcher { return !atom.negated }; return false
            }
        }) else { return [] }
        return launcher.candidates(for: text)
    }
    func setSearchMode(_ mode: SearchMode) {
        session.setMode(mode); forcedFileInput = nil
        results.clear(); startSearch()
    }
    @objc func forceFileSearch() {
        forcedFileInput = searchField.text; startSearch(); searchField.focus()
    }
    @objc private func showModes() {
        let menu = NSMenu(); menu.delegate = self
        var modes: [SearchMode] = [.ordinary, .application, .open, .save]
        if capturedMode == .finder { modes.insert(capturedMode, at: 0) }
        for mode in modes {
            let item = NSMenuItem(title: L10n.text("session." + mode.rawValue), action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = ModeMenuRequest(token: session.token, mode: mode)
            item.state = session.context.mode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 26), in: modeButton)
    }
    @objc private func selectMode(_ item: NSMenuItem) {
        guard let request = item.representedObject as? ModeMenuRequest, session.isCurrent(request.token) else { return }
        setSearchMode(request.mode); searchField.focus()
    }
    private func updateRouteControls() {
        guard isViewLoaded else { return }
        modeButton.title = L10n.text("session." + session.context.mode.rawValue)
        updateDialogControls()
        footer.contextText = modeButton.title
        fileSearchButton.title = L10n.text("launcher.forceFiles")
        switch queryRoute {
        case .files:
            fileSearchButton.isHidden = true
            routeHint.stringValue = launcher.error == nil ? "" : L10n.text("launcher.error")
            if let item = results.selectedPaletteItem, case .application(let app) = item { routeHint.stringValue = app.url.path }
        case .waiting(let keyword):
            fileSearchButton.isHidden = false; routeHint.stringValue = L10n.text("launcher.waiting", keyword.name)
            footer.contextText = L10n.text("launcher.webMode")
            footer.text = routeHint.stringValue
        case .web(let web):
            fileSearchButton.isHidden = false; routeHint.stringValue = L10n.text("launcher.web", web.keyword.name)
            footer.contextText = L10n.text("launcher.webMode")
            footer.text = web.keyword.name + " · ↩ " + L10n.text("hint.open")
        }
        routeHint.toolTip = routeHint.stringValue
        footer.actionable = !syntaxVisible && stateView == nil && results.selectedItem != nil
    }
    private func paletteActionDidFinish(_ event: PaletteActionEvent) {
        guard session.isCurrent(event.request.token) else { return }
        switch event.outcome {
        case .accepted:
            if event.request.action == .open || event.request.action == .reveal { hidePanel?() }
        case .verified:
            if case .application(let app) = event.request.item {
                switch event.request.action {
                case .copyName: footer.showToast(.copiedName, value: app.name)
                case .copyPath: footer.showToast(.copiedPath, value: app.url.path)
                default: footer.showMessage("action.copiedFile", value: app.name, snapshot: snapshot)
                }
            }
        case .failed(let failure), .cancelled(let failure): footer.showMessage("action." + failure.rawValue, snapshot: snapshot)
        }
    }
    @objc func paletteContextAction(_ item: NSMenuItem) {
        guard !searchField.editor.hasMarkedText(), let request = item.representedObject as? PaletteActionRequest else { return }
        actionExecutor.execute(request)
    }
    func setDirectoryScope(_ url: URL?) {
        session.setDirectoryScope(url)
        results.clear()
        updateDirectoryControls(); startSearch(preserveSelection: true)
    }
    @objc private func toggleDirectoryScope() {
        if session.directoryScope != nil { setDirectoryScope(nil) }
        else if let url = session.context.directoryScope { setDirectoryScope(url) }
    }
    private func updateDirectoryControls() {
        guard isViewLoaded else { return }
        scopeButton.title = L10n.text(session.directoryScope == nil ? "directory.all" : "directory.current")
        scopeButton.isEnabled = session.directoryScope != nil || session.context.directoryScope != nil
        directoryButton.title = L10n.text("directory.switch")
        if let url = session.directoryScope ?? session.context.directoryScope {
            directoryHint.stringValue = url.path; directoryHint.toolTip = url.path
        } else if let reason = session.context.finderUnavailable {
            directoryHint.stringValue = L10n.text("finder." + reason.rawValue); directoryHint.toolTip = directoryHint.stringValue
        } else { directoryHint.stringValue = ""; directoryHint.toolTip = nil }
        favoriteRows.arrangedSubviews.forEach { favoriteRows.removeArrangedSubview($0); $0.removeFromSuperview() }
        favoriteRows.isHidden = !searchField.text.isEmpty || favorites.favorites.isEmpty
        if !favoriteRows.isHidden {
            let header = NSTextField(labelWithString: L10n.text("directory.favorites"))
            header.font = .systemFont(ofSize: 11, weight: .medium); header.textColor = .secondaryLabelColor
            favoriteRows.addArrangedSubview(header)
            for candidate in directoryCandidates.filter({ $0.origin == .favorite }).prefix(3) {
                let button = NSButton(title: candidate.name + " · " + L10n.text("directory." + candidate.availability.rawValue), target: self, action: #selector(favoriteRowClicked(_:)))
                button.bezelStyle = .inline; button.controlSize = .small; button.toolTip = candidate.url.path
                button.identifier = NSUserInterfaceItemIdentifier(candidate.id)
                favoriteRows.addArrangedSubview(button)
            }
            if favorites.favorites.count > 3 {
                let more = NSButton(title: L10n.text("directory.more"), target: self, action: #selector(showDirectories))
                more.bezelStyle = .inline; favoriteRows.addArrangedSubview(more)
            }
            let recent = NSTextField(labelWithString: L10n.text("directory.recent"))
            recent.font = .systemFont(ofSize: 11, weight: .medium); recent.textColor = .secondaryLabelColor
            favoriteRows.addArrangedSubview(recent)
        }
        view.needsLayout = true
    }
    func directoryMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        for origin in [DirectoryCandidate.Origin.finder, .favorite] {
            let title = NSMenuItem(title: L10n.text(origin == .finder ? "directory.finder" : "directory.favorites"), action: nil, keyEquivalent: "")
            title.isEnabled = false; menu.addItem(title)
            for candidate in directoryCandidates where candidate.origin == origin {
                let item = NSMenuItem(title: candidate.name + " · " + (candidate.sourceName.isEmpty ? L10n.text("directory." + candidate.availability.rawValue) : candidate.sourceName + " · " + L10n.text("directory." + candidate.availability.rawValue)), action: nil, keyEquivalent: "")
                item.toolTip = candidate.url.path
                let submenu = NSMenu(); submenu.autoenablesItems = false
                if let finder = candidate.finderDirectory {
                    item.title += " · " + L10n.text("dialog.finderSource", finder.method.rawValue, DateFormatter.localizedString(from: finder.observedAt, dateStyle: .none, timeStyle: .short))
                }
                for key in (isDialogMode ? ["handoff", "scope", "copy", "favorite"] : ["scope", "copy", "favorite"]) {
                    let action = NSMenuItem(title: L10n.text("directory." + key), action: #selector(directoryAction(_:)), keyEquivalent: "")
                    action.target = self; action.identifier = NSUserInterfaceItemIdentifier(key)
                    action.representedObject = DirectoryMenuRequest(token: session.token, candidate: candidate)
                    action.isEnabled = key == "copy" || candidate.availability == .available || candidate.availability == .unindexed
                    submenu.addItem(action)
                }
                item.submenu = submenu; menu.addItem(item)
            }
        }
        let authorize = NSMenuItem(title: L10n.text("finder.authorize"), action: #selector(authorizeFinder), keyEquivalent: "")
        authorize.target = self; menu.addItem(.separator()); menu.addItem(authorize)
        return menu
    }
    @objc private func showDirectories() { directoryMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: 26), in: directoryButton) }
    @objc private func favoriteRowClicked(_ sender: NSButton) {
        guard let candidate = directoryCandidates.first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        let item = NSMenuItem(); item.identifier = NSUserInterfaceItemIdentifier("scope")
        item.representedObject = DirectoryMenuRequest(token: session.token, candidate: candidate)
        directoryAction(item)
    }
    @objc private func directoryAction(_ item: NSMenuItem) {
        guard let request = item.representedObject as? DirectoryMenuRequest, session.isCurrent(request.token) else { return }
        let candidate = request.candidate
        if item.identifier?.rawValue == "copy" {
            let board = NSPasteboard.general; board.clearContents()
            if board.setString(candidate.url.path, forType: .string) { footer.showToast(.copiedPath, value: candidate.url.path) }
            return
        }
        guard candidate.availability == .available || candidate.availability == .unindexed,
              favorites.system.check(candidate.url) == .available else { return }
        if item.identifier?.rawValue == "handoff" { navigateDirectory(candidate, token: request.token); return }
        if item.identifier?.rawValue == "scope" { setDirectoryScope(candidate.url) }
        else { do { try favorites.add(candidate.url) } catch { footer.showMessage("directory.error", snapshot: snapshot) } }
    }
    @objc private func favoriteSelected(_ item: NSMenuItem) {
        guard let request = item.representedObject as? ActionRequest, actionExecutor.validate(request) == nil else { return }
        do { try favorites.add(request.target.url, sourceID: request.target.sourceID) }
        catch { footer.showMessage("directory.error", snapshot: snapshot) }
    }
    @objc private func authorizeFinder() {
        _ = SystemAccessibilityPermission().requestTrust()
        _ = SystemFinderProbe.automationPermission(request: true)
        footer.showMessage("finder.authorizationResult", snapshot: snapshot)
    }
    func menuWillOpen(_ menu: NSMenu) { menuTracking = true }
    func menuDidClose(_ menu: NSMenu) {
        menuTracking = false
        // AppKit dispatches the chosen action after menu tracking closes.
        scheduleHideIfInactive()
    }
    private func scheduleHideIfInactive() {
        let sessionID = session.sessionID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session.sessionID == sessionID else { return }
            self.hideIfInactive()
        }
    }
    private func hideIfInactive() {
        if session.isActive && pendingOpen == nil && !actionExecutor.dialog.isNavigating && view.window?.isKeyWindow == false && !quickLook.isVisible && !menuTracking && !dragging && !actionModalActive { hidePanel?() }
    }
    func windowDidResignKey(_ notification: Notification) {
        // Quick Look visibility settles after the key-window transition.
        scheduleHideIfInactive()
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === searchField.input ? searchField.editor : nil
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { validatedPreviewURL != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.end(panel) }
}
