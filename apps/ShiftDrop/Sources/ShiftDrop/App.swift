import AppKit
import ServiceManagement
import SwiftUI

@main
enum ShiftDropMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let arguments = CommandLine.arguments

        // Developer modes used by CI: run every conversion, or render the UI to PNG files.
        for (flag, job) in [("--selftest", DevMode.selfTest), ("--snapshots", DevMode.snapshots)] {
            guard let index = arguments.firstIndex(of: flag) else { continue }
            let directory = arguments.indices.contains(index + 1)
                ? URL(fileURLWithPath: arguments[index + 1])
                : FileManager.default.temporaryDirectory.appendingPathComponent("ShiftDrop\(flag)")
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                let passed = await job.run(in: directory)
                exit(passed ? 0 : 1)
            }
            app.run()
            return
        }

        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
enum DevMode {
    case selfTest, snapshots

    func run(in directory: URL) async -> Bool {
        switch self {
        case .selfTest: return await SelfTest.run(in: directory)
        case .snapshots: return await Snapshots.render(into: directory)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let monitor = DragMonitor()
    private let wheel = WheelController()
    private var welcome: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusIcon.idle
        item.button?.toolTip = "ShiftDrop — drag a file and press Shift"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        monitor.onShift = { [weak self] payload, location in self?.shiftPressed(payload, at: location) }
        monitor.onDragEnded = { [weak self] in self?.wheel.dragEnded() }
        monitor.isEnabled = Settings.shared.enabled
        monitor.start()

        JobCenter.shared.onChange = { [weak self] busy in
            self?.statusItem?.button?.image = busy ? StatusIcon.busy : StatusIcon.idle
        }

        if !Settings.shared.hasSeenWelcome {
            Settings.shared.hasSeenWelcome = true
            showWelcome()
        }
    }

    private func shiftPressed(_ payload: DragPayload, at location: CGPoint) {
        if wheel.isPresented {
            wheel.toggleMode()
        } else {
            wheel.present(payload: payload, at: location)
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "ShiftDrop", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: "ShiftDrop", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        header.isEnabled = false
        menu.addItem(header)
        let hint = NSMenuItem(title: "Drag a file, then press ⇧ Shift", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(item("Enabled", #selector(toggleEnabled), checked: Settings.shared.enabled))
        let saveTo = NSMenuItem(title: "Save Results", action: nil, keyEquivalent: "")
        let saveMenu = NSMenu()
        saveMenu.addItem(item("Next to the Original", #selector(saveNextToOriginal),
                              checked: Settings.shared.outputLocation == .nextToOriginal))
        saveMenu.addItem(item("In Downloads", #selector(saveToDownloads), checked: Settings.shared.outputLocation == .downloads))
        saveTo.submenu = saveMenu
        menu.addItem(saveTo)
        menu.addItem(item("Reveal Results in Finder", #selector(toggleReveal), checked: Settings.shared.revealResults))
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin), checked: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Open File…", #selector(openFile), key: "o"))
        menu.addItem(item("How It Works", #selector(showWelcome)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit ShiftDrop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector, checked: Bool = false, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
        monitor.isEnabled = Settings.shared.enabled
        statusItem?.button?.appearsDisabled = !Settings.shared.enabled
    }

    @objc private func saveNextToOriginal() { Settings.shared.outputLocation = .nextToOriginal }
    @objc private func saveToDownloads() { Settings.shared.outputLocation = .downloads }
    @objc private func toggleReveal() { Settings.shared.revealResults.toggle() }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nMove ShiftDrop to the Applications folder and try again."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// Without a drag: pick a file and click a segment.
    @objc private func openFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let payload = DragPayload(urls: panel.urls)
        guard payload.kind != .unsupported else {
            Toast.shared.show(AppError.unsupported("ShiftDrop can't convert this kind of file yet."), near: nil)
            return
        }
        wheel.present(payload: payload, at: NSEvent.mouseLocation, interactive: true)
    }

    @objc private func showWelcome() {
        if let welcome {
            NSApp.activate(ignoringOtherApps: true)
            welcome.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: WelcomeView { [weak self] in
            self?.welcome?.close()
            self?.welcome = nil
        })
        window.center()
        welcome = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum StatusIcon {
    static let idle = draw(highlighted: nil)
    static let busy = draw(highlighted: 0)

    /// A tiny six-segment wheel, drawn as a template image so it follows the menu bar's appearance.
    private static func draw(highlighted: Int?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setFill()
            for index in 0..<6 {
                let start = CGFloat(index) * 60 + 7 + 90
                let end = start + 46
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: 8, startAngle: start, endAngle: end, clockwise: false)
                path.appendArc(withCenter: center, radius: highlighted == index ? 2.6 : 4.4, startAngle: end, endAngle: start,
                               clockwise: true)
                path.close()
                path.fill()
            }
            NSBezierPath(ovalIn: CGRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
