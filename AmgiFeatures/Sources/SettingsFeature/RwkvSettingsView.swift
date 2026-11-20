//
//  RwkvSettingsView.swift
//  SettingsFeature
//
//  RWKV: install the model, choose it for your presets, and see how well
//  its predictions match what you actually remember.
//

import SwiftUI
import Charts
import Theme
import AnkiKit
import AppShared
import UniformTypeIdentifiers

struct RwkvSettingsView: View {
    @Environment(\.palette) private var palette
    @Bindable private var engine = RwkvEngine.shared

    @State private var importing = false
    @State private var calibration: RwkvCalibration?
    @State private var confirmRebuild = false
    @State private var applying: ReviewScheduler?

    var body: some View {
        SettingsPage {
            modelSection
            if engine.hasCurveModel {
                schedulerSection
            }
            if engine.status.loaded && engine.status.hasCurve {
                exploreSection
            }
            // Kept through a reload, so the page doesn't jump while RWKV
            // relearns after a scheduler change.
            if let calibration, calibration.total > 0 {
                calibrationSection(calibration)
            }
            if engine.hasCurveModel {
                advancedSection
            }
        }
        .animation(AmgiMotion.standard, value: engine.phase)
        .animation(AmgiMotion.standard, value: engine.showsProgress)
        .animation(AmgiMotion.standard, value: calibration)
        .navigationTitle("RWKV")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: engine.status.reviewCount) {
            if let latest = await engine.calibration() {
                calibration = latest
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                Task { await engine.importModel(from: url) }
            }
        }
        .confirmationDialog(
            "Rebuild the model state?",
            isPresented: $confirmRebuild,
            titleVisibility: .visible
        ) {
            Button("Rebuild") { Task { await engine.rebuild() } }
        } message: {
            Text("RWKV replays your whole review history. This only takes a moment, and your reviews are not changed.")
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Group {
            SettingsSectionHeader(title: "Memory Model")
            SettingsGroup {
                SettingsValueRow(
                    title: "Status",
                    value: statusText,
                    systemImage: "brain.head.profile",
                    tone: .mature
                )
                // Short loads and replays finish within a moment; a row that
                // appears and vanishes for them only makes the page jump.
                if engine.showsProgress {
                    SettingsSeparator()
                    progressRow
                        .transition(.opacity)
                }
                if !engine.hasCurveModel {
                    SettingsSeparator()
                    SettingsButtonRow(
                        title: "Turn On RWKV",
                        systemImage: "arrow.down.circle",
                        tone: .accent,
                        isBusy: engine.phase == .installing
                    ) {
                        Task { await engine.installModels(thenUse: .rwkvCurve) }
                    }
                    .disabled(engine.phase == .installing)
                    SettingsSeparator()
                    SettingsButtonRow(
                        title: "Import from Files…",
                        systemImage: "folder",
                        tone: .neutral
                    ) {
                        importing = true
                    }
                } else if engine.status.loaded {
                    SettingsSeparator()
                    SettingsValueRow(
                        title: "Reviews learned from",
                        value: engine.status.reviewCount.formatted(),
                        systemImage: "clock.arrow.circlepath",
                        tone: .info
                    )
                }
            }
            if case .failed(let message) = engine.phase {
                SettingsFootnote(message)
                    .foregroundStyle(palette.danger)
            }
            SettingsFootnote(
                engine.hasCurveModel
                    ? "RWKV is a neural memory model that learns from your whole review history, across every card and deck. It runs entirely on this iPhone."
                    : "RWKV is a neural memory model that learns from your whole review history, across every card and deck. Turning it on downloads the model (2.7 MB) and schedules all presets with RWKV-Curve; it then runs entirely on this iPhone."
            )
        }
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: AmgiSpacing.sm) {
            if let fraction = engine.progress?.fraction {
                ProgressView(value: fraction)
                Text("Learning from \(engine.progress?.total.formatted() ?? "") reviews…")
                    .amgiFont(.caption)
                    .foregroundStyle(palette.textSecondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, AmgiSpacing.lg)
        .padding(.vertical, AmgiSpacing.md)
    }

    private var statusText: String {
        switch engine.phase {
        case .idle:
            if !engine.hasCurveModel { return "Not installed" }
            return engine.status.inUse ? "Not loaded" : "Not in use"
        case .installing: return "Downloading…"
        case .loading: return "Loading…"
        case .syncing: return "Learning…"
        case .ready: return engine.status.paired ? "Ready · Curve + Instant" : "Ready"
        case .failed: return "Needs attention"
        }
    }

    // MARK: - Scheduler

    private var schedulerSection: some View {
        Group {
            SettingsSectionHeader(title: "Schedule With")
            SettingsGroup {
                SchedulerChoiceRow(
                    title: "RWKV-Curve",
                    subtitle: "Due dates from each card's forgetting curve",
                    systemImage: "chart.line.downtrend.xyaxis",
                    tone: .review,
                    isSelected: shownScheduler == .rwkvCurve,
                    isBusy: applying == .rwkvCurve
                ) { choose(.rwkvCurve) }
                SettingsSeparator()
                SchedulerChoiceRow(
                    title: "RWKV-Instant",
                    subtitle: "Shows what you're closest to forgetting now",
                    systemImage: "bolt",
                    tone: .learning,
                    isSelected: shownScheduler == .rwkvInstant,
                    isBusy: applying == .rwkvInstant
                ) { choose(.rwkvInstant) }
                SettingsSeparator()
                SchedulerChoiceRow(
                    title: "FSRS",
                    subtitle: "Anki's standard scheduler",
                    systemImage: "function",
                    tone: .neutral,
                    isSelected: shownScheduler == .fsrs,
                    isBusy: applying == .fsrs
                ) { choose(.fsrs) }
            }
            SettingsFootnote(
                shownScheduler == nil
                    ? "Your presets use different schedulers. Choosing one here puts every preset on it; each deck's preset can also be changed in its options. Settings sync to your other devices."
                    : "Applies to every preset. RWKV-Curve sets the next review where recall falls to your desired retention; RWKV-Instant shows the cards you are most likely to forget right now. Each deck's preset can also be changed in its options. Settings sync to your other devices."
            )
        }
    }

    /// The scheduler every preset uses, as far as the counts tell; nil when
    /// presets differ. While applying, the choice just made.
    private var shownScheduler: ReviewScheduler? {
        if let applying { return applying }
        let status = engine.status
        if status.instantPresets > 0 {
            // Instant presets count as curve presets too (due dates).
            return status.instantPresets == status.curvePresets ? .rwkvInstant : nil
        }
        return status.curvePresets > 0 ? .rwkvCurve : .fsrs
    }

    private func choose(_ scheduler: ReviewScheduler) {
        guard applying == nil, scheduler != shownScheduler else { return }
        withAnimation(AmgiMotion.quick) { applying = scheduler }
        Task {
            await engine.useForAllPresets(scheduler)
            withAnimation(AmgiMotion.standard) { applying = nil }
        }
    }

    // MARK: - Explore

    private var exploreSection: some View {
        Group {
            SettingsSectionHeader(title: "Explore")
            SettingsGroup {
                SettingsRowLink(
                    title: "Inside RWKV",
                    systemImage: "waveform.path.ecg",
                    tone: .mature
                ) {
                    RwkvInsideView()
                }
            }
            SettingsFootnote("See how RWKV pictures your memory of a card: its forgetting curve, what it's made of, and the numbers RWKV keeps for it.")
        }
    }

    // MARK: - Calibration

    private func calibrationSection(_ calibration: RwkvCalibration) -> some View {
        Group {
            SettingsSectionHeader(title: "Calibration")
            SettingsGroup {
                VStack(alignment: .leading, spacing: AmgiSpacing.md) {
                    Chart {
                        ForEach(calibration.buckets.filter { $0.count > 0 }) { bucket in
                            PointMark(
                                x: .value("Predicted", bucket.meanPredicted),
                                y: .value("Recalled", bucket.observed)
                            )
                            .symbolSize(min(220, 20 + Double(bucket.count) / 4))
                            .foregroundStyle(palette.accent)
                        }
                        LineMark(x: .value("Predicted", 0), y: .value("Recalled", 0))
                            .foregroundStyle(palette.textTertiary)
                        LineMark(x: .value("Predicted", 1), y: .value("Recalled", 1))
                            .foregroundStyle(palette.textTertiary)
                    }
                    .chartXScale(domain: 0...1)
                    .chartYScale(domain: 0...1)
                    .chartXAxisLabel("Predicted recall")
                    .chartYAxisLabel("Actually recalled")
                    .frame(height: 220)
                    HStack {
                        metric("Reviews", calibration.total.formatted())
                        Spacer()
                        metric("Log loss", calibration.logLoss.formatted(.number.precision(.fractionLength(3))))
                        Spacer()
                        metric("RMSE (bins)", calibration.rmseBins.formatted(.percent.precision(.fractionLength(1))))
                    }
                }
                .padding(AmgiSpacing.lg)
            }
            SettingsFootnote(
                "Each dot groups reviews by the recall RWKV predicted just before you answered. Dots near the diagonal mean the predictions match how often you actually remembered."
            )
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .amgiFont(.body, .monospacedDigits)
                .foregroundStyle(palette.textPrimary)
            Text(title)
                .amgiFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Group {
            SettingsSectionHeader(title: "Advanced")
            SettingsGroup {
                SettingsToggleRow(
                    title: "Compact model state",
                    systemImage: "archivebox",
                    tone: .neutral,
                    isOn: $engine.compactState
                )
                SettingsSeparator()
                SettingsButtonRow(
                    title: "Rebuild model state",
                    systemImage: "arrow.clockwise",
                    tone: .info,
                    isBusy: engine.phase == .syncing
                ) {
                    confirmRebuild = true
                }
                .disabled(!engine.status.loaded || engine.phase == .syncing)
            }
            SettingsFootnote(
                "Full precision keeps RWKV's memory of each card and note exactly, at about 3.5 KB each. Compact uses roughly a third of the space with very slightly less accurate predictions. Changing it rebuilds the model state."
            )
        }
    }
}

/// One scheduler choice: icon, name, one-line description, and a trailing
/// checkmark (or spinner while it applies) in a fixed-width slot, so
/// selecting animates the mark without moving anything else.
private struct SchedulerChoiceRow: View {
    @Environment(\.palette) private var palette

    let title: String
    let subtitle: String
    let systemImage: String
    let tone: SettingsTone
    let isSelected: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AmgiSpacing.md) {
                SettingsIconTile(systemImage: systemImage, tone: tone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .amgiFont(.body)
                        .foregroundStyle(palette.textPrimary)
                    Text(subtitle)
                        .amgiFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AmgiSpacing.sm)
                ZStack {
                    if isBusy {
                        ProgressView()
                            .transition(.opacity)
                    } else if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .frame(width: 24, height: 24)
            }
            .padding(.horizontal, AmgiSpacing.lg)
            .padding(.vertical, AmgiSpacing.md)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressScale)
        .sensoryFeedback(.selection, trigger: isSelected) { _, selected in selected }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
