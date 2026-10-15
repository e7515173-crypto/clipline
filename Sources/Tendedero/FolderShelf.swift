import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// User-selected folders are references, independent of the screenshot inbox.
@MainActor
final class FolderShelf: ObservableObject {
    struct Mount: Identifiable, Codable {
        let id: UUID
        var url: URL
        var bookmark: Data?
        var name: String { url.lastPathComponent }
    }
    struct Item: Identifiable {
        let id: UUID
        let url: URL
        var thumbnail: NSImage
        var needsThumbnail: Bool
        let modified: Date?
        let bytes: Int?
    }
    @Published private(set) var mounts: [Mount] = []
    @Published private(set) var items: [Item] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var isUnavailable = false
    @Published private(set) var hasMoreItems = false
    @Published var copiedID: UUID?
    var interactionRect: CGRect = .zero
    var canRefresh: (() -> Bool)?
    private let defaults: UserDefaults
    private let persists: Bool
    private let key = "mountedFolders.v1"
    private let scanQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Clipline folder listings"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var generation = 0
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var accessedURLs: [UUID: URL] = [:]
    private var displayLimit = 100
    private var previewsRequested = Set<UUID>()
    private var previewGeneration = 0
    private var readyPreviews: [UUID: (item: Item, thumbnail: NSImage?)] = [:]
    private var previewPublication: DispatchWorkItem?
    private var cachedItems: [UUID: [Item]] = [:]
    private let previewQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Clipline visible file previews"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    nonisolated private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp", "ico"]
    static let limit = 100

    init(defaults: UserDefaults = .standard, persists: Bool = true) {
        self.defaults = defaults
        self.persists = persists
        guard persists, let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([Mount].self, from: data) else { return }
        var seen = Set<String>()
        mounts = saved.compactMap { record in
            var mount = record
            if let bookmark = record.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                      relativeTo: nil, bookmarkDataIsStale: &stale) {
                    mount.url = url.standardizedFileURL
                    if stale { mount.bookmark = try? url.bookmarkData(options: [.minimalBookmark]) }
                }
            }
            guard mount.url.isFileURL, seen.insert(mount.url.standardizedFileURL.path).inserted else { return nil }
            if mount.url.startAccessingSecurityScopedResource() { accessedURLs[mount.id] = mount.url }
            return mount
        }
    }

    @discardableResult
    func add(_ url: URL) throws -> UUID {
        let url = url.standardizedFileURL
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard url.isFileURL, values.isDirectory == true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw CocoaError(.fileReadNoPermission) }
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        if let existing = mounts.first(where: { $0.url.standardizedFileURL == url }) {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return existing.id
        }
        let mount = Mount(id: UUID(), url: url, bookmark: try? url.bookmarkData(options: [.minimalBookmark]))
        if scoped { accessedURLs[mount.id] = url }
        mounts.append(mount)
        save()
        return mount.id
    }

    func remove(_ id: UUID) {
        if selectedID == id { select(nil) }
        mounts.removeAll { $0.id == id }
        cachedItems[id] = nil
        accessedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        save()
    }

    func select(_ id: UUID?) {
        if selectedID == id { if id != nil { refresh() }; return }
        if let previous = selectedID { cachedItems[previous] = Array(items.prefix(Self.limit)) }
        if cachedItems.count > 3, let oldest = cachedItems.keys.first(where: { $0 != id && $0 != selectedID }) {
            cachedItems[oldest] = nil
        }
        previewGeneration += 1
        previewQueue.cancelAllOperations()
        previewPublication?.cancel()
        previewPublication = nil
        readyPreviews.removeAll()
        previewsRequested.removeAll()
        stopWatching()
        generation += 1
        pending?.cancel()
        pending = nil
        selectedID = id
        items = id.flatMap { cachedItems[$0] } ?? []
        copiedID = nil
        isUnavailable = false
        isLoading = false
        hasMoreItems = false
        displayLimit = Self.limit
        interactionRect = .zero
        guard let mount = mounts.first(where: { $0.id == id }) else { return }
        isLoading = true
        watch(mount.url)
        refresh()
    }

    func refresh() {
        guard let mount = mounts.first(where: { $0.id == selectedID }) else { return }
        if canRefresh?() == false { scheduleRefresh(); return }
        generation += 1
        let token = generation
        let limit = displayLimit
        let oldItems = Dictionary(uniqueKeysWithValues: items.map { ($0.url.path, $0) })
        isLoading = true
        scanQueue.cancelAllOperations()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let result: Result<(items: [Item], hasMore: Bool), Error> = Result {
                let files = try FileManager.default.contentsOfDirectory(at: mount.url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])
                guard !operation.isCancelled else { throw CancellationError() }
                var icons: [String: NSImage] = [:]
                let items = try files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    .prefix(limit).map { url in
                        guard !operation.isCancelled else { throw CancellationError() }
                        let url = url.standardizedFileURL
                        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
                        if let old = oldItems[url.path], old.modified == values?.contentModificationDate,
                           old.bytes == values?.fileSize { return old }
                        let isDirectory = values?.isDirectory == true
                        let iconKey = isDirectory ? "folder" : "file:" + url.pathExtension.lowercased()
                        let icon = icons[iconKey] ?? Self.icon(url, isDirectory: isDirectory)
                        icons[iconKey] = icon
                        return Item(id: UUID(), url: url,
                                    thumbnail: icon,
                                    needsThumbnail: !isDirectory && Self.imageExtensions.contains(url.pathExtension.lowercased()),
                                    modified: values?.contentModificationDate,
                                    bytes: values?.fileSize)
                    }
                return (items, files.count > limit)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.selectedID == mount.id else { return }
                self.isLoading = false
                switch result {
                case .success(let result):
                    // A visible preview may finish while this listing is being read.
                    // Preserve that newer image instead of restoring its old placeholder.
                    let current = Dictionary(uniqueKeysWithValues: self.items.map { ($0.id, $0) })
                    self.items = result.items.map { item in
                        if let latest = current[item.id], !latest.needsThumbnail { return latest }
                        return item
                    }
                    self.hasMoreItems = result.hasMore; self.isUnavailable = false
                    self.previewsRequested.formIntersection(Set(result.items.map(\.id)))
                case .failure:
                    self.items = []; self.hasMoreItems = false; self.isUnavailable = true
                }
            }
        }
        scanQueue.addOperation(operation)
    }

    /// The first list contains inexpensive type icons. Decode only visible images,
    /// off the main thread; a slow or obsolete preview cannot block another folder.
    func requestThumbnail(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.needsThumbnail,
              previewsRequested.insert(id).inserted else { return }
        let token = previewGeneration
        previewQueue.addOperation { [weak self] in
            let preview = autoreleasepool { Self.thumbnail(item.url) }
            DispatchQueue.main.async {
                guard let self, self.previewGeneration == token,
                      self.items.contains(where: { $0.id == id }) else { return }
                self.readyPreviews[id] = (item, preview)
                self.schedulePreviewPublication()
            }
        }
    }

    /// Publish nearby completions once per frame, instead of twice per image.
    private func schedulePreviewPublication() {
        guard previewPublication == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewPublication = nil
            let ready = self.readyPreviews
            self.readyPreviews.removeAll()
            var updated = self.items
            var changed = false
            for index in updated.indices {
                let item = updated[index]
                guard let result = ready[item.id] else { continue }
                self.previewsRequested.remove(item.id)
                guard item.modified == result.item.modified, item.bytes == result.item.bytes,
                      item.needsThumbnail else { continue }
                if let thumbnail = result.thumbnail { updated[index].thumbnail = thumbnail }
                updated[index].needsThumbnail = false
                changed = true
            }
            if changed { self.items = updated }
        }
        previewPublication = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: work)
    }

    func loadMore() {
        guard hasMoreItems, !isLoading else { return }
        displayLimit += Self.limit
        refresh()
    }

    func copy(_ item: Item, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item.url as NSURL]) else { NSSound.beep(); return }
        copiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == item.id { self?.copiedID = nil }
        }
    }

    func trash(_ item: Item) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            refresh()
        } catch { NSSound.beep() }
    }

    func stop() {
        generation += 1
        previewGeneration += 1
        previewQueue.cancelAllOperations()
        scanQueue.cancelAllOperations()
        previewPublication?.cancel()
        previewPublication = nil
        readyPreviews.removeAll()
        previewsRequested.removeAll()
        isLoading = false
        stopWatching()
        pending?.cancel()
        pending = nil
        for url in accessedURLs.values { url.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()
    }

    private func save() {
        if persists, let data = try? JSONEncoder().encode(mounts) { defaults.set(data, forKey: key) }
    }

    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func watch(_ folder: URL) {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .attrib, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleRefresh() }
        source.setCancelHandler { close(fd) }
        watcher = source
        source.resume()
    }

    private func stopWatching() { watcher?.cancel(); watcher = nil }

    nonisolated private static func icon(_ url: URL, isDirectory: Bool) -> NSImage {
        NSWorkspace.shared.icon(for: isDirectory ? .folder : (UTType(filenameExtension: url.pathExtension) ?? .item))
    }

    nonisolated private static func thumbnail(_ url: URL) -> NSImage? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              (values.fileSize ?? 0) <= 128 * 1024 * 1024,
              values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current else { return nil }
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320
           ] as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return nil
    }

    deinit {
        scanQueue.cancelAllOperations()
        previewPublication?.cancel()
        previewQueue.cancelAllOperations()
        watcher?.cancel()
        pending?.cancel()
        for url in accessedURLs.values { url.stopAccessingSecurityScopedResource() }
    }
}
