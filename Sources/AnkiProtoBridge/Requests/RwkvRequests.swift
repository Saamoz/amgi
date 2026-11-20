//
//  RwkvRequests.swift
//  AnkiProtoBridge
//
//  The engine's native RWKV scheduler. Once loaded, `getQueuedCards` and
//  `answerCard` schedule with RWKV by themselves; these calls manage the
//  runtime around them.
//

import Foundation
public import AnkiBackend
public import AnkiKit
package import AnkiProto
import SwiftProtobuf

package extension RwkvStatus {
    init(_ proto: Anki_Scheduler_RwkvNativeStatus) {
        self.init(
            loaded: proto.loaded,
            ready: proto.ready,
            curveModel: proto.curveModel,
            instantModel: proto.instantModel,
            paired: proto.paired,
            hasCurve: proto.hasCurve_p,
            reviewCount: Int(clamping: proto.reviewCount),
            lastSyncReplayedReviews: Int(clamping: proto.lastSyncReplayedReviews),
            lastSyncFullRebuild: proto.lastSyncFullRebuild,
            lastSyncRestoredCheckpoint: proto.lastSyncRestoredCheckpoint,
            lastSyncMillis: Int(proto.lastSyncMillis),
            checkpointReviewCount: Int(clamping: proto.checkpointReviewCount),
            curvePresets: Int(proto.curvePresets),
            instantPresets: Int(proto.instantPresets),
            statePrecision: proto.statePrecision,
            lastError: proto.lastError
        )
    }
}

extension Request where Response == RwkvStatus {
    private static func status(_ bytes: Data) throws -> RwkvStatus {
        RwkvStatus(try Anki_Scheduler_RwkvNativeStatus(serializedBytes: bytes))
    }

    /// Loads the models. The state is synced on first use, or by `rwkvSync`.
    public static func rwkvLoad(_ config: RwkvLoadConfig) -> Self {
        Self(
            serviceId: ServiceID.scheduler,
            methodId: SchedulerMethod.rwkvNativeLoad,
            encode: {
                var proto = Anki_Scheduler_RwkvNativeLoadRequest()
                if let path = config.curveModelPath {
                    proto.curveModelPath = path
                }
                proto.curveModel = config.curveModel
                if let path = config.instantModelPath, let model = config.instantModel {
                    proto.instantModelPath = path
                    proto.instantModel = model
                }
                proto.statePrecision = config.statePrecision
                proto.stateDir = config.stateDirectory
                return try proto.serializedData()
            },
            decode: status
        )
    }

    public static var rwkvStatus: Self {
        .empty(serviceId: ServiceID.scheduler, methodId: SchedulerMethod.rwkvNativeGetStatus, decode: status)
    }

    /// Replays new reviews, or rebuilds when earlier history changed.
    /// Blocks until done; poll `rwkvProgress` from another task meanwhile.
    public static func rwkvSync(forceFullRebuild: Bool) -> Self {
        Self(
            serviceId: ServiceID.scheduler,
            methodId: SchedulerMethod.rwkvNativeSync,
            encode: {
                var proto = Anki_Scheduler_RwkvNativeSyncRequest()
                proto.forceFullRebuild = forceFullRebuild
                return try proto.serializedData()
            },
            decode: status
        )
    }

    /// Persists the model state, so the next launch replays only newer
    /// reviews.
    public static var rwkvCheckpoint: Self {
        .empty(serviceId: ServiceID.scheduler, methodId: SchedulerMethod.rwkvNativeCheckpoint, decode: status)
    }
}

extension Request where Response == Void {
    public static var rwkvUnload: Self {
        .empty(serviceId: ServiceID.scheduler, methodId: SchedulerMethod.rwkvNativeUnload, decode: { _ in () })
    }
}

extension Request where Response == RwkvRebuildProgress? {
    /// The running sync's progress. Skips the backend lock, so it answers
    /// while `rwkvSync` holds it.
    public static var rwkvProgress: Self {
        var request = Self.empty(
            serviceId: ServiceID.collection,
            methodId: CollectionOpsMethod.latestProgress,
            decode: { bytes in
                let proto = try Anki_Collection_Progress(serializedBytes: bytes)
                guard case .rwkvRebuild(let progress) = proto.value else { return nil }
                return RwkvRebuildProgress(
                    stage: RwkvRebuildProgress.Stage(rawValue: progress.stage) ?? .history,
                    current: Int(progress.current),
                    total: Int(progress.total)
                )
            }
        )
        request.bypassesLock = true
        return request
    }
}

extension Request where Response == RwkvCardPrediction {
    public static func rwkvCardPrediction(cardId: CardID) -> Self {
        Self(
            serviceId: ServiceID.scheduler,
            methodId: SchedulerMethod.rwkvNativeCardPrediction,
            encode: {
                var proto = Anki_Cards_CardId()
                proto.cid = cardId.rawValue
                return try proto.serializedData()
            },
            decode: { bytes in
                let proto = try Anki_Scheduler_RwkvNativeCardPredictionResponse(serializedBytes: bytes)
                return RwkvCardPrediction(
                    available: proto.available,
                    curveEnabled: proto.curveEnabled,
                    instantEnabled: proto.instantEnabled,
                    retrievability: proto.retrievability,
                    currentS90: proto.hasCurrentS90 ? proto.currentS90 : nil,
                    intervals: proto.intervals,
                    targetRetention: proto.targetRetention
                )
            }
        )
    }
}

extension Request where Response == RwkvCalibration {
    public static func rwkvCalibration(buckets: Int) -> Self {
        Self(
            serviceId: ServiceID.scheduler,
            methodId: SchedulerMethod.rwkvNativeCalibration,
            encode: {
                var proto = Anki_Scheduler_RwkvNativeCalibrationRequest()
                proto.buckets = UInt32(clamping: max(2, buckets))
                return try proto.serializedData()
            },
            decode: { bytes in
                let proto = try Anki_Scheduler_RwkvNativeCalibrationResponse(serializedBytes: bytes)
                return RwkvCalibration(
                    buckets: proto.buckets.map {
                        .init(
                            predictedMin: $0.predictedMin,
                            predictedMax: $0.predictedMax,
                            meanPredicted: $0.meanPredicted,
                            observed: $0.observed,
                            count: Int($0.count)
                        )
                    },
                    total: Int(proto.total),
                    logLoss: proto.logLoss,
                    rmseBins: proto.rmseBins,
                    meanPredicted: proto.meanPredicted,
                    meanObserved: proto.meanObserved
                )
            }
        )
    }
}
