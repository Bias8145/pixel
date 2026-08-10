#!/usr/bin/env bash
set -euo pipefail

# Standalone launcher. The Android source tree is always the source of truth.
# No hard-coded device or ROM list is used here.

need(){ command -v "$1" >/dev/null 2>&1 || { printf '[ERROR] Missing command: %s\n' "$1" >&2; exit 1; }; }
for x in bash curl python3; do need "$x"; done

ROOT="${ANDROID_BUILD_TOP:-$(pwd)}"
if [[ ! -d "$ROOT/out/target/product" ]]; then
  # Walk upward so running from build subdirectories still resolves the source root.
  p="$PWD"
  while [[ "$p" != "/" ]]; do
    if [[ -d "$p/out/target/product" ]]; then ROOT="$p"; break; fi
    p="$(dirname "$p")"
  done
fi
[[ -d "$ROOT/out/target/product" ]] || { printf '[ERROR] Cannot find out/target/product. Run from the Android source tree or set ANDROID_BUILD_TOP.\n' >&2; exit 1; }

export ANDROID_BUILD_TOP="$ROOT"
export PIXEL_UPLOADER_SOURCE_ROOT="$ROOT"

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

# Remove the fragile awk-based image parsing dependency.
s = s.replace("sel=(); while read -r x; do sel+=(\"$x\"); done < <(printf '%s\\n' \"$norm\" | awk '{for(i=1;i<=NF;i++)print $i}')", 'read -r -a sel <<< "$norm"')
s = s.replace('for x in bash curl jq find sed awk sha256sum md5sum stat date mktemp sort tr head basename file wc; do need "$x"; done', 'for x in bash curl jq find sed sha256sum md5sum stat date mktemp sort tr head basename file wc; do need "$x"; done')

# Replace project default: selected ROM metadata first, then filename. Never inherit a stale
# display ID merely because another ROM was built in the same output directory.
old = '''read -r -p "Project name [${DISPLAY:-ROM}]: " PROJECT || exit 1; PROJECT="${PROJECT:-${DISPLAY:-ROM}}"'''
new = r'''ROM_PROJECT_DEFAULT=""
if ((MODE==1 || MODE==3)) && ((${#FILES[@]})); then
  _rom="${FILES[0]}"
  # If the ZIP contains build.prop, use its own display metadata first.
  if command -v unzip >/dev/null 2>&1 && [[ "$_rom" =~ \.[Zz][Ii][Pp]$ ]]; then
    _zip_display="$(unzip -p "$_rom" '*/build.prop' 2>/dev/null | sed -n -e 's/^ro.system.build.display.id=//p' -e 's/^ro.build.display.id=//p' | head -n1 | tr -d '\r')"
    [[ -n "$_zip_display" ]] && ROM_PROJECT_DEFAULT="$_zip_display"
  fi
  # Artifact filename is the next source of truth. Strip common packaging/build suffixes.
  if [[ -z "$ROM_PROJECT_DEFAULT" ]]; then
    _stem="$(basename "$_rom")"
    _stem="${_stem%.*}"
    _name="$(printf '%s' "$_stem" | sed -E 's/[._-](ota|update|package|signed|official|unofficial|final|release|test|debug|user|userdebug|eng)([._-].*)?$//I; s/[._-](gapps|gms|vanilla|microg|core|full|pico)([._-].*)?$//I; s/[-_]+/ /g; s/[[:space:]]+/ /g; s/^ +| +$//g')"
    [[ -n "$_name" ]] && ROM_PROJECT_DEFAULT="$_name"
  fi
fi
[[ -n "$ROM_PROJECT_DEFAULT" ]] || ROM_PROJECT_DEFAULT="ROM"
read -r -p "Project name [${ROM_PROJECT_DEFAULT}]: " PROJECT || exit 1
PROJECT="${PROJECT:-$ROM_PROJECT_DEFAULT}"'''
if old not in s:
    raise SystemExit('project block not found')
s = s.replace(old, new, 1)

# Device discovery: only actual Android output directories with metadata AND current-looking
# artifacts are candidates. No hard-coded Pixel codenames.
old_dev = '''mapfile -t DEVICES < <(find "$OUT" -mindepth 1 -maxdepth 1 -type d -printf '%f\\n' | sort)'''
new_dev = r'''mapfile -t DEVICES < <(for d in "$OUT"/*; do
  [[ -d "$d" ]] || continue
  meta=""
  for f in "$d/build.prop" "$d/system/build.prop" "$d/vendor/build.prop" "$d/product/build.prop" "$d/system/etc/prop.default" "$d/vendor/etc/prop.default"; do
    [[ -f "$f" ]] && { meta="$f"; break; }
  done
  [[ -n "$meta" ]] || continue
  artifact=""
  while IFS= read -r -d '' f; do artifact="$f"; break; done < <(find "$d" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.img' \) -print0)
  [[ -n "$artifact" ]] || continue
  printf '%s\n' "${d##*/}"
done | sort -u)'''
if old_dev in s:
    s = s.replace(old_dev, new_dev, 1)

# ROM discovery: prefer artifacts newer than the device metadata/build marker. If there is a
# build.ninja/AndroidProducts.mk marker, use its mtime as an additional boundary. This prevents
# stale ZIPs from being selected merely because they remain in out/.
old_rom = '''mapfile -t ROMS < <(find "$DOUT" -maxdepth 1 -type f \\( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.zip.md5' \\) | sort)'''
new_rom = r'''_BUILD_MARKER=""
for _m in "$DOUT/build.ninja" "$DOUT/installed-files.json" "$DOUT/obj/PACKAGING/target_files_intermediates"; do
  if [[ -e "$_m" ]]; then _BUILD_MARKER="$_m"; break; fi
done
_BUILD_EPOCH=0
if [[ -n "$_BUILD_MARKER" ]]; then _BUILD_EPOCH="$(stat -c %Y "$_BUILD_MARKER" 2>/dev/null || stat -f %m "$_BUILD_MARKER" 2>/dev/null || printf 0)"; fi
mapfile -t ROMS < <(for _r in "$DOUT"/*; do
  [[ -f "$_r" ]] || continue
  case "${_r,,}" in *.zip|*.ozip|*.zip.md5) ;; *) continue;; esac
  _rt="$(stat -c %Y "$_r" 2>/dev/null || stat -f %m "$_r" 2>/dev/null || printf 0)"
  # If a reliable build marker exists, stale artifacts older than it are excluded.
  if (( _BUILD_EPOCH > 0 && _rt < _BUILD_EPOCH )); then continue; fi
  printf '%s\n' "$_r"
done | sort)'''
if old_rom in s:
    s = s.replace(old_rom, new_rom, 1)

# Make the output root visible to the core and add an explicit diagnostic.
needle='ROOT="${ANDROID_BUILD_TOP:-$(pwd)}"\nOUT="$ROOT/out/target/product"'
replacement='ROOT="${ANDROID_BUILD_TOP:-$(pwd)}"\nOUT="$ROOT/out/target/product"\n[[ -d "$OUT" ]] || die "Cannot find $OUT. Run from Android source tree or export ANDROID_BUILD_TOP."'
if needle in s:
    s=s.replace(needle,replacement,1)

open(dst,'w',encoding='utf-8',newline='\n').write(s)
PY

bash -n "$PATCHED"
exec bash "$PATCHED" "$@"
