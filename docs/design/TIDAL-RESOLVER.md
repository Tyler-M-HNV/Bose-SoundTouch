# Tidal Resolver — Design (rev 2, post-review)

Status: proposed. Branch: `feature/tidal-resolver`. Depends on the vendored
library produced by `scripts/tidal/setup-tidal-resolver.sh`
(`pkg/service/tidalapi/`, from Tyler-M-HNV/tidal-dl).
Rev 2 incorporates the falsification review; each fix cites the finding.

## 1. Scope

Add TIDAL as an AfterTouch music service on two surfaces:

1. **BMX adapter** — speakers and the Stockholm UI browse/search/play TIDAL
   through `/bmx/tidal/...`, modeled 1:1 on the TuneIn adapter.
2. **Web player** — `soundtouch-player` gets a `TidalBrowser` twin of
   `TuneInBrowser`.

Playback covers single tracks AND album/playlist play-all (tracklist
playback — finding 3). Out of scope: DASH/Hi-Res playback, TIDAL
Connect-style casting, and Spotify-style OAuth-intercept priming of the
firmware's native TIDAL source (§9).

## 2. Key facts established by recon

- `constants.ProviderTidal = "TIDAL"` and `constants.TidalProviderID = 24`
  already exist and are in `StaticProviders`.
- TuneIn adapter contract: chi routes under `/bmx/tunein`,
  `models.BmxNavResponse`/`BmxPlaybackResponse`, descriptor in
  `pkg/service/handlers/static/bmx_services.json` (id.value 25),
  `{BMX_SERVER}`/`{MEDIA_SERVER}` templating, outbound host allowlist,
  log-only auth gate. TuneIn distinguishes playback link types
  `stationurl` (single live stream) vs `tracklisturl` (playable list).
- `BuildCustomStreamResponseFromURLs` hardcodes `StreamType: "liveRadio"`;
  the tidal package gets its own builder for on-demand content.
- tidal-dl realities: tokens in **process-global vars** (`credentials/`,
  no persistence/locking); client_id/secret are **consts**; playback is
  `track.GetPlaybackInfo(id, quality)` → base64 manifest; `vnd.tidal.bt`
  JSON manifests with `encryptionType == "NONE"` yield direct FLAC/AAC
  URLs; `application/dash+xml` manifests need segment reassembly (rejected);
  no rate-limiting/retry upstream.

## 3. Architecture

```
speaker / Stockholm UI          soundtouch-player (Preact)
        |                                |
        v                                v
/bmx/tidal/v1/... (handlers_bmx_tidal.go)  /api/control/providers/tidal/*
        |                                |
        +------------> pkg/service/bmx/tidal.go <------------+
                                |
                     tidalclient.Do(fn)  <-- ONE mutex (findings 1+2)
                                |
                +---------------+----------------+
                v                                v
   pkg/service/tidalauth (new)        pkg/service/tidalapi (vendored)
   device flow + refresh +            catalog + GetPlaybackInfo
   token persistence                  (globals touched ONLY inside Do)
```

Design decisions:

- **D1 — One lock, one critical section (fixes findings 1, 2).** A single
  facade — `tidalclient.Do(ctx, func())` in the bmx package — holds ONE
  mutex across the entire sequence: expiry check → (single-flight refresh
  if `Expires < now+5min`, persisting the rotated refresh token BEFORE
  lock release) → inject vendored `credentials` globals → vendored catalog
  call → read out. No second mutex exists anywhere; `tidalauth` exposes
  only pure request functions (device-authorization/token/refresh POSTs,
  ~50 lines, creds from settings) and token-file I/O, never its own lock.
- **D2 — Stream policy (fixes finding 10).** Accept rule is singular:
  manifest `ManifestMimeType` contains `vnd.tidal.bt` AND decoded
  `EncryptionType == "NONE"` → use `Urls`; else try next quality. Default
  ladder `LOSSLESS,HIGH` (HI_RES tiers return DASH almost always;
  `HI_RES_LOSSLESS` is opt-in via `Settings.TidalStreamQuality`).
  On-demand single track: `StreamType: "onDemand"`, `HasPlaylist: false`,
  `IsRealtime: false`, `Duration` set — **this exact response shape must be
  validated on real firmware before the adapter is merged (bench gate G1,
  finding 4).**
- **D3 — Navigation: path-based.** `/v1/navigate/{kind}/{id}` (kinds:
  `artist`, `album`, `playlist`, `user-playlists`). Search cursors are
  **per-section** (finding 11): the initial search response embeds a cursor
  per type (`tracks|q|offset`, `albums|q|offset`, …) in each section's
  `BmxNext` link; search-next is only valid for one type at a time.
  Allowlist hosts: `api.tidal.com`, `auth.tidal.com`, `resources.tidal.com`.
  Audio CDN URLs in manifests are **passed through to the speaker
  un-fetched** (finding 12); no validation/HEAD step exists.
- **D4 — Rate limiting.** Token bucket 1 req/300 ms burst 3, executed
  INSIDE `tidalclient.Do` (counts against the lock hold, deliberately —
  serializes upstream pressure); 429 → backoff, max 2 retries; one shared
  `http.Client`, 10 s timeout.
- **D5 — Speaker visibility.** `bmx_services.json` TIDAL entry
  (`id {name:"TIDAL", value:24}`, `baseUrl "{BMX_SERVER}/bmx/tidal"`,
  `authenticationModel.anonymousAccount {autoCreate, enabled}`, icons under
  `static/media/bmx-icons/tidal/`), availability JSON entry, default source
  canonical ID 10006 in `getDefaultSources()`/`getInitialSources()`
  (`SourceKeyType "TIDAL"`, `SourceProviderID "24"`, `Type "Audio"`,
  `SecretType "token"`, `Secret: GenerateSerialSecret("tidal")`), plus
  `extractIDs` arm + canonical-defaults support.
