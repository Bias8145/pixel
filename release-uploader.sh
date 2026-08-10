#!/usr/bin/env bash
set -euo pipefail

CORE_URL="https://raw.githubusercontent.com/Bias8145/pixel/main/release-uploader-core.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CORE="$TMP/release-uploader-core.sh"
PATCHED="$TMP/release-uploader-patched.sh"

curl --fail --silent --show-error --location "${CORE_URL}?ts=$(date +%s)" -o "$CORE"

awk '
# Replace the core device enumeration with artifact-aware output discovery.
$0 ~ /^mapfile -t DEVICES < <\(find/ {
  print "mapfile -t DEVICES < <(find \"$OUT\" -mindepth 1 -maxdepth 1 -type d -print0 | while IFS= read -r -d \"\" d; do"
  print "  if find \"$d\" -maxdepth 2 -type f \\( -name build.prop -o -name prop.default -o -iname \"*.zip\" -o -iname \"*.img\" \\) -print -quit | grep -q .; then"
  print "    printf \"%s\\n\" \"${d##*/}\""
  print "  fi"
  print "done | sort -u)"
  next
}

# Replace the project prompt with artifact-first detection. There are no
# hard-coded ROM-name mappings; unknown ROMs work automatically.
$0 ~ /read -r -p/ && $0 ~ /Project name/ {
  print "ROM_PROJECT_DEFAULT=\"ROM\""
  print "if ((MODE==1 || MODE==3)) && ((${#FILES[@]})); then"
  print "  _rom=\"${FILES[0]}\""
  print "  _base=\"$(basename \"$_rom\")\""
  print "  _stem=\"${_base%.*}\""
  print "  _lower=\"${_stem,,}\""
  print "  # First preference: metadata inside the selected ROM archive."
  print "  if command -v unzip >/dev/null 2>&1; then"
  print "    _zip_display=\"$(unzip -p \"$_rom\" '*/build.prop' 2>/dev/null | sed -n 's/^\\(ro\\.system\\.build\\.display\\.id\\|ro\\.build\\.display\\.id\\)=//p' | head -n1 | tr -d '\\r')\""
  print "    [[ -n \"$_zip_display\" ]] && ROM_PROJECT_DEFAULT=\"$_zip_display\""
  print "  fi"
  print "  # Second preference: derive the project identity from the selected filename."
  print "  if [[ \"$ROM_PROJECT_DEFAULT\" == ROM ]]; then"
  print "    _name=\"$_stem\""
  print "    _name=\"$(printf '%s' \"$_name\" | sed -E 's/[._-](ota|update|package|signed|official|unofficial|final|release|test|debug|user|userdebug|eng|gapps|gms|vanilla|microg|core|full|pico)([._-].*)?$//I')\""
  print "    _name=\"$(printf '%s' \"$_name\" | sed -E 's/[._-][0-9]+([._-][0-9]+)*([._-].*)?$//')\""
  print "    _name=\"$(printf '%s' \"$_name\" | sed -E \"s/(^|[-_])${CODENAME}($|[-_])/\\1\\2/Ig; s/[-_]+/ /g; s/[[:space:]]+/ /g;s/^ +| +$//g\")\""
  print "    [[ -n \"$_name\" ]] && ROM_PROJECT_DEFAULT=\"$_name\""
  print "  fi"
  print "fi"
  print "read -r -p \"Project name [${ROM_PROJECT_DEFAULT}]: \" PROJECT || exit 1"
  print "PROJECT=\"${PROJECT:-$ROM_PROJECT_DEFAULT}\""
  next
}
{ print }
' "$CORE" > "$PATCHED"

bash "$PATCHED" "$@"
