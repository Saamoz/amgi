# RWKV scheduling

Amgi schedules reviews with RWKV, the neural spaced-repetition model from the
[RWKV Anki fork](https://github.com/JSchoreels/anki), running entirely on the
device. This page is the map for anyone (person or agent) picking the work up.

## How it fits together

```
RwkvSettingsView / Deck Options picker        (SettingsFeature, DecksFeature)
        │
RwkvEngine  ── model files, load, sync, checkpoint   (AppShared)
        │
RwkvService ── RwkvRequests                  (AnkiServices, AnkiProtoBridge)
        │
anki-upstream: rslib/src/scheduler/rwkv/native.rs    (Saamoz/anki main)
        └── rslib/src/rwkv/                  the fork's Rust inference engine
```

- **The engine does the scheduling.** Once `RwkvNativeLoad` has loaded the
  models, `GetQueuedCards` returns RWKV-Curve answer states (for the first
  two queued cards), `AnswerCard` fills the RWKV answer metadata and advances
  the model, and RWKV-Instant decks get queue scores before their queue is
  built. The review screen has no RWKV code.
- **Model state always equals a replay of the review history.** `RwkvNativeSync`
  replays only new reviews when the history just grew (checked by a hash of
  every review), restores the newest checkpoint after a relaunch, and rebuilds
  from scratch when earlier history changed (undo, deck moves, a sync that
  inserted older reviews). An answer on an unchanged history replays just that
  card (~17 ms).
- **State lives per profile** in `<profile>/rwkv-state/` (engine checkpoint
  store, not synced). Calibration predictions go to the attached retrievability
  cache database under source `rwkv_native`.
- **Presets** carry the scheduler in `rwkv_review_enabled` (Curve) and
  `rwkv_review_instant_order_enabled` (Instant), mirrored as
  `DeckConfig.Config.reviewScheduler`. These sync with the desktop fork.

- **Inside RWKV** (Settings → RWKV → Explore) shows one card through
  `RwkvNativeCardCurve`: its forgetting curve now and after each answer,
  the fading traces the curve blends, its first-layer memory matrices, and
  the prediction recorded before each past answer. It changes no state.

## Model files

`RwkvEngine.swift` lists them in `RwkvModelFile`: SM92 (two-head, RWKV-Curve)
and SM98 (instant-only, RWKV-Instant), 1.35 MB each. The app never bundles
them: "Turn On RWKV" downloads them from a pinned commit of Saamoz/anki and
checks their SHA-256; Settings can also import them from Files.

Their training data (anki-revlogs-10k) is research-only and the original
srs-benchmark checkpoint carries no license, so keep weights out of public
release artifacts.

### Updating to a newer model

1. Merge the RWKV fork's newer `main` into Saamoz/anki and check its model
   key exists in `rslib/src/rwkv/runtime.rs` (`ModelKind::parse`).
2. In `RwkvModelFile`, change `key`, `sha256` (`sha256sum weights.f32.bin`),
   `bytes`, and the pinned commit in `source`.
3. A new model key changes the engine's replay key, so the state rebuilds
   once on the next launch. Nothing else migrates.

## Verifying without a Mac

The Rust side runs anywhere:

```bash
cd anki-upstream && cargo test -p anki --lib rwkv::native   # needs PROTOC
```

`qt/tests/test_rwkv_native_parity.py` in the fork compares this path with the
desktop's Python scheduler (`just build` first).

The engine-side Swift (`AnkiKit`, `AnkiProtoBridge`, `AnkiServices`) also
builds and tests on Linux with the swift.org toolchain: a scratch SwiftPM
package that symlinks those `Sources/` and `Tests/` folders, replaces
`AnkiRustLib` with a C module over a Linux build of `anki-bridge-rs`
(`AMGI_EN_ONLY=1 cargo build --manifest-path anki-bridge-rs/Cargo.toml` after
applying `scripts/patches/anki-en-only.patch`), stubs `os.Logger`, and pins
swift-protobuf/swift-log to `Tuist/Package.resolved`. The probe-coverage test
cannot find files through symlinks there; everything else, including
`RwkvLiveTests`, runs. SwiftUI targets compile only in CI.

## Releasing

CI (`.github/workflows/build-ipa.yml`) builds the unsigned IPA on every manual
run. To publish a GitHub Release, either push a `v*` tag, or start the
workflow manually with `release_tag` set and add
`.github/release-notes/<tag>.md` first.

## Not on the phone

The desktop fork's workload simulation and forecasts, answer-time estimate,
card-info and stats-graph RWKV scores, Grade Now reconciliation and the
dynamic-DR add-on hooks stay desktop-only.
