#!/usr/bin/env bash
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { printf '[ERROR] Missing command: %s\n' "$1" >&2; exit 1; }; }
for x in bash curl python3 find sed sort stat dirname; do need "$x"; done

# Resolve the Android source tree from where the user actually launched the uploader.
# A stale ANDROID_BUILD_TOP must never silently redirect a release to another ROM tree.
is_android_tree() {
  local d="$1"
  [[ -d "$d/.repo" ]] && return 0
  [[ -f "$d/build/make/core/envsetup.mk" ]] && return 0
  [[ -f "$d/build/envsetup.sh" ]] && return 0
  [[ -d "$d/device" && -d "$d/vendor" && -d "$d/frameworks" ]] && return 0
  return 1
}

find_source_root() {
  local p="$PWD"
  while [[ "$p" != "/" ]]; do
    if is_android_tree "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
    p="$(dirname "$p")"
  done
  return 1
}

# Current source tree wins. Only use ANDROID_BUILD_TOP when the current location
# is not inside an identifiable Android source tree.
ROOT="$(find_source_root || true)"
if [[ -z "$ROOT" && -n "${ANDROID_BUILD_TOP:-}" ]] && is_android_tree "$ANDROID_BUILD_TOP"; then
  ROOT="$ANDROID_BUILD_TOP"
fi
[[ -n "$ROOT" ]] || {
  printf '[ERROR] Cannot identify the Android source tree from: %s\n' "$PWD" >&2
  printf '[ERROR] Run this command from the Android source tree (for example ~/ax), or set ANDROID_BUILD_TOP to that tree.\n' >&2
  exit 1
}

OUT="$ROOT/out/target/product"
[[ -d "$OUT" ]] || {
  printf '[ERROR] Source tree: %s\n' "$ROOT" >&2
  printf '[ERROR] Missing: %s\n' "$OUT" >&2
  printf '[ERROR] This prevents the uploader from accidentally reading another build tree.\n' >&2
  exit 1
}

if [[ -n "${ANDROID_BUILD_TOP:-}" && "$ANDROID_BUILD_TOP" != "$ROOT" ]]; then
  printf '[INFO] Ignoring stale ANDROID_BUILD_TOP: %s\n' "$ANDROID_BUILD_TOP"
  printf '[INFO] Using source tree: %s\n' "$ROOT"
fi
export ANDROID_BUILD_TOP="$ROOT"
export PIXEL_UPLOADER_SOURCE_ROOT="$ROOT"
export PIXEL_UPLOADER_OUT="$OUT"

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

# Force the core to use the source tree resolved by this launcher.
s = re.sub(r'ROOT="\$\{ANDROID_BUILD_TOP:-\$\(pwd\)\}"', 'ROOT="${PIXEL_UPLOADER_SOURCE_ROOT}"', s, count=1)

# No awk is needed for multi-image input.
s = s.replace("sel=(); while read -r x; do sel+=(\"$x\"); done < <(printf '%s\\n' \"$norm\" | awk '{for(i=1;i<=NF;i++)print $i}')", 'read -r -a sel <<< "$norm"')

# Device discovery: only directories in the resolved source tree's out/target/product
# with Android metadata and at least one actual release artifact.
pat = r'mapfile -t DEVICES <\(.*?\)'
replacement = r'''mapfile -t DEVICES < <(for d in "$OUT"/*; do
  [[ -d "$d" ]] || continue
  meta=""
  for f in "$d/build.prop" "$d/prop.default" "$d/system/build.prop" "$d/system/etc/prop.default" "$d/vendor/build.prop" "$d/vendor/etc/prop.default" "$d/product/build.prop"; do
    [[ -f "$f" ]] && { meta="$f"; break; }
  done
  [[ -n "$meta" ]] || continue
  find "$d" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.img' \) -print -quit | grep -q . || continue
  printf '%s\n' "${d##*/}"
done | sort -u)'''
s, _ = re.subn(pat, replacement, s, count=1, flags=re.S)

# ROM discovery is strictly limited to the selected device output. No ROM name is
# hard-coded and no other source tree is consulted.
pat2 = r'mapfile -t ROMS <\(.*?\)'
replacement2 = r'''mapfile -t ROMS < <(for f in "$DOUT"/*; do
  [[ -f "$f" ]] || continue
  case "${f,,}" in
    *.zip|*.ozip) printf '%s\n' "$f";;
  esac
done | sort)'''
s, _ = re.subn(pat2, replacement2, s, count=1, flags=re.S)

open(dst, 'w', encoding='utf-8', newline='\n').write(s)
PY

bash -n "$PATCHED"
exec bash "$PATCHED" "$@"
