import SwiftUI

/// Remind Me, as a reminder's details in Reminders: a time later today, this evening or tomorrow at a tap, or a date
/// and a time of your own. A note with a reminder changes or removes it here. A popover on the Mac, a sheet on iPhone
/// and iPad.
struct ReminderPicker: View {
    let workspace: Workspace
    let url: URL
    var close: () -> Void
    @State private var date: Date

    init(workspace: Workspace, url: URL, close: @escaping () -> Void) {
        self.workspace = workspace
        self.url = url
        self.close = close
        _date = State(initialValue: workspace.reminder(for: url)?.date ?? Self.nextHour(after: .now))
    }

    private var reminder: Reminder? { workspace.reminder(for: url) }
    private var name: String { SearchSection.displayName(url) }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remind Me").font(.headline)
                Text(name).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Form {
                choices
                pickers
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if reminder != nil {
                    Button("Remove Reminder", role: .destructive) { remove() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(reminder == nil ? "Remind Me" : "Change") { set(date) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(date <= .now)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 340)
        #else
        NavigationStack {
            Form {
                choices
                pickers
                if reminder != nil {
                    Section {
                        Button("Remove Reminder", role: .destructive) { remove() }
                    }
                }
            }
            .navigationTitle("Remind Me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(reminder == nil ? "Remind Me" : "Change", role: .confirm) { set(date) }
                        .disabled(date <= .now)
                }
            }
        }
        #endif
    }

    /// Later Today, This Evening and Tomorrow: each sets the reminder at once.
    private var choices: some View {
        Section {
            ForEach(Self.choices(after: .now), id: \.title) { choice in
                Button { set(choice.date) } label: {
                    HStack {
                        Label {
                            Text(choice.title)
                        } icon: {
                            // The sunrise is wider than the clock and the moon: the titles line up all the same.
                            Image(systemName: choice.symbol).frame(width: 22)
                        }
                        .foregroundStyle(Color.primary)
                        Spacer()
                        Text(choice.detail)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        } footer: {
            #if os(iOS)
            Text("A notification with the note’s first points comes at that time.")
            #endif
        }
    }

    private var pickers: some View {
        Section {
            DatePicker("Date", selection: $date, displayedComponents: .date)
            DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
        }
    }

    private func set(_ date: Date) {
        workspace.setReminder(for: url, at: date)
        close()
    }

    private func remove() {
        workspace.removeReminder(for: url)
        close()
    }

    // MARK: - Times

    struct Choice {
        var title: String
        var symbol: String
        var date: Date
        var detail: String
    }

    /// As Mail's Remind Me: in about three hours, on the hour; at six in the evening while it is still afternoon; and
    /// tomorrow at nine.
    static func choices(after now: Date, calendar: Calendar = .current) -> [Choice] {
        var choices: [Choice] = []
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)
        let later = nextHour(after: now.addingTimeInterval(2 * 60 * 60), calendar: calendar)
        if calendar.isDate(later, inSameDayAs: now), calendar.component(.hour, from: later) <= 21, later != evening {
            choices.append(Choice(title: "Later Today", symbol: "clock", date: later, detail: time(later)))
        }
        if let evening, evening.timeIntervalSince(now) >= 60 * 60 {
            choices.append(Choice(title: "This Evening", symbol: "moon", date: evening, detail: time(evening)))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            choices.append(Choice(title: "Tomorrow", symbol: "sunrise", date: morning, detail: morning.formatted(.dateTime.weekday(.abbreviated)) + " " + time(morning)))
        }
        return choices
    }

    /// The next full hour after a time.
    static func nextHour(after date: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? date
    }
}
