import AppKit
import QuartzCore

final class PanelSurface: FlippedView {
    private let effect = NSVisualEffectView()
    private let snapshot: Bool
    init(snapshot: Bool) {
        self.snapshot = snapshot
        super.init(frame: NSRect(origin: .zero, size: Theme.panelSize))
        wantsLayer = true; layer?.cornerRadius = Theme.corner; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        if !snapshot {
            effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
            let mask = NSImage(size: NSSize(width: 46, height: 46), flipped: false) { rect in
                NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22).fill(); return true
            }
            mask.capInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
            mask.resizingMode = .stretch; effect.maskImage = mask
            addSubview(effect)
        }
        addSubview(SurfaceTint(snapshot: snapshot))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); effect.frame = bounds
        subviews.first(where: { $0 is SurfaceTint })?.frame = bounds
    }
}

private final class SurfaceTint: NSView {
    let snapshot: Bool
    init(snapshot: Bool) { self.snapshot = snapshot; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let dark = Theme.dark(self)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 22, yRadius: 22)
        if snapshot {
            NSColor(srgbRed: dark ? 35/255 : 244/255, green: dark ? 35/255 : 244/255, blue: dark ? 38/255 : 246/255, alpha: 1).setFill(); path.fill()
        }
        (dark ? NSColor.black.withAlphaComponent(0.18) : NSColor.white.withAlphaComponent(0.30)).setFill(); path.fill()
        let pixel = Theme.pixel(self)
        (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.10)).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: pixel / 2, dy: pixel / 2), xRadius: 22 - pixel / 2, yRadius: 22 - pixel / 2)
        border.lineWidth = pixel; border.stroke()
    }
}

enum PanelSource: String {
    case hotkey, menu, reopen, welcome, settings, indexing, interaction
}

