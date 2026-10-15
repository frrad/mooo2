# `dllproxy` — forwarder generation for the injection proxy

[`gen-forwarders.sh`](gen-forwarders.sh) emits a `.def` of **name-based forwarder
exports** from a DLL to a renamed copy of itself. Compiled together with the
[`../loadprobe/`](../loadprobe/) `DllMain` body, it yields a proxy DLL that runs our
code on load yet satisfies every import the client resolves from the original
(by forwarding to `<name>__orig.dll`).

It is driven at image-build time by
[`../../docker/box-proxy.sh`](../../docker/box-proxy.sh). See
[`../../docs/inject-spike.md`](../../docs/inject-spike.md) for the full mechanism
and PASS/FAIL.

## Why this is committable (DESIGN §11)

Export **names are read at build time** (with `gendef`) from whatever DLL is
present — the repo commits the *generator*, never a client-specific symbol list or
offsets. The same script re-generates correct forwarders after a re-baseline onto a
new client build (§12).

```sh
gen-forwarders.sh <original.dll> <orig-module-basename> > proxy.def
```
