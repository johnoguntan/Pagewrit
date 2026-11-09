import Foundation
import CoreServices

/// Watches folders for new or changed files (FSEvents) and calls `onChange`
/// once things go quiet, so a book that lands in Downloads shows up in the
/// library without a manual rescan.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let quietPeriod: TimeInterval
    private let onChange: @Sendable () -> Void

    init(quietPeriod: TimeInterval = 2.0, onChange: @escaping @Sendable () -> Void) {
        self.quietPeriod = quietPeriod
        self.onChange = onChange
    }

    deinit { stop() }

    func watch(_ folders: [URL]) {
        stop()
        guard !folders.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().scheduleChange()
        }
        let paths = folders.map { $0.path } as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags
        ) else { return }

        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Always called on the main queue (the stream's dispatch queue).
    fileprivate func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }
}
