import CoreServices
import Foundation

/// Tells about changes under some folders (made by Folio, the Finder, iCloud or anything else), a few at a time.
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
