import Foundation
import ImageIO
import AVFoundation

/// Watches the folder macOS saves screenshots to and reports new ones.
/// Clipline never takes screenshots itself: you keep your usual shortcut
/// (or CleanShot, or anything else) and the line just picks them up.
@MainActor
final class ScreenshotWatcher {
    let folder: URL
    /// On the Desktop we only accept real screenshots, tagged by macOS with an
    /// extended attribute. In a dedicated folder, any image counts.
    enum Kind { case images, recordings, all }
    private let kind: Kind
    private var known = Set<String>()
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var seedsExistingFiles = true
    private let scanQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Clipline screenshot readiness"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var videoChecks: [String: Task<Void, Never>] = [:]
    private var videoNextCheck: [String: TimeInterval] = [:]
    private var retries: [String: Int] = [:]
    private let onNew: (URL) -> Void
    private let onChange: () -> Void

    nonisolated private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    nonisolated static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    /// Watches the folder macOS saves screenshots to, or a given folder.
    init(folder: URL? = nil, kind: Kind = .images, onNew: @escaping (URL) -> Void, onChange: @escaping () -> Void) {
        self.onNew = onNew
        self.onChange = onChange
        self.folder = folder ?? Self.screenshotFolder()
        self.kind = kind
    }

    static func screenshotFolder() -> URL {
        Inbox.locations.screenshots
    }

    /// Anything created after the app launched counts as new, even if it
    /// landed before the watcher was ready (macOS may be asking for Desktop
    /// access at that moment).
    private let launchDate = Date()

    func start() {
        stop()
        known.removeAll()
        seedsExistingFiles = true
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("Clipline: cannot watch \(folder.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        let token = generation
        src.setEventHandler { [weak self] in
            guard let self, self.generation == token else { return }
            if self.source?.data.intersection([.delete, .rename]).isEmpty == false {
                self.stop()
                self.onChange()
            } else {
                self.scheduleScan()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        scan()
    }

    var isRunning: Bool { source != nil }

    func stop() {
        generation &+= 1
        scanQueue.cancelAllOperations()
        videoChecks.values.forEach { $0.cancel() }
        videoChecks.removeAll()
        videoNextCheck.removeAll()
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        retries.removeAll()
    }

    private func scheduleScan(delay: TimeInterval = 0.05) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pending = work
        // React soon after the final rename. An incomplete write is retried
        // instead of adding an undecodable screenshot to the known set.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scan() {
        let token = generation
        let folder = folder, kind = kind, known = known
        let seed = seedsExistingFiles, launchDate = launchDate
        scanQueue.cancelAllOperations()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let files = Self.listing(in: folder)
            var results: [(url: URL, existing: Bool, candidate: Bool, ready: Bool)] = []
            for entry in files {
                guard !operation.isCancelled else { return }
                let existing = known.contains(entry.url.path) || (seed && entry.created < launchDate)
                let candidate = !existing && Self.isCandidate(entry.url, in: folder, kind: kind)
                let ready = candidate && !CaptureMedia.isVideo(entry.url) && autoreleasepool { Self.isReady(entry.url) }
                results.append((entry.url, existing, candidate, ready))
            }
            let snapshot = results
            DispatchQueue.main.async {
                guard let self, self.generation == token, !operation.isCancelled else { return }
                self.seedsExistingFiles = false
                let paths = Set(snapshot.map { $0.url.path })
                self.known.formIntersection(paths)
                self.retries = self.retries.filter { paths.contains($0.key) }
                self.videoNextCheck = self.videoNextCheck.filter { paths.contains($0.key) }
                var needsRetry = false
                for entry in snapshot {
                    let url = entry.url
                    if entry.existing { self.known.insert(url.path) }
                    guard !self.known.contains(url.path) else { continue }
                    guard entry.candidate else { self.known.insert(url.path); continue }
                    if CaptureMedia.isVideo(url) {
                        self.checkVideo(url)
                        needsRetry = true
                    } else if entry.ready {
                        self.known.insert(url.path)
                        self.retries.removeValue(forKey: url.path)
                        self.onNew(url)
                    } else {
                        let attempts = (self.retries[url.path] ?? 0) + 1
                        self.retries[url.path] = attempts
                        if attempts < 30 { needsRetry = true }
                    }
                }
                self.onChange()
                // In-place writes need not generate another directory event.
                if needsRetry {
                    self.scheduleScan(delay: self.retries.values.contains(where: { $0 < 30 }) ? 0.1 : 1)
                }
            }
        }
        scanQueue.addOperation(operation)
    }

    nonisolated static func isReady(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete else { return false }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceThumbnailMaxPixelSize: 16,
                                       kCGImageSourceShouldCache: false]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    private func checkVideo(_ url: URL) {
        guard videoChecks[url.path] == nil, videoChecks.count < 8,
              ProcessInfo.processInfo.systemUptime >= (videoNextCheck[url.path] ?? 0) else { return }
        let token = generation
        videoChecks[url.path] = Task.detached(priority: .utility) { [weak self] in
            let asset = AVURLAsset(url: url)
            let duration = try? await asset.load(.duration)
            let tracks = try? await asset.loadTracks(withMediaType: .video)
            let ready = duration.map { $0.seconds.isFinite && $0.seconds > 0 } == true && !(tracks?.isEmpty ?? true)
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.videoChecks.removeValue(forKey: url.path)
                if ready && FileManager.default.fileExists(atPath: url.path) {
                    self.known.insert(url.path)
                    self.videoNextCheck.removeValue(forKey: url.path)
                    self.onNew(url)
                    self.onChange()
                    self.scheduleScan()
                } else {
                    // A visible movie can exist throughout a long recording.
                    // Retry until its container is finalized, without blocking UI.
                    self.videoNextCheck[url.path] = ProcessInfo.processInfo.systemUptime + 1
                }
            }
        }
    }

    nonisolated private static func listing(in folder: URL) -> [(url: URL, created: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.map { url in
            (url: url.standardizedFileURL.absoluteURL,
             created: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }.sorted { $0.created == $1.created ? $0.url.path < $1.url.path : $0.created < $1.created }
    }

    deinit {
        scanQueue.cancelAllOperations()
        pending?.cancel()
        source?.cancel()
        videoChecks.values.forEach { $0.cancel() }
    }

    nonisolated static func isCandidate(_ url: URL, in folder: URL, kind: Kind) -> Bool {
        if CaptureMedia.isVideo(url) { return kind != .images }
        guard kind != .recordings, imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return folder.standardizedFileURL == desktop.standardizedFileURL ? isScreenCapture(url) : true
    }

    nonisolated private static func isScreenCapture(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
    }
}
