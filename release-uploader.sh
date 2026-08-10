#!/usr/bin/env bash
set -euo pipefail

# Keep the downloaded uploader isolated from interactive shell functions/aliases.
unalias awk 2>/dev/null || true
unset -f awk 2>/dev/null || true

CORE_URL="https://raw.githubusercontent.com/Bias8145/pixel/main/release-uploader-core.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CORE="$TMP/release-uploader-core.sh"
PATCHED="$TMP/release-uploader-patched.sh"

command -v curl >/dev/null 2>&1 || { echo '[ERROR] Missing command: curl' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo '[ERROR] Missing command: python3' >&2; exit 1; }

curl --fail --silent --show-error --location "${CORE_URL}?ts=$(date +%s%N)" -o "$CORE"

python3 - "$CORE" "$PATCHED" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src, "r", encoding="utf-8").read()

old_device = '''mapfile -t DEVICES < <(find "$OUT" -mindepth 1 -maxdepth 1 -type d -printf '%f\\n' | sort)'''
new_device = '''mapfile -t DEVICES < <(for d in "$OUT"/*; do
  [[ -d "$d" ]] || continue
  _has_meta=0
  _has_artifact=0
  while IFS= read -r _meta; do _has_meta=1; break; done < <(find "$d" -maxdepth 3 -type f \\( -name build.prop -o -name prop.default \\) -print -quit)
  while IFS= read -r _artifact; do _has_artifact=1; break; done < <(find "$d" -maxdepth 1 -type f \\( -iname "*.zip" -o -iname "*.ozip" -o -iname "*.zip.md5" -o -iname "*.img" \\) -print -quit)
  (( _has_meta && _has_artifact )) || continue
  printf '%s\\n' "${d##*/}"
done | sort -u)'''
if old_device not in s:
    raise SystemExit("device detection target not found")
s = s.replace(old_device, new_device, 1)

old_project = '''read -r -p "Project name [${DISPLAY:-ROM}]: " PROJECT || exit 1; PROJECT="${PROJECT:-${DISPLAY:-ROM}}"'''
new_project = '''ROM_PROJECT_DEFAULT="${DISPLAY:-ROM}"
if ((MODE==1 || MODE==3)) && ((${#FILES[@]})); then
  _rom="${FILES[0]}"
  _zip_display=""
  if command -v unzip >/dev/null 2>&1 && [[ "$_rom" == *.zip || "$_rom" == *.ZIP ]]; then
    _zip_display="$(unzip -p "$_rom" '*/build.prop' 2>/dev/null | sed -n -e 's/^ro.system.build.display.id=//p' -e 's/^ro.build.display.id=//p' | head -n1 | tr -d '\\r')"
    [[ -n "$_zip_display" ]] && ROM_PROJECT_DEFAULT="$_zip_display"
  fi
  if [[ -z "$_zip_display" ]]; then
    _stem="$(basename "$_rom")"
    _stem="${_stem%.*}"
    _name="$(printf '%s' "$_stem" | sed -E 's/[._-](ota|update|package|signed|official|unofficial|final|release|test|debug|user|userdebug|eng|gapps|gms|vanilla|microg|core|full|pico)([._-].*)?$//I; s/[._-][0-9]+([._-][0-9]+)*([._-].*)?$//; s/[-_]+/ /g; s/[[:space:]]+/ /g; s/^ +| +$//g')"
    [[ -n "$_name" ]] && ROM_PROJECT_DEFAULT="$_name"
  fi
fi
read -r -p "Project name [${ROM_PROJECT_DEFAULT}]: " PROJECT || exit 1
PROJECT="${PROJECT:-$ROM_PROJECT_DEFAULT}"'''
if old_project not in s:
    raise SystemExit("project detection target not found")
s = s.replace(old_project, new_project, 1)

# Eliminate every awk dependency from the generated runtime. This removes the
# remaining source of the observed "awk ... default" failure on customized shells.
s = s.replace('for x in bash curl jq find sed awk sha256sum md5sum stat date mktemp sort tr head basename file wc; do need "$x"; done',
              'for x in bash curl jq find sed sha256sum md5sum stat date mktemp sort tr head basename file wc; do need "$x"; done', 1)

old_size = '''size_of(){ awk -v b="$1" 'BEGIN{if(b>=1073741824)printf "%.2f GB",b/1073741824;else if(b>=1048576)printf "%.1f MB",b/1048576;else if(b>=1024)printf "%.1f KB",b/1024;else printf "%d B",b}'; }'''
new_size = '''size_of(){
  local b="$1" whole rem scaled
  if ((b>=1073741824)); then
    whole=$((b/1073741824)); rem=$((b%1073741824)); scaled=$((rem*100/1073741824)); printf '%d.%02d GB' "$whole" "$scaled"
  elif ((b>=1048576)); then
    whole=$((b/1048576)); rem=$((b%1048576)); scaled=$((rem*10/1048576)); printf '%d.%d MB' "$whole" "$scaled"
  elif ((b>=1024)); then
    whole=$((b/1024)); rem=$((b%1024)); scaled=$((rem*10/1024)); printf '%d.%d KB' "$whole" "$scaled"
  else
    printf '%d B' "$b"
  fi
}'''
if old_size not in s:
    raise SystemExit("size_of target not found")
s = s.replace(old_size, new_size, 1)

old_sel = '''sel=(); while read -r x; do sel+=("$x"); done < <(printf '%s\\n' "$norm" | awk '{for(i=1;i<=NF;i++)print $i}')'''
new_sel = '''read -r -a sel <<< "$norm"'''
if old_sel not in s:
    raise SystemExit("image selection target not found")
s = s.replace(old_sel, new_sel, 1)

old_hash = '''sz="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"; md5="$(md5sum "$f" | awk '{print $1}')"; sha="$(sha256sum "$f" | awk '{print $1}')"; ty="$(file_type "$f")"'''
new_hash = '''sz="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"
  _sum="$(md5sum "$f")"; md5="${_sum%% *}"
  _sum="$(sha256sum "$f")"; sha="${_sum%% *}"
  ty="$(file_type "$f")"'''
if old_hash not in s:
    raise SystemExit("hash target not found")
s = s.replace(old_hash, new_hash, 1)

open(dst, "w", encoding="utf-8", newline="\n").write(s)
PY

bash -n "$PATCHED"
exec bash "$PATCHED" "$@"
