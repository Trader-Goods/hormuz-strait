import BackgroundTasks
import SwiftUI

@main
struct SpamSweepApp: App {
    @StateObject private var model = SweepModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundSweep.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .tint(amber)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.activate() }
            } else if phase == .background {
                BackgroundSweep.schedule()
            }
        }
    }
}

enum BackgroundSweep {
    static let identifier = "com.tradergoods.spamsweep.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { return }
            handle(refresh)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let stop = StopFlag()
        let work = Task {
            let snapshot = ScanStore.load()
            guard snapshot.autoSweep else { return }
            guard snapshot.pendingMove?.hasWork != true else { return }
            let resume = snapshot.pendingSweep?.hasWork == true
            guard resume || SweepSchedule.due(last: snapshot.lastSweepAt, now: Date()) else { return }
            try? await SweepEngine.sweepBlocked(stop: stop)
        }
        task.expirationHandler = {
            stop.stop()
            work.cancel()
        }
        Task {
            _ = await work.result
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }
}

let ink = Color(red: 0.15, green: 0.18, blue: 0.24)
let amber = Color(red: 0.72, green: 0.42, blue: 0.09)
