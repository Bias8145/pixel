#!/usr/bin/env bash
set -u -o pipefail

msg(){ printf '%s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
for x in bash curl jq find sed awk sha256sum md5sum stat date mktemp sort tr head basename file wc; do need "$x"; done

SECRETS_FILE="${PIXEL_UPLOADER_SECRETS:-$HOME/.config/pixel-uploader/secrets.env}"
if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" || -z "${PIXELDRAIN_API_KEY:-}" || -z "${TELEGRAPH_TOKEN:-}" ]]; then
  if [[ -f "$SECRETS_FILE" ]]; then
    mode="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || stat -f '%Lp' "$SECRETS_FILE")"
    [[ "$mode" == 600 ]] || die "Secrets file must have mode 600: $SECRETS_FILE"
    source "$SECRETS_FILE"
  elif [[ -f "$HOME/.build_env" ]]; then
    mode="$(stat -c '%a' "$HOME/.build_env" 2>/dev/null || stat -f '%Lp' "$HOME/.build_env")"
    [[ "$mode" == 600 ]] || die "~/.build_env must have mode 600"
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
  local max="$1" prompt="$2" v
  while :; do
    read -r -p "$prompt" v || exit 1
    if [[ "$v" =~ ^[0-9]+$ ]] && ((v>=1 && v<=max)); then printf '%s' "$v"; return; fi
    warn "Enter 1-$max."
  done
}
prop(){
  local k="$1" f v
  for f in "$DOUT/system/build.prop" "$DOUT/vendor/build.prop" "$DOUT/product/build.prop" "$DOUT/system/system/build.prop" "$DOUT/system/etc/prop.default" "$DOUT/vendor/etc/build.prop"; do
    [[ -f "$f" ]] || continue
    v="$(sed -n "s/^${k}=//p" "$f" | head -n1 | tr -d '\r')"
    [[ -n "$v" ]] && { printf '%s' "$v"; return; }
  done
  printf 'Unknown'
}
safe(){ printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g;s/_\+/_/g;s/^_//;s/_$//'; }
clean(){ printf '%s' "$1" | tr '\r\n' '  ' | sed -E 's/[[:space:]]+/ /g;s/^ +//;s/ +$//'; }
html(){ printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g;'; }
size_of(){ awk -v b="$1" 'BEGIN{if(b>=1073741824)printf "%.2f GB",b/1073741824;else if(b>=1048576)printf "%.1f MB",b/1048576;else if(b>=1024)printf "%.1f KB",b/1024;else printf "%d B",b}'; }

file_type(){
  local l="$(basename "$1")"; l="${l,,}"
  case "$l" in
    *.zip|*.ozip|*.zip.md5) echo ROM ;;
    boot.img|boot[-_]*.img) echo BOOT ;;
    dtbo.img|dtbo[-_]*.img) echo DTBO ;;
    vendor_boot.img|vendor_boot[-_]*.img|vendor-boot*) echo "VENDOR BOOT" ;;
    vendor_kernel_boot.img|vendor_kernel_boot[-_]*.img|vendor-kernel-boot*) echo "VENDOR KERNEL BOOT" ;;
    init_boot.img|init_boot[-_]*.img|init-boot*) echo "INIT BOOT" ;;
    vbmeta_system.img|vbmeta_system[-_]*.img|vbmeta-system*) echo "VBMETA SYSTEM" ;;
    vbmeta_vendor.img|vbmeta_vendor[-_]*.img|vbmeta-vendor*) echo "VBMETA VENDOR" ;;
    vbmeta.img|vbmeta[-_]*.img|vbmeta-*) echo VBMETA ;;
    recovery.img|recovery[-_]*.img) echo RECOVERY ;;
    *.img) echo IMAGE ;;
    *) echo FILE ;;
  esac
}
part_of(){
  case "$(file_type "$1")" in
    BOOT) echo boot;; DTBO) echo dtbo;; "VENDOR BOOT") echo vendor_boot;;
    "VENDOR KERNEL BOOT") echo vendor_kernel_boot;; "INIT BOOT") echo init_boot;;
    VBMETA) echo vbmeta;; "VBMETA SYSTEM") echo vbmeta_system;; "VBMETA VENDOR") echo vbmeta_vendor;;
    RECOVERY) echo recovery;; *) echo;;
  esac
}

