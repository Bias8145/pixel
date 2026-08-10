#!/usr/bin/env bash
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { printf '[ERROR] Missing command: %s\n' "$1" >&2; exit 1; }; }
for x in bash curl python3 find sed sort stat; do need "$x"; done

# Resolve the source tree from the directory where the user invoked the command.
# A stale ANDROID_BUILD_TOP from another build tree must never win over the current tree.
find_source_root() {
  local p="$PWD"
  while [[ "$p" != "/" ]]; do
    [[ -d "$p/out/target/product" ]] && { printf '%s\n' "$p"; return 0; }
    p="$(dirname "$p")"
  done
  return 1
}

ROOT="$(find_source_root || true)"
if [[ -z "$ROOT" && -n "${ANDROID_BUILD_TOP:-}" && -d "$ANDROID_BUILD_TOP/out/target/product" ]]; then
  ROOT="$ANDROID_BUILD_TOP"
fi
[[ -n "$ROOT" ]] || { printf '[ERROR] Cannot locate Android source root. Current directory: %s\n' "$PWD" >&2; exit 1; }

# If the environment points elsewhere, make the choice explicit and override it.
if [[ -n "${ANDROID_BUILD_TOP:-}" && "$ANDROID_BUILD_TOP" != "$ROOT" ]]; then
  printf '[INFO] Ignoring stale ANDROID_BUILD_TOP: %s\n' "$ANDROID_BUILD_TOP"
  printf '[INFO] Using current source tree: %s\n' "$ROOT"
fi
export ANDROID_BUILD_TOP="$ROOT"
export PIXEL_UPLOADER_SOURCE_ROOT="$ROOT"
export PIXEL_UPLOADER_OUT="$ROOT/out/target/product"

CORE_URL="https://raw.githubusercontent.com/Bias8145/pixel/main/release-uploader-core.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CORE="$TMP/release-uploader-core.sh"
PATCHED="$TMP/release-uploader-patched.sh"
curl --fail --silent --show-error --location "${CORE_URL}?ts=$(date +%s%N)" -o "$CORE"

python3 - "$CORE" "$PATCHED" "$ROOT" <<'PY'
import re, sys
src, dst, root = sys.argv[1:]
s = open(src, encoding='utf-8').read()

# Force the core to use the launcher-resolved source tree even when the shell has stale vars.
s = re.sub(r'ROOT="\$\{ANDROID_BUILD_TOP:-\$\(pwd\)\}"', 'ROOT="${PIXEL_UPLOADER_SOURCE_ROOT:-${ANDROID_BUILD_TOP:-$(pwd)}}"', s, count=1)

# Remove the fragile awk-based image selection parser if present.
s = s.replace("sel=(); while read -r x; do sel+=(\"$x\"); done < <(printf '%s\\n' \"$norm\" | awk '{for(i=1;i<=NF;i++)print $i}')", 'read -r -a sel <<< "$norm"')

# Device discovery must be tied to the resolved out tree, with real Android metadata and artifacts.
pat = r'mapfile -t DEVICES <\(.*?\)'
replacement = r'''mapfile -t DEVICES < <(for d in "$OUT"/*; do
  [[ -d "$d" ]] || continue
  meta=""
  for f in "$d/build.prop" "$d/prop.default" "$d/system/build.prop" "$d/system/etc/prop.default" "$d/vendor/build.prop" "$d/vendor/etc/prop.default" "$d/product/build.prop"; do
    [[ -f "$f" ]] && { meta="$f"; break; }
  done
  [[ -n "$meta" ]] || continue
  find "$d" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.img' \) -print -quit | grep -q . || continue
  printf '%s\\n' "${d##*/}"
done | sort -u)'''
s, n = re.subn(pat, replacement, s, count=1, flags=re.S)

# ROM discovery: use only the selected source tree's output. Do not consult another tree.
pat2 = r'mapfile -t ROMS <\(.*?\)'
replacement2 = r'''mapfile -t ROMS < <(for f in "$DOUT"/*; do
  [[ -f "$f" ]] || continue
  case "${f,,}" in
    *.zip|*.ozip) printf '%s\\n' "$f";;
  esac
done | sort)'''
s, n2 = re.subn(pat2, replacement2, s, count=1, flags=re.S)

# Remove any accidental hard-coded Lunaris project default if present.
s = re.sub(r'(?i)Lunaris[^\n]*', 'ROM', s)

open(dst, 'w', encoding='utf-8', newline='\n').write(s)
PY

bash -n "$PATCHED"
exec bash "$PATCHED" "$@"
