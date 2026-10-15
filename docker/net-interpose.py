#!/usr/bin/env python3
"""Network interpose for the Wine-boxed reference client (Tier 1, DESIGN §4/§8).

The nftables rules installed by net-interpose.sh redirect every IPv4 DNS query
and TCP connection made by the wine user to this process. Everything else that
uid sends off-box (UDP, ICMP, IPv6) is dropped and counted in nftables. This
process then:

  * DNS stub (UDP). Names on the allowlist are resolved for real (this process
    runs as root, so its own lookups are not redirected) and the answers are
    remembered as allowed destinations. Every other name gets a unique
    "sinkhole" address from 198.18.0.0/15 (RFC 2544 benchmark range, never
    routed), so the client still attempts its connection and we learn which port
    and TLS server name it wanted. AAAA and other types get an empty answer.
  * Transparent TCP proxy. Reads the original destination (SO_ORIGINAL_DST). If it
    is allowlisted, bytes are spliced to the real server. Otherwise the connection
    is held for up to 2 s to read a TLS ClientHello (for the SNI), logged, and
    reset. Default is deny: an empty allowlist lets nothing out.
  * Ingress fan-out (Shadow mode, DESIGN §8). For allowed flows, every chunk is
    also published to fan-out subscribers (JSON lines on --fanout HOST:PORT):
    "in" is server->client, "out" is client->server. Inbound is received once
    here and delivered to the reference and to each subscriber identically. A
    subscriber (the candidate) can only read; it has no path to the server, so it
    runs dry-run by construction.

Every decision is written as a JSON line to --log. The log holds hostnames and
addresses only, never payload bytes; payload goes to fan-out subscribers alone.
Treat it as a lab artifact anyway and do not commit it (DESIGN §11).

Allowlist entries (one per line in --allowlist, or repeated --allow):
    name           exact DNS name           e.g. example.com
    *.suffix       any name under suffix    e.g. *.example.com
    a.b.c.d[/n]    IPv4 address or CIDR
each optionally followed by :PORT to restrict the TCP port.
"""

import argparse
import asyncio
import base64
import fnmatch
import ipaddress
import json
import signal
import socket
import struct
import sys
import time

SO_ORIGINAL_DST = 80
SINKHOLE = ipaddress.ip_network("198.18.0.0/15")
HELLO_WAIT = 2.0


# --- Allowlist ------------------------------------------------------------------

class Allowlist:
    def __init__(self, entries):
        self.names = []   # (pattern, port|None)
        self.nets = []    # (network, port|None)
        for raw in entries:
            e = raw.split("#", 1)[0].strip()
            if not e:
                continue
            host, port = e, None
            if e.count(":") == 1:
                host, p = e.rsplit(":", 1)
                port = int(p)
            try:
                self.nets.append((ipaddress.ip_network(host, strict=False), port))
            except ValueError:
                self.names.append((host.lower().rstrip("."), port))

    def name_ports(self, name):
        """Ports allowed for a DNS name: None if the name is not allowed, else a
        set (empty set = any port)."""
        name = name.lower().rstrip(".")
        hit, ports = False, set()
        for pat, port in self.names:
            if fnmatch.fnmatchcase(name, pat) or (pat.startswith("*.") and name == pat[2:]):
                hit = True
                if port is None:
                    return set()
                ports.add(port)
        return ports if hit else None

    def ip_allowed(self, ip, port):
        a = ipaddress.ip_address(ip)
        return any(a in net and (p is None or p == port) for net, p in self.nets)

    def __len__(self):
        return len(self.names) + len(self.nets)


# --- Interpose state --------------------------------------------------------------

