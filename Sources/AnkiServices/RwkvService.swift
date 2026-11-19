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
            calibration: { buckets in try backend.invoke(.rwkvCalibration(buckets: buckets)) }
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
