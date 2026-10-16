#!/usr/bin/env bash
# Network interpose check (docs/containment.md "Network"; DESIGN §8 Shadow gate).
# Like verify-launch.sh it does NOT log in and needs no account. It proves:
#   1. the UNMODIFIED client still launches and stays up behind default-deny egress;
#   2. blocked egress is observable: a probe running as the boxed user makes a DNS
#      lookup, a TLS connection and a UDP send, and each is denied and logged (the
#      TLS server name included) or counted;
#   3. the allow path and ingress fan-out work: an allowlisted connection to a test
#      server inside the container is spliced through, and the server's reply is
#      delivered both to the probe and, identically, to a fan-out subscriber.
# On a Docker user-defined network it also queries Docker's embedded resolver
# directly on its real port, which must be dropped.
# It also lists what the client itself tried to reach, which is the starting point
# for the login spike's allowlist (see docs/boxing.md).
#
# Needs root + CAP_NET_ADMIN:  docker run --rm --cap-add NET_ADMIN -u 0 <image> verify-net.sh
# Optional: NET_ALLOWLIST=/path/file (operator allowlist, merged in). Default is the
# image's /etc/kakao/net-allowlist, which ships with no entries.
set -euo pipefail

HOLD="${LAUNCH_HOLD_SECONDS:-20}"
: "${WINEPREFIX:?WINEPREFIX must be set}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NET_RUN_DIR="${NET_RUN_DIR:-/tmp/net-interpose}"
EVENTS="$NET_RUN_DIR/events.jsonl"
FANOUT_PORT=15002
TEST_PORT=18080
TEST_REPLY="interpose-fanout-ok"
BOX=(setpriv --reuid=wine --regid=wine --clear-groups env HOME=/home/wine)

if [ "$(id -u)" != 0 ]; then
  echo "FAIL: verify-net.sh must run as root with CAP_NET_ADMIN, e.g.:" >&2
  echo "        docker run --rm --cap-add NET_ADMIN -u 0 <image> verify-net.sh" >&2
  exit 2
fi

# KAKAO_EXE is set by prefix-layer.sh run (the client's path inside the layer).
EXE="${KAKAO_EXE:-$(cat /home/wine/.kakao_exe_path 2>/dev/null || true)}"
if [ -z "$EXE" ] || [ ! -f "$EXE" ]; then
  EXE="$(find "$WINEPREFIX/drive_c" -iname 'KakaoTalk.exe' 2>/dev/null | head -1 || true)"
fi
[ -n "$EXE" ] || { echo "FAIL: KakaoTalk.exe not found in prefix" >&2; exit 1; }

# The container's own address: the allow-path test server listens there. A UDP
# connect sends nothing; it only picks the source address.
SELF_IP="$(python3 -c 'import socket;s=socket.socket(2,2);s.connect(("192.0.2.1",9));print(s.getsockname()[0])' 2>/dev/null || true)"
[ -n "$SELF_IP" ] && [ "${SELF_IP#127.}" = "$SELF_IP" ] \
  || { echo "FAIL: no non-loopback address (run on a Docker network, not --network none)" >&2; exit 1; }

# On a Docker user-defined network, the embedded resolver's real UDP port (the
# target of Docker's own 127.0.0.11:53 DNAT). The probe queries it directly: that
# must be dropped too. Empty on the default bridge, which has no such resolver.
RESOLVER_PORT="$(nft list chain ip nat DOCKER_POSTROUTING 2>/dev/null \
  | awk '/127.0.0.11 udp sport/{for(i=1;i<=NF;i++) if($i=="sport") print $(i+1)}' | head -1 || true)"

mkdir -p "$NET_RUN_DIR"
PIDS=()
cleanup() {
  wineserver -k >/dev/null 2>&1 || true
  pkill -9 -u wine >/dev/null 2>&1 || true
  "$HERE/net-interpose.sh" down || true
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

# --- Test server (root, so its replies are not interposed) + fan-out subscriber --
python3 - "$SELF_IP" "$TEST_PORT" "$TEST_REPLY" <<'EOF' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], int(sys.argv[2]))); s.listen(4)
while True:
    c, _ = s.accept(); c.recv(64); c.sendall(sys.argv[3].encode() + b"\n"); c.close()
EOF
PIDS+=($!)

ALLOW_ARGS=(--allow "$SELF_IP:$TEST_PORT" --fanout "127.0.0.1:$FANOUT_PORT")
NET_ALLOWLIST="${NET_ALLOWLIST:-/etc/kakao/net-allowlist}"
[ -f "$NET_ALLOWLIST" ] && ALLOW_ARGS+=(--allowlist "$NET_ALLOWLIST")
"$HERE/net-interpose.sh" up "${ALLOW_ARGS[@]}"

python3 - "$FANOUT_PORT" "$NET_RUN_DIR/fanout.jsonl" <<'EOF' &
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
with open(sys.argv[2], "wb", buffering=0) as f:
    while True:
        d = s.recv(65536)
        if not d: break
        f.write(d)
EOF
PIDS+=($!)
sleep 1   # let the subscriber attach before any allowed flow starts

# --- The unmodified client, as the boxed user, behind the interpose -------------
echo ">> launching: $EXE (hold ${HOLD}s)"
"${BOX[@]}" wine "$EXE" >/tmp/kakao.log 2>&1 &
disown $!   # cleanup SIGKILLs it; keep bash from reporting the job

