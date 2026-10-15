# Does the official client expose a drivable native local IPC?

Findings for the "driving options" question (see the driving-options discussion and
[`../DESIGN.md`](../DESIGN.md) §5.1, *Commands / UI*). This evaluates **option 3**:
driving the boxed reference KakaoTalk Windows client through an IPC the client
*already exposes between its own processes* — a named pipe, a localhost TCP
socket, or a local HTTP endpoint — with **no injected hook and no UI scripting**.

This is a methodology/findings note. Per [`../DESIGN.md`](../DESIGN.md) §11 it
contains no credentials, captures, device identifiers, binary addresses, or
decompiled source. No proprietary client was installed or run to produce it;
§4 below is an **operator-run** check for a disposable, owned machine.

---

## 1. Verdict

**No evidence of a drivable native local IPC — treat as "does not exist for this
purpose" unless an owned-install check (§4) proves otherwise.**

More precisely:

- **Public evidence: none.** No documentation, reverse-engineering write-up, or
  third-party project describes a command-shaped local interface the KakaoTalk PC
  client exposes for reading or sending messages. Every project that drives the
  desktop client uses one of three *other* mechanisms (§2).
- **Architectural prior: low.** The client's likely process model (§3) gives it no
  reason to run a drivable local command surface. The local endpoints such a
  client *does* open are for its own transport, updater, or single-instance
  coordination — not a documented, stable action API.
- **Definitive confirmation is cheap** and is an owned-install check, not more
  OSINT (§4). The strong prior is "no"; one operator can settle it in minutes.

Consequence for the roadmap: option 3 is **not** a path to lean on. The two viable
driving mechanisms remain the injected hook with a command RPC (option 2, scoped
in [`driving.md`](driving.md)) and speaking the protocol directly (option 1). This
note feeds that comparison in §5.

---

## 2. OSINT: what the ecosystem actually does

The whole third-party ecosystem is the strongest available signal. If the client
exposed an easy local command socket, projects would use it in preference to the
far harder paths they actually take (decrypting a SQLCipher database, or
reverse-engineering a private wire protocol). None do.

Every project that drives or reads the **official desktop client** falls into one
of three buckets, and **none** uses a client-exposed IPC:

| Project | Platform | Mechanism | Native IPC? |
|---|---|---|---|
| `Bum-Boo/kakaotalk-local-mcp` | Windows | Win32 window navigation (UI) + optional local SQLCipher DB watcher | No — explicitly *no* "private network protocol"; drives via windows |
| `supaplex11/kakaocli-hybrid` (`jaehyunstewart/kakaocli`) | macOS | Read-only SQLCipher DB reads + Accessibility (`AXUIElement`) UI automation to send | No |
| `Amulopapa67/TalkLens` | macOS | Accessibility overlay (read-only) | No |
| `rokrokss/kakaotalk-bridge` | Server | Runs the **Android** client headlessly under redroid (read-only) | No (not the PC client) |
| `carpedm20/kakaotalk`, `hallazzang/pykakao`, `NetRiceCake/loco-wrapper`, KiwiTalk | — | Reimplement the **LOCO protocol** directly; the client is bypassed, not driven | N/A (option 1) |
| `frrad/mooo` (this project's sibling) | — | Speaks LOCO/the server protocol directly, derived from client *behavior* (static Mac trace + observed fixtures); does **not** drive the desktop client | N/A (option 1) |

Two observations that matter:

- **The DB + UI split keeps recurring.** When a project wants to touch the *running
  official client* (not reimplement the protocol), it reads the local database for
  **receive** and uses UI/accessibility/Win32-window automation for **send**. That
  split only exists *because* there is no command IPC to call — if there were,
  neither the SQLCipher decryption dance nor the UI poking would be necessary.
- **"socket" tags are the MCP/agent side, not Kakao.** Projects tagged `socket`
  (e.g. an MCP bridge) expose a socket *to the AI client*; that is the project's
  own server, not an interface KakaoTalk exposes. Do not mistake these for a
  client-native IPC.

Caveat on OSINT: absence in public sources is not proof of absence in the binary.
It is, however, a strong prior, because the incentive to discover and publish such
an interface (it would obsolete every UI-automation project) is high and has gone
unrealized for over a decade of community work.

## 3. Process-model reasoning (first principles)

Whether a desktop app exposes a local command IPC is largely determined by *why*
it would have one. The usual reasons, and how they apply here:

1. **Multi-process UI frameworks (Electron/Chromium/CEF).** These split into a
   broker process and renderer/GPU/utility processes and coordinate over an
   internal IPC (Mojo/named pipes). Such an IPC is a private, versioned, internal
   bus — *not* a stable public command API — but its existence at least creates a
   seam. **KakaoTalk PC is a native Win32 application** (installed as
   `KakaoTalk.exe` under `Program Files (x86)\Kakao\KakaoTalk`), not an
   Electron/Chromium app. So it does not inherit a Chromium-style IPC broker, and
   the strongest architectural reason for a local command bus is absent.
2. **Privileged helper / service split.** Some apps run a background service and a
   UI front-end that talk over a named pipe (updaters, VPNs, AV). A chat client
   *can* ship an auto-updater helper, but an updater pipe carries update commands,
   not "send message / open chat / fetch members." It is not a driving surface.
3. **Single-instance coordination.** Many Windows apps use a named pipe or a hidden
   window + `WM_COPYDATA` so a second launch hands its arguments (e.g. a clicked
   `kakaotalk://` link) to the already-running instance and exits. If KakaoTalk has
   anything pipe-shaped locally, **this is the most likely candidate** — and it is
   the worst possible driving surface: undocumented, carrying at most a URL/open
   intent, with no read path and no message-send semantics.
4. **The real network endpoints are outbound to Kakao.** The sockets the client
   opens are its transport to Kakao's servers (LOCO, historically a custom
   RSA-OAEP+AES-GCM layer, more recently reported to run over TLS with the same
   22-byte LOCO header). These are *client → server* connections, not a loopback
   command interface, and intercepting them is option 1 (protocol), not option 3.

