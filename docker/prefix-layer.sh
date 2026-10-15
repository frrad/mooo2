#!/usr/bin/env bash
# Tier 1 containment (docs/boxing.md, "Layered prefix"): run the client from a
# prefix split into separately mounted layers, after the wechat-box precedent:
#
#   base     the image's installed prefix (KAKAO_BASE, default /home/wine/.wine).
#            Its immutable trees (BASE_PATHS in prefix-state.sh: Wine's C:\windows
#            and the installed client) are symlinked into the state layer, never
#            copied. Run the container with --read-only and the base is read-only
#            at the filesystem level: any write to it fails EROFS.
#   state    KAKAO_STATE (default /var/lib/kakao/prefix): a volume or tmpfs mounted
#            by docker run, NOT the container's own overlay (overlay-on-overlay
#            breaks; keep the frequently written state on a real mount). It holds
#            the prefix root (registry hives, dosdevices) and the writable trees
#            (users, ProgramData), seeded from the base on first use. The whole
#            STATE_GLOBS set lives here, so prefix-state.sh snapshot/restore/diff
#            touch only this small layer.
#   payload  KAKAO_PAYLOAD (default /var/lib/kakao/payload), linked as C:\injector.
#            Empty by default; a future version-matched tap DLL is mounted here and
#            swapped without touching the prefix.
#
# Usage (as the wine user):
#   prefix-layer.sh assemble [--fresh]     seed the state layer if empty (--fresh: reseed)
#   prefix-layer.sh check                  verify the layering invariants
#   prefix-layer.sh run [--fresh] -- CMD   assemble, check, then exec CMD with
#                                          WINEPREFIX=KAKAO_STATE and KAKAO_EXE set
#
# e.g. docker run --rm --read-only --tmpfs /tmp:exec \
#        --tmpfs /var/lib/kakao/prefix:exec,uid=1000,gid=1000 \
#        -v kakao-taps:/var/lib/kakao/payload:ro <image> prefix-layer.sh run -- CMD
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${KAKAO_BASE:-/home/wine/.wine}"
STATE="${KAKAO_STATE:-/var/lib/kakao/prefix}"
PAYLOAD="${KAKAO_PAYLOAD:-/var/lib/kakao/payload}"
MARKER=".layer-base"

[ -d "$BASE" ]  || { echo "FAIL: base prefix '$BASE' not found" >&2; exit 1; }
[ -d "$STATE" ] || { echo "FAIL: state layer '$STATE' not found (mount a volume or tmpfs there)" >&2; exit 1; }
# shellcheck source=prefix-state.sh
WINEPREFIX="$STATE" source "$HERE/prefix-state.sh"   # STATE_GLOBS, BASE_PATHS

is_base() { local p; for p in "${BASE_PATHS[@]}"; do [ "$1" = "$p" ] && return 0; done; return 1; }

cmd_assemble() {
  local fresh=0
  [ "${1:-}" = "--fresh" ] && fresh=1
  if [ -f "$STATE/$MARKER" ] && [ "$fresh" -eq 0 ]; then
    echo ">> state layer already assembled: $STATE"
    return 0
  fi
  [ -w "$STATE" ] || { echo "FAIL: state layer '$STATE' is not writable by $(id -un)" >&2; exit 1; }
  find "$STATE" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

  # Prefix root: registry hives, bookkeeping, dosdevices (c: -> ../drive_c, z: -> /).
  ( cd "$BASE" && find . -mindepth 1 -maxdepth 1 ! -name drive_c -exec cp -a {} "$STATE/" \; )
  mkdir -p "$STATE/drive_c"
  local e rel
  while IFS= read -r -d '' e; do
    rel="drive_c/${e#./}"
    if is_base "$rel"; then
      ln -s "$BASE/$rel" "$STATE/$rel"          # immutable: linked, never copied
    else
      cp -a "$BASE/$rel" "$STATE/$rel"          # writable: users, ProgramData, ...
    fi
  done < <(cd "$BASE/drive_c" && find . -mindepth 1 -maxdepth 1 -print0)
  ln -s "$PAYLOAD" "$STATE/drive_c/injector"
  printf '%s\n' "$BASE" > "$STATE/$MARKER"
  echo ">> state layer assembled: $STATE  ($(du -sh "$STATE" 2>/dev/null | cut -f1) writable; base $BASE linked)"
}

cmd_check() {
  local bad=0 p fs real
  fs="$(stat -f -c %T "$STATE")"
  echo ">> state layer fs: $fs"
  case "$fs" in
    overlayfs) echo "  ! state layer is on the container overlay; mount a volume or tmpfs" >&2; bad=1 ;;
  esac
  for p in "${BASE_PATHS[@]}"; do
    [ -e "$BASE/$p" ] || continue
    if [ "$(readlink "$STATE/$p" 2>/dev/null)" != "$BASE/$p" ]; then
      echo "  ! $p is not linked to the base" >&2; bad=1
    fi
  done
  # Every state path must live in the state layer, never resolve into the base.
  while IFS= read -r p; do
    real="$(realpath "$STATE/$p")"
    case "$real" in
      "$STATE"/*) ;;
      *) echo "  ! state path $p resolves outside the state layer ($real)" >&2; bad=1 ;;
    esac
  done < <(state_paths)
  [ "$(readlink "$STATE/drive_c/injector")" = "$PAYLOAD" ] \
    || { echo "  ! C:\\injector is not linked to $PAYLOAD" >&2; bad=1; }
  [ -d "$PAYLOAD" ] || echo "  (payload dir $PAYLOAD absent; C:\\injector dangles until it is mounted)"
  [ "$bad" -eq 0 ] || { echo "FAIL: layering invariants violated" >&2; return 1; }
  echo ">> layering invariants hold"
}

cmd_run() {
  local fresh=()
  [ "${1:-}" = "--fresh" ] && { fresh=(--fresh); shift; }
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || { echo "FAIL: no command given" >&2; exit 1; }
  cmd_assemble "${fresh[@]}"
  cmd_check
  export WINEPREFIX="$STATE"
  # The image records the client's path inside the base; map it into the layer
  # so Wine sees it as C:\Program Files\..., not via Z:.
  local exe
  exe="$(cat /home/wine/.kakao_exe_path 2>/dev/null || true)"
  [ -n "$exe" ] && export KAKAO_EXE="$STATE/${exe#"$BASE"/}"
  exec "$@"
}

SUB="${1:?usage: prefix-layer.sh assemble|check|run ...}"; shift
case "$SUB" in
  assemble) cmd_assemble "$@" ;;
  check)    cmd_check ;;
  run)      cmd_run "$@" ;;
  *) echo "FAIL: unknown subcommand '$SUB'" >&2; exit 1 ;;
esac
