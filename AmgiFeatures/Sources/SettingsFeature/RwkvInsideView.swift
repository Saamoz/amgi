//
//  RwkvInsideView.swift
//  SettingsFeature
//
//  A look inside RWKV for one card: the forgetting curve it predicts now and
//  after each answer, the fading traces that curve blends, the numbers RWKV
//  keeps for the card, and how its past predictions turned out.
//

import SwiftUI
import Charts
import Theme
import AnkiKit
import AppShared

struct RwkvInsideView: View {
    @Environment(\.palette) private var palette
    private let engine = RwkvEngine.shared

    @State private var curve: RwkvCardCurve?
    @State private var loaded = false
    @State private var answer = 2  // Good

    var body: some View {
        SettingsPage {
            if let curve, curve.available {
                Group {
                    cardSection(curve)
                    curveSection(curve)
                    componentsSection(curve)
                    memorySection(curve)
                    historySection(curve)
                }
                .id(curve.cardId)
                .transition(.opacity)
            } else if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
            } else {
                ContentUnavailableView(
                    "Nothing to show yet",
                    systemImage: "brain.head.profile",
                    description: Text("Review a card in a deck that uses RWKV, then come back to look inside.")
                )
                .padding(.top, 60)
            }
        }
        .animation(AmgiMotion.standard, value: curve?.cardId)
        .navigationTitle("Inside RWKV")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load(shuffle: true) }
                } label: {
                    Image(systemName: "shuffle")
                }
                .accessibilityLabel("Show another card")
                .disabled(!loaded)
            }
        }
        .task { await load(shuffle: false) }
    }

    private func load(shuffle: Bool) async {
        let next = await engine.cardCurve(shuffle: shuffle)
        withAnimation(AmgiMotion.standard) {
            // A shuffle that finds nothing keeps the card on screen.
            if next?.available == true || curve == nil { curve = next }
            loaded = true
        }
    }

    // MARK: - Card

    private func cardSection(_ curve: RwkvCardCurve) -> some View {
        Group {
            SettingsSectionHeader(title: "Card")
            SettingsGroup {
                VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
                    Text(curve.question.isEmpty ? "Card \(curve.cardId.rawValue)" : curve.question)
                        .amgiFont(.sectionHeading)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(3)
                    if !curve.answer.isEmpty {
                        Text(curve.answer)
                            .amgiFont(.body)
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(3)
                    }
                    HStack {
                        metric("Recall now", percent(curve.now.first))
                        Spacer()
                        metric("Reviews", curve.reviews.count.formatted())
                        Spacer()
                        metric(
                            "Next if \(Self.answerNames[answer])",
                            duration(crossing(curve, answer: answer))
                        )
                    }
                    .padding(.top, AmgiSpacing.sm)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AmgiSpacing.lg)
            }
        }
    }

    // MARK: - Forgetting curve

    private static let answerNames = ["Again", "Hard", "Good", "Easy"]

    private func answerColor(_ index: Int) -> Color {
        switch index {
        case 0: palette.cardStateRelearn
        case 1: palette.cardStateLearning
        case 2: palette.cardStateReview
        default: palette.accent
        }
    }

    private struct Point: Identifiable {
        let series: String
        let day: Double
        let recall: Double
        var id: String { "\(series)-\(day)" }
    }

    /// Days the chart spans: a few Good intervals, within two years.
    private func horizon(_ curve: RwkvCardCurve) -> Double {
        let good = crossing(curve, answer: 2) ?? 30
        return min(730, max(14, good * 2.5))
    }

    private func points(_ values: [Float], series: String, in curve: RwkvCardCurve, upTo horizon: Double) -> [Point] {
        zip(curve.days, values)
            .filter { Double($0.0) <= horizon }
            .map { Point(series: series, day: Double($0.0), recall: Double($0.1)) }
    }

    /// Days from now until `answer`'s curve falls to the desired retention.
    private func crossing(_ curve: RwkvCardCurve, answer: Int) -> Double? {
        guard curve.answers.indices.contains(answer) else { return nil }
        let values = curve.answers[answer]
        let target = curve.targetRetention
        for index in values.indices.dropFirst() where values[index] < target {
            let (d0, d1) = (Double(curve.days[index - 1]), Double(curve.days[index]))
            let (r0, r1) = (Double(values[index - 1]), Double(values[index]))
            let t = r0 == r1 ? 0 : (r0 - Double(target)) / (r0 - r1)
            return d0 + (d1 - d0) * t
        }
        return nil
    }

    private func curveSection(_ curve: RwkvCardCurve) -> some View {
        let horizon = horizon(curve)
        let next = crossing(curve, answer: answer)
        return Group {
            SettingsSectionHeader(title: "Forgetting Curve")
            SettingsGroup {
                VStack(alignment: .leading, spacing: AmgiSpacing.md) {
                    Chart {
                        ForEach(0..<4, id: \.self) { index in
                            if index != answer {
                                ForEach(points(curve.answers[index], series: Self.answerNames[index], in: curve, upTo: horizon)) { point in
                                    LineMark(
                                        x: .value("Days", point.day),
                                        y: .value("Recall", point.recall),
                                        series: .value("Answer", point.series)
                                    )
                                    .foregroundStyle(answerColor(index).opacity(0.25))
                                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                                }
                            }
                        }
                        ForEach(points(curve.now, series: "Unreviewed", in: curve, upTo: horizon)) { point in
                            LineMark(
                                x: .value("Days", point.day),
                                y: .value("Recall", point.recall),
                                series: .value("Answer", point.series)
                            )
                            .foregroundStyle(palette.textTertiary)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                        ForEach(points(curve.answers[answer], series: "Chosen", in: curve, upTo: horizon)) { point in
                            AreaMark(
                                x: .value("Days", point.day),
                                yStart: .value("Recall", 0),
                                yEnd: .value("Recall", point.recall)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [answerColor(answer).opacity(0.22), answerColor(answer).opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            LineMark(
                                x: .value("Days", point.day),
                                y: .value("Recall", point.recall),
                                series: .value("Answer", point.series)
                            )
                            .foregroundStyle(answerColor(answer))
                            .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        }
                        RuleMark(y: .value("Desired retention", Double(curve.targetRetention)))
                            .foregroundStyle(palette.textTertiary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        if let next, next <= horizon {
                            PointMark(
                                x: .value("Days", next),
                                y: .value("Recall", Double(curve.targetRetention))
                            )
                            .symbolSize(90)
                            .foregroundStyle(answerColor(answer))
                            .annotation(position: .top, alignment: .center, spacing: 6) {
                                Text("Next review")
                                    .amgiFont(.micro)
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                    }
                    .chartYScale(domain: 0...1)
                    .chartXScale(domain: 0...horizon)
                    .chartYAxis {
                        AxisMarks(
                            format: FloatingPointFormatStyle<Double>.Percent(),
                            values: [0.0, 0.25, 0.5, 0.75, 1.0]
                        )
                    }
                    .chartXAxisLabel("Days from now")
                    .frame(height: 240)

                    Picker("Answer", selection: $answer.animation(AmgiMotion.standard)) {
                        ForEach(0..<4, id: \.self) { Text(Self.answerNames[$0]).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .sensoryFeedback(.selection, trigger: answer)

                    Text(caption(curve, next: next))
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                .padding(AmgiSpacing.lg)
            }
            SettingsFootnote("The dashed line is recall if you don't review. The coloured line is recall after answering now; RWKV schedules the next review where it meets your desired retention.")
        }
    }

    private func caption(_ curve: RwkvCardCurve, next: Double?) -> String {
        let target = percent(curve.targetRetention)
        guard let next else {
            return "Answer \(Self.answerNames[answer]) and RWKV expects recall to stay above \(target) for more than two years."
        }
        return "Answer \(Self.answerNames[answer]) and recall is predicted to fall to \(target) in \(duration(next)), so that's when RWKV would show the card again."
    }

    // MARK: - Components

    private func componentsSection(_ curve: RwkvCardCurve) -> some View {
        let parts = curve.components
            .filter { $0.weight >= 0.01 }
            .sorted { $0.s90Days < $1.s90Days }
        let largest = parts.map(\.weight).max() ?? 1
        return Group {
            SettingsSectionHeader(title: "What the Memory Is Made Of")
            SettingsGroup {
                VStack(alignment: .leading, spacing: AmgiSpacing.md) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        HStack(spacing: AmgiSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lifetime(Double(part.s90Days)))
                                    .amgiFont(.body)
                                    .foregroundStyle(palette.textPrimary)
                                GeometryReader { proxy in
                                    Capsule()
                                        .fill(palette.cardStateMature.gradient)
                                        .frame(width: max(6, proxy.size.width * CGFloat(part.weight / largest)))
                                }
                                .frame(height: 8)
                            }
                            Text(percent(part.weight))
                                .amgiFont(.body, .monospacedDigits)
                                .foregroundStyle(palette.textSecondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
                .padding(AmgiSpacing.lg)
            }
            SettingsFootnote("RWKV pictures each memory as a blend of traces that fade at different speeds: some within seconds, some over years. Every answer reshapes the blend. Shown is the blend right now, by how long each trace stays above 90% recall.")
        }
    }

    private func lifetime(_ days: Double) -> String {
        let seconds = days * 86_400
        if seconds < 60 { return "Fades within a minute" }
        if seconds < 3_600 { return "Fades in \(Int(seconds / 60)) min" }
        if days < 1 { return "Fades in \(Int(seconds / 3_600)) h" }
        return "Lasts \(duration(days))"
    }

    // MARK: - Memory state

    private func memorySection(_ curve: RwkvCardCurve) -> some View {
        let heads = curve.memoryHeads
        let scale = curve.memory.map { abs($0) }.max() ?? 1
        return Group {
            if !heads.isEmpty {
                SettingsSectionHeader(title: "Memory State")
                SettingsGroup {
                    VStack(spacing: AmgiSpacing.md) {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: AmgiSpacing.md), count: 2),
                            spacing: AmgiSpacing.md
                        ) {
                            ForEach(Array(heads.enumerated()), id: \.offset) { index, head in
                                VStack(spacing: AmgiSpacing.xs) {
                                    MemoryHeatmap(
                                        values: head,
                                        side: curve.memorySide,
                                        scale: max(scale, 1e-6),
                                        positive: palette.cardStateLearning,
                                        negative: palette.accent
                                    )
                                    .aspectRatio(1, contentMode: .fit)
                                    Text("Head \(index + 1)")
                                        .amgiFont(.micro)
                                        .foregroundStyle(palette.textTertiary)
                                }
                            }
                        }
                    }
                    .padding(AmgiSpacing.lg)
                }
                SettingsFootnote("These \(curve.memory.count.formatted()) numbers are this card's memory inside RWKV's first layer, one \(curve.memorySide) × \(curve.memorySide) matrix per attention head (orange positive, blue negative). Each answer rewrites them; together with what RWKV keeps for the card's note, deck and your whole collection, they produce the curve above.")
            }
        }
    }

    // MARK: - History

    private func historySection(_ curve: RwkvCardCurve) -> some View {
        let reviews = Array(curve.reviews.reversed().prefix(12))
        let predicted = curve.reviews.compactMap(\.predicted)
        let remembered = curve.reviews.filter { $0.ease > 1 }.count
        return Group {
            if !reviews.isEmpty {
                SettingsSectionHeader(title: "History")
                SettingsGroup {
                    ForEach(Array(reviews.enumerated()), id: \.offset) { index, review in
                        if index > 0 { SettingsSeparator() }
                        HStack(spacing: AmgiSpacing.md) {
                            Circle()
                                .fill(answerColor(review.ease - 1))
                                .frame(width: 10, height: 10)
                            Text(Self.answerNames[max(0, min(3, review.ease - 1))])
                                .amgiFont(.body)
                                .foregroundStyle(palette.textPrimary)
                            Text(review.date.formatted(date: .abbreviated, time: .omitted))
                                .amgiFont(.caption)
                                .foregroundStyle(palette.textSecondary)
                            Spacer()
                            if let expected = review.predicted {
                                Text("expected \(percent(expected))")
                                    .amgiFont(.caption, .monospacedDigits)
                                    .foregroundStyle(palette.textSecondary)
                            }
                        }
                        .padding(.horizontal, AmgiSpacing.lg)
                        .padding(.vertical, AmgiSpacing.md)
                    }
                }
                SettingsFootnote(
                    predicted.isEmpty
                        ? "Your answers to this card, newest first."
                        : "Before each answer RWKV predicted how likely you were to remember. On average it expected \(percent(predicted.reduce(0, +) / Float(predicted.count))); you remembered \(remembered) of \(curve.reviews.count) times."
                )
            }
        }
    }

    // MARK: - Formatting

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .amgiFont(.bodyEmphasis, .monospacedDigits)
                .foregroundStyle(palette.textPrimary)
                .contentTransition(.numericText())
            Text(title)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    private func percent(_ value: Float?) -> String {
        guard let value else { return "–" }
        return Double(value).formatted(.percent.precision(.fractionLength(0)))
    }

    private func duration(_ days: Double?) -> String {
        guard let days else { return "2 yr +" }
        if days < 1 {
            let hours = max(1, Int((days * 24).rounded()))
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        if days < 60 {
            let whole = Int(days.rounded())
            return whole == 1 ? "1 day" : "\(whole) days"
        }
        if days < 730 { return "\(Int((days / 30.4).rounded())) months" }
        return "\((days / 365).formatted(.number.precision(.fractionLength(1)))) years"
    }
}

/// A grid of cells coloured by sign and size.
private struct MemoryHeatmap: View {
    let values: [Float]
    let side: Int
    let scale: Float
    let positive: Color
    let negative: Color

    var body: some View {
        Canvas { context, size in
            guard side > 0 else { return }
            let cell = min(size.width, size.height) / CGFloat(side)
            for (index, value) in values.enumerated() {
                let row = index / side
                let column = index % side
                // Square root lifts the many small values into view.
                let strength = Double(min(1, (abs(value) / scale).squareRoot()))
                let rect = CGRect(
                    x: CGFloat(column) * cell,
                    y: CGFloat(row) * cell,
                    width: cell,
                    height: cell
                ).insetBy(dx: 0.5, dy: 0.5)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: cell * 0.18),
                    with: .color((value >= 0 ? positive : negative).opacity(0.08 + 0.92 * strength))
                )
            }
        }
        .accessibilityLabel("Memory matrix, \(side) by \(side)")
    }
}
