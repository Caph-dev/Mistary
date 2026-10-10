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
    private let scopeButton = NSButton(title: "", target: nil, action: nil)
    private let directoryButton = NSButton(title: "", target: nil, action: nil)
    private let directoryHint = NSTextField(labelWithString: "")
    private let favoriteRows = NSStackView()
    private var favoritesObserver: AnyCancellable?
    private struct DirectoryMenuRequest { let token: SearchSessionToken; let candidate: DirectoryCandidate }
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
            return self.snapshot ? (self.results.result?.sources ?? []) : self.searchSources
        })
        executor.onEvent = { [weak self] event in
            self?.actionDidFinish(event); self?.onActionEvent?(event)
        }
        return executor
    }()
    var onActionEvent: ((ActionEvent) -> Void)?
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
    private let queue = DispatchQueue(label: "com.oiloil.find.search", qos: .userInteractive)
    private let generation = SearchGeneration(), cache = SearchCache()
    private var timer: Timer?
    private var stateView: NSView?
    private var languageObserver: NSObjectProtocol?
    private var menuTracking = false, dragging = false
    private var selectionAnchor: (sourceID: String, store: IndexStore, id: UInt32, path: String)?
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
    init(snapshot: Bool, favorites: FavoritesStore? = nil) {
        self.snapshot = snapshot
        self.favorites = favorites ?? (snapshot ? FavoritesStore(url: nil) : .shared)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = PanelSurface(snapshot: snapshot) }
    override func viewDidLoad() {
        super.viewDidLoad()
        [searchField, topLine, filters, scopeButton, directoryButton, directoryHint, favoriteRows, results, empty, indexing, bottomLine, footer, syntax].forEach(view.addSubview)
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
            if let item = self.results.selectedItem {
                self.selectionAnchor = (item.source.id, item.source.store, item.id, item.path)
            }
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
            guard let self, let item = self.results.item(at: row),
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
        updateDirectoryControls()
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
        favoriteRows.frame = NSRect(x: 22, y: 140 + px, width: w - 44, height: favoriteHeight)
        let top: CGFloat = 140 + px + favoriteHeight
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
        footer.actionable = !syntaxVisible && stateView == nil && (results.result?.total ?? 0) > 0
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
        if results.result?.directoryScope != nil { results.clear() }
        session.begin(source: source, context: context); _ = generation.next()
        cancelPendingOpen(); results.cancelPendingRefresh(); quickLook.close(); previewRequest = nil
        footer.contextText = L10n.text("session." + context.mode.rawValue)
        updateDirectoryControls()
    }
    func endSession() {
        session.end(); _ = generation.next(); cancelPendingOpen()
        quickLook.close(); previewRequest = nil
    }
    private func cancelPendingOpen(reason: ActionFailure = .staleSession) {
        results.cancelPress()
        if let request = pendingOpen { pendingOpen = nil; actionExecutor.cancel(request, reason: reason) }
    }
    func panelWillShow() {
        supplementaryProvider?.userActivity(visible: true, typing: false)
        let currentQuery = Query.parse(searchField.text, store: manager?.store)
        if let result = results.result, result.isCurrent(searchSources),
           result.query.raw == currentQuery.raw, result.directoryScope == session.directoryScope.map({ DirectoryScope(path: $0.path) }), !currentQuery.isTimeDependent,
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
        if manager?.store == nil { setState(.indexing) }
    }
    private func refreshProgress() {
        if let result = results.result, result.query.isEmpty { updateFooter(result) }
        guard let manager else { return }
        searchField.indexing = manager.state == .scanning || manager.isRescanning
        if manager.store == nil {
            let count = manager.scannedCount
            indexing.updateCount(count); footer.text = L10n.text("footer.indexing", Presentation.countText(count))
        }
    }
    func startSearch(preserveSelection: Bool = false) {
        session.queryChanged(); cancelPendingOpen(); quickLook.close(); previewRequest = nil
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
        let sources = searchSources
        guard let store = sources.first?.store else { refreshProgress(); return }
        var options = filters.options
        options.directoryScope = session.directoryScope.map { DirectoryScope(path: $0.path) }
        if !snapshot { options.pinyin = UserDefaults.standard.bool(forKey: "pinyinEnabled") }
        let query = editingQuery(store: store), previous = results.result
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
            let anchoredRow = anchor.flatMap { found.index(sourceID: $0.sourceID, store: $0.store, id: $0.id, path: $0.path) }
            let row = anchoredRow ?? 0
            let deferNames = anchor != nil && anchoredRow == nil && supplementary != nil && previous?.query.raw == query.raw
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation.current(token), self.session.isCurrent(sessionToken) else { return }
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
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation.current(token), self.session.isCurrent(sessionToken), combined.isCurrent(self.searchSources) else { return }
                        self.pendingNewSearch = nil
                        self.results.refresh(combined)
                    }
                }
            }
        }
    }
    func present(_ result: SearchResult, selection: Int = 0, resetScroll: Bool = true) { present(SearchPresentation(result), selection: selection, resetScroll: resetScroll) }
    func present(_ result: SearchPresentation, selection: Int = 0, resetScroll: Bool = true) {
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
        footer.actionable = !visible && stateView == nil && (results.result?.total ?? 0) > 0
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
        setState(result.total == 0 ? .empty : nil)
        updateFooter(result)
        refreshProgress()
    }
    private func updateFooter(_ result: SearchPresentation) {
        footer.warning = !diagnostics.isEmpty
        if let diagnostic = diagnostics.first { footer.text = L10n.diagnostic(diagnostic); return }
        if result.query.isEmpty {
            let count = Presentation.countText(result.sources.reduce(0) { count, source in count + source.store.read { source.store.liveCount } })
            footer.text = L10n.text("footer.recent", count)
        } else {
            footer.text = L10n.text(result.sortedCount < result.total ? "footer.partial" : "footer.results", Presentation.countText(result.total), Presentation.elapsedText(result.elapsedMs))
        }
    }
    func prepareSnapshot(state: String, query: String, options: SearchOptions, store: IndexStore?, selection: Int, additionalSources: [SearchSource] = []) throws {
        _ = view
        searchField.text = state == "recent" ? "" : query; filters.options = options
        if state == "indexing" {
            setState(.indexing); indexing.updateCount(1_234_567); searchField.indexing = true
            footer.text = L10n.text("footer.indexing", Presentation.countText(1_234_567)); return
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
        case 125: if command { results.select((results.result?.count ?? 1) - 1, repeatKey: event.isARepeat) } else { results.move(1, repeatKey: event.isARepeat) }; return true
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
        guard (view.window as? SearchPanel)?.hiding != true else { return }
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
            if request.action == .open || request.action == .reveal { hidePanel?() }
        case .verified:
            switch request.action {
            case .copyPath: footer.showToast(.copiedPath, value: request.target.url.path)
            case .copyName: footer.showToast(.copiedName, value: request.target.name)
            case .copyFile: footer.showMessage("action.copiedFile", value: request.target.name, snapshot: snapshot)
            case .trash: footer.showToast(.trashed, value: request.target.name)
            default: break
            }
        case .cancelled(let failure), .failed(let failure):
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
        let actions: [FileAction?] = [.open, .reveal, .preview, nil, .copyFile, .copyPath, .copyName, nil, .trash, nil, .contextNavigation]
        for action in actions {
            guard let action else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: L10n.text("ctx." + action.rawValue), action: #selector(contextAction(_:)), keyEquivalent: "")
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
        return menu
    }
    @objc func contextAction(_ item: NSMenuItem) {
        guard let request = item.representedObject as? ActionRequest else { return }
        performAction(request.action, request: request)
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
                for key in ["scope", "copy", "favorite"] {
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
        if session.isActive && pendingOpen == nil && view.window?.isKeyWindow == false && !quickLook.isVisible && !menuTracking && !dragging { hidePanel?() }
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
