#!/bin/sh
# toryo installer: one-line install of the headless CLI on macOS, Linux and WSL2.
#
#   curl -fsSL https://raw.githubusercontent.com/ForceBuilders/toryo-releases/main/install.sh | sh
#
# Downloads toryo-<v>-<os>-<arch>.tar.gz from the public releases repo, verifies
# SHA256SUMS against a minisign signature (when the tool is available) and the
# tarball against SHA256SUMS, extracts it into ~/.toryo/bin, and runs
# `toryo setup`. This is the same artifact `toryo update` consumes, so a fresh
# install and a self-update land identical bytes.
#
# The macOS tarballs are signed and notarized by Apple; the Linux ones are
# cross-compiled on the same Mac and carry no OS-level signature, which is what
# the minisign check over SHA256SUMS exists for.
#
# Env overrides:
#   TORYO_HOME             install root (default ~/.toryo)
#   TORYO_UPDATE_CHANNEL   owner/repo of the releases repo (default ForceBuilders/toryo-releases)
#   TORYO_VERSION          pin an explicit version (default: latest release)
#   TORYO_PRINT_ASSET=1    print the asset name this machine resolves to, then exit
#   TORYO_SKIP_SETUP=1     extract only, don't run `toryo setup`
#   TORYO_SKIP_SKILLS=1    don't install the /-command skills into the harness skills roots
set -eu

REPO="${TORYO_UPDATE_CHANNEL:-ForceBuilders/toryo-releases}"
TORYO_HOME="${TORYO_HOME:-$HOME/.toryo}"
BIN="$TORYO_HOME/bin"

# The release signing key's public half. Rotated with
# `bun scripts/gen-release-keypair.ts`; must stay byte-identical to
# RELEASE_PUBLIC_KEY in packages/minisign/src/keys.ts, which
# scripts/tests/install-sh.test.ts asserts.
PUBKEY='untrusted comment: toryo release key C7EE1C6DD07ADC5B
RWRb3HrQbRzux4O8CkBYUHAQrlJ5pmxQ2a4SaVF6rGE5x+jN0J0J5K4y'

die() {
  echo "toryo install: $1" >&2
  exit 1
}

# --- platform ---------------------------------------------------------------
case "$(uname -s)" in
  Darwin) os="darwin" ;;
  Linux) os="linux" ;;
  *) die "unsupported operating system: $(uname -s) (macOS, Linux and WSL2 are supported; native Windows is not)" ;;
esac

case "$(uname -m)" in
  arm64 | aarch64) arch="arm64" ;;
  x86_64 | amd64) arch="x64" ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

# WSL2 is Linux and installs the Linux artifact; saying so out loud is what
# stops a user reporting "the Windows installer" as broken.
wsl=""
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
  wsl="1"
fi

if [ -n "${TORYO_VERSION:-}" ]; then
  version="${TORYO_VERSION#v}"
  tag="v${version}"
else
  version=""
fi

# A debugging affordance, and what lets scripts/tests/install-sh.test.ts check
# the mapping above per platform without a network call. Before everything.
if [ "${TORYO_PRINT_ASSET:-0}" = "1" ]; then
  echo "toryo-${version:-<version>}-${os}-${arch}.tar.gz"
  exit 0
fi

command -v curl >/dev/null 2>&1 || die "curl is required"

# Most Linux distributions ship coreutils' sha256sum and no shasum at all, so
# requiring shasum outright killed the install before it started.
if command -v shasum >/dev/null 2>&1; then
  sha256c="shasum -a 256 -c"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256c="sha256sum -c"
else
  die "one of shasum or sha256sum is required"
fi

# --- resolve version --------------------------------------------------------
if [ -z "$version" ]; then
  echo "resolving latest toryo release from $REPO…"
  tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep '"tag_name"' | head -1 \
    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  [ -n "$tag" ] || die "could not resolve latest release (is $REPO public and does it have a release?)"
  version="${tag#v}"
fi

asset="toryo-${version}-${os}-${arch}.tar.gz"
base="https://github.com/$REPO/releases/download/$tag"
echo "installing toryo $version ($os-$arch)"
[ -z "$wsl" ] || echo "detected WSL2: installing the Linux build inside this distro"

# --- download + verify ------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading $asset…"
curl -fSL --progress-bar "$base/$asset" -o "$tmp/$asset" || die "download failed: $base/$asset"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" || die "download failed: $base/SHA256SUMS"

# SHA256SUMS travels from the same host as the tarball, so on its own it proves
# only that the download is self-consistent. minisign checks it against a key
# that never crossed the network.
if command -v minisign >/dev/null 2>&1; then
  curl -fsSL "$base/SHA256SUMS.minisig" -o "$tmp/SHA256SUMS.minisig" \
    || die "download failed: $base/SHA256SUMS.minisig"
  printf '%s\n' "$PUBKEY" > "$tmp/toryo.pub"
  # Unredirected on purpose: on success minisign echoes the trusted comment, which
  # names the version the signature actually covers. It is signed too (see
  # packages/minisign/src/format.ts), so it is the one field worth reading.
  minisign -V -p "$tmp/toryo.pub" -m "$tmp/SHA256SUMS" \
    || die "signature verification failed for SHA256SUMS; do not install this download"
else
  echo ""
  echo "  WARNING: minisign is not installed, so the SHA256SUMS signature was NOT checked."
  echo "  The checksum below proves the download is intact, not that we published it."
  echo "  Install it and re-run to get the full check:"
  echo "    macOS:  brew install minisign"
  echo "    Debian: sudo apt install minisign"
  echo ""
fi

# Verify only our tarball's line (SHA256SUMS also lists the other platforms' tarballs and the dmg).
grep " $asset\$" "$tmp/SHA256SUMS" > "$tmp/SHA256SUMS.one" \
  || die "$asset is not listed in SHA256SUMS"
( cd "$tmp" && $sha256c SHA256SUMS.one >/dev/null 2>&1 ) \
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

# Install the operator /-commands (namespaced toryo-*) into both skills roots,
# ~/.claude/skills and ~/.agents/skills, so every harness picks them up.
if [ "${TORYO_SKIP_SKILLS:-0}" = "1" ]; then
  echo "TORYO_SKIP_SKILLS=1 — skipping 'toryo skills install'."
else
  echo "installing toryo skills…"
  "$BIN/toryo" skills install || echo "  (skills install skipped — no bundle found)"
fi

echo ""
echo "toryo $version installed. If 'toryo' isn't found, add ~/.toryo/bin to your PATH:"
echo "  export PATH=\"$BIN:\$PATH\""
