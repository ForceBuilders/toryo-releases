# toryo-releases

Distribution channel for [toryo](https://docs.toryo.ai). This repository holds
the installer and the signed release artifacts — nothing else. **toryo's source
is closed;** it is not here and not public.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ForceBuilders/toryo-releases/main/install.sh | sh
```

macOS only for now. The installer resolves the latest release, downloads the
signed + notarized tarball for your architecture, verifies it against
`SHA256SUMS`, extracts it into `~/.toryo/bin`, and runs `toryo setup`.

## Documentation

**[docs.toryo.ai](https://docs.toryo.ai)** — requirements, setup, licensing, and
the full CLI reference. Start there; this README exists so the install URL
resolves, not to duplicate it.

## What's in a release

| Asset | |
|---|---|
| `toryo-<version>-darwin-<arch>.tar.gz` | the CLI binaries |
| `board.dmg` | the desktop console, when a build is attached |
| `SHA256SUMS` | `shasum -a 256` over the above |

Verify by hand if you'd rather not trust the installer to do it:

```sh
shasum -a 256 -c SHA256SUMS
```

## Updating

```sh
toryo update
```

Reads this same channel and lands the same bytes a fresh install does. board
does **not** auto-update during alpha — download a newer `.dmg` and replace it.
