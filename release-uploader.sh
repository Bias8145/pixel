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
html(){ printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g'; }
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
    read -r -p 'Select images (e.g. 1 3 4): ' raw || exit 1
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
n="$(choose 5 'Select: ')"
case "$n" in
  1) VARIANT=GAPPS; GTAG=GAPPS-FULL; GS='GApps Full included'; NOTE='Google Apps (Full) included';;
  2) VARIANT=GAPPS; GTAG=GAPPS-CORE; GS='GApps Core included'; NOTE='Google Apps (Core) included';;
  3) VARIANT=GAPPS; GTAG=GAPPS-PICO; GS='GApps Pico included'; NOTE='Google Apps (Pico) included';;
  4) VARIANT=VANILLA; GTAG=NO-GMS; GS='No Google services'; NOTE='Vanilla build without Google services';;
  5) VARIANT=VANILLA; GTAG=MICROG; GS='microG included'; NOTE='Vanilla build with microG services';;
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
  ROWS+="<b>$(html "$ty")</b> — $(size_of "$sz") | SHA256: <code>${sha:0:8}</code>\n"
  p="$(part_of "$f")"; [[ -n "$p" ]] && GUIDE_LINES+=("fastboot flash $p $(basename "$f")")
done < "$MANIFEST"

ROOT_TAG="$RTAG"; [[ -n "$ROOT_VERSION" ]] && ROOT_TAG+="-$ROOT_VERSION"
SUS_TAG=''; [[ "$SUSFS" == Enabled ]] && SUS_TAG='SUSFS'; [[ -n "$SUSFS_VERSION" && "$SUSFS" == Enabled ]] && SUS_TAG+="-$SUSFS_VERSION"
TAG="[$PROJECT] [$BUILD] [Android $ANDROID] [$GTAG]"; [[ -n "$ROOT_TAG" ]] && TAG+=" [$ROOT_TAG]"; [[ -n "$SUS_TAG" ]] && TAG+=" [$SUS_TAG]"; TAG+=" [$DDATE]"

NOTES="• $NOTE"
[[ "$ROOTM" != None ]] && NOTES+="\n• $ROOTM support included$( [[ -n "$ROOT_VERSION" ]] && printf ' — %s' "$(html "$ROOT_VERSION")" )"
[[ "$SUSFS" == Enabled ]] && NOTES+="\n• SUSFS enabled$( [[ -n "$SUSFS_VERSION" ]] && printf ' — %s' "$(html "$SUSFS_VERSION")" )"
[[ "$ROOTM" == None ]] && NOTES+="\n• No root implementation included"
NOTES+="\n• Installation guide generated for the selected files"

GUIDE_TEXT="Flash Guide — $DEVICE_NAME

Before flashing, verify the device codename and files. Keep a backup of important data.