mapfile -t DEVICES < <(find "$OUT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
((${#DEVICES[@]})) || die "No device output found."
echo; echo "Build outputs:"
for ((i=0;i<${#DEVICES[@]};i++)); do printf '  [%d] %s\n' "$((i+1))" "${DEVICES[$i]}"; done
n="$(choose "${#DEVICES[@]}" 'Select device: ')"
CODENAME="${DEVICES[$((n-1))]}"; DOUT="$OUT/$CODENAME"
ANDROID="$(prop ro.build.version.release)"; PATCH="$(prop ro.build.version.security_patch)"; BUILD="$(prop ro.build.id)"; DISPLAY="$(prop ro.build.display.id)"
DETECTED="$(prop ro.product.model)"; [[ "$DETECTED" == Unknown ]] && DETECTED="$(prop ro.product.name)"; [[ "$DETECTED" == Unknown ]] && DETECTED="$CODENAME"
printf 'Device: %s | Android: %s | Build: %s | SPL: %s\n' "$CODENAME" "$ANDROID" "$BUILD" "$PATCH"

echo; echo 'Upload:'; echo '  [1] ROM'; echo '  [2] Images'; echo '  [3] ROM + Images'
MODE="$(choose 3 'Select: ')"; FILES=()
if ((MODE==1 || MODE==3)); then
  mapfile -t ROMS < <(find "$DOUT" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.zip.md5' \) | sort)
  ((${#ROMS[@]})) || die 'No ROM package found.'
  echo; echo 'ROM packages:'
  for ((i=0;i<${#ROMS[@]};i++)); do printf '  [%d] %s\n' "$((i+1))" "$(basename "${ROMS[$i]}")"; done
  n="$(choose "${#ROMS[@]}" 'Select ROM: ')"; FILES+=("${ROMS[$((n-1))]}")
fi
if ((MODE==2 || MODE==3)); then
  IMGS=()
  while IFS= read -r -d '' f; do
    b="$(basename "$f")"
    [[ "${b,,}" =~ ^(boot|init_boot|dtbo|vendor_boot|vendor_kernel_boot|vbmeta|vbmeta_system|vbmeta_vendor|recovery)([-_].*)?\.img$ ]] && IMGS+=("$f")
  done < <(find "$DOUT" -maxdepth 1 -type f -iname '*.img' -print0 | sort -z)
  ((${#IMGS[@]})) || die 'No supported images found.'
  echo; echo 'Images:'
  for ((i=0;i<${#IMGS[@]};i++)); do printf '  [%d] %s\n' "$((i+1))" "$(basename "${IMGS[$i]}")"; done
  while :; do
    read -r -p 'Select images (e.g. 1 2 6): ' raw || exit 1
    norm="$(printf '%s' "$raw" | tr ',\t\r' '   ' | sed -E 's/[[:space:]]+/ /g;s/^ +//;s/ +$//')"
    [[ "$norm" =~ ^[0-9]+( [0-9]+)*$ ]] || { warn 'Use space-separated numbers, for example: 1 2 6'; continue; }
    sel=(); while read -r x; do sel+=("$x"); done < <(printf '%s\n' "$norm" | awk '{for(i=1;i<=NF;i++)print $i}')
    good=1; seen=' '
    for x in "${sel[@]}"; do ((x>=1&&x<=${#IMGS[@]})) || good=0; [[ "$seen" == *" $x "* ]] && good=0; seen+="$x "; done
    ((good)) && break
    warn "Enter valid image numbers from 1-${#IMGS[@]}, separated by spaces."
  done
  echo 'Selected images:'
  for x in "${sel[@]}"; do FILES+=("${IMGS[$((x-1))]}"); printf '  - %s\n' "$(basename "${IMGS[$((x-1))]}")"; done
fi

read -r -p "Project name [${DISPLAY:-ROM}]: " PROJECT || exit 1; PROJECT="${PROJECT:-${DISPLAY:-ROM}}"
read -r -p 'Maintainer [Unknown]: ' AUTHOR || exit 1; AUTHOR="${AUTHOR:-Unknown}"
read -r -p "Device name [${DETECTED}]: " DEVICE_NAME || exit 1; DEVICE_NAME="${DEVICE_NAME:-$DETECTED}"
read -r -p 'Banner URL [optional]: ' BANNER_URL || exit 1
[[ -z "$BANNER_URL" || "$BANNER_URL" =~ ^https?:// ]] || die 'Banner URL must start with http:// or https://'

echo; echo 'Build Variant:'; echo '  [1] GApps Full'; echo '  [2] GApps Core'; echo '  [3] GApps Pico'; echo '  [4] Vanilla (No Google)'; echo '  [5] Vanilla + microG'
VARIANT_CHOICE="$(choose 5 'Select: ')"
case "$VARIANT_CHOICE" in
  1) VARIANT='GApps'; GTAG='GAPPS-FULL'; GS='GApps Full included'; NOTE='Google Apps (Full) included';;
  2) VARIANT='GApps'; GTAG='GAPPS-CORE'; GS='GApps Core included'; NOTE='Google Apps (Core) included';;
  3) VARIANT='GApps'; GTAG='GAPPS-PICO'; GS='GApps Pico included'; NOTE='Google Apps (Pico) included';;
  4) VARIANT='Vanilla'; GTAG='NO-GMS'; GS='Not included'; NOTE='Vanilla build without Google services';;
  5) VARIANT='Vanilla'; GTAG='MICROG'; GS='microG included'; NOTE='Vanilla build with microG services';;
esac

echo; echo 'Rooting method:'; echo '  [1] None'; echo '  [2] KSU'; echo '  [3] KSU Next'; echo '  [4] KSU Legacy'; echo '  [5] ReSukiSU'; echo '  [6] SukiSU'
n="$(choose 6 'Select: ')"
case "$n" in
  1) ROOTM=None; RTAG=;; 2) ROOTM=KSU; RTAG=KSU;; 3) ROOTM='KSU Next'; RTAG=KSU-Next;; 4) ROOTM='KSU Legacy'; RTAG=KSU-Legacy;; 5) ROOTM=ReSukiSU; RTAG=ReSukiSU;; 6) ROOTM=SukiSU; RTAG=SukiSU;;
esac
ROOT_VERSION=''
if [[ "$ROOTM" != None ]]; then read -r -p 'Root implementation/version [optional]: ' ROOT_VERSION || exit 1; ROOT_VERSION="$(clean "$ROOT_VERSION")"; fi
SUSFS=Disabled; SUSFS_VERSION=''
if [[ "$ROOTM" != None ]]; then
  echo; echo 'SUSFS:'; echo '  [1] Without SUSFS'; echo '  [2] With SUSFS'; n="$(choose 2 'Select: ')"
  if [[ "$n" == 2 ]]; then SUSFS=Enabled; read -r -p 'SUSFS version [optional]: ' SUSFS_VERSION || exit 1; SUSFS_VERSION="$(clean "$SUSFS_VERSION")"; fi
fi

DATE="$(date +%Y-%m-%d)"; DDATE="$(date +%d-%m-%Y)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MANIFEST="$TMP/files.tsv"; : > "$MANIFEST"

curl --fail --silent --show-error --max-time 20 -u ":$PIXELDRAIN_API_KEY" https://pixeldrain.com/api/user/files >/dev/null || die 'Pixeldrain authentication failed.'
curl --fail --silent --show-error --max-time 20 "https://api.telegram.org/bot$BOT_TOKEN/getMe" | jq -e '.ok==true' >/dev/null || die 'Telegram bot authentication failed.'
curl --fail --silent --show-error --max-time 20 -X POST https://api.telegra.ph/getPageList -d "access_token=$TELEGRAPH_TOKEN" | jq -e '.ok==true' >/dev/null || die 'Telegraph authentication failed.'
ok 'Pixeldrain authentication OK'; ok 'Telegram bot authentication OK'; ok 'Telegraph authentication OK'

upload(){
  local f="$1" name="$2" r id
  r="$(curl --fail-with-body -sS --max-time 3600 -u ":$PIXELDRAIN_API_KEY" -F "file=@$f;filename=$name" https://pixeldrain.com/api/file)" || return 1
  id="$(jq -r '.id // empty' <<< "$r")"; [[ -n "$id" ]] || return 1; printf 'https://pixeldrain.com/u/%s' "$id"
}

echo; echo 'Uploading selected files to Pixeldrain...'; OKN=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  base="$(basename "$f")"; ext="${base##*.}"; stem="${base%.*}"
  name="${stem}_$(safe "$CODENAME")_${DATE}.${ext}"
  sz="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"; md5="$(md5sum "$f" | awk '{print $1}')"; sha="$(sha256sum "$f" | awk '{print $1}')"; ty="$(file_type "$f")"
  url="$(upload "$f" "$name")" || { warn "Pixeldrain upload failed: $base"; continue; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$name" "$url" "$sz" "$md5" "$sha" "$ty" >> "$MANIFEST"
  ok "FILE: $base uploaded"; OKN=$((OKN+1))
done
((OKN>0)) || die 'No files were uploaded to Pixeldrain.'

MAIN_URLS=(); FILE_TYPES=(); ROWS=''; GUIDE_LINES=()
while IFS=$'\t' read -r f name url sz md5 sha ty; do
  MAIN_URLS+=("$url"); FILE_TYPES+=("$ty")
  ROWS+="▫️ <b>$(html "$ty")</b> — $(size_of "$sz") | MD5: <code>${md5:0:8}</code> | SHA256: <code>${sha:0:8}</code>"$'\n'
  p="$(part_of "$f")"; [[ -n "$p" ]] && GUIDE_LINES+=("fastboot flash $p $name")
done < "$MANIFEST"

RELEASE_NOTES=()
case "$VARIANT_CHOICE" in
  1|2|3) RELEASE_NOTES+=("$NOTE") ;;
  4) RELEASE_NOTES+=("Vanilla build without Google services") ;;
  5) RELEASE_NOTES+=("Vanilla build with microG services") ;;
esac
if [[ "$ROOTM" != None ]]; then
  root_note="$ROOTM"; [[ -n "$ROOT_VERSION" ]] && root_note+=" $ROOT_VERSION"
  RELEASE_NOTES+=("$root_note integrated")
fi
[[ "$SUSFS" == Enabled ]] && { sus_note="SUSFS enabled"; [[ -n "$SUSFS_VERSION" ]] && sus_note+=" — $SUSFS_VERSION"; RELEASE_NOTES+=("$sus_note"); }
RELEASE_NOTES+=("Installation guide generated for the selected files")
RELEASE_BLOCK=''; for line in "${RELEASE_NOTES[@]}"; do RELEASE_BLOCK+="• $(html "$line")"$'\n'; done

TAG="[$PROJECT] [$BUILD] [Android $ANDROID] [$GTAG]"
[[ -n "$RTAG" ]] && TAG+=" [$RTAG${ROOT_VERSION:+-$ROOT_VERSION}]"
[[ "$SUSFS" == Enabled ]] && TAG+=" [SUSFS${SUSFS_VERSION:+-$SUSFS_VERSION}]"
TAG+=" [$DDATE]"

TELEGRAPH_TITLE="Flash Guide — $PROJECT — $DEVICE_NAME"
GUIDE_TEXT="FLASH GUIDE — $PROJECT
Device: $DEVICE_NAME ($CODENAME)
Android: $ANDROID
Build: $BUILD
Security Patch: $PATCH
Build Variant: $VARIANT
Google Services: $GS"
GUIDE_TEXT+="

IMPORTANT
- Unlocking the bootloader normally erases user data. Back up everything first.
- Use firmware appropriate for this device and ROM release.
- Verify every downloaded file before flashing.
- Follow the exact device/ROM instructions supplied by the maintainer.

1. REBOOT TO BOOTLOADER
adb reboot bootloader
fastboot devices"
if ((${#GUIDE_LINES[@]})); then
  GUIDE_TEXT+="

2. FLASH THE SELECTED IMAGES
"
  for line in "${GUIDE_LINES[@]}"; do GUIDE_TEXT+="$line"$'\n'; done
  GUIDE_TEXT+="
After flashing, reboot to recovery:
fastboot reboot recovery"; STEP=3
else
  GUIDE_TEXT+="

2. ENTER RECOVERY
Reboot the device to the recovery supplied for this ROM/device.
"; STEP=3
fi
GUIDE_TEXT+="
${STEP}. INSTALL THE ROM
In recovery, select Apply Update / Apply from ADB, then run:
adb sideload <ROM_FILE>.zip
"
STEP=$((STEP+1))
GUIDE_TEXT+="
${STEP}. FACTORY RESET / FORMAT DATA
Use the recovery's Factory Reset / Format Data option when required for a clean installation.
This erases user data. Do not skip device-specific migration/upgrade instructions."
if [[ "$ROOTM" != None ]]; then
  STEP=$((STEP+1)); GUIDE_TEXT+="

${STEP}. ROOT / MODIFICATION
The selected root implementation is integrated into the uploaded build. Follow the maintainer's documentation for first boot and module setup."
fi
STEP=$((STEP+1)); GUIDE_TEXT+="

${STEP}. REBOOT
Return to the recovery main menu and select Reboot System."
GUIDE_TEXT+="

TERMS OF USE
Flashing is performed at your own risk. The installer is responsible for selecting the correct device, firmware, recovery and files, and for following the instructions correctly. The developer/maintainer is not responsible for damage, data loss, bootloops, bricking, or other failures caused by incorrect installation, unsupported modifications, incompatible firmware, or user error."
GUIDE_JSON_CONTENT="$(jq -Rn --arg t "$GUIDE_TEXT" '[{tag:"pre",children:[$t]}]')"
FLASH_GUIDE_RESPONSE="$(curl --fail --silent --show-error -X POST https://api.telegra.ph/createPage -d "access_token=$TELEGRAPH_TOKEN" --data-urlencode "title=$TELEGRAPH_TITLE" --data-urlencode "author_name=Morp_02" --data-urlencode "author_url=https://t.me/Morp_02" --data-urlencode "content=$GUIDE_JSON_CONTENT" 2>/dev/null)" || FLASH_GUIDE_RESPONSE=''
FLASH_GUIDE_URL="$(jq -r '.result.url // empty' <<< "$FLASH_GUIDE_RESPONSE" 2>/dev/null || true)"

MESSAGE="<b>New Release: $(html "$PROJECT") for $(html "$DEVICE_NAME")</b>"$'\n\n'
MESSAGE+="<b>Device:</b> $(html "$DEVICE_NAME") ($(html "$CODENAME"))"$'\n'
MESSAGE+="<b>Project:</b> $(html "$PROJECT")"$'\n'
MESSAGE+="<b>Android Version:</b> $(html "$ANDROID")"$'\n'
MESSAGE+="<b>Security Patch:</b> $(html "$PATCH")"$'\n'
MESSAGE+="<b>Build Variant:</b> $(html "$VARIANT")"$'\n'
MESSAGE+="<b>Google Services:</b> $(html "$GS")"$'\n'
MESSAGE+="<b>Release Date:</b> $(html "$DDATE")"$'\n'
MESSAGE+="<b>Maintainer:</b> $(html "$AUTHOR")"$'\n'
if [[ -n "$RTAG" ]]; then root_display="$ROOTM"; [[ -n "$ROOT_VERSION" ]] && root_display+=" $ROOT_VERSION"; MESSAGE+="<b>Rooting:</b> $(html "$root_display")"$'\n'; fi
if [[ "$SUSFS" == Enabled ]]; then sus_display="Enabled"; [[ -n "$SUSFS_VERSION" ]] && sus_display+=" $SUSFS_VERSION"; MESSAGE+="<b>SUSFS:</b> $(html "$sus_display")"$'\n'; fi
MESSAGE+=$'\n'"<b>Tag:</b> $(html "$TAG")"$'\n\n'
MESSAGE+="<b>Release Notes:</b>"$'\n'
MESSAGE+='<blockquote>'"$RELEASE_BLOCK"'</blockquote>'$'\n'
MESSAGE+=$'\n'"<b>Files Size Information:</b>"$'\n'
MESSAGE+="$ROWS"
MESSAGE+=$'\n'"Click the buttons below to download the files"

ABOUT_URL='https://khaliq-repos.pages.dev/'
INLINE_KEYBOARD='{"inline_keyboard":['
for ((i=0;i<${#MAIN_URLS[@]};i+=2)); do
  ((i>0)) && INLINE_KEYBOARD+=','
  a="${FILE_TYPES[$i]}"; au="${MAIN_URLS[$i]}"
  INLINE_KEYBOARD+="[{\"text\":\"$a\",\"url\":\"$au\"}"
  if ((i+1<${#MAIN_URLS[@]})); then b="${FILE_TYPES[$((i+1))]}"; bu="${MAIN_URLS[$((i+1))]}"; INLINE_KEYBOARD+=",{\"text\":\"$b\",\"url\":\"$bu\"}"; fi
  INLINE_KEYBOARD+=']'
done
if [[ -n "$FLASH_GUIDE_URL" ]]; then
  [[ ${#MAIN_URLS[@]} -gt 0 ]] && INLINE_KEYBOARD+=','
  INLINE_KEYBOARD+='[{"text":"Flash Guide","url":"'"$FLASH_GUIDE_URL"'"}'
  INLINE_KEYBOARD+=',{"text":"About Developer","url":"'"$ABOUT_URL"'"}]'
elif [[ -n "$ABOUT_URL" ]]; then
  [[ ${#MAIN_URLS[@]} -gt 0 ]] && INLINE_KEYBOARD+=','
  INLINE_KEYBOARD+='[{"text":"About Developer","url":"'"$ABOUT_URL"'"}]'
fi
INLINE_KEYBOARD+=']}'

TEMP_MSG_FILE="$(mktemp)"; printf '%s' "$MESSAGE" > "$TEMP_MSG_FILE"
BANNER_FILE=''; BANNER_FILE_ID=''
resolve_telegram_banner(){
  local url="$1" channel msgid copy_response copied_id photo_id
  if [[ "$url" =~ ^https?://t\.me/([^/?#]+)/([0-9]+)(/)?$ ]]; then channel="${BASH_REMATCH[1]}"; msgid="${BASH_REMATCH[2]}"
  elif [[ "$url" =~ ^https?://telegram\.me/([^/?#]+)/([0-9]+)(/)?$ ]]; then channel="${BASH_REMATCH[1]}"; msgid="${BASH_REMATCH[2]}"
  else return 1; fi
  copy_response="$(curl --fail --silent --show-error --max-time 30 -X POST "https://api.telegram.org/bot$BOT_TOKEN/copyMessage" --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "from_chat_id=@$channel" --data-urlencode "message_id=$msgid" --data-urlencode "disable_notification=true" 2>/dev/null)" || return 1
  copied_id="$(jq -r '.result.message_id // empty' <<< "$copy_response" 2>/dev/null)"
  photo_id="$(jq -r '.result.photo[-1].file_id // empty' <<< "$copy_response" 2>/dev/null)"
  if [[ -n "$copied_id" ]]; then curl --fail --silent --show-error --max-time 20 -X POST "https://api.telegram.org/bot$BOT_TOKEN/deleteMessage" --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "message_id=$copied_id" >/dev/null 2>&1 || true; fi
  [[ -n "$photo_id" ]] || return 1
  printf '%s' "$photo_id"
}
resolve_banner_from_html(){
  local page="$TMP/banner.html" image_url='' page_url="$BANNER_URL"
  if [[ "$page_url" =~ ^https?://(t\.me|telegram\.me)/[^/?#]+/[0-9]+/?$ ]]; then page_url="${page_url}?embed=1"; fi
  curl --fail --location --silent --show-error --max-time 60 -A 'Mozilla/5.0' "$page_url" -o "$page" 2>/dev/null || return 1
  image_url="$(sed -nE 's/.*property="og:image"[^>]*content="([^"]+)".*/\1/p' "$page" | head -n1)"
  [[ -n "$image_url" ]] || image_url="$(sed -nE "s/.*property='og:image'[^>]*content='([^']+)'.*/\1/p" "$page" | head -n1)"
  [[ -n "$image_url" ]] || image_url="$(sed -nE 's/.*name="twitter:image"[^>]*content="([^"]+)".*/\1/p' "$page" | head -n1)"
  [[ -n "$image_url" ]] || image_url="$(sed -nE "s/.*name='twitter:image'[^>]*content='([^']+)'.*/\1/p" "$page" | head -n1)"
  [[ -n "$image_url" ]] || return 1
  image_url="$(printf '%s' "$image_url" | sed 's/&amp;/\&/g')"; [[ "$image_url" =~ ^https?:// ]] || return 1
  BANNER_FILE="$TMP/banner"; curl --fail --location --silent --show-error --max-time 60 -A 'Mozilla/5.0' "$image_url" -o "$BANNER_FILE" 2>/dev/null || return 1
  [[ -s "$BANNER_FILE" ]] && file "$BANNER_FILE" | grep -Eqi 'image|webp'
}
if [[ -n "$BANNER_URL" ]]; then
  if BANNER_FILE_ID="$(resolve_telegram_banner "$BANNER_URL")"; then ok 'Telegram banner resolved from public post'
  elif resolve_banner_from_html; then ok 'Banner image resolved from URL'
  else BANNER_FILE=''; BANNER_FILE_ID=''; warn 'Banner URL could not be resolved to an image; publishing without banner.'; fi
fi

echo
if [[ -n "$BANNER_FILE_ID" ]]; then
  curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "photo=$BANNER_FILE_ID" --data-urlencode "caption@$TEMP_MSG_FILE" --data-urlencode "parse_mode=HTML" --data-urlencode "reply_markup=$INLINE_KEYBOARD" >/dev/null
elif [[ -n "$BANNER_FILE" ]]; then
  curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" -F "chat_id=$CHAT_ID" -F "photo=@$BANNER_FILE" -F "caption=<$TEMP_MSG_FILE" -F "parse_mode=HTML" -F "reply_markup=$INLINE_KEYBOARD" >/dev/null
else
  curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text@$TEMP_MSG_FILE" --data-urlencode "parse_mode=HTML" --data-urlencode "reply_markup=$INLINE_KEYBOARD" >/dev/null
fi || { warn 'Telegram publish failed.'; rm -f "$TEMP_MSG_FILE"; exit 1; }
rm -f "$TEMP_MSG_FILE"
ok 'Telegram release published successfully.'
