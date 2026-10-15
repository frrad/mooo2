# Grey-box tap seam

This directory is the **injection seam** for the grey-box taps described in
[`../DESIGN.md`](../DESIGN.md) §5.2. The §13.1 launch spike boxes the **unmodified**
client; real taps and drivers (the §5.2 seams) are attached *after* that passes and
are **not** committed (they carry version-specific offsets — §11, §12).

The artifacts committed here are **our own** code (no client internals, no
offsets) and prove only the *injection vector* (Spike A — see
[`../docs/inject-spike.md`](../docs/inject-spike.md)):

- [`loadprobe/`](loadprobe/) — a do-nothing probe: the `DllMain` body that records
  it was loaded.
- [`dllproxy/`](dllproxy/) — generates forwarder exports so the probe can ride in
  as a proxy of a client-bundled import without breaking it.

## How a tap will slot in

The injection vector proven by Spike A is **proxying a client-bundled import**
(`AppInit_DLLs` is not honored by Wine; see inject-spike.md). A real tap/driver
reuses that vector, in preference order:

1. **Injected hook DLL.** A small Windows DLL that hooks the chosen seam
   (crypto/transport, storage, model, decision — §5.2), loaded by proxying a
   bundled module (as the probe does) and, where a seam module must be forced
   native, selected via `KAKAO_HOOK_OVERRIDES` → `WINEDLLOVERRIDES` (wired in
   [`../docker/entrypoint.sh`](../docker/entrypoint.sh)).

2. **Reviewed post-install binary patch.** A patch applied to the installed
   client inside the image (a build step after `box-install.sh`). Patches live
   here as reviewed artifacts.

The chosen seam module, its entry points, and any offsets are **not** committed
(§11, §12); only our implementation-neutral tooling is.

## Hard rules (DESIGN §11)

- **No proprietary bytes or binary-specific addresses** in this repo — tap
  offsets move every release (§12) and are not committed.
- No credentials, captures, device identifiers, or decrypted data.
- Taps are implementation-neutral tooling that produce the contract bundle (§6);
  they are added as separate, reviewed work.