// NSWindow has no public presentation layer. NSAnimation keeps alphaValue at the
// displayed value, allowing a reversal to start from that exact alpha.
private final class WindowFade: NSAnimation, NSAnimationDelegate {
    weak var window: NSWindow?
    let startAlpha: CGFloat, endAlpha: CGFloat
    var completion: (() -> Void)?
    init(window: NSWindow, target: CGFloat, duration: Double, curve: NSAnimation.Curve, completion: (() -> Void)? = nil) {
        self.window = window; startAlpha = window.alphaValue; endAlpha = target; self.completion = completion
        super.init(duration: duration, animationCurve: curve)
        animationBlockingMode = .nonblocking; frameRate = 60; delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var currentProgress: NSAnimation.Progress {
        get { super.currentProgress }
        set {
            super.currentProgress = newValue
            window?.alphaValue = startAlpha + (endAlpha - startAlpha) * CGFloat(currentValue)
        }
    }
    func animationDidEnd(_ animation: NSAnimation) { window?.alphaValue = endAlpha; completion?() }
}

final class PanelDragHandle: NSView {
    var onDragging: ((Bool) -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        onDragging?(true); defer { onDragging?(false) }
        window?.performDrag(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 16, y: bounds.midY - 1.5, width: 32, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

final class SearchPanel: NSPanel {
    let searchController: SearchViewController
    private(set) var hiding = false
    private var animationGeneration = 0
    private var presentationGeneration = UUID()
    private var fade: WindowFade?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    private let contextResolver: ContextResolving
    let preferences: PanelPreferences
    private let screens: () -> [PanelScreen]
    private var screenObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    private var contextTimer: Timer?
    private var applyingFrame = false
    init(snapshot: Bool = false, contextResolver: ContextResolving = ContextResolver(), preferences: PanelPreferences? = nil,
         screens: @escaping () -> [PanelScreen] = { PanelScreen.current }) {
        self.contextResolver = contextResolver
        self.preferences = preferences ?? (snapshot ? PanelPreferences() : .shared)
        self.screens = screens
        searchController = SearchViewController(snapshot: snapshot)
        super.init(contentRect: NSRect(origin: .zero, size: Theme.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = true; isMovableByWindowBackground = false; hidesOnDeactivate = false; isOpaque = false; backgroundColor = .clear; hasShadow = true
        isReleasedWhenClosed = false
        contentViewController = searchController; delegate = searchController
        searchController.hidePanel = { [weak self] in self?.hide(source: .interaction) }
        searchController.keepPanelOpen = { [weak self] in self?.preferences.keepOpen == true }
        searchController.onPanelMove = { [weak self] in self?.rememberPlacement() }
        preferencesObserver = NotificationCenter.default.addObserver(forName: PanelPreferences.changed, object: self.preferences, queue: .main) { [weak self] _ in
            self?.applyPreferences()
            self?.searchController.hideIfInactive()
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isVisible, !self.hiding else { return }
            self.restorePlacement()
        }
        contextTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isVisible, !self.hiding else { return }
            self.searchController.session.validateContext()
        }
        applyPreferences()
        if let layer = contentView?.layer {
            let frame = layer.frame; layer.anchorPoint = CGPoint(x: 0.5, y: 0.5); layer.frame = frame
        }
        invalidateShadow()
    }
    func toggle(source: PanelSource = .hotkey) {
        if isVisible && isKeyWindow && !hiding { hide(source: source) } else { show(source: source) }
    }
    func show(source: PanelSource = .interaction, captureContext: Bool = true) {
        let presentation = UUID(); presentationGeneration = presentation
        if !isVisible || hiding || !searchController.session.isActive ||
            (preferences.keepOpen && !isKeyWindow && source.capturesExternalContext) {
            searchController.endSession()
            if captureContext && source.capturesExternalContext {
                contextResolver.capture(source: source) { [weak self] context in
                    guard let self, self.presentationGeneration == presentation else { return }
                    self.searchController.beginSession(source: source, context: context)
                    self.present(source: source)
                }
                return
            }
            searchController.beginSession(source: source, context: .ordinary)
        }
        present(source: source)
    }
    func resumeDialog() { if searchController.session.isActive { present(source: .interaction, refresh: false) } }
    private func present(source: PanelSource, refresh: Bool = true) {
        let cold = !isVisible
        if cold, !restorePlacement() { return }
        AppLog.logger.info("panel show source=\(source.rawValue, privacy: .public)")
        animationGeneration += 1; hiding = false; fade?.stop()
        contentView?.layoutSubtreeIfNeeded()
        if let layer = contentView?.layer {
            if cold {
                alphaValue = 0
                let transform = CATransform3DScale(CATransform3DMakeTranslation(0, Theme.Motion.panelInOffset, 0), Theme.Motion.panelInScale, Theme.Motion.panelInScale, 1)
                Theme.Motion.animate(layer, "transform", to: NSValue(caTransform3D: Theme.Motion.reduced ? CATransform3DIdentity : transform), using: nil)
            }
            Theme.Motion.animate(layer, "transform", to: NSValue(caTransform3D: CATransform3DIdentity), using: Theme.Motion.reduced ? nil : Theme.Motion.panelIn)
        }
        orderFrontRegardless(); makeKey()
        if refresh { searchController.panelWillShow() }
        searchController.searchField.focus(selectAll: refresh)
        fade = WindowFade(window: self, target: 1, duration: Theme.Motion.reduced ? Theme.Motion.reducedFade : Theme.Motion.panelInFade, curve: .easeOut)
        fade?.start()
    }
    func hide(source: PanelSource = .interaction, endingSession: Bool = true) {
        presentationGeneration = UUID()
        if endingSession { searchController.endSession() }
        guard isVisible, !hiding else { return }
        AppLog.logger.info("panel hide source=\(source.rawValue, privacy: .public)")
        animationGeneration += 1; let token = animationGeneration
        hiding = true; fade?.stop(); searchController.results.cancelPress()
        if let layer = contentView?.layer {
            let target = CATransform3DMakeScale(Theme.Motion.panelOutScale, Theme.Motion.panelOutScale, 1)
            Theme.Motion.animate(layer, "transform", to: NSValue(caTransform3D: Theme.Motion.reduced ? CATransform3DIdentity : target), using: Theme.Motion.reduced ? nil : Theme.Motion.basic(Theme.Motion.panelOut, .easeIn))
        }
        fade = WindowFade(window: self, target: 0, duration: Theme.Motion.reduced ? Theme.Motion.reducedFade : Theme.Motion.panelOut, curve: .easeIn) { [weak self] in
            guard let self, self.hiding, self.animationGeneration == token else { return }
            self.orderOut(nil); self.searchController.quickLook.close(); self.hiding = false
        }
        fade?.start()
    }
    private func applyPreferences() { searchController.session.contextLifetime = preferences.keepOpen ? 120 : nil }
    @discardableResult
    private func restorePlacement() -> Bool {
        guard let frame = preferences.restoredFrame(screens: screens(), mouse: NSEvent.mouseLocation) else { return false }
        applyingFrame = true; setFrame(frame, display: false); applyingFrame = false
        return true
    }
    func rememberPlacement() {
        guard !applyingFrame else { return }
        preferences.save(frame: frame, screens: screens())
    }
    override func close() { hide(); super.close() }
    deinit {
        contextTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }
    override func keyDown(with event: NSEvent) {
        if !searchController.handleKey(event) { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !searchController.searchField.editor.hasMarkedText(), searchController.handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
