import CodexBarCore
import SwiftUI

enum ProviderDetailChartLabelFormatter {
    private static let source: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let display: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    static func axisLabel(_ label: String) -> String {
        guard let date = self.source.date(from: label) else { return label }
        return self.display.string(from: date)
    }
}

struct ProviderDetailSectionsContent: View {
    let sections: [ProviderDetailSection]
    let chartColor: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(self.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Divider()
                }
                self.section(section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ section: ProviderDetailSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = section.title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .textCase(.uppercase)
                    .lineLimit(1)
            }
            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(row.value)
                            .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                            .fontWeight(.medium)
                        if let secondaryValue = row.secondaryValue {
                            Text(secondaryValue)
                                .font(.caption2)
                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        }
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            if let chart = section.chart {
                ProviderDetailChartContent(chart: chart, color: self.chartColor)
            }
        }
    }
}

private struct ProviderDetailChartContent: View {
    let chart: ProviderDetailSection.Chart
    let color: Color
    @State private var hoveredIndex: Int?
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if self.chart.title != nil || self.chart.unit != nil {
                HStack(spacing: 6) {
                    if let title = self.chart.title {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                    if let unit = self.chart.unit {
                        Text(unit)
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)
            }
            Group {
                switch self.chart.kind {
                case .bars:
                    self.bars
                case .line:
                    self.line
                }
            }
            .frame(height: 58)
            self.axisLabels
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityLabel)
    }

    private var bars: some View {
        GeometryReader { geometry in
            let scale = UsageChartScale(values: self.chart.points.map(\.value))
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(self.chart.points.enumerated()), id: \.offset) { index, point in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(self.fillColor(value: point.value, scale: scale))
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.height(value: point.value, scale: scale, available: geometry.size.height))
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            self
                                .hoveredIndex = hovering ? index :
                                (self.hoveredIndex == index ? nil : self.hoveredIndex)
                        }
                        .help(self.hoverText(for: point))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .overlay(alignment: .bottomLeading) {
                Rectangle()
                    .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.22))
                    .frame(height: 1)
            }
            .overlay(alignment: .top) {
                if let point = self.hoveredPoint {
                    Text(self.hoverText(for: point))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    private var line: some View {
        GeometryReader { _ in
            Canvas { context, size in
                let scale = UsageChartScale(values: self.chart.points.map(\.value))
                let points = self.chart.points.enumerated().map { index, point in
                    let x = self.chart.points.count == 1
                        ? size.width / 2
                        : size.width * CGFloat(index) / CGFloat(self.chart.points.count - 1)
                    let y = size.height * (1 - CGFloat(scale.fraction(for: point.value)))
                    return CGPoint(x: x, y: y)
                }
                guard let first = points.first else { return }
                var path = Path()
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                context.stroke(
                    path,
                    with: .color(self.isHighlighted ? .white.opacity(0.82) : self.color),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                for point in points {
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)),
                        with: .color(self.isHighlighted ? .white : self.color))
                }
            }
            .overlay(alignment: .bottomLeading) {
                Rectangle()
                    .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.22))
                    .frame(height: 1)
            }
        }
    }

    private var accessibilityLabel: String {
        let title = self.chart.title.map { "\($0): " } ?? ""
        let unit = self.chart.unit.map { " \($0)" } ?? ""
        let points = self.chart.points.map { "\($0.label) \($0.value)\(unit)" }.joined(separator: ", ")
        return title + points
    }

    private var hoveredPoint: ProviderDetailSection.Chart.Point? {
        guard let hoveredIndex, self.chart.points.indices.contains(hoveredIndex) else { return nil }
        return self.chart.points[hoveredIndex]
    }

    private var axisLabels: some View {
        HStack(spacing: 4) {
            if let first = self.chart.points.first {
                Text(ProviderDetailChartLabelFormatter.axisLabel(first.label))
                Spacer(minLength: 4)
            }
            if self.chart.points.count > 2 {
                Text(ProviderDetailChartLabelFormatter.axisLabel(
                    self.chart.points[self.chart.points.count / 2].label))
                Spacer(minLength: 4)
            }
            if self.chart.points.count > 1, let last = self.chart.points.last {
                Text(ProviderDetailChartLabelFormatter.axisLabel(last.label))
            }
        }
        .font(.system(size: 8))
        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func hoverText(for point: ProviderDetailSection.Chart.Point) -> String {
        let unit = self.chart.unit.map { " \($0)" } ?? ""
        let value = point.value.formatted(.number.precision(.fractionLength(0...2)))
        return "\(point.label): \(value)\(unit)"
    }

    private func fillColor(value: Double, scale: UsageChartScale) -> Color {
        let ratio = max(0.18, scale.fraction(for: value))
        if self.isHighlighted {
            return Color.white.opacity(0.55 + ratio * 0.35)
        }
        return self.color.opacity(0.42 + ratio * 0.58)
    }

    private static func height(value: Double, scale: UsageChartScale, available: CGFloat) -> CGFloat {
        let ratio = scale.fraction(for: value)
        guard ratio > 0 else { return 1 }
        return max(3, CGFloat(ratio) * available)
    }
}
