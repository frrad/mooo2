# Boxing the reference client (Wine pipeline)

This is the reproducible pipeline for DESIGN.md §10 ("Hosting the reference") and
roadmap step 1, the **Wine spike** (§13.1): box the official KakaoTalk Windows
client under Wine in a container and prove it launches headlessly. The grey-box
taps (§5.2) are a later, reviewed step — the [`patches/`](../patches/) seam is
empty for now.

## Quick start

```sh
make fetch    # download the pinned x64 installer into vendor/ and verify its SHA256
make build    # build the image: Debian + Wine, client installed into the prefix
make run      # launch spike: PASS if the client runs under Wine headlessly
make shell    # interactive shell in the image to poke at the prefix
```

`make build` depends on `make fetch`, so `make build` alone is enough after a
clean checkout.

## What is pinned, and how

| Thing | Pin | Where |
|-------|-----|-------|
| Installer bytes | SHA256 | [`../SHA256SUMS`](../SHA256SUMS), checked by `make verify` |
| Debian base | manifest digest | `DEBIAN_DIGEST` in [`../Dockerfile`](../Dockerfile) |
| Wine | exact WineHQ apt version | `WINE_VERSION` in the Dockerfile |
| winetricks | release tag | `WINETRICKS_VERSION` in the Dockerfile |

The installer itself is **never committed** (it is proprietary; see DESIGN §11).
Only its SHA256 is tracked. `vendor/` is gitignored.

### The installer URL is a rolling "latest"

`https://app-pc.kakaocdn.net/talk/win32/x64/KakaoTalk_Setup.exe` has no version in
its path — it always serves the current build. So "pinned" means the bytes must
match `SHA256SUMS`. When Kakao ships a new client, `make fetch` fails with a
checksum mismatch. **That is by design** (DESIGN §9): a new upstream build is a
deliberate re-baseline event, not a silent upgrade.

## Re-baselining on a new client release

```sh
make rebaseline   # re-download, rewrite SHA256SUMS
```

Then review and commit the new `SHA256SUMS`, rebuild, and **re-baseline any
grey-box taps** — tap offsets move every release (DESIGN §12).

## Reproducibility notes

- The hard pins (installer bytes, base image digest, Wine version, winetricks tag)
  are exact. `apt-get update` for the WineHQ/Debian repos still reaches live
  mirrors, so transitive apt dependencies are only as reproducible as those
  mirrors at build time — acceptable for a bench oracle, and documented here.
- Scripts live under [`../docker/`](../docker/): `box-install.sh` (build-time
  silent install), `entrypoint.sh` (headless X + tap seam), `verify-launch.sh`
  (the spike's pass/fail check).

## Scope and safety

`verify-launch.sh` stops at "the process launches and stays up." It does **not**
attempt login — that needs a disposable, owned test account and is done manually
(DESIGN §11). No credentials, captures, or device identifiers belong in the image
or the repo.
