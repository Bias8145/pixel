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
    [[ "$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || stat -f '%Lp' "$SECRETS_FILE")" == 600 ]] || die "Secrets file must have mode 600: $SECRETS_FILE"
    source "$SECRETS_FILE"
  elif [[ -f "$HOME/.build_env" ]]; then
    [[ "$(stat -c '%a' "$HOME/.build_env" 2>/dev/null || stat -f '%Lp' "$HOME/.build_env")" == 600 ]] || die "~/.build_env must have mode 600"
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
    if [[ "$v" =~ ^[0-9]+$ ]] && ((v>=1&&v<=max)); then printf '%s' "$v"; return; fi
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

type_of(){
  local b l; b="$(basename "$1")"; l="${b,,}"
  case "$l" in
    *.zip|*.ozip|*.zip.md5) echo ROM ;;
    boot.img|boot[_-]*.img) echo BOOT ;;
    dtbo.img|dtbo[_-]*.img) echo DTBO ;;
    vendor_boot.img|vendor_boot[_-]*.img|vendor-boot*) echo "VENDOR BOOT" ;;
    vendor_kernel_boot.img|vendor_kernel_boot[_-]*.img|vendor-kernel-boot*) echo "VENDOR KERNEL BOOT" ;;
    init_boot.img|init_boot[_-]*.img|init-boot*) echo "INIT BOOT" ;;
    vbmeta_system.img|vbmeta_system[_-]*.img|vbmeta-system*) echo "VBMETA SYSTEM" ;;
    vbmeta_vendor.img|vbmeta_vendor[_-]*.img|vbmeta-vendor*) echo "VBMETA VENDOR" ;;
    vbmeta.img|vbmeta[_-]*.img|vbmeta-*) echo VBMETA ;;
    recovery.img|recovery[_-]*.img) echo RECOVERY ;;
    *.img) echo IMAGE ;;
    *) echo FILE ;;
  esac
}
part_of(){
  case "$(type_of "$1")" in
    BOOT) echo boot ;;
    DTBO) echo dtbo ;;
    "VENDOR BOOT") echo vendor_boot ;;
    "VENDOR KERNEL BOOT") echo vendor_kernel_boot ;;
    "INIT BOOT") echo init_boot ;;
    VBMETA) echo vbmeta ;;
    "VBMETA SYSTEM") echo vbmeta_system ;;
    "VBMETA VENDOR") echo vbmeta_vendor ;;
    RECOVERY) echo recovery ;;
    *) echo ;;
  esac
}
size_of(){ awk -v b="$1" 'BEGIN{if(b>=1073741824)printf "%.2f GB",b/1073741824;else if(b>=1048576)printf "%.1f MB",b/1048576;else if(b>=1024)printf "%.1f KB",b/1024;else printf "%d B",b}'; }