class Interpose:
    def __init__(self, allow, log):
        self.allow = allow
        self.log = log
        self.resolved = {}     # ip -> (name, ports set)
        self.sink_by_name = {}
        self.sink_by_ip = {}
        self.subs = set()      # fan-out writers
        self.conn_seq = 0
        self.stats = {"dns_allow": 0, "dns_deny": 0, "tcp_allow": 0, "tcp_deny": 0}

    def event(self, **kv):
        kv = {"ts": round(time.time(), 3), **kv}
        self.log.write(json.dumps(kv, sort_keys=True) + "\n")
        self.log.flush()
        key = "%s_%s" % (kv.get("kind"), kv.get("verdict"))
        if key in self.stats:
            self.stats[key] += 1

    def sinkhole(self, name):
        ip = self.sink_by_name.get(name)
        if ip is None:
            ip = str(SINKHOLE[len(self.sink_by_name) + 1])
            self.sink_by_name[name] = ip
            self.sink_by_ip[ip] = name
        return ip

    def tcp_verdict(self, ip, port):
        """Return (allowed, name-or-None)."""
        if self.allow.ip_allowed(ip, port):
            return True, None
        if ip in self.resolved:
            name, ports = self.resolved[ip]
            return (not ports or port in ports), name
        return False, self.sink_by_ip.get(ip)

    def publish(self, conn, direction, data):
        if not self.subs:
            return
        line = (json.dumps({"conn": conn, "dir": direction,
                            "b64": base64.b64encode(data).decode()}) + "\n").encode()
        for w in list(self.subs):
            try:
                w.write(line)
            except Exception:  # noqa: BLE001
                self.subs.discard(w)


# --- DNS stub -------------------------------------------------------------------

def parse_query(pkt):
    if len(pkt) < 12:
        return None
    qid, flags, qd = struct.unpack("!HHH", pkt[:6])
    if qd != 1 or flags & 0x8000:
        return None
    off, labels = 12, []
    while off < len(pkt):
        n = pkt[off]
        off += 1
        if n == 0:
            break
        if n & 0xC0:
            return None
        labels.append(pkt[off:off + n].decode("ascii", "replace"))
        off += n
    if off + 4 > len(pkt):
        return None
    qtype, qclass = struct.unpack("!HH", pkt[off:off + 4])
    return qid, flags, ".".join(labels), qtype, qclass, pkt[12:off + 4]


def build_answer(qid, qflags, question, ips, rcode=0):
    flags = 0x8000 | (qflags & 0x0100) | 0x0080 | rcode   # QR, RD echoed, RA
    out = struct.pack("!HHHHHH", qid, flags, 1, len(ips), 0, 0) + question
    for ip in ips:
        out += struct.pack("!HHHIH", 0xC00C, 1, 1, 60, 4) + socket.inet_aton(ip)
    return out


class DNSStub(asyncio.DatagramProtocol):
    def __init__(self, ip):
        self.ip = ip

    def connection_made(self, transport):
        self.t = transport

    def datagram_received(self, data, addr):
        asyncio.ensure_future(self.answer(data, addr))

    async def answer(self, data, addr):
        q = parse_query(data)
        if q is None:
            return
        qid, qflags, name, qtype, _qclass, question = q
        ports = self.ip.allow.name_ports(name)
        ips = []
        if ports is not None:
            if qtype == 1:
                try:
                    infos = await asyncio.get_running_loop().getaddrinfo(
                        name, None, family=socket.AF_INET, type=socket.SOCK_STREAM)
                    ips = sorted({i[4][0] for i in infos})
                except OSError:
                    ips = []
                for a in ips:
                    self.ip.resolved[a] = (name, ports)
            self.ip.event(kind="dns", verdict="allow", name=name, qtype=qtype, answers=ips)
        else:
            if qtype == 1:
                ips = [self.ip.sinkhole(name)]
            self.ip.event(kind="dns", verdict="deny", name=name, qtype=qtype, answers=ips)
        self.t.sendto(build_answer(qid, qflags, question, ips), addr)


# --- TCP proxy ------------------------------------------------------------------

def original_dst(sock):
    raw = sock.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
    port = struct.unpack("!H", raw[2:4])[0]
    return socket.inet_ntoa(raw[4:8]), port


