//
//  RwkvTypes.swift
//  AnkiKit
//
//  Mirrors for the engine's native RWKV scheduler (the `RwkvNative*` RPCs).
//

public import Foundation

/// What to load into the engine's RWKV runtime.
public struct RwkvLoadConfig: Sendable, Hashable {
    /// The two-head model (RWKV-Curve, and RWKV-Instant without an instant
    /// model), e.g. `sm92`.
    public var curveModelPath: String?
    public var curveModel: String
    /// The instant-only model beside it, e.g. `sm98`.
    public var instantModelPath: String?
    public var instantModel: String?
    /// `f32`, `int8` or `cards_int4_notes_int8`.
    public var statePrecision: String
    /// Where the engine keeps its persistent model state. Not synced.
    public var stateDirectory: String

    public init(
        curveModelPath: String?,
        curveModel: String,
        instantModelPath: String? = nil,
        instantModel: String? = nil,
        statePrecision: String,
        stateDirectory: String
    ) {
        self.curveModelPath = curveModelPath
        self.curveModel = curveModel
        self.instantModelPath = instantModelPath
        self.instantModel = instantModel
        self.statePrecision = statePrecision
        self.stateDirectory = stateDirectory
    }
}

/// The engine runtime's state after a call.
public struct RwkvStatus: Sendable, Hashable {
    public var loaded: Bool
    /// The model state matches the review history.
    public var ready: Bool
    public var curveModel: String
    public var instantModel: String
    public var paired: Bool
    public var hasCurve: Bool
    public var reviewCount: Int
    public var lastSyncReplayedReviews: Int
    public var lastSyncFullRebuild: Bool
    public var lastSyncRestoredCheckpoint: Bool
    public var lastSyncMillis: Int
    public var checkpointReviewCount: Int
    public var curvePresets: Int
    public var instantPresets: Int
    public var statePrecision: String
    public var lastError: String

    public init(
        loaded: Bool = false,
        ready: Bool = false,
        curveModel: String = "",
        instantModel: String = "",
        paired: Bool = false,
        hasCurve: Bool = false,
        reviewCount: Int = 0,
        lastSyncReplayedReviews: Int = 0,
        lastSyncFullRebuild: Bool = false,
        lastSyncRestoredCheckpoint: Bool = false,
        lastSyncMillis: Int = 0,
        checkpointReviewCount: Int = 0,
        curvePresets: Int = 0,
        instantPresets: Int = 0,
        statePrecision: String = "",
        lastError: String = ""
    ) {
        self.loaded = loaded
        self.ready = ready
        self.curveModel = curveModel
        self.instantModel = instantModel
        self.paired = paired
        self.hasCurve = hasCurve
        self.reviewCount = reviewCount
        self.lastSyncReplayedReviews = lastSyncReplayedReviews
        self.lastSyncFullRebuild = lastSyncFullRebuild
        self.lastSyncRestoredCheckpoint = lastSyncRestoredCheckpoint
        self.lastSyncMillis = lastSyncMillis
        self.checkpointReviewCount = checkpointReviewCount
        self.curvePresets = curvePresets
        self.instantPresets = instantPresets
        self.statePrecision = statePrecision
        self.lastError = lastError
    }

    /// Whether any preset schedules with RWKV.
    public var inUse: Bool { curvePresets + instantPresets > 0 }
}

/// Progress of a running RWKV sync.
public struct RwkvRebuildProgress: Sendable, Hashable {
    public enum Stage: String, Sendable, Hashable {
        case history, replay, saving
    }

    public var stage: Stage
    public var current: Int
    public var total: Int

    public init(stage: Stage, current: Int, total: Int) {
        self.stage = stage
        self.current = current
        self.total = total
    }

    /// 0...1 while replaying; nil while the stage has no count.
    public var fraction: Double? {
        guard stage == .replay, total > 0 else { return nil }
        return min(1, Double(current) / Double(total))
    }
}

/// One card's RWKV prediction.
public struct RwkvCardPrediction: Sendable, Hashable {
    public var available: Bool
    public var curveEnabled: Bool
    public var instantEnabled: Bool
    /// Probability of recall right now.
    public var retrievability: Float
    /// Days until recall falls to 90%.
    public var currentS90: Float?
    /// Again, Hard, Good, Easy, in days.
    public var intervals: [Float]
    public var targetRetention: Float

