//
//  RwkvService.swift
//  AnkiServices
//
//  The engine's native RWKV scheduler: load the models, keep the model state
//  in step with the review history, and read calibration. Reviewing needs
//  nothing extra: once loaded, `SchedulerService` returns RWKV states.
//

import AnkiBackend
import AnkiProtoBridge
public import AnkiKit
public import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct RwkvService: Sendable {
    public var load: @Sendable (_ config: RwkvLoadConfig) throws -> RwkvStatus
    public var unload: @Sendable () throws -> Void
    public var status: @Sendable () throws -> RwkvStatus
    /// Blocks until the state matches the history; `progress` answers
    /// meanwhile from another task.
    public var sync: @Sendable (_ forceFullRebuild: Bool) throws -> RwkvStatus
    public var progress: @Sendable () throws -> RwkvRebuildProgress?
    public var checkpoint: @Sendable () throws -> RwkvStatus
    public var cardPrediction: @Sendable (_ cardId: CardID) throws -> RwkvCardPrediction
    public var calibration: @Sendable (_ buckets: Int) throws -> RwkvCalibration
    /// Puts every preset on `scheduler` and turns FSRS on collection-wide,
    /// which RWKV-Curve's answer states build on. Other settings are kept.
    public var useSchedulerForAllPresets: @Sendable (_ scheduler: ReviewScheduler) throws -> Void
}

extension RwkvService: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        return Self(
            load: { config in try backend.invoke(.rwkvLoad(config)) },
            unload: { try backend.invoke(.rwkvUnload) },
            status: { try backend.invoke(.rwkvStatus) },
            sync: { force in try backend.invoke(.rwkvSync(forceFullRebuild: force)) },
            progress: { try backend.invoke(.rwkvProgress) },
            checkpoint: { try backend.invoke(.rwkvCheckpoint) },
            cardPrediction: { cardId in try backend.invoke(.rwkvCardPrediction(cardId: cardId)) },
            calibration: { buckets in try backend.invoke(.rwkvCalibration(buckets: buckets)) },
            useSchedulerForAllPresets: { scheduler in
                let deckId = try backend.invoke(.getCurrentDeck).id
                let context = try backend.invoke(.deckConfigsForUpdate(deckId: deckId))
                // The engine assigns the target deck the last preset sent, so
                // its own preset goes last to keep the assignment unchanged.
                let own = context.currentDeck?.configID
                let configs = context.allConfig
                    .map { entry in
                        var config = entry.config
                        config.config.reviewScheduler = scheduler
                        return config
                    }
                    .sorted { ($0.id == own ? 1 : 0) < ($1.id == own ? 1 : 0) }
                guard !configs.isEmpty else { return }
                try backend.invoke(.updateDeckConfigs(UpdateDeckConfigsRequest(
                    targetDeckID: deckId,
                    configs: configs,
                    cardStateCustomizer: context.cardStateCustomizer,
                    limits: context.currentDeck?.limits,
                    newCardsIgnoreReviewLimit: context.newCardsIgnoreReviewLimit,
                    fsrs: scheduler == .fsrs ? context.fsrs : true,
                    applyAllParentLimits: context.applyAllParentLimits,
                    fsrsHealthCheck: context.fsrsHealthCheck,
                    switches: context.switches
                )))
            }
        )
    }()
}

extension RwkvService: TestDependencyKey {
    public static let testValue = RwkvService()
}

extension DependencyValues {
    public var rwkvService: RwkvService {
        get { self[RwkvService.self] }
        set { self[RwkvService.self] = newValue }
    }
}
