#!/usr/bin/env bash
set -u -o pipefail

msg(){ printf '%s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
for x in bash curl jq find sed awk sha256sum md5sum stat date mktemp sort tr head; do need "$x"; done

SECRETS_FILE="${PIXEL_UPLOADER_SECRETS:-$HOME/.config/pixel-uploader/secrets.env}"
if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" || -z "${PIXELDRAIN_API_KEY:-}" || -z "${TELEGRAPH_TOKEN:-}" ]]; then
  if [[ -f "$SECRETS_FILE" ]]; then
    perms="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || stat -f '%Lp' "$SECRETS_FILE")"
    [[ "$perms" == 600 ]] || die "Secrets file must have mode 600: $SECRETS_FILE"
    source "$SECRETS_FILE"
  elif [[ -f "$HOME/.build_env" ]]; then
    perms="$(stat -c '%a' "$HOME/.build_env" 2>/dev/null || stat -f '%Lp' "$HOME/.build_env")"
    [[ "$perms" == 600 ]] || die "~/.build_env must have mode 600"
    source "$HOME/.build_env"
  fi
fi
: "${BOT_TOKEN:?Set BOT_TOKEN}"
: "${CHAT_ID:?Set CHAT_ID}"
: "${PIXELDRAIN_API_KEY:?Set PIXELDRAIN_API_KEY}"
: "${TELEGRAPH_TOKEN:?Set TELEGRAPH_TOKEN}"

ROOT="${ANDROID_BUILD_TOP:-$(pwd)}"
OUT="$ROOT/out/target/product"
[[ -d "$OUT" ]] || die "Cannot find $OUT. Run from Android source tree or export ANDROID_BUILD_TOP."

choose(){
  local max="$1" prompt="$2" value
  while :; do
    read -r -p "$prompt" value || exit 1
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= max )); then
      printf '%s' "$value"; return
    fi
    warn "Enter 1-$max."
  done
}

prop(){
  local key="$1" f v
  for f in "$DOUT/system/build.prop" "$DOUT/vendor/build.prop" "$DOUT/product/build.prop" "$DOUT/system/system/build.prop" "$DOUT/system/etc/prop.default" "$DOUT/vendor/etc/build.prop"; do
    [[ -f "$f" ]] || continue
    v="$(sed -n "s/^${key}=//p" "$f" | head -n1 | tr -d '\r')"
    [[ -n "$v" ]] && { printf '%s' "$v"; return; }
  done
  printf 'Unknown'
}

safe(){ printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g;s/_\+/_/g;s/^_//;s/_$//'; }
html(){ printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

file_type(){
  local b="${1##*/}" l="${b,,}"
  case "$l" in
    *.zip|*.ozip|*.zip.md5) echo ROM ;;
    *.img)
      if [[ "$l" =~ (^|[_-])vendor_kernel_boot([_-]|\.img$) ]]; then echo "VENDOR KERNEL BOOT"
      elif [[ "$l" =~ (^|[_-])vendor_boot([_-]|\.img$) ]]; then echo "VENDOR BOOT"
      elif [[ "$l" =~ (^|[_-])init_boot([_-]|\.img$) ]]; then echo "INIT BOOT"
      elif [[ "$l" =~ (^|[_-])vbmeta_system([_-]|\.img$) ]]; then echo "VBMETA SYSTEM"
      elif [[ "$l" =~ (^|[_-])vbmeta_vendor([_-]|\.img$) ]]; then echo "VBMETA VENDOR"
      elif [[ "$l" =~ (^|[_-])vbmeta([_-]|\.img$) ]]; then echo "VBMETA"
      elif [[ "$l" =~ (^|[_-])dtbo([_-]|\.img$) ]]; then echo "DTBO"
      elif [[ "$l" =~ (^|[_-])boot([_-]|\.img$) ]]; then echo "BOOT"
      else echo "IMAGE"; fi ;;
    *) echo FILE ;;
  esac
}

image_partition(){
  case "$(file_type "$1")" in
    BOOT) echo boot ;;
    DTBO) echo dtbo ;;
    "VENDOR BOOT") echo vendor_boot ;;
    "VENDOR KERNEL BOOT") echo vendor_kernel_boot ;;
    "INIT BOOT") echo init_boot ;;
    VBMETA) echo vbmeta ;;
    "VBMETA SYSTEM") echo vbmeta_system ;;
    "VBMETA VENDOR") echo vbmeta_vendor ;;
    *) echo "" ;;
  esac
}