Fastboot:
1. Reboot to bootloader: adb reboot bootloader
"
if ((${#GUIDE_LINES[@]})); then GUIDE_TEXT+="2. Flash only the selected images:\n"; for line in "${GUIDE_LINES[@]}"; do GUIDE_TEXT+="$line\n"; done; fi
if [[ "$MODE" == 1 || "$MODE" == 3 ]]; then GUIDE_TEXT+="\nRecovery / ROM installation:\n- Reboot to recovery after image flashing.\n- Use Apply Update / ADB Sideload and sideload the selected ROM package.\n- Reboot only after installation completes.\n"; fi
GUIDE_TEXT+="\nTerms of Use and Risk Notice:\nInstallation is performed at your own risk. The developer is not responsible for bootloops, data loss, device damage, failed flashing, or other consequences caused by incorrect installation, incompatible files, or failure to follow the guide. Always verify the device and build before flashing."
GUIDE_JSON="$(jq -n --arg t "$GUIDE_TEXT" '{tag:"pre",children:[$t]}' | jq -c '[.]')"
GUIDE_RES="$(curl --fail --silent --show-error -X POST https://api.telegra.ph/createPage -d "access_token=$TELEGRAPH_TOKEN" --data-urlencode "title=Flash Guide - $DEVICE_NAME - $DDATE" --data-urlencode 'author_name=Bias8145' --data-urlencode 'author_url=https://khaliq-repos.pages.dev/' --data-urlencode "content=$GUIDE_JSON")" || die 'Telegraph guide creation failed.'
GUIDE_URL="$(jq -r '.result.url // empty' <<< "$GUIDE_RES")"; [[ -n "$GUIDE_URL" ]] || die "Telegraph guide creation failed: $(printf '%s' "$GUIDE_RES" | head -c 300)"

PROJECT_H="$(html "$PROJECT")"; DEVICE_H="$(html "$DEVICE_NAME")"; AUTHOR_H="$(html "$AUTHOR")"; BUILD_H="$(html "$BUILD")"; ANDROID_H="$(html "$ANDROID")"; PATCH_H="$(html "$PATCH")"; GS_H="$(html "$GS")"; TAG_H="$(html "$TAG")"; NOTES_H="$(printf '%s' "$NOTES" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')"
MESSAGE="<b>New Release: $PROJECT_H for $DEVICE_H</b>

<b>Device:</b> $CODENAME
<b>Project:</b> $PROJECT_H
<b>Android Version:</b> $ANDROID_H
<b>Security Patch:</b> $PATCH_H
<b>Build Variant:</b> $GTAG
<b>Google Services:</b> $GS_H
<b>Release Date:</b> $DDATE
<b>Maintainer:</b> $AUTHOR_H

<b>Tag:</b> $TAG_H

<b>Release Notes:</b>
<blockquote>$NOTES_H</blockquote>

<b>Files Size Information:</b>
$ROWS"

# Telegram inline keyboard: two columns, preserving actual uploaded file type.
KB='{"inline_keyboard":['
for ((i=0;i<${#MAIN_URLS[@]};i+=2)); do
  ((i>0)) && KB+=','
  KB+='['
  t="${FILE_TYPES[$i]}"; u="${MAIN_URLS[$i]}"; KB+="{\"text\":\"$(printf '%s' "$t" | sed 's/"/\\"/g')\",\"url\":\"$u\"}"
  if ((i+1<${#MAIN_URLS[@]})); then t="${FILE_TYPES[$((i+1))]}"; u="${MAIN_URLS[$((i+1))]}"; KB+=",{\"text\":\"$(printf '%s' "$t" | sed 's/"/\\"/g')\",\"url\":\"$u\"}"; fi
  KB+=']'
done
KB+=",[{\"text\":\"Flash Guide\",\"url\":\"$GUIDE_URL\"},{\"text\":\"About Developer\",\"url\":\"https://khaliq-repos.pages.dev/\"}]]}"
printf '%s' "$KB" | jq -e . >/dev/null || die 'Generated Telegram keyboard JSON is invalid.'

# Banner is downloaded first so Telegram receives a real image file, not a webpage/redirect.
# The publish message itself intentionally contains no Terms of Use; those remain in Flash Guide.
echo; echo 'Publishing to Telegram...'; RES=''; SENT_BANNER=0
if [[ -n "$BANNER_URL" ]]; then
  BANNER="$TMP/banner"
  if curl -L --fail --silent --show-error --max-time 90 -A 'Mozilla/5.0' -o "$BANNER" "$BANNER_URL" && [[ -s "$BANNER" ]] && file "$BANNER" | grep -Eqi 'image|jpeg|png|webp|gif'; then
    RES="$(curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" -F "chat_id=$CHAT_ID" -F "photo=@$BANNER" --form-string "caption=$MESSAGE" -F 'parse_mode=HTML' --form-string "reply_markup=$KB")" || RES=''
    jq -e '.ok==true' <<< "$RES" >/dev/null 2>&1 && SENT_BANNER=1
  else
    warn 'Banner URL could not be downloaded as an image; publishing without banner.'
  fi
fi

if ((SENT_BANNER==0)); then
  RES="$(curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d "chat_id=$CHAT_ID" --data-urlencode "text=$MESSAGE" -d 'parse_mode=HTML' --data-urlencode "reply_markup=$KB")" || RES=''
fi
if ((SENT_BANNER==1)) && ((${#MESSAGE}>1024)); then
  RES2="$(curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d "chat_id=$CHAT_ID" --data-urlencode "text=$MESSAGE" -d 'parse_mode=HTML' --data-urlencode "reply_markup=$KB")" || RES2=''
  jq -e '.ok==true' <<< "$RES2" >/dev/null 2>&1 || die "Telegram detail message failed: $(printf '%s' "$RES2" | head -c 300)"
fi
jq -e '.ok==true' <<< "$RES" >/dev/null 2>&1 || die "Telegram publish failed: $(printf '%s' "$RES" | head -c 300)"
ok 'Telegram publish complete'
[[ -n "$GUIDE_URL" ]] && ok "Telegraph flash guide: $GUIDE_URL"
echo 'Upload complete.'
