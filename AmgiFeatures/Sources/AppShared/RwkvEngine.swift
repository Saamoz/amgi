//
//  RwkvEngine.swift
//  AppShared
//
//  The app side of RWKV scheduling. The engine does the scheduling itself
//  once its runtime is loaded (GetQueuedCards returns RWKV states, AnswerCard
//  advances the model); this controller installs the model files, loads
//  them for the open profile, keeps the model state in step with the review
//  history (launch, foreground, after a sync), and saves it in the
//  background.
//

public import AnkiKit
import AnkiBackend
import AnkiServices
import AppCore
import Dependencies
public import Foundation
public import Observation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// One model file the app knows how to load.
public struct RwkvModelFile: Sendable, Hashable, Identifiable {
    /// The engine's model key.
    public let key: String
    public let title: String
    public let sha256: String
    public let bytes: Int
    public var id: String { key }

    var fileName: String { "\(key).weights.f32.bin" }

    /// The fork pins the files at this commit, so the bytes never change
    /// under a fixed URL.
    private static let source = "https://raw.githubusercontent.com/Saamoz/anki/f740693f120fb59776273ca1d767f91e2b8c022b/qt/aqt/rwkv_inference"
    var downloadURL: URL { URL(string: "\(Self.source)/\(key)/weights.f32.bin")! }

    /// RWKV-Curve's two-head model (SM92): forgetting curve, intervals, S90.
    public static let curve = RwkvModelFile(
        key: "sm92",
        title: "RWKV Small",
        sha256: "4fbc5f963b6ef18d23dbc0f11358fed8a9c7c97c271d6eda95df3b8ed6fbeb6e",
        bytes: 1_351_553
    )
    /// RWKV-Instant's model (SM98), trained only to predict recall when a
    /// card is shown.
    public static let instant = RwkvModelFile(
        key: "sm98",
        title: "RWKV Small Instant",
        sha256: "a006dcc039d19142dc95d257d9c238fb93c7efa12b78e18ec6ae881ac9009a24",
        bytes: 1_351_553
    )
    public static let all = [curve, instant]
}

@Observable
@MainActor
public final class RwkvEngine {
    public static let shared = RwkvEngine()

    public enum Phase: Equatable, Sendable {
        /// Nothing loaded: no model files, or no preset uses RWKV.
        case idle
        case installing
        case loading
        /// Replaying reviews; `progress` reports how far.
        case syncing
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var status = RwkvStatus()
    public private(set) var progress: RwkvRebuildProgress?
    public private(set) var installed: Set<String> = []
    /// True while a sync replays enough reviews to be worth showing.
    public private(set) var showsProgress = false

    /// Off: full-precision model state, the most accurate, at about 3.5 KB
    /// per card and per note. On: the desktop's compact default.
    public var compactState: Bool = UserDefaults.standard.bool(forKey: RwkvEngine.compactKey) {
        didSet {
            guard compactState != oldValue else { return }
            UserDefaults.standard.set(compactState, forKey: Self.compactKey)
            Task { await prepare(force: true) }
        }
    }

    @ObservationIgnored @Dependency(\.rwkvService) private var service
    @ObservationIgnored private var loadedConfig: RwkvLoadConfig?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    nonisolated private static let compactKey = "rwkv.compactState"

    public nonisolated init() {}

    // MARK: - Model files

    public static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL.applicationSupportDirectory
        return appSupport.appendingPathComponent("RWKV", isDirectory: true)
    }

    private func path(_ model: RwkvModelFile) -> URL {
        Self.modelsDirectory.appendingPathComponent(model.fileName)
    }

    public func isInstalled(_ model: RwkvModelFile) -> Bool { installed.contains(model.key) }

    public var hasCurveModel: Bool { isInstalled(.curve) }

    private func refreshInstalled() {
        installed = Set(RwkvModelFile.all.filter {
            FileManager.default.fileExists(atPath: path($0).path)
        }.map(\.key))
    }

