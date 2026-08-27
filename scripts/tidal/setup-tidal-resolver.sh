#!/usr/bin/env bash
# setup-tidal-resolver.sh
#
# One-time scaffold for the Tidal BMX resolver in AfterTouch.
# Run from the repo root of your Bose-SoundTouch fork:
#
#   bash scripts/tidal/setup-tidal-resolver.sh
#
# What it does:
#   1. Clones your tidal-dl fork (Tyler-M-HNV/tidal-dl) into .tidal-dl-src/
#      at a pinned commit (override with TIDAL_DL_REF).
#   2. Vendors the auth + playback packages into pkg/service/tidalapi/
#      and rewrites the module import path so `go build` resolves locally.
#   3. Prints a checklist of the wiring that still has to be done by hand
#      (routes, service descriptor, settings fields).
#
# It deliberately does NOT generate Go adapter code or touch go.mod —
# that part deserves an editor, not sed.

set -euo pipefail

TIDAL_DL_FORK="${TIDAL_DL_FORK:-https://github.com/Tyler-M-HNV/tidal-dl.git}"
TIDAL_DL_REF="${TIDAL_DL_REF:-main}"
SRC_DIR=".tidal-dl-src"
VENDOR_DIR="pkg/service/tidalapi"

# --- preconditions -----------------------------------------------------------

if [[ ! -f go.mod ]] || ! grep -q "github.com/gesellix/bose-soundtouch" go.mod; then
  echo "error: run this from the root of the Bose-SoundTouch fork" >&2
  exit 1
fi

for tool in git go; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found" >&2; exit 1; }
done

# --- 1. fetch tidal-dl at a pinned ref --------------------------------------

if [[ -d "$SRC_DIR/.git" ]]; then
  echo "==> updating existing $SRC_DIR"
  git -C "$SRC_DIR" fetch --quiet origin
else
  echo "==> cloning $TIDAL_DL_FORK"
  git clone --quiet "$TIDAL_DL_FORK" "$SRC_DIR"
fi
git -C "$SRC_DIR" checkout --quiet "$TIDAL_DL_REF"
PINNED="$(git -C "$SRC_DIR" rev-parse HEAD)"
echo "==> pinned tidal-dl at $PINNED"

# --- 2. vendor auth + playback packages -------------------------------------

# tidal-dl layout (adjust here if upstream reshuffles):
#   auth/      device-code OAuth flow, token refresh
#   tidalapi/  catalog + playback info (GetPlaybackInfo -> BTS manifest)
PACKAGES=(auth tidalapi)

rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR"

for pkg in "${PACKAGES[@]}"; do
  if [[ ! -d "$SRC_DIR/$pkg" ]]; then
    echo "error: upstream package '$pkg' not found — check tidal-dl layout" >&2
    exit 1
  fi
  cp -r "$SRC_DIR/$pkg" "$VENDOR_DIR/$pkg"
done

# Rewrite imports: upstream module path -> local vendored path.
UPSTREAM_MODULE="$(grep '^module ' "$SRC_DIR/go.mod" | awk '{print $2}')"
LOCAL_MODULE="$(grep '^module ' go.mod | awk '{print $2}')/$VENDOR_DIR"
echo "==> rewriting imports: $UPSTREAM_MODULE -> $LOCAL_MODULE"
grep -rl "$UPSTREAM_MODULE" "$VENDOR_DIR" | while read -r f; do
  sed -i "s|$UPSTREAM_MODULE|$LOCAL_MODULE|g" "$f"
done

echo "$PINNED" > "$VENDOR_DIR/UPSTREAM-COMMIT"
cat > "$VENDOR_DIR/README.md" <<EOF
Vendored from $TIDAL_DL_FORK @ $PINNED
Regenerate with: bash scripts/tidal/setup-tidal-resolver.sh
Do not edit by hand — patch upstream and re-vendor instead.
EOF

# --- 3. build check ----------------------------------------------------------

echo "==> go build ./$VENDOR_DIR/..."
go build "./$VENDOR_DIR/..."

cat <<EOF

Done. Vendored tidal-dl ($PINNED) into $VENDOR_DIR/.

Remaining manual wiring (see docs/content/docs/appendix/EXTERNAL-SERVICES-ABSTRACTION.md
and the TuneIn adapter as the template):

  [ ] pkg/service/bmx/tidal.go          — model on tunein.go:
        Navigate/Search/Playback returning models.BmxNavResponse /
        models.BmxPlaybackResponse; use tidalapi GetPlaybackInfo and keep
        only manifests with encryptionType NONE (plain FLAC URLs) so
        BuildCustomStreamResponseFromURLs can consume them.
  [ ] pkg/service/handlers/handlers_bmx_tidal.go
        — model on handlers_bmx_tunein.go (chi routes under /bmx/tidal/).
  [ ] bmx_services.json                  — add the TIDAL service descriptor
        (copy the TUNEIN entry, swap names/ids).
  [ ] Settings                           — add TidalClientID/TidalClientSecret
        (externalized, NOT baked in — Tidal revoked leaked keys en masse
        in March 2026) plus the persisted device-flow refresh token.
  [ ] Frontend                           — TidalBrowser.js modeled on
        pkg/service/soundtouchweb/static/js/components/TuneInBrowser.js.
  [ ] Favorites/presets persistence      — mirror SaveTuneInFavorite.

Also on the bench: test whether the speaker firmware's baked-in Tidal
client still authenticates against Tidal (Spotify-style OAuth-intercept
priming) — if yes, that path is cheaper than this resolver for playback.
EOF
