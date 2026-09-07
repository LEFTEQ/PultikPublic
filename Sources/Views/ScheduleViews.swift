import SwiftUI

/// The schedule tab — the forward-looking read of the todo engine, in time order.
///
/// Deliberately a different page from Todos: the backlog is browsed by
/// priority, an agenda is read by when. Read-only like every todo surface —
/// rows open the task in vitrinka, and state changes go through
/// `vitrinka schedule` / the AI.
struct SchedulePageView: View {
    let todos: [TodoItem]
    let isSelected: (String) -> Bool
    var selectedID: String?
    let onBack: () -> Void

    /// Today's calendar events (EventKit read grant, Integrations → Calendar
    /// access) — interleaved into TODAY so the day and the deadlines read as
    /// one list. Empty when not granted; the agenda just shows todos.
    private var dayEvents: [CalendarDayStore.DayEvent] {
        CalendarDayStore.shared.todayEvents.filter { $0.end > .now }
    }

    /// The agenda's buckets. OVERDUE is first and always shown when
    /// non-empty — a missed rotation is the one thing that must not scroll
    /// off the top.
    private enum Bucket: String, CaseIterable {
        case overdue = "OVERDUE"
        case today = "TODAY"
        case week = "THIS WEEK"
        case later = "LATER"
    }

    private var buckets: [(Bucket, [TodoItem])] {
        let now = Date.now
        let cal = Calendar.current
        let weekOut = now.addingTimeInterval(7 * 86400)
        var out: [Bucket: [TodoItem]] = [:]
        for todo in todos {
            guard let at = todo.at else { continue }
            let bucket: Bucket
            if at < now {
                bucket = .overdue
            } else if cal.isDateInToday(at) {
                bucket = .today
            } else if at < weekOut {
                bucket = .week
            } else {
                bucket = .later
            }
            out[bucket, default: []].append(todo)
        }
        return Bucket.allCases.compactMap { b in
            let items = out[b] ?? []
            // TODAY earns its header from calendar events too — a day full of
            // meetings and no deadlines is still a day worth seeing.
            if items.isEmpty && !(b == .today && !dayEvents.isEmpty) { return nil }
            return (b, items)
        }
    }

    /// TODAY as one time-sorted list: calendar events and scheduled todos
    /// interleaved, each keeping its own row style.
    private enum TodayEntry: Identifiable {
        case todo(TodoItem)
        case event(CalendarDayStore.DayEvent)

        var id: String {
            switch self {
            case .todo(let t): "todo:\(t.id)"
            case .event(let e): "event:\(e.id)"
            }
        }

        var when: Date {
            switch self {
            case .todo(let t): t.at ?? .distantFuture
            case .event(let e): e.start
            }
        }
    }

    private func mergedToday(_ todos: [TodoItem]) -> [TodayEntry] {
        (todos.map(TodayEntry.todo) + dayEvents.map(TodayEntry.event))
            .sorted { $0.when < $1.when }
    }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    header
                    if todos.isEmpty {
                        Text("nothing scheduled")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                            .padding(.horizontal, 10)
                    }
                    ForEach(buckets, id: \.0) { bucket, items in
                        Text(bucket.rawValue)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(bucket == .overdue ? .red : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        if bucket == .today {
                            ForEach(mergedToday(items)) { entry in
                                switch entry {
                                case .todo(let todo):
                                    ScheduleRow(todo: todo, selected: isSelected("todo:\(todo.id)"))
                                        .id("todo:\(todo.id)")
                                case .event(let event):
                                    CalendarEventRow(event: event)
                                }
                            }
                        } else {
                            ForEach(items) { todo in
                                ScheduleRow(todo: todo, selected: isSelected("todo:\(todo.id)"))
                                    .id("todo:\(todo.id)")
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Back (Esc)")
            Text("Schedule")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                NSWorkspace.shared.open(VitrinkaClient.shared.myWorkURL)
            } label: {
                Text("vitrinka")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(VitrinkaClient.shared.myWorkURL.absoluteString)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }
}

private struct ScheduleRow: View {
    let todo: TodoItem
    let selected: Bool

    private var overdue: Bool { todo.isOverdue() }
    private var ripe: Bool { todo.isRipe() }

    var body: some View {
        Button { todo.open() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The state dot: red overdue, amber ripe, quiet otherwise.
                Circle()
                    .fill(overdue ? Color.red : (ripe ? Color.orange : Color.secondary.opacity(0.35)))
                    .frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(todo.name)
                            .font(.system(size: 12, weight: overdue ? .semibold : .regular))
                            .lineLimit(1)
                        if let every = todo.every {
                            Text("↻\(every)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if todo.priority == "high" {
                            Text("high")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(todo.project)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let at = todo.at {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(overdue
                             ? "OVERDUE \((todo.gap() ?? "").replacingOccurrences(of: " ago", with: ""))"
                             : todo.gap() ?? "")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(overdue ? .red : (ripe ? .orange : .secondary))
                        Text(at.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A calendar event inside TODAY — visually quieter than a todo: the day's
/// shape, not a demand. Read-only; the calendar app owns it.
private struct CalendarEventRow: View {
    let event: CalendarDayStore.DayEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .frame(width: 5)
            Text(event.title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("\(event.start.formatted(.dateTime.hour().minute()))–\(event.end.formatted(.dateTime.hour().minute()))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

// MARK: - Right rail: reminders

/// Scheduled (or milestone-ripe) todos that want attention NOW (decision D4=B, 2026-08-27).
///
/// Reminders had no resting surface before this: five scheduled todos existed
/// only inside the `.s` page, so a thing with a hard timestamp was less visible
/// than a backlog item with none. The rail is deliberately not "the schedule" —
/// it shows overdue and ripe only, because a reminder that is not yet due is
/// not yet information.
struct RemindersRail: View {
    let todos: [TodoItem]

    /// Overdue first, then ripe, each soonest-first. Time order within a tier:
    /// a schedule is read forwards.
    static func attentionWorthy(_ all: [TodoItem]) -> [TodoItem] {
        let overdue = all.filter { $0.isOverdue() }
        let ripe = all.filter { !$0.isOverdue() && $0.isRipe() }
        return overdue + ripe
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(todos.prefix(6)) { todo in
                ReminderRailRow(todo: todo)
            }
            if todos.count > 6 {
                Text("+\(todos.count - 6) more — .s")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }
        }
    }
}

private struct ReminderRailRow: View {
    let todo: TodoItem
    @State private var hovering = false

    private var overdue: Bool { todo.isOverdue() }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: overdue ? "exclamationmark.circle.fill" : "clock")
                .font(.system(size: 9))
                .foregroundStyle(overdue ? Color.red : .orange)
            Text(todo.name)
                .font(.system(size: 10.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let at = todo.at {
                Text(at, format: .dateTime.hour().minute())
                    .font(.system(size: 9, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(overdue ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(overdue ? Color.red.opacity(hovering ? 0.14 : 0.08)
                    : hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { todo.open() }
        .help("\(todo.name)\(overdue ? " — overdue" : " — ripe")\nClick opens it in vitrinka")
    }
}