    /// Downloads both model files (about 2.7 MB), checks their hashes, and
    /// with `scheduler` puts every preset on it.
    public func installModels(thenUse scheduler: ReviewScheduler? = nil) async {
        phase = .installing
        do {
            try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
            for model in RwkvModelFile.all where !isInstalled(model) {
                let (temporary, response) = try await URLSession.shared.download(from: model.downloadURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw RwkvEngineError.download(model.title)
                }
                try install(from: temporary, as: model)
            }
            refreshInstalled()
            if let scheduler {
                await useForAllPresets(scheduler)
            } else {
                await prepare(force: true)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Installs a model file picked from Files; the hash says which model it is.
    public func importModel(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let digest = try Self.sha256(of: url)
            guard let model = RwkvModelFile.all.first(where: { $0.sha256 == digest }) else {
                throw RwkvEngineError.unknownModel
            }
            try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
            try install(from: url, as: model)
            refreshInstalled()
            await prepare(force: true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func install(from source: URL, as model: RwkvModelFile) throws {
        guard try Self.sha256(of: source) == model.sha256 else {
            throw RwkvEngineError.corrupt(model.title)
        }
        let target = path(model)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        _ = data
        return ""
        #endif
    }

    // MARK: - Runtime

    /// What to load for the presets in use, or nil when RWKV is unused or
    /// its model is missing.
    private func desiredConfig(for status: RwkvStatus) -> RwkvLoadConfig? {
        guard isInstalled(.curve), status.inUse else { return nil }
        let stateDirectory = AccountStore.profileDirectory(for: AccountStore.shared.current.id)
            .appendingPathComponent("rwkv-state", isDirectory: true)
        // RWKV-Instant gets its own model beside the curve when it is in use.
        let paired = status.instantPresets > 0 && isInstalled(.instant)
        return RwkvLoadConfig(
            curveModelPath: path(.curve).path,
            curveModel: RwkvModelFile.curve.key,
            instantModelPath: paired ? path(.instant).path : nil,
            instantModel: paired ? RwkvModelFile.instant.key : nil,
            statePrecision: compactState ? "cards_int4_notes_int8" : "f32",
            stateDirectory: stateDirectory.path
        )
    }

    /// Loads the models for the open profile when presets use RWKV, then
    /// syncs. Call after the collection opens and after preset changes.
    public func prepare(force: Bool = false) async {
        refreshInstalled()
        let service = self.service
        do {
            var current = try await backendOffload { try service.status() }
            guard let config = desiredConfig(for: current) else {
                if current.loaded {
                    try await backendOffload { try service.unload() }
                    current = try await backendOffload { try service.status() }
                }
                loadedConfig = nil
                status = current
                phase = .idle
                return
            }
            if force || !current.loaded || loadedConfig != config {
                phase = .loading
                current = try await backendOffload { try service.load(config) }
                loadedConfig = config
            }
            status = current
            await sync(force: false)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Replays reviews made since the last sync (on this device or synced in
    /// from another): call when returning to the app and after a sync.
    public func refresh() async {
        guard loadedConfig != nil else {
            await prepare()
            return
        }
        await sync(force: false)
    }

    /// Rebuilds the model state from the whole review history.
    public func rebuild() async {
        guard loadedConfig != nil else { return }
        await sync(force: true)
    }

    private func sync(force: Bool) async {
        if let syncTask {
            await syncTask.value
            if !force { return }
        }
        let service = self.service
        let task = Task { @MainActor in
            phase = .syncing
            progress = nil
            let poller = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { break }
                    if let latest = try? await backendOffload({ try service.progress() }) {
                        progress = latest
                        // Small replays finish before anyone would read a bar.
                        showsProgress = latest.stage == .replay && latest.total > 2_000
                    }
                }
            }
            defer {
                poller.cancel()
                progress = nil
                showsProgress = false
            }
            do {
                status = try await backendOffload { try service.sync(force) }
                phase = status.ready ? .ready : .failed(status.lastError)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
        syncTask = task
        await task.value
        syncTask = nil
    }

    /// Saves the model state; call when the app leaves the foreground.
    public func checkpoint() async {
        guard loadedConfig != nil else { return }
        let service = self.service
        if let saved = try? await backendOffload({ try service.checkpoint() }) {
            status = saved
        }
    }

    /// Forgets the loaded runtime before the collection closes (profile
    /// switch); the next `prepare()` loads it for the new profile.
    public func collectionWillClose() async {
        await checkpoint()
        loadedConfig = nil
        status = RwkvStatus()
        phase = .idle
    }

    /// Puts every preset on `scheduler`, then loads what it needs.
    public func useForAllPresets(_ scheduler: ReviewScheduler) async {
        let service = self.service
        do {
            try await backendOffload { try service.useSchedulerForAllPresets(scheduler) }
            await prepare()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func calibration() async -> RwkvCalibration? {
        guard loadedConfig != nil else { return nil }
        let service = self.service
        return try? await backendOffload { try service.calibration(10) }
    }
}

enum RwkvEngineError: LocalizedError {
    case download(String)
    case corrupt(String)
    case unknownModel

    var errorDescription: String? {
        switch self {
        case .download(let model): "Couldn't download \(model). Check your connection and try again."
        case .corrupt(let model): "The \(model) file is damaged. Download it again."
        case .unknownModel: "This isn't an RWKV model file Amgi can use. Choose sm92 or sm98 weights.f32.bin."
        }
    }
}
