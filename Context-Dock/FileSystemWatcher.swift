//
//  FileSystemWatcher.swift
//  ILauncher
//
//  Real-time file system monitoring using FSEvents
//

import Foundation

class FileSystemWatcher {
    private var eventStream: FSEventStreamRef?
    private let callback: ([String]) -> Void
    private let pathsToWatch: [String]

    init(paths: [String], callback: @escaping ([String]) -> Void) {
        self.pathsToWatch = paths
        self.callback = callback
    }

    func startWatching() {
        guard !pathsToWatch.isEmpty else {
            print("⚠️ No paths to watch")
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (
            streamRef,
            clientCallBackInfo,
            numEvents,
            eventPaths,
            eventFlags,
            eventIds
        ) in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()

            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))

            // Filter for relevant events (created, modified, removed)
            var changedPaths: [String] = []
            for (index, path) in paths.enumerated() {
                let flag = flags[index]
                let isRelevant = (flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0) ||
                                 (flag & UInt32(kFSEventStreamEventFlagItemModified) != 0) ||
                                 (flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0) ||
                                 (flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0)

                if isRelevant {
                    changedPaths.append(path)
                }
            }

            if !changedPaths.isEmpty {
                watcher.callback(changedPaths)
            }
        }

        eventStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // Latency in seconds
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream = eventStream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

            if FSEventStreamStart(stream) {
                print("✅ File system watcher started for \(pathsToWatch.count) paths")
            } else {
                print("⚠️ Failed to start file system watcher")
                stopWatching()
            }
        } else {
            print("⚠️ Failed to create FSEventStream")
        }
    }

    func stopWatching() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
            print("🛑 File system watcher stopped")
        }
    }

    deinit {
        stopWatching()
    }
}
