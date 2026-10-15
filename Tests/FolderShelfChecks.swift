import AppKit
import SwiftUI

/// Focused checks use invented files, disposable defaults and our offscreen panel.
@main
struct FolderShelfChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let suite = "local.clipline.folder-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipline-folder-checks-" + UUID().uuidString)
        let folder = root.appendingPathComponent("FixtureFiles", isDirectory: true)
        let empty = root.appendingPathComponent("EmptyFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let text = folder.appendingPathComponent("Notes.txt")
        try Data("Invented folder fixture".utf8).write(to: text)
        try Data("Hidden".utf8).write(to: folder.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Subfolder"), withIntermediateDirectories: true)
        let png = folder.appendingPathComponent("Photo.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 160,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<160 { for x in 0..<240 {
            bitmap.setColor(NSColor(calibratedHue: 0.52 + Double(x) / 2000,
                                    saturation: 0.6, brightness: 0.95 - Double(y) / 800, alpha: 1), atX: x, y: y)
        } }
        try bitmap.representation(using: .png, properties: [:])!.write(to: png)
        let folders = FolderShelf(defaults: defaults)
        defer { folders.stop() }
        let id = try folders.add(folder)
        let duplicate = try folders.add(folder)
        precondition(id == duplicate && folders.mounts.count == 1, "Duplicate folders share one mount")
        let emptyID = try folders.add(empty)
        func wait(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(8)
            while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            precondition(predicate(), "Folder update timed out")
        }
        folders.select(id)
        wait { !folders.isLoading && folders.items.count == 3 }
        precondition(folders.items.map { $0.url.lastPathComponent } == ["Notes.txt", "Photo.png", "Subfolder"])
        precondition(folders.items.allSatisfy { $0.thumbnail.size.width > 0 })
        let photo = folders.items.first { $0.url == png }!
        precondition(photo.needsThumbnail, "The file list is published before decoding image previews")
        folders.requestThumbnail(photo.id)
        wait { folders.items.first { $0.id == photo.id }?.needsThumbnail == false }
        precondition(folders.items.first { $0.url == png }!.thumbnail.size == CGSize(width: 240, height: 160))
        let originalID = folders.items.first { $0.url == text }!.id
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        folders.copy(folders.items.first { $0.url == text }!, to: board)
        let copied = board.readObjects(forClasses: [NSURL.self], options: nil) as! [NSURL]
        precondition((copied.first! as URL).standardizedFileURL == text.standardizedFileURL)
        let added = folder.appendingPathComponent("Added.txt")
        try Data("Directory watcher check".utf8).write(to: added)
        wait { folders.items.count == 4 }
        precondition(folders.items.first { $0.url == text }!.id == originalID, "Unchanged cards retain their identity")
        try FileManager.default.removeItem(at: added)
        wait { folders.items.count == 3 }
        let restored = FolderShelf(defaults: UserDefaults(suiteName: suite)!)
        defer { restored.stop() }
        precondition(restored.mounts.map(\.id) == folders.mounts.map(\.id), "Mounts survive reopening")
        folders.select(emptyID)
        wait { !folders.isLoading }
        precondition(folders.items.isEmpty && !folders.isUnavailable, "Empty is distinct from inaccessible")
        folders.select(id)
        precondition(folders.items.count == 3, "Returning to a folder immediately displays cached cards")
        folders.select(emptyID)
        wait { !folders.isLoading }
        precondition(folders.items.isEmpty && folders.selectedID == emptyID, "Old async loads cannot replace the selected folder")
        let large = root.appendingPathComponent("LargeFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
        for index in 0...100 { try Data("Fixture".utf8).write(to: large.appendingPathComponent("File-\(index).txt")) }
        let largeID = try folders.add(large)
        folders.select(largeID)
        wait { !folders.isLoading && folders.items.count == 100 }
        precondition(folders.hasMoreItems)
        folders.loadMore()
        wait { !folders.isLoading && folders.items.count == 101 }
        precondition(!folders.hasMoreItems, "Every file remains accessible beyond the first batch")
        folders.remove(largeID)

        let language = AppLanguage(defaults: defaults, preferredLanguages: { ["en"] }, appliesGlobally: true)
        language.selected = .en
        let line = Line(persistsScreenshots: false, folders: folders)
        precondition(line.menuBarDoubleClickEnabled)
        line.menuBarDoubleClickEnabled = false
        precondition(!line.menuBarDoubleClickEnabled)
        precondition(line.hang(png, quietly: true) != nil)
        let screenshotIDs = line.items.map(\.id)
        line.section = .folder(id)
        wait { !folders.isLoading && folders.items.count == 3 }
        precondition(line.items.map(\.id) == screenshotIDs, "Folder browsing preserves screenshots")
        line.revealed = true
        let clipboard = ClipboardHistory(pasteboard: board)
        let pinned = PinnedPhotos(persists: false)
        let host = LineHostingView(rootView: LineView(line: line, clipboard: clipboard, pinnedPhotos: pinned))
        host.sizingOptions = []
        let panel = LinePanel(content: host)
        panel.setFrame(CGRect(x: -10_000, y: -10_000, width: 1280, height: Layout.panelHeight), display: true)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.close() }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func render(_ name: String, width: CGFloat) throws {
            panel.setFrame(CGRect(origin: panel.frame.origin, size: CGSize(width: width, height: Layout.panelHeight)), display: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            host.layoutSubtreeIfNeeded()
            precondition(line.controlsRect.width > 0 && line.controlsRect.maxX <= width + 1)
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot render folder row") }
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
        }
        try render("folder-preview.png", width: 1280)
        precondition(folders.interactionRect.width > 0, "Folder row reports its mouse interaction area")
        for index in 1...6 {
            let other = root.appendingPathComponent("Another mounted folder \(index)")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            _ = try folders.add(other)
        }
        try render("folder-preview-narrow.png", width: 640)
        line.section = .screenshots
        precondition(folders.selectedID == nil && line.items.map(\.id) == screenshotIDs)
        folders.remove(id)
        precondition(FileManager.default.fileExists(atPath: text.path) && FileManager.default.fileExists(atPath: png.path),
                     "Removing a mount preserves source files")
        print("PASS: folder mount/deduplication, mixed file cards, image thumbnails, URL copying, directory updates, persistence, empty folders, switching and source preservation")
        print("PASS: offscreen folder row and narrow navigation rendered to build/folder-preview*.png")
    }
}
