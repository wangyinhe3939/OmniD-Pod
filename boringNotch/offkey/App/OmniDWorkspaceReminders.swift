import AppKit
import Combine
import EventKit
import SwiftUI
import UserNotifications

@MainActor
final class OmniDWorkspaceReminders: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = OmniDWorkspaceReminders()
    @Published private(set) var status = "仅本机保存"
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var reminderPermission = false
    @Published private(set) var notificationPermission = false
    @Published private(set) var busy = false
    @Published var error: String?
    private let store = EKEventStore()
    private let center = UNUserNotificationCenter.current()
    private weak var notes: OffKeyNotesStore?
    private var cancellable: AnyCancellable?
    private var observer: NSObjectProtocol?
    private var notificationTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var remoteRecords: [String: EKReminder] = [:]
    private let prefix = "omnid.task."
    private var onOpenTask: ((String) -> Void)?

    var selectedCalendarID: String? { UserDefaults.standard.string(forKey: "omnid.workspace.reminderList") }

    func start(notes: OffKeyNotesStore, onOpenTask: @escaping (String) -> Void) {
        guard self.notes == nil else { return }
        self.notes = notes
        self.onOpenTask = onOpenTask
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "OMNID_TASK", actions: [
            UNNotificationAction(identifier: "COMPLETE", title: "完成", options: []),
            UNNotificationAction(identifier: "LATER", title: "10 分钟后", options: [])
        ], intentIdentifiers: [])])
        cancellable = notes.$document.map(\.entries).removeDuplicates().dropFirst().sink { [weak self, weak notes] _ in
            Task { @MainActor in
                await Task.yield()
                guard let self, let notes else { return }
                self.reconcile(notes: notes)
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        reconcile(notes: notes)
    }

    func requestNotifications() async {
        do {
            notificationPermission = try await center.requestAuthorization(options: [.alert, .sound])
            if !notificationPermission { status = "已保存；通知未允许，暂不提醒" }
            if let notes { reconcile(notes: notes) }
        } catch { self.error = error.localizedDescription }
    }

    func requestReminders() async {
        do {
            reminderPermission = try await store.requestFullAccessToReminders()
            if reminderPermission { refresh() }
            else { status = "提醒事项未允许；本机内容保留" }
        } catch { self.error = error.localizedDescription }
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            reminderPermission = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
            notificationPermission = await center.notificationSettings().authorizationStatus == .authorized
            guard !Task.isCancelled else { return }
            guard reminderPermission else {
                calendars = []
                remoteRecords = [:]
                if selectedCalendarID != nil { status = "同步暂停：权限不可用，已有内容保留" }
                return
            }
            calendars = store.calendars(for: .reminder).filter { $0.allowsContentModifications }
            guard !busy, let calendarID = selectedCalendarID, let notes else { return }
            guard let calendar = calendars.first(where: { $0.calendarIdentifier == calendarID }) else {
                status = "同步暂停：所选列表不可用，已有内容保留"; return
            }
            guard let reminders = await fetch(calendar: calendar), !Task.isCancelled, !busy,
                  EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                status = "同步暂停，已有内容保留"; return
            }
            remoteRecords = Dictionary(uniqueKeysWithValues: reminders.map { ($0.calendarItemIdentifier, $0) })
            // Only the chosen list is read. Local rows are recoverable caches, not a second master.
            for record in notes.document.entries where record.workspace?.reminderIdentifier != nil {
                guard let remoteID = record.workspace?.reminderIdentifier else { continue }
                guard let reminder = remoteRecords[remoteID] ?? reminders.first(where: {
                    $0.url?.scheme == "omnid-pod" && $0.url?.host == "task" && $0.url?.lastPathComponent == record.id
                }) else {
                    guard notes.archiveWorkspaceRecord(id: record.id) else {
                        error = notes.presentedError; status = "同步未完成，本机内容保留"; return
                    }
                    continue
                }
                let updated = metadata(from: reminder, preserving: record.workspace!)
                let title = reminder.title ?? ""
                let body = reminder.notes ?? title
                if record.title != title || record.notes != body || record.workspace != updated {
                    guard notes.updateWorkspaceRecord(id: record.id, edit: {
                        $0.title = String(title.prefix(OffKeyNotesDocument.maxTitleCount)); $0.notes = body; $0.workspace = updated
                    }) else { error = notes.presentedError; status = "同步未完成，本机内容保留"; return }
                }
            }
            // Include externally added reminders from this list without reissuing them.
            for reminder in reminders {
                guard !notes.document.entries.contains(where: { $0.workspace?.reminderIdentifier == reminder.calendarItemIdentifier }),
                      !notes.document.trash.contains(where: { $0.workspace?.reminderIdentifier == reminder.calendarItemIdentifier }) else { continue }
                // A migration interrupted after system save is linked by its stable local marker.
                if let url = reminder.url, url.scheme == "omnid-pod", url.host == "task",
                   let record = notes.document.entries.first(where: { $0.id == url.lastPathComponent }) {
                    guard notes.updateWorkspaceRecord(id: record.id, edit: {
                        $0.workspace = self.metadata(from: reminder, preserving: $0.workspace ?? .init(isTask: true))
                    }) else { error = notes.presentedError; status = "同步未完成，本机内容保留"; return }
                } else {
                    let metadata = metadata(from: reminder, preserving: .init(isTask: true))
                    guard notes.insertWorkspaceReminder(id: "reminder-" + reminder.calendarItemIdentifier,
                        title: reminder.title ?? "", text: reminder.notes ?? reminder.title ?? "", metadata: metadata) else {
                        error = notes.presentedError; status = "同步未完成，本机内容保留"; return
                    }
                }
            }
            status = "已连接：\(calendar.title)"
            reconcile(notes: notes)
        }
    }

    // Explicit confirmation only: selecting a list alone does not migrate or create reminders.
    func migrate(to calendarID: String, notes: OffKeyNotesStore) async {
        guard !busy else { error = "正在同步，请稍后再试。"; return }
        guard reminderPermission, let calendar = calendars.first(where: { $0.calendarIdentifier == calendarID }) else {
            status = "同步暂停：权限或列表不可用，本机内容保留"; return
        }
        if let current = selectedCalendarID, current != calendarID,
           notes.document.entries.contains(where: { $0.workspace?.reminderIdentifier != nil }) {
            error = "已有事项连接其他列表；不会自动迁移或重复创建。"; return
        }
        busy = true
        notificationTask?.cancel()
        await notificationTask?.value
        refreshTask?.cancel()
        defer { busy = false; refresh() }
        UserDefaults.standard.set(calendarID, forKey: "omnid.workspace.reminderList")
        guard let existing = await fetch(calendar: calendar) else { error = "无法读取选定列表，没有迁移事项。"; return }
        for record in notes.document.entries where record.workspace?.isTask == true && record.workspace?.reminderIdentifier == nil {
            guard var metadata = record.workspace else { continue }
            let marker = URL(string: "omnid-pod://task/" + record.id)
            let reminder = existing.first(where: { marker != nil && $0.url == marker }) ?? EKReminder(eventStore: store)
            reminder.calendar = calendar
            reminder.url = marker
            apply(record, to: reminder)
            // Cancel this local source before arming the native reminder's alarm.
            center.removePendingNotificationRequests(withIdentifiers: [prefix + record.id])
            do {
                try store.save(reminder, commit: true)
                guard !reminder.calendarItemIdentifier.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
                metadata.reminderIdentifier = reminder.calendarItemIdentifier
                guard notes.updateWorkspaceRecord(id: record.id, edit: { $0.workspace = metadata }) else {
                    error = "系统已保存这条事项，但本机连接记录未保存。原文保留；刷新会尝试按标记恢复连接。"
                    return
                }
            } catch {
                self.error = "同步未全部完成，已有内容保留：\(error.localizedDescription)"
                reconcile(notes: notes)
                return
            }
        }
        status = "已同步到：\(calendar.title)"
    }

    @discardableResult
    func update(id: String, notes: OffKeyNotesStore, edit: (inout OffKeyNoteRecord) -> Void) -> Bool {
        guard notes.isPersistenceAvailable, var candidate = notes.document.entries.first(where: { $0.id == id }) else { return false }
        edit(&candidate)
        do { _ = try OffKeyNotesDocument(entries: [candidate]).validated() }
        catch { self.error = error.localizedDescription; return false }
        if let remoteID = candidate.workspace?.reminderIdentifier {
            guard reminderPermission, let reminder = remoteRecords[remoteID],
                  reminder.calendar.calendarIdentifier == selectedCalendarID else {
                error = "连接的提醒事项暂不可用；未改变完成状态。请刷新权限与列表。"; return false
            }
            apply(candidate, to: reminder)
            do { try store.save(reminder, commit: true) }
            catch { self.error = error.localizedDescription; refresh(); return false }
        }
        guard notes.updateWorkspaceRecord(id: id, edit: { $0 = candidate }) else {
            if candidate.workspace?.reminderIdentifier != nil { refresh() }
            return false
        }
        reconcile(notes: notes)
        return true
    }

    func reconcile(notes: OffKeyNotesStore) {
        let previousTask = notificationTask
        previousTask?.cancel()
        let entries = notes.document.entries
        notificationTask = Task { [weak self] in
            await previousTask?.value
            guard let self else { return }
            let settings = await center.notificationSettings()
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled else { return }
            notificationPermission = settings.authorizationStatus == .authorized
            let eligible = entries.filter {
                $0.workspace?.isTask == true && $0.workspace?.completed != true &&
                $0.workspace?.reminderIdentifier == nil && ($0.workspace?.reminderDate ?? .distantPast) > Date()
            }
            let wanted = Set(eligible.map { self.prefix + $0.id })
            center.removePendingNotificationRequests(withIdentifiers: pending.filter {
                $0.identifier.hasPrefix(self.prefix) && !wanted.contains($0.identifier)
            }.map(\.identifier))
            guard notificationPermission else {
                if !eligible.isEmpty { status = "已保存；通知未允许，暂不提醒" }
                return
            }
            for record in eligible {
                guard !Task.isCancelled, let date = record.workspace?.reminderDate else { return }
                let identifier = prefix + record.id
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                if let previous = pending.first(where: { $0.identifier == identifier }),
                   previous.content.body == record.title,
                   (previous.trigger as? UNCalendarNotificationTrigger)?.dateComponents == components { continue }
                let content = UNMutableNotificationContent()
                content.title = "OmniD-Pod · 待办"
                content.body = record.title
                content.sound = .default
                content.categoryIdentifier = "OMNID_TASK"
                content.userInfo = ["taskID": record.id]
                do {
                    try await center.add(UNNotificationRequest(identifier: identifier, content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
                } catch { self.error = "已保存，但提醒安排失败：\(error.localizedDescription)" }
            }
        }
    }

    private func fetch(calendar: EKCalendar) async -> [EKReminder]? {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: [calendar])) { continuation.resume(returning: $0) }
        }
    }

    private func apply(_ record: OffKeyNoteRecord, to reminder: EKReminder) {
        reminder.title = record.title
        reminder.notes = record.notes
        reminder.isCompleted = record.workspace?.completed ?? false
        let originalTime = reminder.dueDateComponents
        reminder.dueDateComponents = record.workspace?.scheduledDate.map { date in
            var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
            // Editing text or postponing a connected task must not erase its native due time.
            components.hour = originalTime?.hour
            components.minute = originalTime?.minute
            components.timeZone = originalTime?.timeZone
            return components
        }
        reminder.alarms = record.workspace?.reminderDate.map { [EKAlarm(absoluteDate: $0)] } ?? []
    }

    private func metadata(from reminder: EKReminder, preserving original: OffKeyWorkspaceMetadata) -> OffKeyWorkspaceMetadata {
        var metadata = original
        metadata.isTask = true
        metadata.completed = reminder.isCompleted
        metadata.scheduledDate = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        metadata.reminderDate = reminder.alarms?.first.flatMap { alarm in
            alarm.absoluteDate ?? metadata.scheduledDate?.addingTimeInterval(alarm.relativeOffset)
        }
        metadata.reminderIdentifier = reminder.calendarItemIdentifier
        return metadata
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self, let notes, let id = response.notification.request.content.userInfo["taskID"] as? String else { return }
            switch response.actionIdentifier {
            case "COMPLETE": _ = update(id: id, notes: notes) { $0.workspace?.completed = true }
            case "LATER": _ = update(id: id, notes: notes) { $0.workspace?.reminderDate = Date().addingTimeInterval(600) }
            default: onOpenTask?(id)
            }
        }
    }
}

