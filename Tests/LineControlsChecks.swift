import AppKit
import SwiftUI

/// Validate only the switching control with temporary folders and a private pasteboard.
@main
struct LineControlsChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipline-controls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = FolderShelf(persists: false)
        defer { folders.stop() }
        for name in ["Applications", "一班（40人）"] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            _ = try folders.add(url)
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = ClipboardHistory(pasteboard: board)
        clipboard.record(.text("Invented clipboard fixture"), source: "Test")
        let line = Line(persistsScreenshots: false, folders: folders)
        line.revealed = true
        let pinned = PinnedPhotos(persists: false)
        let host = LineHostingView(rootView: LineView(line: line, clipboard: clipboard, pinnedPhotos: pinned))
        host.sizingOptions = []
        let panel = LinePanel(content: host)
        panel.setFrame(CGRect(x: -10_000, y: -10_000, width: 1728, height: Layout.panelHeight), display: true)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.close() }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func render(_ name: String, width: CGFloat, section: Line.Section) throws -> CGRect {
            panel.setFrame(CGRect(origin: panel.frame.origin, size: CGSize(width: width, height: Layout.panelHeight)), display: true)
            line.section = section
            RunLoop.main.run(until: Date().addingTimeInterval(0.75))
            host.layoutSubtreeIfNeeded()
            let rect = line.controlsRect
            print("Control bounds \(name): \(rect)")
            check(rect.width > 150 && rect.minX >= 0 && rect.maxX <= width,
                  "Controls stay within the screen")
            check(abs(rect.midX - width / 2) < 1, "Controls stay centered")
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
            check(rect.minY >= 170 && rect.maxY <= Layout.panelHeight, "Controls fit below the hanging cards")
            return rect
        }
        let captures = try render("controls-captures.png", width: 1728, section: .screenshots)
        let history = try render("controls-clipboard.png", width: 1728, section: .clipboard)
        check(captures.width < 700, "Four tabs remain compact on a wide display")
        check(history.width < 850, "Clipboard controls do not stretch across the display")
        check(history.width - captures.width < 180, "Only the clipboard actions add width")
        let returned = try render("controls-returned.png", width: 1728, section: .screenshots)
        check(abs(returned.width - captures.width) < 1, "Returning restores the original compact width")
        _ = try render("controls-narrow.png", width: 640, section: .clipboard)
        for index in 1...6 {
            let url = root.appendingPathComponent("Extra folder \(index)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            _ = try folders.add(url)
        }
        _ = try render("controls-overflow.png", width: 640, section: .clipboard)
        check(clipboard.entries.count == 1 && folders.mounts.count == 8, "Style changes preserve clipboard entries and folder mounts")
        print("PASS: \(checks) switching-control bounds, compact clipboard width, return width, centering and narrow/overflow checks")
        print("Widths: captures=\(captures.width), clipboard=\(history.width), returned=\(returned.width)")
    }
}