    public init(
        available: Bool = false,
        curveEnabled: Bool = false,
        instantEnabled: Bool = false,
        retrievability: Float = 0,
        currentS90: Float? = nil,
        intervals: [Float] = [],
        targetRetention: Float = 0
    ) {
        self.available = available
        self.curveEnabled = curveEnabled
        self.instantEnabled = instantEnabled
        self.retrievability = retrievability
        self.currentS90 = currentS90
        self.intervals = intervals
        self.targetRetention = targetRetention
    }
}

/// How well RWKV's recall predictions matched what happened.
public struct RwkvCalibration: Sendable, Hashable {
    public struct Bucket: Sendable, Hashable, Identifiable {
        public var predictedMin: Float
        public var predictedMax: Float
        public var meanPredicted: Float
        public var observed: Float
        public var count: Int

        public var id: Float { predictedMin }

        public init(predictedMin: Float, predictedMax: Float, meanPredicted: Float, observed: Float, count: Int) {
            self.predictedMin = predictedMin
            self.predictedMax = predictedMax
            self.meanPredicted = meanPredicted
            self.observed = observed
            self.count = count
        }
    }

    public var buckets: [Bucket]
    public var total: Int
    public var logLoss: Float
    public var rmseBins: Float
    public var meanPredicted: Float
    public var meanObserved: Float

    public init(
        buckets: [Bucket] = [],
        total: Int = 0,
        logLoss: Float = 0,
        rmseBins: Float = 0,
        meanPredicted: Float = 0,
        meanObserved: Float = 0
    ) {
        self.buckets = buckets
        self.total = total
        self.logLoss = logLoss
        self.rmseBins = rmseBins
        self.meanPredicted = meanPredicted
        self.meanObserved = meanObserved
    }
}

/// RWKV-Curve's view of one card, for the "Inside RWKV" screen.
public struct RwkvCardCurve: Sendable, Hashable {
    /// One of the simple curves the forgetting curve blends.
    public struct Component: Sendable, Hashable {
        /// Days until this part of the memory falls to 90% recall.
        public var s90Days: Float
        public var weight: Float

        public init(s90Days: Float, weight: Float) {
            self.s90Days = s90Days
            self.weight = weight
        }
    }

    public struct Review: Sendable, Hashable {
        public var date: Date
        /// 1 to 4: Again, Hard, Good, Easy.
        public var ease: Int
        /// RWKV's recall prediction just before the answer.
        public var predicted: Float?

        public init(date: Date, ease: Int, predicted: Float?) {
            self.date = date
            self.ease = ease
            self.predicted = predicted
        }
    }

    public var available: Bool
    public var cardId: CardID
    public var question: String
    public var answer: String
    /// Days from now that the curves are sampled at.
    public var days: [Float]
    /// Recall at `days` if the card is not reviewed.
    public var now: [Float]
    /// Recall at `days` after answering Again, Hard, Good or Easy now.
    public var answers: [[Float]]
    public var components: [Component]
    /// One `memorySide` × `memorySide` matrix per head, row-major.
    public var memory: [Float]
    public var memorySide: Int
    public var targetRetention: Float
    public var reviews: [Review]

    public init(
        available: Bool = false,
        cardId: CardID = CardID(0),
        question: String = "",
        answer: String = "",
        days: [Float] = [],
        now: [Float] = [],
        answers: [[Float]] = [],
        components: [Component] = [],
        memory: [Float] = [],
        memorySide: Int = 0,
        targetRetention: Float = 0.9,
        reviews: [Review] = []
    ) {
        self.available = available
        self.cardId = cardId
        self.question = question
        self.answer = answer
        self.days = days
        self.now = now
        self.answers = answers
        self.components = components
        self.memory = memory
        self.memorySide = memorySide
        self.targetRetention = targetRetention
        self.reviews = reviews
    }

    /// The memory matrices, one per head.
    public var memoryHeads: [[Float]] {
        let size = memorySide * memorySide
        guard size > 0 else { return [] }
        return stride(from: 0, to: memory.count - size + 1, by: size).map {
            Array(memory[$0 ..< $0 + size])
        }
    }
}
