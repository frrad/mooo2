#!/usr/bin/env bash
# Tier 1 containment (docs/containment.md, "Network"): default-deny egress for the
# boxed client, with every attempt logged, plus ingress fan-out for Shadow mode
# (DESIGN §8). Out-of-process: nothing touches the client binary.
#
# How: nftables rules in the container's network namespace, matched on the wine
# user's uid (the client, wineserver and every helper run as it):
#   - IPv4 DNS (port 53, any server, including Docker's 127.0.0.11) -> DNS stub
#   - every other IPv4 TCP connection off loopback                  -> TCP proxy
#   - loopback                                                      -> allowed
#   - anything else (UDP, ICMP, IPv6, ...)                          -> dropped, counted
# The stub and proxy are net-interpose.py, run as root so their own traffic is not
# redirected. Allowed flows are spliced to the real server and fanned out to
# subscribers; denied ones are logged and reset. An empty allowlist lets nothing out.
#
# Usage (root, with CAP_NET_ADMIN; e.g. docker run --cap-add NET_ADMIN -u 0 ...):
#   net-interpose.sh up [--allowlist FILE] [--allow ENTRY]... [--fanout HOST:PORT]
#   net-interpose.sh counters        # dropped-packet counters (non-DNS, non-TCP)
#   net-interpose.sh down
# Environment: NET_RUN_DIR (default /tmp/net-interpose) holds the decision log
# (events.jsonl) and the daemon's pid; NET_UID (default 1000) is the boxed user.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${NET_RUN_DIR:-/tmp/net-interpose}"
UID_BOX="${NET_UID:-1000}"
DNS_PORT=15353
TCP_PORT=15001
TABLE=kakao_net

need_root() {
  if [ "$(id -u)" != 0 ]; then
    echo "FAIL: net-interpose.sh must run as root with CAP_NET_ADMIN, e.g.:" >&2
    echo "        docker run --rm --cap-add NET_ADMIN -u 0 <image> verify-net.sh" >&2
    exit 2
  fi
}

ruleset() {
  cat <<EOF
table inet $TABLE {
  counter drop_udp {}
  counter drop_ipv6 {}
  counter drop_other {}

  chain nat_out {
    type nat hook output priority -100; policy accept;
    meta skuid $UID_BOX meta nfproto ipv4 udp dport 53 redirect to :$DNS_PORT
    meta skuid $UID_BOX meta nfproto ipv4 tcp dport 53 redirect to :$TCP_PORT
    meta skuid $UID_BOX ip daddr 127.0.0.0/8 return
    meta skuid $UID_BOX meta nfproto ipv4 meta l4proto tcp redirect to :$TCP_PORT
  }

  chain filter_out {
    type filter hook output priority 0; policy accept;
    meta skuid $UID_BOX oifname "lo" accept
    # Redirected flows keep their pre-NAT output interface here, so match them
    # by conntrack status rather than by "lo".
    meta skuid $UID_BOX ct status dnat accept
    meta skuid $UID_BOX meta nfproto ipv6 counter name drop_ipv6 drop
    meta skuid $UID_BOX meta l4proto udp counter name drop_udp drop
    meta skuid $UID_BOX counter name drop_other drop
  }
}
EOF
}

cmd_up() {
  need_root
  command -v nft >/dev/null || { echo "FAIL: nft not found in image" >&2; exit 2; }
  mkdir -p "$RUN_DIR"
  : > "$RUN_DIR/events.jsonl"
  python3 "$HERE/net-interpose.py" --log "$RUN_DIR/events.jsonl" \
    --dns "127.0.0.1:$DNS_PORT" --tcp "127.0.0.1:$TCP_PORT" "$@" \
    >"$RUN_DIR/daemon.log" 2>&1 &
  echo $! > "$RUN_DIR/pid"
  # Rules only after the daemon listens, so no early connection is refused oddly.
  for _ in $(seq 1 50); do
    grep -q 'net-interpose: up' "$RUN_DIR/daemon.log" 2>/dev/null && break
    kill -0 "$(cat "$RUN_DIR/pid")" 2>/dev/null || break
    sleep 0.1
  done
  if ! grep -q 'net-interpose: up' "$RUN_DIR/daemon.log" 2>/dev/null; then
    echo "FAIL: net-interpose.py did not start" >&2
    cat "$RUN_DIR/daemon.log" >&2 || true
    exit 1
  fi
  nft delete table inet "$TABLE" 2>/dev/null || true
  ruleset | nft -f -
  cat "$RUN_DIR/daemon.log"
  echo ">> egress default-deny for uid $UID_BOX (log: $RUN_DIR/events.jsonl)"
}

cmd_counters() {
  local c
  for c in drop_udp drop_ipv6 drop_other; do
    printf '%s=%s ' "$c" \
      "$(nft list counter inet "$TABLE" "$c" 2>/dev/null | awk '/packets/{print $2; exit}')"
  done
  echo
}

cmd_down() {
  need_root
  # Stop the client before calling this: once the table is gone, its egress is no
  # longer gated. The daemon goes first so no flow is spliced during teardown.
  if [ -f "$RUN_DIR/pid" ]; then
    kill "$(cat "$RUN_DIR/pid")" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$(cat "$RUN_DIR/pid")" 2>/dev/null || break; sleep 0.1; done
    rm -f "$RUN_DIR/pid"
  fi
  nft delete table inet "$TABLE" 2>/dev/null || true
}

SUB="${1:?usage: net-interpose.sh up|counters|down ...}"; shift
case "$SUB" in
  up)       cmd_up "$@" ;;
  counters) cmd_counters ;;
  down)     cmd_down ;;
  *) echo "FAIL: unknown subcommand '$SUB'" >&2; exit 1 ;;
esac