**Conclusion of the reasoning:** the client has no architectural reason to expose a
loopback *command* API, and the one pipe-shaped thing it plausibly has
(single-instance / URL-handoff) is not drivable for read+send. This agrees with the
OSINT null result in §2.

## 4. The owned-install check that would settle it

The verdict above is a strong prior, not a proof. An operator with a disposable,
**owned** Windows machine and an owned test account can confirm or refute it
directly. This is the only part that needs the real client; **do not run it in this
repo's CI or on a shared machine**, and keep all output (which may contain account
or device identifiers) out of the repository (DESIGN §11).

Procedure (observe, do not modify):

1. **Enumerate named pipes** before and after launching the client, and diff:
   - Sysinternals `pipelist` (or PowerShell
     `Get-ChildItem \\.\pipe\`). Note any pipe that appears only once the client
     is running. A single-instance/URL pipe is expected (§3.3); anything
     command-shaped is the interesting case.
2. **Enumerate loopback listeners** owned by the client's PID(s):
   - Sysinternals `TCPView`, or `netstat -ano -p tcp` filtered to `127.0.0.1` /
     `[::1]`, cross-referenced to `KakaoTalk.exe` PIDs. A listener bound to
     loopback (not just outbound connections to Kakao's servers) is the thing to
     explain.
3. **Map the process tree** with Process Explorer: is it a lone `KakaoTalk.exe`, or
     a broker + helpers? Helpers sharing a private pipe would corroborate §3.1/3.2.
4. **Probe cautiously, read-only.** For any loopback TCP listener, a plain
   connect / minimal HTTP `GET /` reveals whether it speaks HTTP or something
   custom — *without* sending app commands. Do not fuzz; the goal is existence and
   shape, not exploitation.

**Pass/fail for "option 3 is viable":**

- **Viable (surprising):** a loopback listener or named pipe owned by the client
  that accepts structured requests mapping to read/send/open actions, stable enough
  to script. → Re-evaluate; this would beat option 2 on effort.
- **Not viable (expected):** only outbound server connections, plus at most a
  single-instance/URL-handoff pipe with no read/send semantics. → Confirms the
  verdict; proceed with option 2 / option 1.

The check is also worth re-running on each re-baseline (new client build), since a
future version could add a local interface (e.g. a companion/bot feature).

## 5. Comparison with option 2 (injected hook + command RPC)

| Dimension | Option 3: native IPC (if it existed) | Option 2: injected hook RPC ([`driving.md`](driving.md)) |
|---|---|---|
| Exists today? | No public evidence; strong prior "no" (§1–3) | Yes — a seam we build (`patches/`, `WINEDLLOVERRIDES`) |
| Driving surface | Would be whatever the client happens to expose (likely URL-open only) | Exactly the internal send/open/fetch paths we choose to call |
| Read path | None expected (receive would still need DB or protocol) | Same hook taps outputs → lands in the same contract bundle (DESIGN §6) |
| Coupling to internals | Lower *if* a documented surface existed | Higher — internal entry points move per release (DESIGN §12 re-baseline tax) |
| Scope-safety | Clean (no injected code) | Needs the §11/§12 discipline the hook doc already imposes |
| Net | Not available; even if present, too narrow to drive read+send | The realistic mechanism for driving the *reference* in Record/Shadow |

**Bottom line for [`driving.md`](driving.md):** option 3 does not provide a usable
driving mechanism and should be recorded as *evaluated and rejected, pending a
cheap owned-install re-check*. The hook-RPC (option 2) remains the way to drive the
boxed reference; speaking the protocol directly (option 1) remains the endgame for
the shipping candidate.

---

## Sources

- [Not so Secret: Analysis of KakaoTalk's Secret Chat E2EE](https://stulle123.github.io/posts/kakaotalk/secret-chat/)
- [carpedm20/kakaotalk — LOCO protocol (Python)](https://github.com/carpedm20/kakaotalk)
- [hallazzang/pykakao — LOCO/HTTP wrapper](https://github.com/hallazzang/pykakao)
- [NetRiceCake/loco-wrapper](https://github.com/NetRiceCake/loco-wrapper)
- [bpak.org — LOCO protocol analysis (2012, Korean)](https://www.bpak.org/blog/2012/12/kakaotalk-loco-%ED%94%84%EB%A1%9C%ED%86%A0%EC%BD%9C-%EB%B6%84%EC%84%9D-1/)
- [Bum-Boo/kakaotalk-local-mcp](https://github.com/Bum-Boo/kakaotalk-local-mcp)
- [supaplex11/kakaocli-hybrid](https://github.com/supaplex11/kakaocli-hybrid)
- [rokrokss/kakaotalk-bridge](https://github.com/rokrokss/kakaotalk-bridge)
- [KakaoTalk GitHub topic (ecosystem survey)](https://github.com/topics/kakaotalk?o=desc&s=updated)
- [KiwiTalk — unofficial cross-platform client](https://github.com/KiwiTalk/KiwiTalk)
- [Microsoft — Interprocess communication (IPC) on Windows](https://learn.microsoft.com/en-us/windows/apps/develop/communication/interprocess-communication)
