import Foundation
import UserNotifications

/// The notifications of reminders. Each device schedules its own from the reminders it knows: the note's name as the
/// title, the time under it, and the note's first points as the text, read off the main thread. Time Sensitive, so they
/// get through a Focus. A tap opens the note; Remind Me in 1 Hour and Done are their actions.
@MainActor
final class ReminderNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderNotifications()

    nonisolated static let category = "reminder"
    nonisolated static let laterAction = "later"
    nonisolated static let doneAction = "done"
    private nonisolated static let prefix = "reminder."

    /// Only the app schedules notifications: tests and previews leave the system's alone.
    private(set) var isActive = false
    /// The last scheduling, which the next waits for, so an older one never takes away what a newer one added.
    private var last: Task<Void, Never>?

    /// What a notification is made from: the reminder, and the note's text when it is open.
    struct Job: Sendable {
        var id: UUID
        var date: Date
        var title: String
        /// The note's name in the store, to find it again after the reminder is done.
        var note: String
        var url: URL?
        var text: String?
    }

    /// Called as the app starts, before a tap on a notification can reach it.
    static func activate() {
        guard !shared.isActive else { return }
        shared.isActive = true
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        let later = UNNotificationAction(identifier: laterAction, title: "Remind Me in 1 Hour", options: [], icon: UNNotificationActionIcon(systemImageName: "clock"))
        let done = UNNotificationAction(identifier: doneAction, title: "Done", options: [], icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [later, done], intentIdentifiers: [], options: [])])
    }

    nonisolated static func identifier(_ id: UUID) -> String { prefix + id.uuidString }

    /// Asks for notifications the first time a reminder is set. False when they are turned off.
    func requestPermission() async -> Bool {
        guard isActive else { return true }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied: return false
        default: return true
        }
    }

    /// Schedules the reminders to come. With `everything`, these are all there are: notifications of reminders that
    /// are gone, done here or on another device, go too, including those already shown.
    @discardableResult
    func schedule(_ jobs: [Job], everything: Bool, known: Set<UUID> = []) -> Task<Void, Never>? {
        guard isActive else { return nil }
        let previous = last
        let task = Task.detached(priority: .utility) {
            await previous?.value
            let center = UNUserNotificationCenter.current()
            let now = Date()
            if everything {
                let coming = Set(jobs.filter { $0.date > now }.map { Self.identifier($0.id) })
                let pending = await center.pendingNotificationRequests().map(\.identifier)
                center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.hasPrefix(Self.prefix) && !coming.contains($0) })
                let all = Set(known.map(Self.identifier))
                let delivered = await center.deliveredNotifications().map(\.request.identifier)
                center.removeDeliveredNotifications(withIdentifiers: delivered.filter { $0.hasPrefix(Self.prefix) && !all.contains($0) })
            }
            for job in jobs where job.date > now {
                let text = job.text ?? job.url.flatMap(Self.readIfHere)
                let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: job.date), repeats: false)
                let request = UNNotificationRequest(identifier: Self.identifier(job.id), content: Self.content(for: job, text: text), trigger: trigger)
                try? await center.add(request)
            }
        }
        last = task
        return task
    }

    /// A reminder changed or finished: its notification goes, the one waiting and the one shown.
    func withdraw(_ id: UUID) {
        guard isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(id)])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(id)])
    }

    /// Shows a reminder's notification in a moment, as it will at its time: for the debug remote.
    func fireSoon(_ job: Job) {
        guard isActive else { return }
        Task.detached(priority: .userInitiated) {
            let text = job.text ?? job.url.flatMap(Self.readIfHere)
            let request = UNNotificationRequest(identifier: Self.identifier(job.id), content: Self.content(for: job, text: text),
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated static func content(for job: Job, text: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = job.title
        content.subtitle = job.date.formatted(date: .omitted, time: .shortened)
        content.body = text.map(NotePoints.text(of:)) ?? ""
        content.sound = .default
        content.categoryIdentifier = category
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["reminder": job.id.uuidString, "note": job.note]
        return content
    }

    /// The text of a note on this device. One still in iCloud is asked for, for next time, rather than waited for:
    /// the notification goes without its points instead of late.
    private nonisolated static func readIfHere(_ url: URL) -> String? {
        guard NoteDocument.wait(for: url) == nil else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        return NoteDocument.read(url)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown while Notebook is in front too: a reminder is something you asked for.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let id = (userInfo["reminder"] as? String).flatMap(UUID.init(uuidString:))
        let note = userInfo["note"] as? String
        let done = UncheckedSendable(completionHandler)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let id else { return done.value() }
                let workspace = Workspace.shared
                // An action can be what started the app: the reminders are read first.
                workspace.start()
                var task: Task<Void, Never>?
                switch action {
                case UNNotificationDefaultActionIdentifier: workspace.openReminder(id, note: note)
                case Self.laterAction: task = workspace.remindAgain(id, in: 60 * 60)
                case Self.doneAction: workspace.finishReminder(id)
                default: break
                }
                // An action from the Lock Screen gets the app only for a moment: the new time is scheduled first.
                Task {
                    await task?.value
                    done.value()
                }
            }
        }
    }
}

/// A value the compiler can't tell is safe to send, that is only used once on the other side.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
