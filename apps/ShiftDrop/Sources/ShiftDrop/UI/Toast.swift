import AppKit
import SwiftUI

struct ToastView: View {
    let success: Bool
    let title: String
    let detail: String?
    let canReveal: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(success ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.yellow))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
            if canReveal {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.1).opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .fixedSize()
    }
}

/// Small HUD that confirms a result. Clicking it reveals the files in Finder.
@MainActor
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private let hideDelay = Delay()
    private var revealURLs: [URL] = []

    func show(_ result: ActionResult, near point: CGPoint?) {
        show(success: true, title: result.headline, detail: result.detail, reveal: result.outputs, near: point)
    }

    func show(_ error: Error, near point: CGPoint?) {
        show(success: false, title: "Couldn't finish", detail: error.localizedDescription, reveal: [], near: point)
    }

    func show(success: Bool, title: String, detail: String?, reveal: [URL], near point: CGPoint?) {
        revealURLs = reveal
        let host = NSHostingView(rootView: ToastView(success: success, title: title, detail: detail, canReveal: !reveal.isEmpty))
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)

        let catcher = ClickCatcher(frame: host.frame)
        catcher.onClick = { [weak self] in self?.reveal() }
        let content = NSView(frame: host.frame)
        content.addSubview(host)
        content.addSubview(catcher)

        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.contentView = content

        let screen = point.flatMap { p in NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: CGPoint
        if let point {
            origin = CGPoint(x: point.x - size.width / 2, y: point.y - 200 - size.height)
            if origin.y < visible.minY + 12 { origin.y = point.y + 200 }
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24)
        }
        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        hideDelay.schedule(after: success ? 3.2 : 6) { [weak self] in self?.hide() }
    }

    private func reveal() {
        if !revealURLs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealURLs) }
        hide()
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}

final class ClickCatcher: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}