def tls_sni(buf):
    """Best-effort SNI from a TLS ClientHello; None if not parseable."""
    try:
        if len(buf) < 43 or buf[0] != 0x16 or buf[5] != 0x01:
            return None
        off = 43
        off += 1 + buf[off]                                   # session id
        off += 2 + struct.unpack("!H", buf[off:off + 2])[0]   # cipher suites
        off += 1 + buf[off]                                   # compression
        end = off + 2 + struct.unpack("!H", buf[off:off + 2])[0]
        off += 2
        while off + 4 <= min(end, len(buf)):
            etype, elen = struct.unpack("!HH", buf[off:off + 4])
            off += 4
            if etype == 0:
                nlen = struct.unpack("!H", buf[off + 3:off + 5])[0]
                return buf[off + 5:off + 5 + nlen].decode("ascii", "replace")
            off += elen
    except (IndexError, struct.error):
        pass
    return None


def hard_close(writer):
    sock = writer.get_extra_info("socket")
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    except OSError:
        pass
    writer.close()


async def pump(ip, conn, direction, reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            ip.publish(conn, direction, data)
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            writer.write_eof()
        except (OSError, RuntimeError):
            writer.close()


async def handle_tcp(ip, reader, writer):
    sock = writer.get_extra_info("socket")
    try:
        dst, port = original_dst(sock)
    except OSError:
        writer.close()
        return
    allowed, name = ip.tcp_verdict(dst, port)
    if not allowed:
        hello = b""
        try:
            hello = await asyncio.wait_for(reader.read(4096), HELLO_WAIT)
        except (asyncio.TimeoutError, ConnectionError, OSError):
            pass
        ip.event(kind="tcp", verdict="deny", dst=dst, port=port, name=name,
                 sni=tls_sni(hello), sent=len(hello))
        hard_close(writer)
        return

    ip.conn_seq += 1
    conn = ip.conn_seq
    try:
        ur, uw = await asyncio.wait_for(asyncio.open_connection(dst, port), 15)
    except (OSError, asyncio.TimeoutError) as exc:
        ip.event(kind="tcp", verdict="allow", dst=dst, port=port, name=name,
                 conn=conn, error=str(exc))
        hard_close(writer)
        return
    ip.event(kind="tcp", verdict="allow", dst=dst, port=port, name=name, conn=conn)
    await asyncio.gather(pump(ip, conn, "out", reader, uw),
                         pump(ip, conn, "in", ur, writer))
    uw.close()
    writer.close()


async def handle_sub(ip, _reader, writer):
    ip.subs.add(writer)
    try:
        await _reader.read()        # held until the subscriber disconnects
    finally:
        ip.subs.discard(writer)


# --- Main -----------------------------------------------------------------------

def hostport(s):
    h, p = s.rsplit(":", 1)
    return h, int(p)


async def amain(args):
    entries = list(args.allow)
    if args.allowlist:
        with open(args.allowlist) as f:
            entries += f.read().splitlines()
    allow = Allowlist(entries)
    log = open(args.log, "a", buffering=1)
    ip = Interpose(allow, log)
    loop = asyncio.get_running_loop()

    h, p = hostport(args.dns)
    await loop.create_datagram_endpoint(lambda: DNSStub(ip), local_addr=(h, p))
    h, p = hostport(args.tcp)
    tcp = await asyncio.start_server(lambda r, w: handle_tcp(ip, r, w), h, p)
    servers = [tcp]
    if args.fanout:
        h, p = hostport(args.fanout)
        servers.append(await asyncio.start_server(lambda r, w: handle_sub(ip, r, w), h, p))

    stop = asyncio.Event()
    for s in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(s, stop.set)
    ip.event(kind="start", allowlist_entries=len(allow), fanout=args.fanout or None)
    print(">> net-interpose: up (dns=%s tcp=%s fanout=%s, %d allowlist entries)"
          % (args.dns, args.tcp, args.fanout or "-", len(allow)), flush=True)
    await stop.wait()
    ip.event(kind="stop", **ip.stats)
    for s in servers:
        s.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dns", default="127.0.0.1:15353")
    ap.add_argument("--tcp", default="127.0.0.1:15001")
    ap.add_argument("--fanout", default="", help="HOST:PORT for fan-out subscribers")
    ap.add_argument("--allowlist", default="", help="file of allowlist entries")
    ap.add_argument("--allow", action="append", default=[], help="one allowlist entry")
    ap.add_argument("--log", required=True, help="JSON-lines decision log")
    asyncio.run(amain(ap.parse_args()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
