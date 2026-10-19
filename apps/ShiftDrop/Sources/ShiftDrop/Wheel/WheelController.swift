import AppKit
import SwiftUI

/// Borderless floating panel. It never takes focus, so the drag keeps flowing to whatever app it came from.
final class WheelPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Receives the drop. Sits above the SwiftUI view and only claims points inside the disc.
final class WheelDropView: NSView {
    var hitTester: ((CGFloat, CGFloat) -> WheelHit)?
    var onHover: ((WheelHit) -> Void)?
    var onDrop: ((WheelHit, NSDraggingInfo) -> Bool)?
    var onClick: ((WheelHit) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var types: [NSPasteboard.PasteboardType] = [.fileURL]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes(types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func hit(atWindowPoint point: NSPoint) -> WheelHit {
        let local = convert(point, from: nil)
        return hitTester?(local.x - bounds.midX, local.y - bounds.midY) ?? .outside
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let hit = hitTester?(local.x - bounds.midX, local.y - bounds.midY) ?? .outside
        return hit == .outside ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        let hit = self.hit(atWindowPoint: sender.draggingLocation)
        onHover?(hit)
        guard case .segment = hit else { return [] }
        let mask = sender.draggingSourceOperationMask
        for candidate in [NSDragOperation.copy, .generic, .link, .move] where mask.contains(candidate) {
            return candidate
        }
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { onHover?(.outside) }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if case .segment = hit(atWindowPoint: sender.draggingLocation) { return true }
        return false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(hit(atWindowPoint: sender.draggingLocation), sender) ?? false
    }

    override func mouseMoved(with event: NSEvent) { onHover?(hit(atWindowPoint: event.locationInWindow)) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?(hit(atWindowPoint: event.locationInWindow)) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
}

/// Glass disc (behind-window blur) + SwiftUI wheel + drop target.
final class WheelContainerView: NSView {
    let effect = NSVisualEffectView()
    let host: NSHostingView<WheelRootView>
    let drop = WheelDropView(frame: .zero)
    var diameter: CGFloat = 324 { didSet { needsLayout = true } }

    init(model: WheelModel) {
        host = NSHostingView(rootView: WheelRootView(model: model))
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        effect.blendingMode = .behindWindow
        effect.material = .popover
        effect.state = .active
        host.sizingOptions = []
        addSubview(effect)
        addSubview(host)
        addSubview(drop)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        host.frame = bounds
        drop.frame = bounds
        let disc = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        if effect.frame != disc {
            effect.frame = disc
            effect.maskImage = NSImage(size: disc.size, flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
        }
    }
}

@MainActor
final class WheelController {
    let model = WheelModel()
    private(set) var isPresented = false
    private var panel: WheelPanel?
    private var container: WheelContainerView?
    private let dismissDelay = Delay()
    private var center: CGPoint = .zero
    private var clickMonitors: [Any] = []
    private var pendingFiles: [URL] = []

    func present(payload: DragPayload, at point: CGPoint, interactive: Bool = false) {
        let kind = payload.kind
        let convert = Catalog.items(for: kind, source: payload.sourceFormat, mode: .convert, fileCount: payload.count)
        let tools = Catalog.items(for: kind, source: payload.sourceFormat, mode: .tools, fileCount: payload.count)
        guard !convert.isEmpty || !tools.isEmpty else { return }

        cancelDismiss()
        removeClickMonitors()
        pendingFiles = interactive ? payload.urls : []
        model.configure(kind: kind, summary: payload.summary, convert: convert, tools: tools, interactive: interactive)

        let panel = ensurePanel()
        let side = model.geometry.windowSide
        var frame = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX - model.geometry.margin), visible.maxX - side + model.geometry.margin)
            frame.origin.y = min(max(frame.minY, visible.minY - model.geometry.margin), visible.maxY - side + model.geometry.margin)
        }
        container?.diameter = model.geometry.diameter
        panel.setFrame(frame, display: true)
        center = CGPoint(x: frame.midX, y: frame.midY)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        Task { @MainActor [weak panel] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            panel?.invalidateShadow()
        }
        isPresented = true
        if interactive { installClickMonitors() }
    }

    func toggleMode() {
        guard isPresented, model.phase == .choosing else { return }
        let next: WheelMode = model.mode == .convert ? .tools : .convert
        guard !model.items(for: next).isEmpty else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            model.mode = next
            model.hovered = nil
        }
    }