mapfile -t DEVICES < <(find "$OUT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
((${#DEVICES[@]})) || die "No device output found."
echo; echo "Build outputs:"
for ((i=0;i<${#DEVICES[@]};i++)); do printf '  [%d] %s\n' "$((i+1))" "${DEVICES[$i]}"; done
n="$(choose "${#DEVICES[@]}" 'Select device: ')"
CODENAME="${DEVICES[$((n-1))]}"
DOUT="$OUT/$CODENAME"
ANDROID="$(prop ro.build.version.release)"
PATCH="$(prop ro.build.version.security_patch)"
BUILD="$(prop ro.build.id)"
DISPLAY="$(prop ro.build.display.id)"
DETECTED="$(prop ro.product.model)"
[[ "$DETECTED" == Unknown ]] && DETECTED="$(prop ro.product.name)"
[[ "$DETECTED" == Unknown ]] && DETECTED="$CODENAME"
msg "Device: $CODENAME | Android: $ANDROID | Build: $BUILD | SPL: $PATCH"

echo; echo "Upload:"; echo '  [1] ROM'; echo '  [2] Images'; echo '  [3] ROM + Images'
MODE="$(choose 3 'Select: ')"
FILES=()

if ((MODE==1||MODE==3)); then
  mapfile -t ROMS < <(find "$DOUT" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.zip.md5' \) | sort)
  ((${#ROMS[@]})) || die "No ROM package found."
  echo; echo "ROM packages:"
  for ((i=0;i<${#ROMS[@]};i++)); do printf '  [%d] %s\n' "$((i+1))" "$(basename "${ROMS[$i]}")"; done
  n="$(choose "${#ROMS[@]}" 'Select ROM: ')"
  FILES+=("${ROMS[$((n-1))]}")
fi

if ((MODE==2||MODE==3)); then
  IMGS=()
  while IFS= read -r -d '' f; do
    b="$(basename "$f")"
    [[ "${b,,}" =~ ^(boot|init_boot|dtbo|vendor_boot|vendor_kernel_boot|vbmeta|vbmeta_system|vbmeta_vendor|recovery)([-_].*)?\.img$ ]] && IMGS+=("$f")
  done < <(find "$DOUT" -maxdepth 1 -type f -iname '*.img' -print0 | sort -z)
  ((${#IMGS[@]})) || die "No supported images found."
  echo; echo "Images:"
  for ((i=0;i<${#IMGS[@]};i++)); do printf '  [%d] %s\n' "$((i+1))" "$(basename "${IMGS[$i]}")"; done
  while :; do
    read -r -p 'Select images (e.g. 1 3 4): ' raw || exit 1
    norm="$(printf '%s' "$raw" | tr ',\t\r' '   ' | sed -E 's/[[:space:]]+/ /g;s/^ +//;s/ +$//')"
    [[ "$norm" =~ ^[0-9]+( [0-9]+)*$ ]] || { warn 'Use space-separated numbers, for example: 1 2 6'; continue; }
    sel=(); while read -r x; do sel+=("$x"); done < <(printf '%s\n' "$norm" | awk '{for(i=1;i<=NF;i++)print $i}')
    good=1; seen=' '
    for x in "${sel[@]}"; do
      ((x>=1&&x<=${#IMGS[@]})) || good=0
      [[ "$seen" == *" $x "* ]] && good=0
      seen+="$x "
    done
    ((good)) && break
    warn "Enter valid image numbers from 1-${#IMGS[@]}, separated by spaces."
  done
  echo "Selected images:"
  for x in "${sel[@]}"; do
    FILES+=("${IMGS[$((x-1))]}")
    printf '  - %s\n' "$(basename "${IMGS[$((x-1))]}")"
  done
fi

read -r -p "Project name [${DISPLAY:-ROM}]: " PROJECT || exit 1
PROJECT="${PROJECT:-${DISPLAY:-ROM}}"
read -r -p 'Maintainer [Unknown]: ' AUTHOR || exit 1
AUTHOR="${AUTHOR:-Unknown}"
read -r -p "Device name [${DETECTED}]: " DEVICE_NAME || exit 1
DEVICE_NAME="${DEVICE_NAME:-$DETECTED}"
read -r -p 'Banner URL [optional]: ' BANNER_URL || exit 1
[[ -z "$BANNER_URL" || "$BANNER_URL" =~ ^https?:// ]] || die 'Banner URL must start with http:// or https://'

echo; echo "Build Variant:"; echo '  [1] GApps Full'; echo '  [2] GApps Core'; echo '  [3] GApps Pico'; echo '  [4] Vanilla (No Google)'; echo '  [5] Vanilla + microG'
n="$(choose 5 'Select: ')"
case "$n" in
  1) VARIANT=GAPPS; GTAG=GAPPS-FULL; GS='GApps Full included'; NOTE='Google Apps (Full) included'; GM=gapps ;;
  2) VARIANT=GAPPS; GTAG=GAPPS-CORE; GS='GApps Core included'; NOTE='Google Apps (Core) included'; GM=gapps ;;
  3) VARIANT=GAPPS; GTAG=GAPPS-PICO; GS='GApps Pico included'; NOTE='Google Apps (Pico) included'; GM=gapps ;;
  4) VARIANT=VANILLA; GTAG=NO-GMS; GS='No Google services'; NOTE='Vanilla build without Google services'; GM=none ;;
  5) VARIANT=VANILLA; GTAG=MICROG; GS='microG included'; NOTE='Vanilla build with microG services'; GM=microg ;;
esac

echo; echo "Rooting method:"; echo '  [1] None'; echo '  [2] KSU'; echo '  [3] KSU Next'; echo '  [4] KSU Legacy'; echo '  [5] ReSukiSU'; echo '  [6] SukiSU'
n="$(choose 6 'Select: ')"
case "$n" in
  1) ROOTM=None; RTAG= ;;
  2) ROOTM=KSU; RTAG=KSU ;;
  3) ROOTM='KSU Next'; RTAG=KSU-Next ;;
  4) ROOTM='KSU Legacy'; RTAG=KSU-Legacy ;;
  5) ROOTM=ReSukiSU; RTAG=ReSukiSU ;;
  6) ROOTM=SukiSU; RTAG=SukiSU ;;
esac
SUSFS=Disabled
if [[ "$ROOTM" != None ]]; then
  echo; echo "SUSFS:"; echo '  [1] Without SUSFS'; echo '  [2] With SUSFS'
  n="$(choose 2 'Select: ')"
  [[ "$n" == 2 ]] && SUSFS=Enabled
fi

DATE="$(date +%Y-%m-%d)"
DDATE="$(date +%d-%m-%Y)"
RELEASE_ID="$(safe "$PROJECT")_${CODENAME}_${VARIANT}_${GTAG}_$(safe "$ROOTM")_$(safe "$SUSFS")_$DATE"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MANIFEST="$TMP/files.tsv"
: > "$MANIFEST"

curl --fail --silent --show-error --max-time 20 -u ":$PIXELDRAIN_API_KEY" https://pixeldrain.com/api/user/files >/dev/null || die "Pixeldrain authentication failed. No files were uploaded."
curl --fail --silent --show-error --max-time 20 "https://api.telegram.org/bot$BOT_TOKEN/getMe" | jq -e '.ok==true' >/dev/null || die "Telegram bot authentication failed. No files were uploaded."
curl --fail --silent --show-error --max-time 20 -X POST https://api.telegra.ph/getPageList -d "access_token=$TELEGRAPH_TOKEN" | jq -e '.ok==true' >/dev/null || die "Telegraph authentication failed. No files were uploaded."
ok "Pixeldrain authentication OK"; ok "Telegram bot authentication OK"; ok "Telegraph authentication OK"

upload(){
  local f="$1" name="$2" r id
  r="$(curl --fail-with-body -sS --max-time 3600 -u ":$PIXELDRAIN_API_KEY" -F "file=@$f;filename=$name" https://pixeldrain.com/api/file)" || return 1
  id="$(jq -r '.id // empty' <<< "$r")"
  [[ -n "$id" ]] || return 1
  printf 'https://pixeldrain.com/u/%s' "$id"
}

echo; echo "Uploading selected files to Pixeldrain..."; OKN=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  base="$(basename "$f")"; ext="${base##*.}"; stem="${base%.*}"
  [[ "$base" == *.zip.md5 ]] && name="${base%.zip.md5}_${RELEASE_ID}.zip.md5" || name="${stem}_${RELEASE_ID}.${ext}"
  sz="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"
  md5="$(md5sum "$f" | awk '{print $1}')"
  sha="$(sha256sum "$f" | awk '{print $1}')"
  ty="$(type_of "$f")"
  url="$(upload "$f" "$name")" || { warn "Pixeldrain upload failed: $base"; continue; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$name" "$url" "$sz" "$md5" "$sha" "$ty" >> "$MANIFEST"
  ok "FILE: $base uploaded"; OKN=$((OKN+1))
done
((OKN>0)) || die "No files were uploaded to Pixeldrain; Telegram publish cancelled."

TITLE="$(clean "$PROJECT")"; DEV="$(clean "$DEVICE_NAME")"; AUTH="$(clean "$AUTHOR")"; A="$(clean "$ANDROID")"; P="$(clean "$PATCH")"; V="$(clean "$VARIANT")"; G="$(clean "$GS")"; D="$(clean "$DDATE")"
TAG="[$TITLE]"
[[ "$DISPLAY" != Unknown ]] && TAG+=" [$(clean "$DISPLAY")]"
[[ "$BUILD" != Unknown ]] && TAG+=" [$(clean "$BUILD")]"
TAG+=" [Android $A] [$V] [$GTAG]"
[[ -n "$RTAG" ]] && TAG+=" [$RTAG]"
[[ "$SUSFS" == Enabled ]] && TAG+=' [SUSFS]'
TAG+=" [$D]"

ROWS=''; CMDS=''; ROM_NAME=''
while IFS=$'\t' read -r orig name url sz md5 sha ty; do
  [[ -n "$url" ]] || continue
  label="$ty"
  rowsize="$(size_of "$sz")"
  ROWS+="▫️ $(clean "$label") — $(clean "$rowsize") | MD5: ${md5:0:8} | SHA: ${sha:0:8}"$'\n'
  part="$(part_of "$orig")"
  [[ -n "$part" ]] && CMDS+="fastboot flash $part $(basename "$orig")"$'\n'
  [[ "$ty" == ROM ]] && ROM_NAME="$name"
done < "$MANIFEST"
[[ -n "$ROM_NAME" ]] || ROM_NAME="<selected-ROM>.zip"

NOTES="• $(clean "$NOTE")"$'\n'
[[ "$ROOTM" != None ]] && NOTES+="• $(clean "$ROOTM support included")"$'\n'
[[ "$SUSFS" == Enabled ]] && NOTES+='• SUSFS (Suspicious File System) enabled'$'\n'
NOTES+='• Advanced users recommended'

if [[ "$CODENAME" == bramble ]]; then
  GUIDE="$(cat <<G
Fastboot / Recovery Flash Guide — $DEVICE_NAME ($CODENAME)

1. Back up your data and make sure the bootloader is unlocked.
2. Install current Android platform-tools (adb/fastboot).
3. Boot to bootloader:
   adb -d reboot bootloader
4. Verify the connection:
   fastboot devices
5. Flash only the selected images:
$CMDS
6. Select Recovery Mode from the bootloader menu.
7. For a clean installation, use Factory Reset -> Format data / factory reset.
8. Select Apply Update -> Apply from ADB.
9. Sideload the selected ROM:
   adb -d sideload $ROM_NAME
10. $([ "$GM" = gapps ] && echo "This build already contains $GS. Do not sideload another GApps package unless the ROM documentation explicitly requires it." || echo "No separate GApps package is required for this variant.")
11. Reboot to system.
G
)"
else
  GUIDE="$(cat <<G
Fastboot / Recovery Flash Guide — $DEVICE_NAME ($CODENAME)

1. Back up your data and confirm the bootloader is unlocked.
2. Install current Android platform-tools.
3. Boot to bootloader:
   adb -d reboot bootloader
4. Verify:
   fastboot devices
5. Flash only the selected images to their matching partitions:
$CMDS
6. Boot the recovery recommended by the ROM/device maintainer.
7. Follow the ROM's documented Factory Reset / Format Data procedure for a clean installation.
8. Select Apply Update / Apply from ADB and sideload:
   adb -d sideload $ROM_NAME
9. $([ "$GM" = gapps ] && echo "This build already contains $GS. Do not add another GApps package unless explicitly required." || echo "No separate GApps package is required for this variant.")
10. Reboot to system.
G
)"
fi

TCONTENT="$(jq -nc --arg t "$GUIDE" '[{"tag":"pre","children":[$t]}]')"
TRES="$(curl --fail --silent --show-error -X POST https://api.telegra.ph/createPage -d "access_token=$TELEGRAPH_TOKEN" --data-urlencode "title=Flash Guide - $PROJECT - $CODENAME" --data-urlencode 'author_name=Bias8145' --data-urlencode 'author_url=https://khaliq-repos.pages.dev/' --data-urlencode "content=$TCONTENT")" || TRES=""
GUIDE_URL="$(jq -r '.result.url // empty' <<< "$TRES" 2>/dev/null || true)"
ABOUT='https://khaliq-repos.pages.dev/'

declare -a BUTTON_ROWS=()
while IFS=$'\t' read -r orig name url sz md5 sha ty; do
  [[ -n "$url" ]] || continue
  label="$ty"
  [[ "$ty" == ROM ]] && label='ROM'
  BUTTON_ROWS+=("$label"$'\t'"$url")
done < "$MANIFEST"

button_json(){
  local text="$1" url="$2"
  jq -nc --arg t "$text" --arg u "$url" '[{"text":$t,"url":$u}]'
}
KB='{"inline_keyboard":['
add_row=1
append_row(){
  local row="$1"
  ((add_row)) || KB+=","
  KB+="$row"
  add_row=0
}

if ((${#BUTTON_ROWS[@]}==4)); then
  IFS=$'\t' read -r a_label a_url <<< "${BUTTON_ROWS[0]}"
  IFS=$'\t' read -r b_label b_url <<< "${BUTTON_ROWS[1]}"
  IFS=$'\t' read -r c_label c_url <<< "${BUTTON_ROWS[2]}"
  IFS=$'\t' read -r d_label d_url <<< "${BUTTON_ROWS[3]}"
  append_row "$(jq -nc --arg a "$a_label" --arg au "$a_url" --arg b "$b_label" --arg bu "$b_url" '[{"text":$a,"url":$au},{"text":$b,"url":$bu}]')"
  append_row "$(jq -nc --arg a "$c_label" --arg au "$c_url" --arg b "$d_label" --arg bu "$d_url" '[{"text":$a,"url":$au},{"text":$b,"url":$bu}]')"
elif ((${#BUTTON_ROWS[@]}==2)); then
  IFS=$'\t' read -r a_label a_url <<< "${BUTTON_ROWS[0]}"
  IFS=$'\t' read -r b_label b_url <<< "${BUTTON_ROWS[1]}"
  append_row "$(jq -nc --arg a "$a_label" --arg au "$a_url" --arg b "$b_label" --arg bu "$b_url" '[{"text":$a,"url":$au},{"text":$b,"url":$bu}]')"
else
  row_count=0
  for item in "${BUTTON_ROWS[@]}"; do
    IFS=$'\t' read -r label url <<< "$item"
    if ((row_count%2==0)); then pending_label="$label"; pending_url="$url"; else append_row "$(jq -nc --arg a "$pending_label" --arg au "$pending_url" --arg b "$label" --arg bu "$url" '[{"text":$a,"url":$au},{"text":$b,"url":$bu}]')"; fi
    row_count=$((row_count+1))
  done
  if ((row_count%2==1)); then append_row "$(button_json "$pending_label" "$pending_url")"; fi
fi

if [[ -n "$GUIDE_URL" ]]; then
  append_row "$(jq -nc --arg g "$GUIDE_URL" --arg a "$ABOUT" '[{"text":"Flash Guide","url":$g},{"text":"About Developer","url":$a}]')"
else
  append_row "$(button_json 'About Developer' "$ABOUT")"
fi
KB+=']}'
jq -e . >/dev/null <<< "$KB" || die 'Internal error: invalid Telegram keyboard JSON.'

MESSAGE="<b>New Release: $TITLE</b>

<b>Device:</b> $DEV
<b>Project:</b> $TITLE
<b>Android Version:</b> $A
<b>Security Patch:</b> $P
<b>Build Variant:</b> $V
<b>Google Services:</b> $G
<b>Release Date:</b> $D
<b>Maintainer:</b> $AUTH

<b>Tag:</b> $TAG

<b>Release Notes:</b>
<blockquote>$NOTES</blockquote>

⚠️ <b>Terms of Use</b>
Flashing is performed at your own risk. The installer is responsible for selecting the correct device, firmware, recovery, ROM and image files and for following the installation procedure correctly. The developer/maintainer is not responsible for failures, data loss, bootloops, or device damage caused by incorrect installation, incompatible files, unsupported modifications, or user error.

<b>Files Size Information:</b>
$ROWS"
printf '%s\n' "$MESSAGE" > "$TMP/message.html"

BANNER=''
if [[ -n "$BANNER_URL" ]]; then
  BANNER="$TMP/banner"
  if curl -L --fail --silent --show-error --max-time 60 -o "$BANNER" "$BANNER_URL" && file "$BANNER" | grep -Eiq 'image data|JPEG|PNG|WebP'; then
    ok 'Banner downloaded'
  else
    warn 'Banner URL did not return a supported image; publishing without banner.'
    BANNER=''
  fi
fi

echo; echo 'Publishing to Telegram...'; RES=''
if [[ -n "$BANNER" ]]; then
  chars="$(wc -m < "$TMP/message.html" | tr -d ' ')"
  if ((chars<=1024)); then
    RES="$(curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" -F "chat_id=$CHAT_ID" -F "photo=@$BANNER" --form-string "caption=$(cat "$TMP/message.html")" -F 'parse_mode=HTML' --form-string "reply_markup=$KB")" || RES=''
  else
    RES="$(curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" -F "chat_id=$CHAT_ID" -F "photo=@$BANNER" --form-string "caption=<b>New Release: $TITLE</b>" -F 'parse_mode=HTML')" || RES=''
    if jq -e '.ok==true' <<< "$RES" >/dev/null 2>&1; then
      RES="$(curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d "chat_id=$CHAT_ID" --data-urlencode "text@${TMP}/message.html" -d 'parse_mode=HTML' --data-urlencode "reply_markup=$KB")" || RES=''
    fi
  fi
else
  RES="$(curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d "chat_id=$CHAT_ID" --data-urlencode "text@${TMP}/message.html" -d 'parse_mode=HTML' --data-urlencode "reply_markup=$KB")" || RES=''
fi
jq -e '.ok==true' <<< "$RES" >/dev/null 2>&1 || { warn "Telegram publish failed: $(printf '%s' "$RES" | head -c 500)"; exit 1; }
ok 'Telegram publish complete'
[[ -n "$GUIDE_URL" ]] && ok "Telegraph flash guide: $GUIDE_URL"
echo 'Upload complete.'
