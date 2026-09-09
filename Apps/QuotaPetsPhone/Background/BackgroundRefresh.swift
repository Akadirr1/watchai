import Foundation
import BackgroundTasks
import QuotaPetsShared

/// Best-effort background refresh (§10).
///
/// Deliberately makes no promise about cadence. Apple documents `earliestBeginDate` as a
/// floor and explicitly disclaims any launch guarantee, so a ~60s background cadence is
/// not achievable and the UI must show freshness rather than imply liveness.
///
/// Three constraints Apple states that this code is shaped around:
///   - registration must complete before `didFinishLaunching` returns;
///   - registering the same identifier twice terminates the app;
///   - only ONE app-refresh task may be pending, and re-submitting replaces it.
enum BackgroundRefresh {
    static let identifier = "com.quotapets.phone.refresh"
    /// A floor, not a promise.
    static let earliestInterval: TimeInterval = 15 * 60

    /// Call exactly once, from `didFinishLaunching`.
    static func register(handler: @escaping @Sendable (BGAppRefreshTask) -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { return task.setTaskCompleted(success: false) }
            handler(refresh)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        // Throws when more than one request is pending; the previous one is replaced, so
        // a failure here is not worth surfacing to the user.
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Runs one refresh cycle inside a granted background window.
    ///
    /// Reschedules FIRST: if the work throws or the system expires the task, the next
    /// window is already booked. Doing it last is the classic way a background loop
    /// quietly dies after one failure.
    static func handle(_ task: BGAppRefreshTask, work: @escaping @Sendable () async -> Void) {
        schedule()
        let operation = Task {
            await work()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { operation.cancel() }
    }
}
