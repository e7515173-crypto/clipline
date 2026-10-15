import AppKit
import Combine
import QuartzCore

/// Stress checks use disposable directories and images, never the user's files.
@main
struct PerformanceChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("clipline-stress-" + UUID().uuidString)
        let large = root.appendingPathComponent("Large"), empty = root.appendingPathComponent("Empty")
        let images = root.appendingPathComponent("Images")
        for folder in [large, empty, images] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(12)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            check(condition(), "Background work finishes within the stress-test timeout")
        }
        func png(_ width: Int, _ height: Int) -> Data {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            return bitmap.representation(using: .png, properties: [:])!
        }
        for index in 0..<3000 { try Data().write(to: large.appendingPathComponent("File-\(index).txt")) }
        let original = png(1600, 1000), edited = png(1000, 1600)
        for index in 0..<24 { try original.write(to: images.appendingPathComponent("Photo-\(index).png")) }
        let folders = FolderShelf(persists: false)
        defer { folders.stop() }
        let largeID = try folders.add(large), emptyID = try folders.add(empty), imagesID = try folders.add(images)
        var ticks = 0
        var lastTick = CACurrentMediaTime(), longestGap: Double = 0
        let heartbeat = Timer(timeInterval: 0.001, repeats: true) { _ in
            let now = CACurrentMediaTime()
            longestGap = max(longestGap, now - lastTick)
            lastTick = now
            ticks += 1
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        defer { heartbeat.invalidate() }
        let listingStart = CACurrentMediaTime()
        folders.select(largeID)
        wait { !folders.isLoading }
        let listingMS = (CACurrentMediaTime() - listingStart) * 1000
        check(folders.items.count == 100 && folders.hasMoreItems, "A 3,000-file folder publishes only its first page")
        check(ticks > 0, "Main run loop remains responsive during the directory scan")
        let switchStart = CACurrentMediaTime()
        for _ in 0..<40 { folders.select(emptyID); folders.select(largeID) }
        folders.select(emptyID)
        wait { !folders.isLoading }
        check(folders.selectedID == emptyID && folders.items.isEmpty, "81 rapid switches publish only the final selection")
        let switchMS = (CACurrentMediaTime() - switchStart) * 1000
        folders.select(imagesID)
        wait { !folders.isLoading }
        var folderPublications = 0
        let folderObservation = folders.$items.dropFirst().sink { _ in folderPublications += 1 }
        for item in folders.items { folders.requestThumbnail(item.id) }
        wait { folders.items.allSatisfy { !$0.needsThumbnail } }
        check(folderPublications <= 24, "An image no longer publishes separate thumbnail and readiness mutations")
        check(folders.items.allSatisfy { $0.thumbnail.size == CGSize(width: 320, height: 200) }, "Visible previews stay bounded")
        let previewImages = Dictionary(uniqueKeysWithValues: folders.items.map { ($0.id, $0.thumbnail) })
        folders.refresh()
        wait { !folders.isLoading }
        check(folders.items.allSatisfy { !$0.needsThumbnail && $0.thumbnail === previewImages[$0.id] }, "Refreshing unchanged files preserves decoded images")
        folderObservation.cancel()
        folders.select(emptyID)
        wait { !folders.isLoading }

        let line = Line(persistsScreenshots: false)
        for item in (try fm.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)) {
            check(line.hang(item, quietly: true) != nil, "Stress fixture hangs")
            try edited.write(to: item, options: .atomic)
        }
        // Fixture creation deliberately runs synchronously; exclude setup from
        // the run-loop gap measured during actual background application work.
        lastTick = CACurrentMediaTime()
        var screenshotPublications = 0
        let lineObservation = line.$items.dropFirst().sink { _ in screenshotPublications += 1 }
        var done = false
        let refreshStart = CACurrentMediaTime()
        line.refreshChangedThumbnails { done = true }
        wait { done }
        let refreshMS = (CACurrentMediaTime() - refreshStart) * 1000
        check(screenshotPublications == 1, "24 edited screenshots produce one row publication")
        check(line.items.allSatisfy { $0.thumb.size == CGSize(width: 200, height: 320) }, "Background refresh decodes all edited screenshots")
        let steadyImages = line.items.map(\.thumb)
        done = false
        line.refreshChangedThumbnails { done = true }
        wait { done }
        check(screenshotPublications == 1 && zip(steadyImages, line.items.map(\.thumb)).allSatisfy { $0 === $1 }, "Unchanged refresh avoids decoding and UI publication")
        lineObservation.cancel()
        print(String(format: "METRIC: 3000-file first page %.1f ms; 81 switches %.1f ms; 24 edited previews %.1f ms; main-loop maximum gap %.1f ms; folder preview publications %d", listingMS, switchMS, refreshMS, longestGap * 1000, folderPublications))
        print("PASS: \(checks) large-folder, cancellation, preview reuse, run-loop responsiveness and batched-refresh stress checks")
    }
}