struct OmniDWorkspaceReminderSettings: View {
    @ObservedObject private var reminders = OmniDWorkspaceReminders.shared
    @ObservedObject var notes: OffKeyNotesStore
    @State private var calendarID = ""
    @State private var preview = false
    private var unsynced: [OffKeyNoteRecord] {
        notes.document.entries.filter { $0.workspace?.isTask == true && $0.workspace?.reminderIdentifier == nil }
    }
    var body: some View {
        Section("清单与提醒") {
            LabeledContent("通知", value: reminders.notificationPermission ? "已允许" : "未允许")
            Button("允许到点通知…") { Task { await reminders.requestNotifications() } }
            LabeledContent("提醒事项", value: reminders.reminderPermission ? "已允许" : "未允许")
            Button("连接 Apple 提醒事项…") { Task { await reminders.requestReminders() } }
            if reminders.reminderPermission {
                OmniDWorkspaceChoicePicker(title: "只连接这个列表", selection: $calendarID,
                    choices: [("请选择", "")] + reminders.calendars.map { ($0.title, $0.calendarIdentifier) })
                Button("预览并确认同步…") { preview = true }.disabled(calendarID.isEmpty || reminders.busy)
            }
            Text(reminders.status).font(.caption).foregroundStyle(.secondary)
            Text("系统授权允许读写提醒事项；本 App 只操作你选定的列表。同步成功后由提醒事项负责通知，避免重复。跨设备效果还需在你的设备核验。").font(.caption).foregroundStyle(.secondary)
            Button("刷新权限与同步状态") { reminders.refresh() }
        }
        .onAppear { calendarID = reminders.selectedCalendarID ?? ""; reminders.refresh() }
        .sheet(isPresented: $preview) {
            VStack(alignment: .leading, spacing: 14) {
                Text("将 \(unsynced.count) 条本机待办连接到所选列表").font(.headline)
                Text("原文保留，逐条保存后才切换通知来源；不整理其他列表。").font(.caption)
                ScrollView { ForEach(unsynced) { Text($0.title).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3) } }
                HStack {
                    Button("取消") { preview = false }
                    Spacer()
                    Button("确认同步") {
                        preview = false
                        Task { await reminders.migrate(to: calendarID, notes: notes) }
                    }.disabled(reminders.busy)
                }
            }.padding(20).frame(width: 360, height: 300)
                .workspacePreferences().workspaceSecondarySurface()
        }
        .workspaceNotice("提醒状态", isPresented: Binding(get: { reminders.error != nil }, set: { if !$0 { reminders.error = nil } }),
            message: reminders.error ?? "")
    }
}
