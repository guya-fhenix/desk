import AppKit
import Charts
import DeskCore
import SwiftUI

/// Categorical slots 1-3 of the validated default palette, stepped per appearance.
enum ChartPalette {
    static let firstReview = dynamic(light: 0x2A78D6, dark: 0x3987E5)
    static let approval = dynamic(light: 0xEB6834, dark: 0xD95926)
    static let merge = dynamic(light: 0x1BAF7A, dark: 0x199E70)
    static let grid = dynamic(light: 0xE1E0D9, dark: 0x2C2C2A)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }
}

private struct Phase: Identifiable {
    let name: String
    let color: Color
    let value: (WeeklyCycle) -> TimeInterval?
    var id: String { name }
}

struct MetricsTab: View {
    @Environment(AppModel.self) private var model
    @State private var selectedWeek: Date?

    private static let phases = [
        Phase(name: "To first review", color: ChartPalette.firstReview) { $0.medianToFirstReview },
        Phase(name: "Review to approval", color: ChartPalette.approval) { $0.medianToApproval },
        Phase(name: "Approval to merge", color: ChartPalette.merge) { $0.medianToMerge },
    ]
    private static let rowHeight: CGFloat = 26

    @State private var weeklyOrder: [KeyPathComparator<WeeklyCycle>] = []
    @AppStorage("sort.metricsWeeks") private var storedSort = ""

    private static let sort = TableSort<WeeklyCycle>(
        [
            ("week", KeyPathComparator(\.weekStart)),
            ("merged", KeyPathComparator(\.merged)),
            ("firstReview", KeyPathComparator(\.medianToFirstReview, comparator: OptionalComparator())),
            ("approval", KeyPathComparator(\.medianToApproval, comparator: OptionalComparator())),
            ("merge", KeyPathComparator(\.medianToMerge, comparator: OptionalComparator())),
            ("total", KeyPathComparator(\.medianTotal, comparator: OptionalComparator())),
        ],
        fallback: [KeyPathComparator(\WeeklyCycle.weekStart)]
    )

    private var weekly: [WeeklyCycle] { model.state.weekly }
    private var cycles: [PullRequestCycle] { model.state.cycles }
    private var latencies: [ReviewLatency] { model.state.reviewLatencies }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statTiles
                phaseChart
                weeklyTable
            }
            .padding(20)
        }
        .remembersSort(Self.sort, order: $weeklyOrder, stored: $storedSort)
        .navigationTitle("Metrics")
    }

    private var statTiles: some View {
        HStack(alignment: .top, spacing: 28) {
            tile("Median cycle, \(model.config.metricsWeeks) weeks", Format.duration(CycleTime.median(cycles.compactMap(\.total))))
            tile("Median to first review", Format.duration(CycleTime.median(cycles.compactMap(\.toFirstReview))))
            tile("Merged PRs", "\(cycles.count)")
            tile("My review latency, median", Format.duration(CycleTime.median(latencies.map(\.latency))))
            tile("Reviews I gave", "\(latencies.count)")
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).scaled(.size(26).weight(.semibold))
            Text(label).scaled(.caption).foregroundStyle(.secondary)
        }
    }

    private var phaseChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Median hours per phase, by merge week").scaled(.headline)
            Chart {
                ForEach(weekly) { week in
                    ForEach(Self.phases) { phase in
                        BarMark(
                            x: .value("Week", week.weekStart, unit: .weekOfYear),
                            y: .value("Hours", Format.hours(phase.value(week))),
                            width: .fixed(10)
                        )
                        .position(by: .value("Phase", phase.name))
                        .foregroundStyle(by: .value("Phase", phase.name))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    }
                }
                if let selectedWeek, let week = weekly.first(where: { $0.weekStart == selectedWeek }) {
                    RuleMark(x: .value("Week", selectedWeek, unit: .weekOfYear))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .annotation(position: .top, alignment: .leading, spacing: 4) { tooltip(week) }
                }
            }
            .chartForegroundStyleScale([
                Self.phases[0].name: Self.phases[0].color,
                Self.phases[1].name: Self.phases[1].color,
                Self.phases[2].name: Self.phases[2].color,
            ])
            .chartXSelection(value: $selectedWeek)
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                    AxisGridLine().foregroundStyle(ChartPalette.grid)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(ChartPalette.grid)
                    AxisValueLabel()
                }
            }
            .chartYAxisLabel("hours", alignment: .trailing)
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 240)
            if cycles.isEmpty {
                EmptyText(text: model.state.errors[.github] ?? "No merged PRs in the window yet.")
            }
        }
    }

    private func tooltip(_ week: WeeklyCycle) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Week of \(week.weekStart.formatted(.dateTime.month(.abbreviated).day()))  ·  \(week.merged) merged").scaled(.caption.weight(.semibold))
            ForEach(Self.phases) { phase in
                HStack(spacing: 6) {
                    Circle().fill(phase.color).frame(width: 8, height: 8)
                    Text(phase.name).scaled(.caption)
                    Text(Format.duration(phase.value(week))).scaled(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1)))
    }

    private var weeklyTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weeks").scaled(.headline)
            Table(weekly.sorted(using: weeklyOrder), sortOrder: $weeklyOrder) {
                TableColumn("Week", value: \.weekStart) { week in Text(week.weekStart.formatted(.dateTime.year().month(.abbreviated).day())) }.width(110)
                TableColumn("Merged", value: \.merged) { week in Text("\(week.merged)").monospacedDigit() }.width(60)
                TableColumn("To first review", value: \.medianToFirstReview, comparator: OptionalComparator()) { week in
                    Text(Format.duration(week.medianToFirstReview)).monospacedDigit()
                }
                .width(110)
                TableColumn("Review to approval", value: \.medianToApproval, comparator: OptionalComparator()) { week in
                    Text(Format.duration(week.medianToApproval)).monospacedDigit()
                }
                .width(130)
                TableColumn("Approval to merge", value: \.medianToMerge, comparator: OptionalComparator()) { week in
                    Text(Format.duration(week.medianToMerge)).monospacedDigit()
                }
                .width(120)
                TableColumn("Total", value: \.medianTotal, comparator: OptionalComparator()) { week in
                    Text(Format.duration(week.medianTotal)).monospacedDigit()
                }
                .width(70)
            }
            .frame(height: CGFloat(weekly.count + 1) * Self.rowHeight + 8)
        }
    }
}
