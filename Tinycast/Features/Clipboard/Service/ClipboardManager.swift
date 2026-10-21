import AppKit
import UniformTypeIdentifiers

@MainActor
final class ClipboardManager {
    /// Marker we attach to the pasteboard when *we* write to it, so polling ignores our own pastes.
    static let internalType = NSPasteboard.PasteboardType("com.tinycast.internal")

    /// Markers put on secret copies by password managers, browsers and the OS.
    static let sensitiveTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("com.apple.is-sensitive")
    ]

    private let store: ClipboardStore
    private let settings: AppSettings
    private var timer: Timer?
    private var sessionTokens: [NotificationToken] = []
    private var lastChangeCount = 0
    private var isCapturing = false
    private var isCapturePaused = false
    private lazy var screenshots = ScreenshotWatcher { [weak self] url in self?.addScreenshot(url) }

    init(store: ClipboardStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    // Isolated so teardown can touch the main-actor timer; the poll block is already weak.
    isolated deinit {
        timer?.invalidate()
    }

    func start() {
        guard !isCapturing else { return }
        isCapturing = true
        installSessionObservers()
        startPolling()
        screenshots.start()
    }

    func stop() {
        isCapturing = false
        sessionTokens = []
        stopPolling()
        screenshots.stop()
    }

    private func addScreenshot(_ url: URL) {
        guard isCapturing else { return }
        let sourceBundleID = ScreenshotWatcher.sourceBundleID
        if settings.clipboardDisabledApps.contains(sourceBundleID) { return }
        let store = store
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return }
            let png =
                UTType(filenameExtension: url.pathExtension) == .png
                ? data
                : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            guard let png else { return }
            await store.addImage(png, sourceBundleID: sourceBundleID)
        }
    }

    // Fast user switching: another session's clipboard isn't ours, so stop waking up for it.
    private func installSessionObservers() {
        guard sessionTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sessionTokens = [
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stopPolling() }
                }, center: center),
            NotificationToken(
                center.addObserver(
                    forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.startPolling() }
                }, center: center)
        ]
    }

    // Re-baselining first is what stops a clip made in another session reading as new on resume.
    private func startPolling() {
        guard isCapturing, timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // Drain first: the real copy must reach history before we overwrite the pasteboard.
    func prepareForTinycastPasteboardMutation() {
        guard isCapturing else { return }
        poll()
    }

    /// For a ⌘C Tinycast sends itself, whose copy is read and restored but never recorded.
    func pauseCapture() {
        prepareForTinycastPasteboardMutation()
        isCapturePaused = true
    }

    func resumeCapture() {
        isCapturePaused = false
    }

    // Load-bearing: a mismatched count means a foreign write the next poll must still see.
    func synchronizeAfterTinycastPasteboardMutation(changeCount: Int) {
        guard NSPasteboard.general.changeCount == changeCount else { return }
        lastChangeCount = changeCount
    }

    /// A Finder select-all must not insert ten thousand rows on one poll tick.
    nonisolated static let maxCapturedFiles = 32

    /// Reclaimable roots, without the `/private` that `resolvingSymlinksInPath` strips.
    nonisolated static let volatileRoots = [
        "/tmp/", "/var/tmp/", "/var/folders/", NSHomeDirectory() + "/Library/Caches/"
    ]

    /// Both parameters are injected environment facts, so a harness can drive its own scratch.
    nonisolated static func fileURLs(
        on pasteboard: NSPasteboard, volatileRoots roots: [String] = volatileRoots
    ) -> [String]? {
        let durable = PasteboardFiles.urls(on: pasteboard, limit: maxCapturedFiles) {
            isDurable($0, roots: roots)
        }
        // Nil rather than empty, so a copied `http` URL falls through and stays a link.
        guard !durable.isEmpty else { return nil }
        // Reversed on insert, so the first file copied ends up leading the history.
        return durable.map(\.standardizedFileURL.path).reversed()
    }

    /// An app that stages a temp file beside better inline content must keep the inline content.
    nonisolated private static func isDurable(_ url: URL, roots: [String]) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var path = url.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        return !roots.contains { path.hasPrefix($0) }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard !isCapturePaused, pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if pb.types?.contains(Self.internalType) == true { return }

        // Never record secrets: skip copies tagged sensitive by any of the marker owners.
        if let types = pb.types, !Set(types).isDisjoint(with: Self.sensitiveTypes) { return }

        // The pasteboard carries no source, so attribute it to the frontmost app.
        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let sourceBundleID, settings.clipboardDisabledApps.contains(sourceBundleID) { return }

        // Ahead of the text branch: Finder puts the file's *name* on `.string` beside its URL.
        if let paths = Self.fileURLs(on: pb) {
            store.addFiles(paths, sourceBundleID: sourceBundleID)
            return
        }

        if let text = pb.string(forType: .string),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            guard text.count <= ClipboardStore.maxTextLength else { return }
            store.addText(text, sourceBundleID: sourceBundleID)
            return
        }

        if let type = pb.availableType(from: [.png, .tiff]), let data = pb.data(forType: type) {
            let isPNG = type == .png
            let store = store
            // A big TIFF→PNG re-encode can take 100ms+, so keep the poll off that path.
            Task.detached(priority: .utility) {
                let png =
                    isPNG
                    ? data
                    : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
                guard let png else { return }
                await store.addImage(png, sourceBundleID: sourceBundleID)
            }
        }
    }
}

/// ⌘⇧3/⌘⇧4 save to disk without touching the pasteboard, so Spotlight's capture flag finds them.
@MainActor
final class ScreenshotWatcher {
    /// Screenshot.app, so the row credits the system screenshot tool as its source.
    static let sourceBundleID = "com.apple.screenshot.launcher"

    private let onScreenshot: (URL) -> Void
    private var query: NSMetadataQuery?
    private var token: NotificationToken?
    private var startedAt = Date.distantFuture
    private var seen: Set<String> = []

    init(onScreenshot: @escaping (URL) -> Void) {
        self.onScreenshot = onScreenshot
    }

    isolated deinit {
        query?.stop()
    }

    func start() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K == 1", "kMDItemIsScreenCapture")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        // Only captures made from now on: the initial gather is the user's whole screenshot past.
        startedAt = Date()
        token = NotificationToken(
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate, object: query, queue: .main
            ) { [weak self] note in
                let keys = [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey]
                let found = keys.flatMap { note.userInfo?[$0] as? [NSMetadataItem] ?? [] }
                    .compactMap { item -> (String, Date)? in
                        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                            let created = item.value(forAttribute: NSMetadataItemFSCreationDateKey)
                                as? Date
                        else { return nil }
                        return (path, created)
                    }
                MainActor.assumeIsolated { self?.receive(found) }
            }, center: .default)
        query.start()
        self.query = query
    }

    func stop() {
        query?.stop()
        query = nil
        token = nil
        seen = []
    }

    private func receive(_ found: [(String, Date)]) {
        for (path, created) in found where created >= startedAt && !seen.contains(path) {
            let url = URL(fileURLWithPath: path)
            // Screen recordings carry the same flag; only stills belong in the history.
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            else { continue }
            seen.insert(path)
            onScreenshot(url)
        }
    }
}
