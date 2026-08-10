#!/usr/bin/env bash
set -euo pipefail

CORE_URL="https://raw.githubusercontent.com/Bias8145/pixel/main/release-uploader-core.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CORE="$TMP/release-uploader-core.sh"
PATCHED="$TMP/release-uploader-patched.sh"

curl --fail --silent --show-error --location "${CORE_URL}?ts=$(date +%s)" -o "$CORE"

awk '
# Discover only genuine Android product outputs. A product directory must
# contain Android build metadata and at least one release artifact.
index($0, "mapfile -t DEVICES < <(find") == 1 {
  print "mapfile -t DEVICES < <(for d in \"$OUT\"/*; do"
  print "  [[ -d \"$d\" ]] || continue"
  print "  _has_meta=0; _has_artifact=0"
  print "  find \"$d\" -maxdepth 2 -type f \\( -name build.prop -o -name prop.default \\) -print -quit | grep -q . && _has_meta=1"
  print "  find \"$d\" -maxdepth 1 -type f \\( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.zip.md5' -o -iname '*.img' \\) -print -quit | grep -q . && _has_artifact=1"
  print "  (( _has_meta && _has_artifact )) || continue"
  print "  printf '%s\\n' \"${d##*/}\""
  print "done | sort -u)"
  next
}

# Project identity comes from the selected ROM artifact and real output metadata.
$0 ~ /read -r -p/ && $0 ~ /Project name/ {
  print "ROM_PROJECT_DEFAULT=\"\""
  print "if ((MODE==1 || MODE==3)) && ((${#FILES[@]})); then"
  print "  _rom=\"${FILES[0]}\""
  print "  _base=\"$(basename \"$_rom\")\""
  print "  _stem=\"${_base%.*}\""
  print "  if command -v unzip >/dev/null 2>&1 && [[ \"$_rom\" == *.zip || \"$_rom\" == *.ZIP ]]; then"
  print "    _zip_display=\"$(unzip -p \"$_rom\" '*/build.prop' 2>/dev/null | sed -n 's/^\\(ro\\.system\\.build\\.display\\.id\\|ro\\.build\\.display\\.id\\)=//p' | head -n1 | tr -d '\\r')\""
  print "    [[ -n \"$_zip_display\" ]] && ROM_PROJECT_DEFAULT=\"$_zip_display\""
  print "  fi"
  print "  if [[ -z \"$ROM_PROJECT_DEFAULT\" ]]; then"
  print "    for _k in ro.system.build.display.id ro.build.display.id ro.system.build.version.incremental ro.build.version.incremental; do"
  print "      _v=\"$(prop \"$_k\")\""
  print "      if [[ -n \"$_v\" && \"$_v\" != Unknown ]]; then ROM_PROJECT_DEFAULT=\"$_v\"; break; fi"
  print "    done"
  print "  fi"
  print "  if [[ -z \"$ROM_PROJECT_DEFAULT\" ]]; then"
  print "    _name=\"$_stem\""
  print "    _name=\"$(printf '%s' \"$_name\" | sed -E 's/[._-](ota|update|package|signed|official|unofficial|final|release|test|debug|user|userdebug|eng|gapps|gms|vanilla|microg|core|full|pico)([._-].*)?$//I')\""
  print "    _name=\"$(printf '%s' \"$_name\" | sed -E 's/[._-][0-9]+([._-][0-9]+)*([._-].*)?$//')\""
  print "    _name=\"$(printf '%s' \"$_name\" | sed -E 's/[-_]+/ /g;s/[[:space:]]+/ /g;s/^ +| +$//g')\""
  print "    [[ -n \"$_name\" ]] && ROM_PROJECT_DEFAULT=\"$_name\""
  print "  fi"
  print "fi"
  print "ROM_PROJECT_DEFAULT=\"${ROM_PROJECT_DEFAULT:-ROM}\""
  print "read -r -p \"Project name [${ROM_PROJECT_DEFAULT}]: \" PROJECT || exit 1"
  print "PROJECT=\"${PROJECT:-$ROM_PROJECT_DEFAULT}\""
  next
}
{ print }
' "$CORE" > "$PATCHED"

bash "$PATCHED" "$@"