mapfile -t DEVICES < <(find "$OUT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
((${#DEVICES[@]})) || die "No device output found."

echo
echo "Build outputs:"
for ((i=0;i<${#DEVICES[@]};i++)); do printf '  [%d] %s\n' "$((i+1))" "${DEVICES[$i]}"; done
n="$(choose "${#DEVICES[@]}" "Select device: ")"
CODENAME="${DEVICES[$((n-1))]}"
DOUT="$OUT/$CODENAME"

ANDROID="$(prop ro.build.version.release)"
PATCH="$(prop ro.build.version.security_patch)"
BUILD="$(prop ro.build.id)"
DISPLAY="$(prop ro.build.display.id)"
DEVICE_DETECTED="$(prop ro.product.model)"
[[ "$DEVICE_DETECTED" == Unknown ]] && DEVICE_DETECTED="$(prop ro.product.name)"
[[ "$DEVICE_DETECTED" == Unknown ]] && DEVICE_DETECTED="$CODENAME"
msg "Device: $CODENAME | Android: $ANDROID | Build: $BUILD | SPL: $PATCH"

echo
echo "Upload:"
echo "  [1] ROM"
echo "  [2] Images"
echo "  [3] ROM + Images"
MODE="$(choose 3 "Select: ")"
FILES=()

if ((MODE==1 || MODE==3)); then
  mapfile -t ROMS < <(find "$DOUT" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.zip.md5' \) | sort)
  ((${#ROMS[@]})) || die "No ROM package found."
  echo
echo "ROM packages:"
  for ((i=0;i<${#ROMS[@]};i++)); do printf '  [%d] %s\n' "$((i+1))" "$(basename "${ROMS[$i]}")"; done
  n="$(choose "${#ROMS[@]}" "Select ROM: ")"
  FILES+=("${ROMS[$((n-1))]}")
fi

if ((MODE==2 || MODE==3)); then
  IMGS=()
  while IFS= read -r -d '' f; do
    b="$(basename "$f")"
    [[ "$b" =~ ^(boot|init_boot|dtbo|vendor_boot|vendor_kernel_boot|vbmeta|vbmeta_system|vbmeta_vendor)([-_].*)?\.img$ ]] && IMGS+=("$f")
  done < <(find "$DOUT" -maxdepth 1 -type f -iname '*.img' -print0 | sort -z)
  ((${#IMGS[@]})) || die "No supported images found."
  echo
echo "Images:"
  for ((i=0;i<${#IMGS[@]};i++)); do printf '  [%d] %s\n' "$((i+1))" "$(basename "${IMGS[$i]}")"; done
  while :; do
    read -r -p "Select images (e.g. 1 3 4): " raw || exit 1
    normalized="$(printf '%s' "$raw" | tr ',\t\r' '   ' | sed -E 's/[[:space:]]+/ /g;s/^ +//;s/ +$//')"
    [[ "$normalized" =~ ^[0-9]+( [0-9]+)*$ ]] || { warn "Use space-separated numbers, for example: 1 2 6"; continue; }
    selected=()
    while read -r number; do selected+=("$number"); done < <(printf '%s\n' "$normalized" | awk '{for(i=1;i<=NF;i++) print $i}')
    good=1; seen=' '
    for number in "${selected[@]}"; do
      ((number>=1 && number<=${#IMGS[@]})) || { good=0; break; }
      [[ "$seen" == *" $number "* ]] && { good=0; break; }
      seen+="$number "
    done
    ((good)) && break
    warn "Enter valid image numbers from 1-${#IMGS[@]}, separated by spaces."
  done
  echo "Selected images:"
  for number in "${selected[@]}"; do
    FILES+=("${IMGS[$((number-1))]}")
    printf '  - %s\n' "$(basename "${IMGS[$((number-1))]}")"
  done
fi

read -r -p "Project name [${DISPLAY:-ROM}]: " PROJECT || exit 1
PROJECT="${PROJECT:-${DISPLAY:-ROM}}"
read -r -p "Maintainer [Unknown]: " AUTHOR || exit 1
AUTHOR="${AUTHOR:-Unknown}"
read -r -p "Device name [${DEVICE_DETECTED}]: " DEVICE_NAME || exit 1
DEVICE_NAME="${DEVICE_NAME:-$DEVICE_DETECTED}"
read -r -p "Banner URL [optional]: " BANNER_URL || exit 1
[[ -z "$BANNER_URL" || "$BANNER_URL" =~ ^https?:// ]] || die "Banner URL must start with http:// or https://"

echo
echo "Build Variant:"
echo "  [1] GApps Full"
echo "  [2] GApps Core"
echo "  [3] GApps Pico"
echo "  [4] Vanilla (No Google)"
echo "  [5] Vanilla + microG"
n="$(choose 5 "Select: ")"
case "$n" in
  1) VARIANT="GAPPS"; GOOGLE_TAG="GAPPS-FULL"; GOOGLE_SERVICES="GApps Full included"; VARIANT_NOTE="Google Apps (Full) included"; GOOGLE_MODE=gapps ;;
  2) VARIANT="GAPPS"; GOOGLE_TAG="GAPPS-CORE"; GOOGLE_SERVICES="GApps Core included"; VARIANT_NOTE="Google Apps (Core) included"; GOOGLE_MODE=gapps ;;
  3) VARIANT="GAPPS"; GOOGLE_TAG="GAPPS-PICO"; GOOGLE_SERVICES="GApps Pico included"; VARIANT_NOTE="Google Apps (Pico) included"; GOOGLE_MODE=gapps ;;
  4) VARIANT="VANILLA"; GOOGLE_TAG="NO-GMS"; GOOGLE_SERVICES="No Google services"; VARIANT_NOTE="Vanilla build; no Google services"; GOOGLE_MODE=none ;;
  5) VARIANT="VANILLA"; GOOGLE_TAG="MICROG"; GOOGLE_SERVICES="microG included"; VARIANT_NOTE="Vanilla build with microG services"; GOOGLE_MODE=microg ;;
esac

echo
echo "Rooting method:"
echo "  [1] None"
echo "  [2] KSU"
echo "  [3] KSU Next"
echo "  [4] KSU Legacy"
echo "  [5] ReSukiSU"
echo "  [6] SukiSU"
n="$(choose 6 "Select: ")"
case "$n" in
  1) ROOTM="None"; ROOT_TAG="" ;;
  2) ROOTM="KSU"; ROOT_TAG="KSU" ;;
  3) ROOTM="KSU Next"; ROOT_TAG="KSU-Next" ;;
  4) ROOTM="KSU Legacy"; ROOT_TAG="KSU-Legacy" ;;
  5) ROOTM="ReSukiSU"; ROOT_TAG="ReSukiSU" ;;
  6) ROOTM="SukiSU"; ROOT_TAG="SukiSU" ;;
esac

SUSFS="Disabled"
if [[ "$ROOTM" != None ]]; then
  echo
echo "SUSFS:"
  echo "  [1] Without SUSFS"
  echo "  [2] With SUSFS"
  n="$(choose 2 "Select: ")"
  [[ "$n" == 2 ]] && SUSFS="Enabled"
fi

DATE="$(date +%Y-%m-%d)"
DISPLAY_DATE="$(date +%d-%m-%Y)"
RELEASE_ID="$(safe "$PROJECT")_${CODENAME}_${VARIANT}_${GOOGLE_TAG}_$(safe "$ROOTM")_$(safe "$SUSFS")_$DATE"
BUILD_TAGS="[$(safe "$PROJECT")]"
[[ -n "$DISPLAY" && "$DISPLAY" != Unknown && "$DISPLAY" != "$BUILD" ]] && BUILD_TAGS+=" [$DISPLAY]"
[[ -n "$BUILD" && "$BUILD" != Unknown ]] && BUILD_TAGS+=" [$BUILD]"
BUILD_TAGS+=" [Android $ANDROID] [$VARIANT] [$GOOGLE_TAG]"
[[ -n "$ROOT_TAG" ]] && BUILD_TAGS+=" [$ROOT_TAG]"
[[ "$SUSFS" == Enabled ]] && BUILD_TAGS+=" [SUSFS]"
BUILD_TAGS+=" [$DISPLAY_DATE]"

msg "Checking credentials..."
curl --fail --silent --show-error --max-time 20 -u ":$PIXELDRAIN_API_KEY" https://pixeldrain.com/api/user/files >/dev/null || die "Pixeldrain authentication failed. No files were uploaded."
curl --fail --silent --show-error --max-time 20 "https://api.telegram.org/bot$BOT_TOKEN/getMe" | jq -e '.ok==true' >/dev/null || die "Telegram bot authentication failed. No files were uploaded."
curl --fail --silent --show-error --max-time 20 -X POST https://api.telegra.ph/getPageList -d "access_token=$TELEGRAPH_TOKEN" | jq -e '.ok==true' >/dev/null || die "Telegraph authentication failed. No files were uploaded."
ok "Pixeldrain authentication OK"
ok "Telegram bot authentication OK"
ok "Telegraph authentication OK"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MANIFEST="$TMP/files.tsv"
: > "$MANIFEST"

pixeldrain_upload(){
  local f="$1" name="$2" response id
  response="$(curl --fail-with-body -sS --max-time 3600 -u ":$PIXELDRAIN_API_KEY" -F "file=@$f;filename=$name" https://pixeldrain.com/api/file)" || return 1
  id="$(jq -r '.id // empty' <<<"$response")"
  [[ -n "$id" ]] || return 1
  printf 'https://pixeldrain.com/u/%s' "$id"
}

echo
echo "Uploading selected files to Pixeldrain..."
SUCCESS=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { warn "Missing file: $f"; continue; }
  base="$(basename "$f")"
  ext="${base##*.}"
  stem="${base%.*}"
  if [[ "$base" == *.zip.md5 ]]; then
    name="${base%.zip.md5}_${RELEASE_ID}.zip.md5"
  else
    name="${stem}_${RELEASE_ID}.${ext}"
  fi
  size="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"
  md5="$(md5sum "$f" | awk '{print $1}')"
  sha="$(sha256sum "$f" | awk '{print $1}')"
  type="$(file_type "$f")"
  if link="$(pixeldrain_upload "$f" "$name")"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$base" "$name" "$type" "$size" "$md5" "$sha" "$link" >> "$MANIFEST"
    SUCCESS=$((SUCCESS+1))
    ok "$type: uploaded"
  else
    warn "Pixeldrain upload failed: $base"
  fi
done
((SUCCESS>0)) || die "No files were uploaded to Pixeldrain; Telegram publish cancelled."

GUIDE=$'INSTALLATION GUIDE\n\n'
GUIDE+="Release: $PROJECT"$'\n'
GUIDE+="Device: $DEVICE_NAME ($CODENAME)"$'\n'
GUIDE+="Android: $ANDROID"$'\n'
GUIDE+="Security Patch: $PATCH"$'\n'
GUIDE+="Build Variant: $VARIANT"$'\n'
GUIDE+="Google Services: $GOOGLE_SERVICES"$'\n'
GUIDE+="Rooting: $ROOTM"$'\n'
GUIDE+="SUSFS: $SUSFS"$'\n'
GUIDE+="Maintainer: $AUTHOR"$'\n\n'
GUIDE+=$'IMPORTANT: This is a community-provided guide for this release. Follow the official device documentation when it differs.\n\n'

if [[ "$CODENAME" == bramble ]]; then
  GUIDE+=$'1. Verify prerequisites\n'
  GUIDE+=$'• Use Android 14 stock firmware as the required firmware baseline for bramble.\n'
  GUIDE+=$'• Enable OEM unlocking and back up all data.\n'
  GUIDE+=$'• Unlocking the bootloader erases user data.\n\n'
  GUIDE+=$'2. Boot to bootloader\n'
  GUIDE+=$'adb -d reboot bootloader\nfastboot devices\n\n'
  GUIDE+=$'3. Flash the additional partitions required by the bramble guide\n'
  for f in "${FILES[@]}"; do
    p="$(image_partition "$f")"
    case "$p" in
      boot|dtbo) GUIDE+="fastboot flash $p $(basename "$f")"$'\n' ;;
    esac
  done
  GUIDE+=$'fastboot reboot bootloader\n\n'
  GUIDE+=$'4. Install Lineage Recovery\n'
  GUIDE+=$'fastboot flash vendor_boot <vendor_boot.img from the release/recovery package>\n'
  GUIDE+=$'Then use the bootloader menu to select Recovery Mode.\n\n'
  GUIDE+=$'5. Factory reset\n'
  GUIDE+=$'In Recovery: Factory Reset → Format data / factory reset.\n\n'
  GUIDE+=$'6. Sideload the ROM\n'
  GUIDE+=$'Recovery: Apply update → Apply from ADB\n'
  GUIDE+=$'Host: adb -d sideload <ROM.zip>\n\n'
else
  GUIDE+=$'1. Read the official installation instructions for this exact device before flashing.\n'
  GUIDE+="Official device guide: https://lineageos.github.io/lineage_wiki/devices/$CODENAME/install/"$'\n\n'
  GUIDE+=$'2. Boot to the device bootloader/fastboot mode as specified by the device guide.\n'
  for f in "${FILES[@]}"; do
    p="$(image_partition "$f")"
    [[ -n "$p" ]] && GUIDE+="fastboot flash $p $(basename "$f")"$'\n'
  done
  GUIDE+=$'\n3. Enter the recovery specified by the device guide.\n'
  GUIDE+=$'4. Factory reset/data format only when required by the device guide.\n'
  GUIDE+=$'5. Sideload/install the ROM package using the recovery method specified by the device guide.\n\n'
fi

if [[ "$GOOGLE_MODE" == gapps ]]; then
  GUIDE+="Google Apps: $GOOGLE_SERVICES"$'\n'
  GUIDE+=$'Do not install a second GApps package unless the ROM maintainer explicitly requires it.\n\n'
elif [[ "$GOOGLE_MODE" == microg ]]; then
  GUIDE+=$'Google services: microG is included in this release. Do not install another GApps package.\n\n'
else
  GUIDE+=$'Google services: none. This is a Vanilla build.\n\n'
fi

if [[ "$ROOTM" != None ]]; then
  GUIDE+="Rooting: $ROOTM"$'\n'
  GUIDE+=$'Rooting is optional and is not supported by LineageOS. Follow the root project instructions for this exact kernel/build.\n\n'
fi

GUIDE+=$'7. First boot\n'
GUIDE+=$'Reboot to system only after all required installation steps have completed successfully.\n\n'
GUIDE+=$'TERMS OF USE / RISK NOTICE\n'
GUIDE+=$'• Installation and flashing are performed entirely at the installer’s own risk.\n'
GUIDE+=$'• The installer is responsible for selecting the correct device, firmware, ROM and image files and for following the installation instructions correctly.\n'
GUIDE+=$'• The developer/maintainer provides the release and guide as-is and is not responsible for damage, data loss, bootloops, soft-bricks or other failures caused by incorrect installation, incompatible files, unsupported modifications or failure to follow the guide.\n'
GUIDE+=$'• Always verify the device codename, firmware requirements and file hashes before flashing.\n'
GUIDE+=$'• If any step fails, stop and verify the official device documentation before continuing.\n'

TITLE="Flash Guide - $DEVICE_NAME - $DISPLAY_DATE"
GUIDE_CONTENT="$(jq -Rs '{tag:"pre",children:[.]}' <<<"$GUIDE")"
FLASH_GUIDE_RESPONSE="$(curl -sS -X POST https://api.telegra.ph/createPage \
  -d "access_token=$TELEGRAPH_TOKEN" \
  --data-urlencode "title=$TITLE" \
  --data-urlencode "author_name=$AUTHOR" \
  --data-urlencode "author_url=https://khaliq-repos.pages.dev/" \
  --data-urlencode "content=[$GUIDE_CONTENT]")"
FLASH_GUIDE_URL="$(jq -r '.result.url // empty' <<<"$FLASH_GUIDE_RESPONSE")"

RELEASE="New Release: $(html "$PROJECT")"$'\n\n'
RELEASE+="Device: $(html "$DEVICE_NAME")"$'\n'
RELEASE+="Project: $(html "$PROJECT")"$'\n'
RELEASE+="Android Version: $(html "$ANDROID")"$'\n'
RELEASE+="Security Patch: $(html "$PATCH")"$'\n'
RELEASE+="Build Variant: $(html "$VARIANT")"$'\n'
RELEASE+="Google Services: $(html "$GOOGLE_SERVICES")"$'\n'
RELEASE+="Release Date: $DISPLAY_DATE"$'\n'
RELEASE+="Maintainer: $(html "$AUTHOR")"$'\n\n'
RELEASE+="Tag: $(html "$BUILD_TAGS")"$'\n\n'
RELEASE+=$'Release Notes:\n'
RELEASE+="• $(html "$VARIANT_NOTE")"$'\n'
[[ -n "$ROOT_TAG" ]] && RELEASE+="• $(html "$ROOTM") support included"$'\n'
[[ "$SUSFS" == Enabled ]] && RELEASE+=$'• SUSFS (Suspicious File System) enabled\n'
RELEASE+=$'• Advanced users recommended\n\n'
RELEASE+=$'⚠️ Always backup your data before flashing\n'
RELEASE+=$'Follow the flash guide for proper installation\n\n'
RELEASE+=$'Terms of Use: Flashing is performed at your own risk. The installer is responsible for correct device, firmware and file selection. The developer/maintainer is not responsible for failures caused by incorrect installation or unsupported modifications.\n\n'
RELEASE+=$'Files Size Information:\n'

while IFS=$'\t' read -r base name type size md5 sha link; do
  mb="$(awk -v s="$size" 'BEGIN{printf "%.1f",s/1024/1024}')"
  short_md5="${md5:0:8}"
  short_sha="${sha:0:8}"
  RELEASE+="▫️ $type – $mb MB | MD5: $short_md5 | SHA: $short_sha"$'\n'
done < "$MANIFEST"
RELEASE+=$'\nClick the buttons below to download the files'

mapfile -t BUTTONS < <(while IFS=$'\t' read -r base name type size md5 sha link; do
  jq -cn --arg text "$type" --arg url "$link" '{text:$text,url:$url}'
done < "$MANIFEST")
ROWS=()
row=()
for b in "${BUTTONS[@]}"; do
  row+=("$b")
  if ((${#row[@]}==2)); then
    ROWS+=("[$(IFS=,; echo "${row[*]}")]")
    row=()
  fi
done
((${#row[@]})) && ROWS+=("[$(IFS=,; echo "${row[*]}")]")
[[ -n "$FLASH_GUIDE_URL" ]] && ROWS+=("$(jq -cn --arg u "$FLASH_GUIDE_URL" '[{text:"Flash Guide",url:$u}]')")
ROWS+=('[{"text":"About Developer","url":"https://khaliq-repos.pages.dev/"}]')
REPLY_MARKUP="$(printf '%s\n' "${ROWS[@]}" | jq -sc '{inline_keyboard:.}')"

PAYLOAD="$TMP/release-message.txt"
printf '%s' "$RELEASE" > "$PAYLOAD"
echo
echo "Publishing release to Telegram..."

if [[ -n "$BANNER_URL" && ${#RELEASE} -le 1000 ]]; then
  TELEGRAM_RESPONSE="$(curl --fail -sS -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "photo=$BANNER_URL" \
    --data-urlencode "caption@$PAYLOAD" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "reply_markup=$REPLY_MARKUP")" || {
      warn "Banner send failed; retrying as text message."
      TELEGRAM_RESPONSE="$(curl --fail -sS -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text@$PAYLOAD" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "reply_markup=$REPLY_MARKUP")" || die "Telegram publish failed."
    }
elif [[ -n "$BANNER_URL" ]]; then
  warn "Release message is too long for a Telegram photo caption; publishing as text instead."
  TELEGRAM_RESPONSE="$(curl --fail -sS -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text@$PAYLOAD" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "reply_markup=$REPLY_MARKUP")" || die "Telegram publish failed."
else
  TELEGRAM_RESPONSE="$(curl --fail -sS -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$CHAT_ID" \
    --data-urlencode "text@$PAYLOAD" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "reply_markup=$REPLY_MARKUP")" || die "Telegram publish failed."
fi

jq -e '.ok==true' <<<"$TELEGRAM_RESPONSE" >/dev/null || die "Telegram publish failed."
ok "Release published successfully."
echo "Flash Guide: ${FLASH_GUIDE_URL:-not created}"