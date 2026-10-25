import Foundation
import os
import UIKit

/// Launch timings under subsystem org.fitgap.app, category Startup.
/// Read them in Console.app (filter `category:Startup`) or as signpost intervals in Instruments.
/// The same lines go to `file`, which Accounts can share; it keeps the last launches.
enum StartupLog {
    static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FITgap-Startprotokoll.txt")
    private static let writer = DispatchQueue(label: "org.fitgap.startup-log", qos: .utility)
    private static let maxBytes = 256 * 1024

    static let log = Logger(subsystem: "org.fitgap.app", category: "Startup")
    static let signposter = OSSignposter(logger: log)

    /// Kernel start time of the process, so the time before `main` is included.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    private static var sinceStart: Int { Int(Date().timeIntervalSince(processStart) * 1000) }

    /// Starts a new launch section in the file; older launches are dropped once it grows too large.
    @MainActor static func beginLaunch() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var system = utsname(); uname(&system)
        let model = withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let header = "\n=== Start \(processStart.formatted(.iso8601)) · FITgap \(version) (\(build)) · \(model) · iOS \(UIDevice.current.systemVersion)\n"
        writer.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > maxBytes,
               let data = try? Data(contentsOf: file) {
                try? data.suffix(maxBytes / 2).write(to: file, options: .atomic)
            }
            append(header)
        }
    }

    private static func write(_ line: String) {
        writer.async { append(line + "\n") }
    }

    private static func append(_ text: String) {
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    private static let marked = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Logs the time since process start; `once` steps such as the first frame are logged a single time.
    static func mark(_ step: String, once: Bool = false) {
        if once, !marked.withLock({ $0.insert(step).inserted }) { return }
        signposter.emitEvent("mark", "\(step, privacy: .public)")
        let elapsed = sinceStart
        log.notice("+\(elapsed, privacy: .public) ms \(step, privacy: .public)")
        write("+\(elapsed) ms \(step)")
    }

    /// Logs how long one step takes, together with the time since process start.
    @discardableResult
    static func measure<T>(_ step: String, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval("step", id: signposter.makeSignpostID(), "\(step, privacy: .public)")
        let clock = ContinuousClock.now
        defer {
            signposter.endInterval("step", state)
            finished(step, after: milliseconds(since: clock))
        }
        return try body()
    }

    static func measure<T>(_ step: String, isolation: isolated (any Actor)? = #isolation,
                           _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval("step", id: signposter.makeSignpostID(), "\(step, privacy: .public)")
        let clock = ContinuousClock.now
        defer {
            signposter.endInterval("step", state)
            finished(step, after: milliseconds(since: clock))
        }
        return try await body()
    }

    private static func finished(_ step: String, after duration: Int) {
        let elapsed = sinceStart
        log.notice("+\(elapsed, privacy: .public) ms \(step, privacy: .public) took \(duration, privacy: .public) ms")
        write("+\(elapsed) ms \(step) took \(duration) ms")
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Reports every main-thread block over 100 ms during the first seconds after launch.
    static func watchMainThread(for duration: TimeInterval = 15) {
        Thread.detachNewThread {
            let end = Date().addingTimeInterval(duration)
            while Date() < end {
                let sent = ContinuousClock.now
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let blocked = milliseconds(since: sent)
                if blocked > 100 {
                    let elapsed = sinceStart
                    log.error("+\(elapsed, privacy: .public) ms main thread blocked for \(blocked, privacy: .public) ms")
                    write("+\(elapsed) ms ⚠︎ main thread blocked for \(blocked) ms")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}
