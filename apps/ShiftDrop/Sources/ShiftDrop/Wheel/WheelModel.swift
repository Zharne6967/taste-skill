import SwiftUI

@MainActor
final class WheelModel: ObservableObject {
    enum Phase: Equatable {
        case choosing
        case working
        case done
        case failed
    }

    @Published var mode: WheelMode = .convert
    @Published var hovered: Int?
    @Published var phase: Phase = .choosing
    @Published private(set) var presentation = UUID()
    @Published private(set) var geometry = WheelGeometry(capacity: 8)
    @Published private(set) var convertItems: [WheelItem] = []
    @Published private(set) var toolItems: [WheelItem] = []
    @Published private(set) var summary = ""

    private(set) var kind: FileKind = .unsupported
    private(set) var interactive = false

    var items: [WheelItem] { items(for: mode) }

    func items(for mode: WheelMode) -> [WheelItem] {
        mode == .convert ? convertItems : toolItems
    }

    var hoveredItem: WheelItem? {
        guard let hovered, items.indices.contains(hovered) else { return nil }
        return items[hovered]
    }

    var otherModeHint: String? {
        switch mode {
        case .convert: return toolItems.isEmpty ? nil : "⇧  TOOLS"
        case .tools: return convertItems.isEmpty ? nil : "⇧  FORMATS"
        }
    }

    func configure(kind: FileKind, summary: String, convert: [WheelItem], tools: [WheelItem], interactive: Bool) {
        self.kind = kind
        self.summary = summary
        self.interactive = interactive
        convertItems = convert
        toolItems = tools
        mode = convert.isEmpty ? .tools : .convert
        hovered = nil
        phase = .choosing
        geometry = WheelGeometry(capacity: max(convert.count, tools.count))
        presentation = UUID()
    }

    /// A ready-made wheel for the welcome window and the snapshot renderer.
    static func preview(kind: FileKind, source: Format?, mode: WheelMode, hovered: Int?, summary: String = "1.2 MB") -> WheelModel {
        let model = WheelModel()
        model.configure(kind: kind, summary: summary,
                        convert: Catalog.items(for: kind, source: source, mode: .convert, fileCount: 1),
                        tools: Catalog.items(for: kind, source: source, mode: .tools, fileCount: 1),
                        interactive: false)
        model.mode = mode
        model.hovered = hovered
        return model
    }
}
