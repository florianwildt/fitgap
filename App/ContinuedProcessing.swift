import BackgroundTasks
import Foundation

/// iOS 26 and later: a sync or export the user started keeps running after leaving the app.
/// iOS shows its title and progress in the Dynamic Island and on the Lock Screen, lets the user stop it there,
/// and may end it early under resource pressure; the expiration then hands over to the normal resume on next open.
/// Earlier iOS versions keep using the short background time from `beginBackgroundTask`.
@MainActor
final class ContinuedProcessing {
    /// Matches `org.fitgap.app.sync.*` in `BGTaskSchedulerPermittedIdentifiers`.
    private static let prefix = (Bundle.main.bundleIdentifier ?? "org.fitgap.app") + ".sync."

    private var identifier: String?
    private var task: AnyObject?
    private var title = ""
    private var subtitle = ""
    private var completed: Int64 = 0
    private var total: Int64 = -1

    /// True from the request until the operation ends or iOS expires it.
    var isRunning: Bool { identifier != nil }

    func begin(title: String, subtitle: String, expired: @escaping @MainActor () -> Void) {
        guard #available(iOS 26, *), identifier == nil else { return }
        // A fresh identifier per run: a launch handler can only be registered once per identifier.
        let identifier = Self.prefix + UUID().uuidString
        self.title = title; self.subtitle = subtitle; completed = 0; total = -1
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                guard let self, self.identifier == identifier else { task.setTaskCompleted(success: false); return }
                self.task = task
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.identifier == identifier else { return }
                        self.finish(success: false)
                        expired()
                    }
                }
                self.apply()
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Start now or not at all; the work itself already runs in the foreground.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            self.identifier = identifier
        } catch { }
    }

    func update(subtitle: String) {
        guard isRunning, !subtitle.isEmpty, subtitle != self.subtitle else { return }
        self.subtitle = subtitle
        apply()
    }

    /// Determinate progress; a negative total shows an indeterminate indicator.
    func report(_ done: Int, of total: Int) {
        guard isRunning else { return }
        completed = Int64(max(done, 0)); self.total = Int64(total)
        apply()
    }

    func finish(success: Bool) {
        guard let identifier else { return }
        if #available(iOS 26, *) {
            if let task = task as? BGContinuedProcessingTask { task.setTaskCompleted(success: success) }
            else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        }
        self.identifier = nil
        task = nil
    }

    private func apply() {
        guard #available(iOS 26, *), let task = task as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = min(completed, max(total, 0))
        // The status text is one line; the progress view's second line holds the counts.
        task.updateTitle(title, subtitle: subtitle.replacingOccurrences(of: "\n", with: " · "))
    }
}
