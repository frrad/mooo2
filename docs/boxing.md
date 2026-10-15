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

## Prefix snapshot / restore (Tier 1 containment)

The filesystem/DB, the Wine registry, and the synthesized device identity all
live inside `$WINEPREFIX`, so one archive snapshots all three "Snapshot" channels
of DESIGN §5.1 at once. Three scripts (shipped in the image at
`/usr/local/bin/`, source under [`../docker/`](../docker/)) implement the
"restore to a known baseline before each run, diff after" loop from
[`containment.md`](containment.md):

```sh
# capture a clean baseline (e.g. right after a fresh boot, before login)
prefix-snapshot.sh /work/baseline.tar

# ... drive the client through a scenario ...

# see what it persisted (paths added / removed / size-changed)
prefix-diff.sh /work/baseline.tar            # fast: path + size
prefix-diff.sh /work/baseline.tar --hash     # also content (sha256)

# reset the prefix to the baseline for the next run
prefix-restore.sh /work/baseline.tar
```

- `prefix-snapshot.sh` writes a deterministic tar (sorted, zeroed owner/mtime) so
  an unchanged prefix hashes identically run to run. It does not modify the prefix.
- `prefix-restore.sh` stops `wineserver`, extracts to a staging dir, then swaps —
  a failed extraction leaves the old prefix intact. It refuses obviously wrong
  targets (`/`, `/home`, `$HOME`).
- `prefix-diff.sh` reports `+ added`, `- removed`, `~ changed` paths; it is
  path+size/hash level only. Decoding the records themselves is the Tier 2 storage
  tap (future work).

A full prefix snapshot is ~1.5 GB / ~13 s uncompressed on the current client — fine
for a bench, heavy for CI. Compression or an overlayfs lower layer is a future
optimization.

## Scope and safety

`verify-launch.sh` stops at "the process launches and stays up." It does **not**
attempt login — that needs a disposable, owned test account and is done manually
(DESIGN §11). No credentials, captures, or device identifiers belong in the image
or the repo.
