//
//  RwkvProgressBanner.swift
//  AppShared
//
//  A small capsule over the app while RWKV replays a long review history
//  (first install, a rebuild, or a large sync from another device).
//

public import SwiftUI
import Theme
import AnkiKit

public struct RwkvProgressBanner: View {
    private let engine = RwkvEngine.shared

    public init() {}

    public var body: some View {
        if engine.showsProgress, let progress = engine.progress {
            HStack(spacing: 8) {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(label(progress))
                    .amgiFont(.caption, .monospacedDigits)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .amgiMaterial(.light, in: Capsule())
            .padding(.top, 8)
            .transition(AmgiMotion.slide(from: .top))
            .accessibilityElement(children: .combine)
        }
    }

    private func label(_ progress: RwkvRebuildProgress) -> String {
        guard let fraction = progress.fraction else { return "RWKV is learning…" }
        return "RWKV is learning · \(Int(fraction * 100))%"
    }
}
