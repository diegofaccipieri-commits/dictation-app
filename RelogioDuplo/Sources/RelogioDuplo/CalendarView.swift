import AppKit
import os
import RelogioDuploCore
import SwiftUI

struct CalendarView: View {
    let today: Date
    @State private var month = Date()

    private var calendar: Calendar { .autoupdatingCurrent }

    var body: some View {
        let grid = MonthGrid.make(month: month, calendar: calendar, today: today)
        VStack(spacing: 8) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Mês anterior")
                Button("Hoje") { month = today }
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Próximo mês")
            }
            .buttonStyle(.borderless)

            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    Text("")
                    ForEach(Array(grid.weekdaySymbols.enumerated()), id: \.offset) { column, symbol in
                        Text(symbol).font(.caption)
                            .foregroundStyle(column == grid.sundayColumn ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    }
                }
                ForEach(grid.weeks) { week in
                    GridRow {
                        Text("\(week.number)")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Color.primary.opacity(0.15))
                            .frame(width: 22)
                        ForEach(week.days) { day in
                            DayCell(day: day) { open(day.date) }
                        }
                    }
                }
            }
        }
        .onAppear { month = today }
    }

    private func shift(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month) ?? month
    }

    private func open(_ date: Date) {
        let log = Logger(subsystem: "com.diegofaccipieri.RelogioDuplo", category: "calendar")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", CalendarScript.source(for: date, calendar: calendar)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            if finished.terminationStatus != 0 {
                log.error("Abrir o Calendar falhou: código \(finished.terminationStatus)")
            }
        }
        do { try process.run() } catch {
            log.error("Não foi possível abrir o Calendar: \(error.localizedDescription)")
        }
    }
}

private struct DayCell: View {
    let day: MonthGrid.Day
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(day.number)")
                .monospacedDigit()
                .fontWeight(day.isToday ? .semibold : .regular)
                .foregroundStyle(color)
                .frame(width: 28, height: 24)
                .background {
                    if day.isToday { Circle().fill(Color.accentColor).frame(width: 24, height: 24) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var color: AnyShapeStyle {
        if day.isToday { return AnyShapeStyle(Color.white) }
        if day.isSunday { return AnyShapeStyle(Color.red.opacity(day.inMonth ? 1 : 0.35)) }
        if !day.inMonth { return AnyShapeStyle(.quaternary) }
        return day.isWeekend ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary)
    }
}