    /// The user let go somewhere. If it was on the wheel, the drop handler takes over first.
    func dragEnded() {
        guard isPresented, !model.interactive, model.phase == .choosing else { return }
        scheduleDismiss(after: model.hovered == nil ? 0.25 : 0.9)
    }

    func dismiss() {
        cancelDismiss()
        removeClickMonitors()
        guard isPresented, let panel else { return }
        isPresented = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isPresented else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    // MARK: - Panel

    private func ensurePanel() -> WheelPanel {
        if let panel { return panel }
        let panel = WheelPanel()
        let container = WheelContainerView(model: model)
        container.drop.hitTester = { [weak self] dx, dy in
            guard let self else { return .outside }
            return self.model.geometry.hit(dx: dx, dy: dy, count: self.model.items.count)
        }
        container.drop.onHover = { [weak self] hit in self?.hover(hit) }
        container.drop.onDrop = { [weak self] hit, info in self?.drop(hit, info) ?? false }
        container.drop.onClick = { [weak self] hit in self?.click(hit) }
        panel.contentView = container
        self.panel = panel
        self.container = container
        return panel
    }

    private func hover(_ hit: WheelHit) {
        guard model.phase == .choosing else { return }
        let index: Int?
        if case .segment(let segment) = hit { index = segment } else { index = nil }
        if model.hovered != index { model.hovered = index }
    }

    private func drop(_ hit: WheelHit, _ info: NSDraggingInfo) -> Bool {
        guard case .segment(let index) = hit, model.items.indices.contains(index), model.phase == .choosing else {
            return false
        }
        let pasteboard = info.draggingPasteboard
        let urls = DragPasteboard.fileURLs(in: pasteboard)
        var batch: PromiseBatch?
        if urls.isEmpty {
            let receivers = DragPasteboard.promiseReceivers(in: pasteboard)
            guard !receivers.isEmpty else { return false }
            batch = PromiseBatch(receivers: receivers)
            batch?.start()
        }
        cancelDismiss()
        run(model.items[index], urls: urls, promises: batch)
        return true
    }

    private func click(_ hit: WheelHit) {
        guard model.interactive, model.phase == .choosing else { return }
        switch hit {
        case .segment(let index) where model.items.indices.contains(index):
            run(model.items[index], urls: pendingFiles, promises: nil)
        case .center:
            toggleMode()
        default:
            dismiss()
        }
    }

    private func run(_ item: WheelItem, urls: [URL], promises: PromiseBatch?) {
        removeClickMonitors()
        let kind = model.kind
        let presentation = model.presentation
        let anchor = center
        model.hovered = model.items.firstIndex(of: item)
        model.phase = .working
        JobCenter.shared.begin()

        Task { @MainActor in
            defer { JobCenter.shared.end() }
            var files = urls
            var override: URL?
            do {
                if let promises {
                    files = try await promises.value()
                    override = Output.downloads
                }
                if case .tool(let tool) = item.action, tool.isInteractive {
                    self.dismiss()
                    Editors.open(tool, files: files, kind: kind, override: override)
                    return
                }
                // Long jobs (video) shouldn't keep the wheel on screen.
                let slow = Delay()
                slow.schedule(after: 1.4) { [weak self] in
                    guard let self, self.model.presentation == presentation else { return }
                    self.dismiss()
                }
                defer { slow.cancel() }

                let result = try await ActionRunner.run(item.action, files: files, kind: kind, override: override)
                self.finish(presentation, phase: .done, delay: 0.7)
                Toast.shared.show(result, near: anchor)
                if Settings.shared.revealResults {
                    NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
                }
            } catch {
                self.finish(presentation, phase: .failed, delay: 1.1)
                Toast.shared.show(error, near: anchor)
            }
        }
    }

    private func finish(_ presentation: UUID, phase: WheelModel.Phase, delay: TimeInterval) {
        guard isPresented, model.presentation == presentation else { return }
        model.phase = phase
        scheduleDismiss(after: delay)
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissDelay.schedule(after: delay) { [weak self] in self?.dismiss() }
    }

    private func cancelDismiss() {
        dismissDelay.cancel()
    }

    // MARK: - Click mode (opened from the menu instead of a drag)

    private func installClickMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.dismiss() }
                return nil
            }
            return event
        }
        clickMonitors = [global, local].compactMap { $0 }
    }

    private func removeClickMonitors() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
    }
}