# --- Probes, as the boxed user (so they hit the same rules as the client) -------
"${BOX[@]}" python3 - "$SELF_IP" "$TEST_PORT" "${RESOLVER_PORT:-0}" >"$NET_RUN_DIR/probe.log" 2>&1 <<'EOF' || true
import socket, ssl, struct, sys
self_ip, port, rport = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    print("dns", socket.gethostbyname("probe-blocked.example"))
except OSError as e:
    print("dns-error", e)
try:
    ctx = ssl.create_default_context()
    with socket.create_connection(("192.0.2.1", 443), timeout=5) as raw:
        ctx.wrap_socket(raw, server_hostname="probe-blocked.example")
    print("tls connected (unexpected)")
except (OSError, ssl.SSLError) as e:
    print("tls-blocked", type(e).__name__)
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    u.sendto(b"probe", ("192.0.2.1", 123)); print("udp sent")
except OSError as e:
    print("udp-error", e)
if rport:
    q = struct.pack("!HHHHHH", 0x6b6b, 0x0100, 1, 0, 0, 0)
    q += b"".join(bytes([len(l)]) + l.encode() for l in "probe-direct.example".split(".")) + b"\0"
    q += struct.pack("!HH", 1, 1)
    r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); r.settimeout(3)
    try:
        r.sendto(q, ("127.0.0.11", rport)); r.recvfrom(512); print("resolver-direct answered")
    except OSError as e:
        print("resolver-direct blocked", type(e).__name__)
with socket.create_connection((self_ip, port), timeout=10) as c:
    c.sendall(b"ping\n"); print("allow-reply", c.recv(64).decode().strip())
EOF

sleep "$HOLD"
ALIVE=0
pgrep -fi 'KakaoTalk.exe' >/dev/null 2>&1 && ALIVE=1
COUNTERS="$("$HERE/net-interpose.sh" counters)"
cleanup
trap - EXIT

echo "----- probe -----"; cat "$NET_RUN_DIR/probe.log"
echo "----- dropped (nftables) -----"; echo "$COUNTERS"

# --- Judge ---------------------------------------------------------------------
REPORT="$(python3 - "$EVENTS" "$NET_RUN_DIR/fanout.jsonl" "$NET_RUN_DIR/probe.log" \
            "$TEST_REPLY" "$COUNTERS" "${RESOLVER_PORT:-}" <<'EOF'
import base64, json, sys
events = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
fan = [json.loads(l) for l in open(sys.argv[2]) if l.strip()] if __import__("os").path.exists(sys.argv[2]) else []
probe = open(sys.argv[3]).read()
reply = sys.argv[4]
counters = dict(kv.split("=") for kv in sys.argv[5].split())
PROBE = "probe-blocked.example"
checks = {
    "dns-deny-logged": any(e.get("kind") == "dns" and e.get("verdict") == "deny"
                           and e.get("name") == PROBE for e in events),
    "tls-deny-logged": any(e.get("kind") == "tcp" and e.get("verdict") == "deny"
                           and e.get("dst") == "192.0.2.1" and e.get("sni") == PROBE
                           for e in events),
    "udp-dropped": int(counters.get("drop_udp") or 0) >= 1,
    "allow-spliced": ("allow-reply " + reply) in probe,
    # Only on a user-defined network (sys.argv[6] = the resolver's real port).
    "resolver-direct-dropped": (not sys.argv[6]) or (
        "resolver-direct blocked" in probe and int(counters.get("drop_resolver") or 0) >= 1),
    "fanout-ingress": any(f.get("dir") == "in" and base64.b64decode(f["b64"]).decode(
                          "ascii", "replace").strip() == reply for f in fan),
}
# What the client itself tried (everything that is not a probe).
client = sorted({"%s %s%s" % (e["kind"], e.get("name") or e.get("dst"),
                              ":%d" % e["port"] if "port" in e else "")
                 for e in events if e.get("verdict") == "deny"
                 and e.get("name") != PROBE and e.get("dst") != "192.0.2.1"})
print("checks:", " ".join("%s=%s" % (k, "ok" if v else "MISSING") for k, v in checks.items()))
print("client-denied:", len(client))
for c in client:
    print("  " + c)
print("RESULT", "ok" if all(checks.values()) else "bad")
EOF
)"
echo "----- interpose report -----"; echo "$REPORT"

if [ "$ALIVE" -eq 1 ] && grep -q '^RESULT ok' <<<"$REPORT"; then
  N="$(awk '/^client-denied:/{print $2}' <<<"$REPORT")"
  echo "PASS: KakaoTalk stayed up ${HOLD}s behind default-deny egress; probe egress denied+logged, allow path and fan-out OK; client denied attempts: ${N}"
  exit 0
fi

echo "FAIL: network interpose check did not pass" >&2
[ "$ALIVE" -eq 1 ] || { echo "  - client not running after ${HOLD}s" >&2; echo "----- wine log -----" >&2; cat /tmp/kakao.log >&2 || true; }
grep -q '^RESULT ok' <<<"$REPORT" || echo "  - interpose checks failed (see report above)" >&2
echo "----- daemon log -----" >&2; cat "$NET_RUN_DIR/daemon.log" >&2 || true
exit 1
