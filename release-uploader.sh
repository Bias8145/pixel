#!/usr/bin/env bash
set -euo pipefail

CORE_URL="https://raw.githubusercontent.com/Bias8145/pixel/main/release-uploader-core.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CORE="$TMP/release-uploader-core.sh"
PATCHED="$TMP/release-uploader-patched.sh"

command -v curl >/dev/null 2>&1 || { echo '[ERROR] Missing command: curl' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo '[ERROR] Missing command: python3' >&2; exit 1; }

curl --fail --silent --show-error --location "${CORE_URL}?ts=$(date +%s)" -o "$CORE"

python3 - "$CORE" "$PATCHED" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src, "r", encoding="utf-8").read()

old_device = '''mapfile -t DEVICES < <(find "$OUT" -mindepth 1 -maxdepth 1 -type d -printf '%f\\n' | sort)'''
new_device = '''mapfile -t DEVICES < <(for d in "$OUT"/*; do
  [[ -d "$d" ]] || continue
  _has_meta=0
  _has_artifact=0
  find "$d" -maxdepth 2 -type f \\( -name build.prop -o -name prop.default \\) -print -quit | grep -q . && _has_meta=1
  find "$d" -maxdepth 1 -type f \\( -iname "*.zip" -o -iname "*.ozip" -o -iname "*.zip.md5" -o -iname "*.img" \\) -print -quit | grep -q . && _has_artifact=1
  (( _has_meta && _has_artifact )) || continue
  printf "%s\\n" "${d##*/}"
done | sort -u)'''

if old_device not in s:
    raise SystemExit("device detection target not found in core")
s = s.replace(old_device, new_device, 1)

old_project = '''read -r -p "Project name [${DISPLAY:-ROM}]: " PROJECT || exit 1; PROJECT="${PROJECT:-${DISPLAY:-ROM}}"'''
new_project = '''ROM_PROJECT_DEFAULT="${DISPLAY:-ROM}"
if ((MODE==1 || MODE==3)) && ((${#FILES[@]})); then
  _rom="${FILES[0]}"
  _zip_display=""
  if command -v unzip >/dev/null 2>&1 && [[ "$_rom" == *.zip || "$_rom" == *.ZIP ]]; then
    _zip_display="$(unzip -p "$_rom" "*/build.prop" 2>/dev/null | sed -n -e 's/^ro.system.build.display.id=//p' -e 's/^ro.build.display.id=//p' | head -n1 | tr -d '\\r')"
    [[ -n "$_zip_display" ]] && ROM_PROJECT_DEFAULT="$_zip_display"
  fi
  if [[ -z "$_zip_display" ]]; then
    _stem="$(basename "$_rom")"
    _stem="${_stem%.*}"
    _name="$(printf "%s" "$_stem" | sed -E 's/[._-](ota|update|package|signed|official|unofficial|final|release|test|debug|user|userdebug|eng|gapps|gms|vanilla|microg|core|full|pico)([._-].*)?$//I; s/[._-][0-9]+([._-][0-9]+)*([._-].*)?$//; s/[-_]+/ /g; s/[[:space:]]+/ /g; s/^ +| +$//g')"
    [[ -n "$_name" ]] && ROM_PROJECT_DEFAULT="$_name"
  fi
fi
read -r -p "Project name [${ROM_PROJECT_DEFAULT}]: " PROJECT || exit 1
PROJECT="${PROJECT:-$ROM_PROJECT_DEFAULT}"'''

if old_project not in s:
    raise SystemExit("project detection target not found in core")
s = s.replace(old_project, new_project, 1)

open(dst, "w", encoding="utf-8", newline="\n").write(s)
PY

bash -n "$PATCHED"
exec bash "$PATCHED" "$@"
