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
            if engine.status.ready, let calibration, calibration.total > 0 {
                calibrationSection(calibration)
            }
            if engine.hasCurveModel {
                advancedSection
            }
        }
        .navigationTitle("RWKV")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: engine.status.reviewCount) {
            calibration = await engine.calibration()
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
                if engine.showsProgress || engine.phase == .syncing || engine.phase == .loading {
                    SettingsSeparator()
                    progressRow
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
                SettingsButtonRow(
                    title: "RWKV-Curve for all presets",
                    systemImage: "chart.line.downtrend.xyaxis",
                    tone: .review,
                    isBusy: applying == .rwkvCurve
                ) {
                    Task { await apply(.rwkvCurve) }
                }
                SettingsSeparator()
                SettingsButtonRow(
                    title: "RWKV-Instant for all presets",
                    systemImage: "bolt",
                    tone: .learning,
                    isBusy: applying == .rwkvInstant
                ) {
                    Task { await apply(.rwkvInstant) }
                }
                SettingsSeparator()
                SettingsButtonRow(
                    title: "FSRS for all presets",
                    systemImage: "function",
                    tone: .neutral,
                    isBusy: applying == .fsrs
                ) {
                    Task { await apply(.fsrs) }
                }
                SettingsSeparator()
                SettingsValueRow(
                    title: "Presets using RWKV",
                    // Instant presets also use RWKV-Curve for due dates.
                    value: "\(max(engine.status.curvePresets, engine.status.instantPresets))",
                    systemImage: "slider.horizontal.3",
                    tone: .info
                )
            }
            SettingsFootnote(
                "RWKV-Curve predicts each card's forgetting curve and sets the next review where recall falls to your desired retention. RWKV-Instant instead shows the cards you are most likely to forget right now. Each deck's preset can also be changed in its options. Settings sync to your other devices."
            )
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

    private func apply(_ scheduler: ReviewScheduler) async {
        applying = scheduler
        await engine.useForAllPresets(scheduler)
        applying = nil
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
