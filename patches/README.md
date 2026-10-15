# Grey-box tap seam

This directory is the **injection seam** for the grey-box taps described in
[`../DESIGN.md`](../DESIGN.md) §5.2. The §13.1 launch spike boxes the **unmodified**
client; real taps and drivers (the §5.2 seams) are attached *after* that passes and
are **not** committed (they carry version-specific offsets — §11, §12).

The one artifact committed here is [`loadprobe/`](loadprobe/): a do-nothing
injection probe that is **our own** code (no client internals, no offsets) and
proves only the *injection vector* — see
[`../docs/inject-spike.md`](../docs/inject-spike.md) (Spike A).

## How a tap will slot in (no code yet)

Two mechanisms the design implies, in preference order:

1. **Injected hook DLL via `WINEDLLOVERRIDES`.** Build a small Windows DLL that
   hooks the chosen seam (crypto/transport, storage, model, decision — §5.2),
   drop it into the Wine prefix, and set `KAKAO_HOOK_OVERRIDES` (consumed by
   [`../docker/entrypoint.sh`](../docker/entrypoint.sh)), e.g.
   `KAKAO_HOOK_OVERRIDES="kakaotap=n,b"`. The entrypoint wires it into
   `WINEDLLOVERRIDES`; nothing else changes.

2. **Reviewed post-install binary patch.** A patch applied to the installed
   client inside the image (a build stage that runs after `box-install.sh`).
   Patches live here as reviewed artifacts.

## Hard rules (DESIGN §11)

- **No proprietary bytes or binary-specific addresses** in this repo — tap
  offsets move every release (§12) and are not committed.
- No credentials, captures, device identifiers, or decrypted data.
- Taps are implementation-neutral tooling that produce the contract bundle (§6);
  they are added as separate, reviewed work.
