#if os(macOS)
import CoreServices
import Foundation

/// Tells about changes under some folders (made by Notebook, the Finder, iCloud or anything else), a few at a time.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init(paths: [String], handler: @escaping ([String]) -> Void) {
        self.handler = handler
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handler(Array(array.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
#else
import Foundation

/// Tells about changes under some folders, a few at a time. iOS has no FSEvents: every folder is presented to the
/// file coordinator, which reports what other apps, the Files app and iCloud change through it.
final class FileWatcher {
    private let presenters: [FolderPresenter]

    init(paths: [String], handler: @escaping ([String]) -> Void) {
        let batch = ChangeBatch(handler: handler)
        presenters = paths.map { FolderPresenter(url: URL(fileURLWithPath: $0, isDirectory: true), batch: batch) }
        presenters.forEach(NSFileCoordinator.addFilePresenter)
    }

    deinit {
        presenters.forEach(NSFileCoordinator.removeFilePresenter)
    }
}

/// Collects the changed paths for a quarter of a second, as FSEvents does on the Mac.
private final class ChangeBatch: @unchecked Sendable {
    private let handler: ([String]) -> Void
    private var paths: [String] = []

    init(handler: @escaping ([String]) -> Void) {
        self.handler = handler
    }

    /// Called on the main queue.
    func add(_ urls: [URL]) {
        let wasEmpty = paths.isEmpty
        paths += urls.map(\.path)
        guard wasEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            let changed = paths
            paths = []
            handler(changed)
        }
    }
}

private final class FolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let batch: ChangeBatch

    init(url: URL, batch: ChangeBatch) {
        presentedItemURL = url
        self.batch = batch
    }

    func presentedSubitemDidChange(at url: URL) { batch.add([url]) }
    func presentedSubitemDidAppear(at url: URL) { batch.add([url]) }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { batch.add([oldURL, newURL]) }
    func presentedItemDidChange() { presentedItemURL.map { batch.add([$0]) } }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
        DispatchQueue.main.async { [batch] in batch.add([url]) }
    }
}
#endif