- **D6 — Favorites, recents, reporting (fixes finding 13).**
  `SaveTidalFavorite`/`DeleteTidalFavorite` marker files
  (`<data>/tidal/favorites/{trackID}`). `"TIDAL"` added to
  `IsStreamingContent()`; `GetTidalItems()` in recents.go. The `/v1/report`
  handler (eventType START) persists the playing track as a recents
  ContentItem (sanitized, capped like existing recents) — otherwise
  recents have no writer.
- **D7 — Handler conventions.** Log-only auth gate (mirrors TuneIn),
  `sanitizeLog` on logged user input, `202 {}` favorites, report returns
  `nextReportIn: 1800` on START. The `/v1/token` echo endpoint is kept
  ONLY for recording-compat with Stockholm, gated behind a comment and a
  test (finding 14a).
- **D8 — Unlinked-account contract (fixes finding 5).** When no Tidal
  account is linked: navigate returns one informational section
  ("Link TIDAL in the AfterTouch settings"); search returns the same;
  playback returns 503 with a plain-text body the speaker surfaces as a
  playback failure. `anonymousAccount.autoCreate` means any LAN speaker
  uses the operator's subscription — documented in README (finding 15).
- **D9 — Graceful scope degradation (fixes finding 6).** T1 must verify the
  device-flow grant's scopes cover every catalog call used (incl.
  user playlists). If `user-playlists` returns 403 at runtime, that section
  is omitted from browse; browse itself never fails on it.

## 4. Route table (new, under existing `/bmx` mount)

```
GET    /bmx/tidal/                               HandleTidalService
GET    /bmx/tidal/v1/navigate                    top-level browse (user playlists if linked, else per D8)
GET    /bmx/tidal/v1/navigate/{kind}/{id}        artist|album|playlist|user-playlists
GET    /bmx/tidal/v1/search?q=                   HandleTidalSearch (per-section cursors)
GET    /bmx/tidal/v1/search/next?cursor=         HandleTidalSearchNext (single-type)
GET    /bmx/tidal/v1/playback/track/{trackID}    single track (trackurl)
GET    /bmx/tidal/v1/playback/list/{kind}/{id}   album|playlist play-all (tracklisturl; finding 3)
POST   /bmx/tidal/v1/token                       recording-compat echo (D7)
POST   /bmx/tidal/v1/report                      report + recents writer (D6)
POST   /bmx/tidal/v1/favorite/{trackID}
DELETE /bmx/tidal/v1/favorite/{trackID}
```

Tracklist responses return a ContentItem of type `tracklisturl` whose items
each reference `/v1/playback/track/{trackID}` — the same shape TuneIn uses
for podcast episodes.

Web player (`mount.go`): `/api/control/providers/tidal/{navigate,navigate/*,search,search/next}`,
`/api/control/devices/{id}/providers/tidal/play`, SPA route `/app/tidal`.

## 5. Settings & secret hygiene (fixes finding 14b)

```go
TidalClientID      string `json:"tidal_client_id,omitempty"`
TidalClientSecret  string `json:"tidal_client_secret,omitempty"`
TidalStreamQuality string `json:"tidal_stream_quality,omitempty"` // default "LOSSLESS,HIGH"
```

`settings.json` written 0600 (verify/ tighten in T5). Token bundle lives in
`data/tidal/auth.json` (0600, atomic), never in settings.

## 6. Frontend

Twin of TuneInBrowser: `TidalBrowser.js` (breadcrumb browse, device-picker
play overlay, play-all button on album/playlist sections), `api.js` gains
`tidalBrowse/tidalSearch/tidalSearchNext/tidalPlay`, `app.js` nav entry +
`tidal-mono.svg`. Items: playback links `trackurl` for tracks,
`tracklisturl` for albums/playlists.

## 7. Testing strategy

- Unit: manifest accept-rule/ladder (table-driven), per-section cursor
  round-trip, nav mapping from canned Tidal fixtures, recents-writer.
- Package tests against mock Tidal upstream via `SetTidalEndpoints`
  (mirrors `SetTuneInEndpoints`), covering 429-retry and
  token-refresh-under-lock (concurrent-call test asserting exactly one
  refresh request — finding 2).
- Handler tests (in T3, not T2 — finding 9) incl. unlinked contract (D8).
- **Bench gate G1 (finding 4, before T2 merges):** replay a handcrafted
  onDemand `BmxPlaybackResponse` + a `tracklisturl` ContentItem to a real
  speaker; verify playback starts, `Duration` honored, and a tidal preset
  can be stored AND recalled. Negative result inverts D2 — resolve before
  continuing.
- `go build ./... && go test ./...` green incl. `docs_consistency_test.go`.

## 8. Risks

- **R1 Upstream key revocation** (mass revocation March 2026): credentials
  externalized; no baked-in fallback in the adapter.
- **R2 Account blocking**: D4 limiter; README warning.
- **R3 Manifest drift**: accept-rule failure → clean 502, sanitized log.
- **R4 Firmware container incompatibility** (#292): NONE-only policy; cost
  is no Hi-Res — accepted.
- **R5 Global-state coupling**: single facade (D1) is the only touch point
  if the vendor lib is replaced.
- **R6 LAN exposure (finding 15)**: any LAN device can use the linked paid
  account; documented; playback route may later reuse AfterTouch's
  device-token gate.

## 9. Deferred: firmware-native priming path

Speaker firmware has a baked-in TIDAL client; if its credentials still
authenticate, priming + OAuth-intercept (spotify-overview.md pattern) gives
native playback with no resolver. Bench task T9; its capture session also
produces the fixtures for gate G1. The resolver ships regardless — BMX
browse/search needs it either way.
