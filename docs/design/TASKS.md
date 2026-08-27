# TASKS — Tidal Resolver Swarm Breakdown (rev 2)

Execution rules (vibecoding-general-swarm): one coder subagent per task on
its own branch off `feature/tidal-resolver`; spec fidelity to
docs/design/TIDAL-RESOLVER.md (rev 2) is mandatory; subagent runs its tests
before committing; main agent merges and runs the full suite.

Dependency order (rev 2 — fixes findings 7/8/9):
T0 → T1 → G1(bench gate, needs user's speaker) → T2 → T3 → (T4 ∥ T6 ∥ T7) → T8
T9 runs independently anytime.

## T0 — Foundation: vendor + settings fields
Run `bash scripts/tidal/setup-tidal-resolver.sh`; commit
`pkg/service/tidalapi/` + gitignore for `.tidal-dl-src`.
ALSO (moved from T5, finding 7): add the three `Settings` fields per design
§5 and verify/force `settings.json` written 0600.
Acceptance: `go build ./pkg/service/tidalapi/...` passes; settings
round-trip test green.

## T1 — Auth package `pkg/service/tidalauth`
Pure request functions for device-authorization/token/refresh POSTs
(`https://auth.tidal.com/v1/oauth2/*`, creds from Settings); token-file I/O
(`data/tidal/auth.json`, 0600, atomic). NO mutex here — locking lives in
T2's facade (finding 1). Real device-flow run: capture granted scopes and
confirm they cover every catalog call T2 uses, incl. user playlists
(finding 6).
Acceptance: httptest unit tests (device poll, refresh rotation, restore);
scope evidence recorded in docs/design/TIDAL-SCOPES.md.

## G1 — Bench gate (finding 4; user + agent assist)
Handcraft an onDemand `BmxPlaybackResponse` and a `tracklisturl`
ContentItem; replay to a real speaker via a scratch handler. Verify:
playback starts, Duration honored, preset store + recall works.
Acceptance: go/no-go note committed. **Blocks T2.**

## T2 — BMX adapter `pkg/service/bmx/tidal.go`
Single-lock facade `tidalclient.Do` (finding 1): expiry check →
single-flight refresh (persist rotated token before unlock) → inject
vendored globals → call. Token bucket inside the lock (1/300ms burst 3,
2 retries on 429, shared 10s client). `TidalNavigate`, `TidalSearch`
(per-section cursors), `TidalSearchNext` (single-type),
`TidalPlaybackTrack`, `TidalPlaybackList` (finding 3); own onDemand
playback builder (D2, default ladder `LOSSLESS,HIGH`);
`SetTidalEndpoints` + allowlist; D8 unlinked responses; D9 403-omit.
Acceptance: package-level tests only (finding 9) — ladder table tests,
cursor round-trip, nav fixtures, concurrent-call test asserting exactly
one refresh upstream request.

## T3 — Handlers + routes `pkg/service/handlers/handlers_bmx_tidal.go`
Full route table per design §4 registered in `cmd/soundtouch-service/main.go`;
D7 conventions; report handler writes recents (D6).
Acceptance: handler tests incl. unlinked contract, token-echo, favorites
202, report→recents; routes live under `/bmx/tidal/...`.

## T4 — Registration & persistence (merged T4+T5, finding 8)
`bmx_services.json` TIDAL entry (id 24) + availability JSON + icons;
default source 10006 + `extractIDs` + canonical defaults;
`SaveTidalFavorite`/`DeleteTidalFavorite`; `"TIDAL"` in
`IsStreamingContent()` + `GetTidalItems()`.
Acceptance: registry output contains TIDAL with substituted URLs; sources
XML includes the ConfiguredSource; datastore/models tests green.

## T6 — Settings/auth UI plumbing (parallel)
Settings tab client id/secret fields; device-link endpoints (start auth,
poll, persist); "tidal linked" health check.
Acceptance: end-to-end link against mock auth server; health check flips
on persisted token.

## T7 — Frontend TidalBrowser (parallel)
Component + api.js + app.js (nav/title/render) + icon + `/app/tidal` +
mount.go provider/play routes + soundtouchweb handlers; play-all on
album/playlist (finding 3).
Acceptance: browse→search→play and play-all against the T3 backend.

## T8 — Integration & docs (gate)
Full suite + `docs_consistency_test.go`; MUSIC-SERVICES blurb (link steps,
NONE-only note, R1/R2/R6 caveats); speaker smoke checklist REQUIRED
(finding 16): browse, search, search-next, single-track play, play-all,
preset store/recall, unlinked behavior, favorite round-trip. Merge all
branches; open PR to `feature/tidal-resolver`.

## T9 — Bench: firmware-native priming feasibility (independent)
Capture whether the speaker's baked-in TIDAL client still authenticates
(Spotify-style). Output: docs/design/TIDAL-PRIMING.md go/no-go; fixtures
feed G1. Non-blocking.

## Subagent assignments (on approval)
- Agent "foundation": T0, T1
- Bench (user + assist): G1 — must pass before T2
- Agent "bmx-core": T2, T3
- Agent "registration": T4
- Agent "web-ui": T6, T7
- Verifier: T8 acceptance sweep
- Bench (user + assist): T9
