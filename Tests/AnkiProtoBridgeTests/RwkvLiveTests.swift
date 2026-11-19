//
//  RwkvLiveTests.swift
//  AnkiProtoBridgeTests
//
//  The engine's native RWKV scheduler, end to end against the Small model
//  weights in the anki-upstream checkout.
//

import Foundation
import Testing
import AnkiKit
import AnkiProto
import SwiftProtobuf
@testable import AnkiProtoBridge
@testable import AnkiBackend

@Suite struct RwkvLiveTests {
    private static let models = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AnkiProtoBridgeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("anki-upstream/qt/aqt/rwkv_inference")

    private static var curveWeights: URL? {
        let url = models.appendingPathComponent("sm92/weights.f32.bin")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func addCard(_ backend: AnkiBackend, _ front: String) throws {
        let names = try backend.invoke(.notetypeNames)
        let basic = try #require(names.first { $0.name == "Basic" })
        var template = try backend.invoke(.newNote(notetypeId: basic.id))
        template.fields[0] = front
        template.fields[1] = "back"
        try backend.invoke(.addNote(template: template, deckId: DeckID(1)))
    }

    private func answerGood(_ backend: AnkiBackend) throws -> QueuedReviewCard? {
        let queued: QueuedCardsResult = try backend.invoke(.getQueuedCards(fetchLimit: 1))
        guard let entry = queued.cards.first else { return nil }
        try backend.invoke(.answerReviewCard(
            cardId: entry.card.id, rating: .good, timeSpentMs: 4_000, states: entry.states
        ))
        return entry
    }

    /// Turns on FSRS and puts the default preset on `scheduler`.
    private func useScheduler(_ scheduler: ReviewScheduler, _ backend: AnkiBackend) throws {
        let context = try backend.invoke(.deckConfigsForUpdate(deckId: DeckID(1)))
        var preset = try #require(context.allConfig.first?.config)
        preset.config.reviewScheduler = scheduler
        try backend.invoke(.updateDeckConfigs(UpdateDeckConfigsRequest(
            targetDeckID: DeckID(1), configs: [preset], fsrs: true, switches: context.switches
        )))
    }

    @Test func savingAPresetKeepsFieldsTheAppDoesNotMirror() throws {
        try withScratchCollection("rwkv-preset-roundtrip") { backend, _ in
            let context = try backend.invoke(.deckConfigsForUpdate(deckId: DeckID(1)))
            var preset = try #require(context.allConfig.first?.config)
            var raw = try Anki_DeckConfig_DeckConfig.Config(serializedBytes: preset.config.preservedProto)
            raw.rwkvReviewMinInterveningReviews = 7
            raw.leechOnlyIfYoung = true
            preset.config = DeckConfig.Config(raw)
            preset.config.reviewScheduler = .rwkvInstant
            preset.config.newPerDay = 3
            var switches = context.switches
            switches.loadBalancerEnabled = true
            try backend.invoke(.updateDeckConfigs(UpdateDeckConfigsRequest(
                targetDeckID: DeckID(1), configs: [preset], switches: switches
            )))

            // A later edit made only through the mirror keeps all of them.
            let reread = try backend.invoke(.deckConfigsForUpdate(deckId: DeckID(1)))
            var again = try #require(reread.allConfig.first?.config)
            #expect(reread.switches.loadBalancerEnabled)
            again.config.newPerDay = 4
            try backend.invoke(.updateDeckConfigs(UpdateDeckConfigsRequest(
                targetDeckID: DeckID(1), configs: [again], switches: reread.switches
            )))

            let final = try backend.invoke(.deckConfigsForUpdate(deckId: DeckID(1)))
            let saved = try #require(final.allConfig.first?.config.config)
            let savedRaw = try Anki_DeckConfig_DeckConfig.Config(serializedBytes: saved.preservedProto)
            #expect(saved.newPerDay == 4)
            #expect(saved.reviewScheduler == .rwkvInstant)
            #expect(savedRaw.rwkvReviewMinInterveningReviews == 7)
            #expect(savedRaw.leechOnlyIfYoung)
            #expect(final.switches.loadBalancerEnabled, "a save must not switch the load balancer off")
        }
    }

    @Test func nativeRuntimeSchedulesAndFollowsAnswers() throws {
        guard let weights = Self.curveWeights else { return }
        try withScratchCollection("rwkv-native") { backend, dir in
            try useScheduler(.rwkvCurve, backend)
            for index in 0..<4 { try addCard(backend, "card \(index)") }
            for _ in 0..<6 { _ = try answerGood(backend) }

            let state = dir.appendingPathComponent("rwkv-state")
            var status = try backend.invoke(.rwkvLoad(RwkvLoadConfig(
                curveModelPath: weights.path,
                curveModel: "sm92",
                statePrecision: "f32",
                stateDirectory: state.path
            )))
            #expect(status.loaded && status.hasCurve && !status.ready)
            #expect(status.curvePresets == 1)

            status = try backend.invoke(.rwkvSync(forceFullRebuild: false))
            #expect(status.ready && status.lastSyncFullRebuild)
            #expect(status.reviewCount == 6)
            // Nothing runs now, so there is no rebuild progress to report.
            _ = try backend.invoke(.rwkvProgress)

            let answered = try #require(try answerGood(backend))
            status = try backend.invoke(.rwkvStatus)
            #expect(status.reviewCount == 7, "an answer advances the state")
            #expect(!status.lastSyncFullRebuild)

            let prediction = try backend.invoke(.rwkvCardPrediction(cardId: answered.card.id))
            #expect(prediction.available && prediction.curveEnabled)
            #expect(prediction.retrievability > 0 && prediction.retrievability <= 1)
            #expect(prediction.intervals.count == 4)

            status = try backend.invoke(.rwkvCheckpoint)
            #expect(status.checkpointReviewCount == 7)
            let calibration = try backend.invoke(.rwkvCalibration(buckets: 10))
            #expect(calibration.buckets.count == 10)

            // A reload restores the checkpoint instead of replaying.
            try backend.invoke(.rwkvUnload)
            #expect(try !backend.invoke(.rwkvStatus).loaded)
            _ = try backend.invoke(.rwkvLoad(RwkvLoadConfig(
                curveModelPath: weights.path,
                curveModel: "sm92",
                statePrecision: "f32",
                stateDirectory: state.path
            )))
            status = try backend.invoke(.rwkvSync(forceFullRebuild: false))
            #expect(status.lastSyncRestoredCheckpoint && status.lastSyncReplayedReviews == 0)
        }
    }
}
