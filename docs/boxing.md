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

### State-only snapshots (`prefix-state.sh`)

A full prefix snapshot is ~1.5 GB / ~13 s uncompressed on the current client,
because almost all of it is immutable base — Wine's own `C:\windows` (~1.4 GB) and
the installed client (~135 MB), which are identical every run and already live in
the image's read-only layers. The only state the client's output actually depends
on is the **registry + the Kakao app-data tree: ~3 MB.** `prefix-state.sh` operates
on exactly that set:

```sh
prefix-state.sh snapshot /work/state.tar      # ~3 MB, not 1.5 GB
prefix-state.sh diff     /work/state.tar       # path+size; add --hash for content
prefix-state.sh restore  /work/state.tar       # resets state only; base untouched
```

The state set (single source of truth, in the script): `system.reg`, `user.reg`,
`userdef.reg`, and `drive_c/users/*/AppData/{Local,Roaming,LocalLow}/Kakao` (plus
`drive_c/ProgramData/Kakao` if present); `Temp` is excluded as run noise. `restore`
clears those paths and extracts the baseline over them, leaving the base in place —
verified: a tampered base file survives a state restore.

Use `prefix-state.sh` for the per-run snapshot/restore/diff loop. Use the
full-prefix `prefix-snapshot.sh` only to re-baseline the whole box on a new client
release (DESIGN §9).

**Is the state set complete?** It is a *declared* set, validated by observation —
see "Validating the state set" in [`containment.md`](containment.md) for how to
enumerate what the client actually reads at runtime and confirm nothing
state-bearing falls outside it.

### Future: a layered prefix

The state-only tool makes the snapshot loop cheap, but the prefix is still one
directory. The structural version splits it, following the Matrix–WeChat
`wechat-box` precedent (immutable Wine base image + mounted-in payloads):

- **Immutable lower layer** — Wine + installed client, baked into the image,
  mounted **read-only**. A read-only base is also what makes "did the client try to
  write/read outside its state?" observable (an `EACCES`/`EROFS` is a signal).
- **Writable upper layer** — the state set, on a real volume or `tmpfs` (not on the
  container's own overlay — overlay-on-overlay fails; keep frequently-written state
  on a volume). Snapshot/restore then touches only this small layer.
- **A dedicated payload dir** (e.g. `drive_c/injector/`, as `injector-box` uses) for
  a future grey-box tap DLL, so a version-matched tap drops in and is swapped with
  zero prefix churn.

This pairs naturally with the network-interpose / clock-RNG work and pre-positions
the Tier 2 payload dir. Not built yet; tracked in `containment.md`'s roadmap.

## Scope and safety

`verify-launch.sh` stops at "the process launches and stays up." It does **not**
attempt login — that needs a disposable, owned test account and is done manually
(DESIGN §11). No credentials, captures, or device identifiers belong in the image
or the repo.

## Next increment: the injection spike

Once the launch spike passes, [`inject-spike.md`](inject-spike.md) ("Spike A") is
the next step: `make inject-spike` proves an injected DLL (`loadprobe.dll`) loads
into the boxed client under Wine and the client stays up. It is still account-free
and is the gate for both driving ([`driving.md`](driving.md)) and the read taps
([`instrumentation.md`](instrumentation.md)).
