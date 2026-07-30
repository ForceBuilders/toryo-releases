#!/bin/sh
# toryo installer — one-line install of the headless CLI on macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/ForceBuilders/toryo-releases/main/install.sh | sh
#
# Downloads the signed + notarized toryo-<v>-darwin-<arch>.tar.gz from the public
# releases repo, verifies its sha256 against SHA256SUMS, extracts it into
# ~/.toryo/bin, and runs `toryo setup`. This is the same artifact `toryo update`
# consumes, so a fresh install and a self-update land identical bytes.
#
# Env overrides:
#   TORYO_HOME             install root (default ~/.toryo)
#   TORYO_UPDATE_CHANNEL   owner/repo of the releases repo (default ForceBuilders/toryo-releases)
#   TORYO_VERSION          pin an explicit version (default: latest release)
#   TORYO_SKIP_SETUP=1     extract only, don't run `toryo setup`
#   TORYO_SKIP_SKILLS=1    don't install the /-command skills into ~/.claude/skills
set -eu

REPO="${TORYO_UPDATE_CHANNEL:-ForceBuilders/toryo-releases}"
TORYO_HOME="${TORYO_HOME:-$HOME/.toryo}"
BIN="$TORYO_HOME/bin"

die() {
  echo "toryo install: $1" >&2
  exit 1
}

# --- platform ---------------------------------------------------------------
os="$(uname -s)"
[ "$os" = "Darwin" ] || die "this installer supports macOS only (got $os); Linux/Windows are later phases"

case "$(uname -m)" in
  arm64) arch="arm64" ;;
  x86_64) arch="x64" ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v shasum >/dev/null 2>&1 || die "shasum is required"

# --- resolve version --------------------------------------------------------
if [ -n "${TORYO_VERSION:-}" ]; then
  version="${TORYO_VERSION#v}"
  tag="v${version}"
else
  echo "resolving latest toryo release from $REPO…"
  tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | head -1 \
    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  [ -n "$tag" ] || die "could not resolve latest release (is $REPO public and does it have a release?)"
  version="${tag#v}"
fi

asset="toryo-${version}-darwin-${arch}.tar.gz"
base="https://github.com/$REPO/releases/download/$tag"
echo "installing toryo $version ($arch)"

# --- download + verify ------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading $asset…"
curl -fSL --progress-bar "$base/$asset" -o "$tmp/$asset" || die "download failed: $base/$asset"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" || die "download failed: $base/SHA256SUMS"

# Verify only our tarball's line (SHA256SUMS may also list board.dmg).
grep " $asset\$" "$tmp/SHA256SUMS" > "$tmp/SHA256SUMS.one" \
  || die "$asset is not listed in SHA256SUMS"
( cd "$tmp" && shasum -a 256 -c SHA256SUMS.one >/dev/null 2>&1 ) \
  || die "checksum verification failed for $asset"
echo "checksum verified."

# --- extract ----------------------------------------------------------------
mkdir -p "$BIN"
tar -xzf "$tmp/$asset" -C "$BIN"
echo "extracted to $BIN"

# --- provision --------------------------------------------------------------
if [ "${TORYO_SKIP_SETUP:-0}" = "1" ]; then
  echo "TORYO_SKIP_SETUP=1 — skipping 'toryo setup'."
else
  echo "running toryo setup…"
  "$BIN/toryo" setup
fi

# Install the operator /-commands into ~/.claude/skills (namespaced toryo-*).
if [ "${TORYO_SKIP_SKILLS:-0}" = "1" ]; then
  echo "TORYO_SKIP_SKILLS=1 — skipping 'toryo skills install'."
else
  echo "installing toryo skills…"
  "$BIN/toryo" skills install || echo "  (skills install skipped — no bundle found)"
fi

echo ""
echo "toryo $version installed. If 'toryo' isn't found, add ~/.toryo/bin to your PATH:"
echo "  export PATH=\"$BIN:\$PATH\""
