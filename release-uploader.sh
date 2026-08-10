#!/usr/bin/env bash
set -euo pipefail

CORE_URL="https://raw.githubusercontent.com/Bias8145/pixel/main/release-uploader-core.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CORE="$TMP/release-uploader-core.sh"
PATCHED="$TMP/release-uploader-patched.sh"

curl --fail --silent --show-error --location "$CORE_URL" -o "$CORE"

awk '
index($0, "read -r -p \"Project name [${DISPLAY:-ROM}]: \" PROJECT") {
  print "# Project is detected from the selected ROM filename first; build.prop is only the fallback."
  print "ROM_PROJECT_DEFAULT=\"${DISPLAY:-ROM}\""
  print "if ((MODE==1 || MODE==3)) && ((${#FILES[@]})); then"
  print "  _rom_base=\"$(basename \"${FILES[0]}\")\""
  print "  _rom_lower=\"${_rom_base,,}\""
  print "  case \"$_rom_lower\" in"
  print "    *lineage*) ROM_PROJECT_DEFAULT=\"LineageOS\" ;;"
  print "    *axion*) ROM_PROJECT_DEFAULT=\"Axion AOSP\" ;;"
  print "    *lunaris*) ROM_PROJECT_DEFAULT=\"Lunaris AOSP\" ;;"
  print "    *risingos*) ROM_PROJECT_DEFAULT=\"RisingOS\" ;;"
  print "    *derp*) ROM_PROJECT_DEFAULT=\"DerpFest\" ;;"
  print "    *crdroid*) ROM_PROJECT_DEFAULT=\"crDroid\" ;;"
  print "    *pixelos*) ROM_PROJECT_DEFAULT=\"PixelOS\" ;;"
  print "    *evolution*) ROM_PROJECT_DEFAULT=\"Evolution X\" ;;"
  print "    *aospa*|*paranoid*) ROM_PROJECT_DEFAULT=\"Paranoid Android\" ;;"
  print "    *cherish*) ROM_PROJECT_DEFAULT=\"CherishOS\" ;;"
  print "    *elixir*) ROM_PROJECT_DEFAULT=\"Project Elixir\" ;;"
  print "    *arrow*) ROM_PROJECT_DEFAULT=\"ArrowOS\" ;;"
  print "    *havoc*) ROM_PROJECT_DEFAULT=\"Havoc-OS\" ;;"
  print "    *corvus*) ROM_PROJECT_DEFAULT=\"Corvus OS\" ;;"
  print "    *bliss*) ROM_PROJECT_DEFAULT=\"BlissRoms\" ;;"
  print "    *bananadroid*) ROM_PROJECT_DEFAULT=\"BananaDroid\" ;;"
  print "    *resurrection*) ROM_PROJECT_DEFAULT=\"Resurrection Remix\" ;;"
  print "    *nameless*) ROM_PROJECT_DEFAULT=\"Nameless AOSP\" ;;"
  print "    *graphene*) ROM_PROJECT_DEFAULT=\"GrapheneOS\" ;;"
  print "    *calyx*) ROM_PROJECT_DEFAULT=\"CalyxOS\" ;;"
  print "    *)"
  print "      _rom_stem=\"${_rom_base%.*}\""
  print "      _rom_stem=\"$(printf \"%s\" \"$_rom_stem\" | sed -E \"s/[-_](bramble|redbull|bluejay|blueline|cheetah|panther|oriole|raven|husky|shiba|felix|akita|tokay|barbet|redfin|sunfish|coral|flame|bonito|sargo|malt|taimen|walleye|marlin)([-_].*)?//I\")\""
  print "      [[ -n \"$_rom_stem\" ]] && ROM_PROJECT_DEFAULT=\"$_rom_stem\""
  print "      ;;"
  print "  esac"
  print "fi"
  print "read -r -p \"Project name [${ROM_PROJECT_DEFAULT}]: \" PROJECT || exit 1"
  print "PROJECT=\"${PROJECT:-$ROM_PROJECT_DEFAULT}\""
  next
}
{ print }
' "$CORE" > "$PATCHED"

bash "$PATCHED" "$@"
