#!/usr/bin/env bash
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { printf '[ERROR] Missing command: %s\n' "$1" >&2; exit 1; }; }
for x in bash curl python3; do need "$x"; done

ROOT="${ANDROID_BUILD_TOP:-$PWD}"
if [[ ! -d "$ROOT/out/target/product" ]]; then
  p="$PWD"
  while [[ "$p" != "/" ]]; do
    if [[ -d "$p/out/target/product" ]]; then ROOT="$p"; break; fi
    p="$(dirname "$p")"
  done
fi
[[ -d "$ROOT/out/target/product" ]] || { printf '[ERROR] Cannot find out/target/product under %s\n' "$ROOT" >&2; exit 1; }
export ANDROID_BUILD_TOP="$ROOT"
export PIXEL_UPLOADER_SOURCE_ROOT="$ROOT"

CORE_URL="https://raw.githubusercontent.com/Bias8145/pixel/main/release-uploader-core.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CORE="$TMP/core.sh"
PATCHED="$TMP/uploader.sh"
curl -fsSL --retry 3 --location "${CORE_URL}?_=$(date +%s%N)" -o "$CORE"

python3 - "$CORE" "$PATCHED" "$ROOT" <<'PY'
import re, sys
src, dst, root = sys.argv[1:]
s = open(src, encoding='utf-8').read()

# 1) Device discovery: only real Android output directories with metadata and artifacts.
new_devices = r'''mapfile -t DEVICES < <(for d in "$OUT"/*; do
  [[ -d "$d" ]] || continue
  meta=0
  for f in "$d/build.prop" "$d/prop.default" "$d/system/build.prop" "$d/vendor/build.prop" "$d/product/build.prop" "$d/system/etc/prop.default" "$d/vendor/etc/prop.default"; do
    [[ -f "$f" ]] && { meta=1; break; }
  done
  ((meta)) || continue
  artifact=0
  for f in "$d"/*.zip "$d"/*.ozip "$d"/*.img; do
    [[ -f "$f" ]] && { artifact=1; break; }
  done
  ((artifact)) || continue
  basename "$d"
done | sort -u)'''
s, n1 = re.subn(r'mapfile -t DEVICES < <\(find "\$OUT" -mindepth 1 -maxdepth 1 -type d -printf \'%f\\n\' \| sort\)', new_devices, s, count=1)

# 2) ROM discovery: read only actual packages from the selected output. Do not invent a ROM
# from a source-tree name. If output metadata identifies a project, prefer matching packages;
# otherwise present every actual package so the user can choose explicitly.
new_roms = r'''PROJECT_HINT=""
for key in ro.axion.version ro.lineage.version ro.crdroid.version ro.pixelos.version ro.rising.version ro.derp.version ro.project.version ro.build.display.id; do
  v="$(prop "$key")"
  if [[ "$v" != Unknown && -n "$v" ]]; then PROJECT_HINT="$v"; break; fi
done
mapfile -t ALL_ROMS < <(find "$DOUT" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.zip.md5' \) -print | sort)
((${#ALL_ROMS[@]})) || die 'No ROM package found in selected out/target/product directory.'
ROMS=()
if [[ -n "$PROJECT_HINT" ]]; then
  hint="$(printf '%s' "$PROJECT_HINT" | sed -E 's/[[:space:][:punct:]]+.*$//')"
  for r in "${ALL_ROMS[@]}"; do
    bn="$(basename "$r")"
    [[ -n "$hint" && "$bn" =~ $hint ]] && ROMS+=("$r")
  done
fi
((${#ROMS[@]})) || ROMS=("${ALL_ROMS[@]}")'''
s, n2 = re.subn(r'mapfile -t ROMS < <\(find "\$DOUT" -maxdepth 1 -type f \\\( -iname \'\*\.zip\' -o -iname \'\*\.ozip\' -o -iname \'\*\.zip\.md5\' \\\) \| sort\)', new_roms, s, count=1)

# 3) Remove the old default that blindly used ro.build.display.id. Project is determined after
# ROM selection from the selected artifact, then falls back to output metadata.
old = r'''read -r -p "Project name \[\$\{DISPLAY:-ROM\}\]: " PROJECT \|\| exit 1; PROJECT="\$\{PROJECT:-\$\{DISPLAY:-ROM\}\}"'''
new = r'''ROM_PROJECT_DEFAULT="${PROJECT_HINT:-ROM}"
if ((${#FILES[@]})); then
  _rom="${FILES[0]}"
  if [[ "$_rom" =~ \.[Zz][Ii][Pp]$ ]] && command -v unzip >/dev/null 2>&1; then
    _zdisplay="$(unzip -p "$_rom" '*/build.prop' 2>/dev/null | sed -n -e 's/^ro.axion.version=//p' -e 's/^ro.lineage.version=//p' -e 's/^ro.crdroid.version=//p' -e 's/^ro.build.display.id=//p' | head -n1 | tr -d '\r')"
    [[ -n "$_zdisplay" ]] && ROM_PROJECT_DEFAULT="$_zdisplay"
  fi
fi
read -r -p "Project name [${ROM_PROJECT_DEFAULT}]: " PROJECT || exit 1
PROJECT="${PROJECT:-$ROM_PROJECT_DEFAULT}"'''
s, n3 = re.subn(r'read -r -p "Project name \[\$\{DISPLAY:-ROM\}\]: " PROJECT \|\| exit 1; PROJECT="\$\{PROJECT:-\$\{DISPLAY:-ROM\}\}"', new, s, count=1)

# 4) Eliminate the broken awk image selector without touching the rest of the uploader.
s, n4 = re.subn(r'sel=\(\); while read -r x; do sel\+=\("\$x"\); done < <\(printf \'%s\\n\' "\$norm" \| awk \'\{for\(i=1;i<=NF;i\+\+\)print \$i\}\'\)', 'read -r -a sel <<< "$norm"', s, count=1)

if n1 != 1 or n2 != 1:
    raise SystemExit(f'core patch anchors not found: devices={n1} roms={n2} project={n3} images={n4}')
open(dst, 'w', encoding='utf-8', newline='\n').write(s)
PY

bash -n "$PATCHED"
exec bash "$PATCHED" "$@"
