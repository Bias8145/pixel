#!/usr/bin/env bash
set -u -o pipefail

msg(){ printf '%s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
for x in bash curl jq find sed awk sha256sum md5sum stat date mktemp sort tr; do need "$x"; done

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
        *.zip|*.ozip|*.zip.md5) echo "ROM" ;;
        boot*.img) echo "BOOT" ;;
        init_boot*.img) echo "INIT BOOT" ;;
        dtbo*.img) echo "DTBO" ;;
        vendor_boot*.img) echo "VENDOR BOOT" ;;
        vendor_kernel_boot*.img) echo "VENDOR KERNEL BOOT" ;;
        vbmeta_system*.img) echo "VBMETA SYSTEM" ;;
        vbmeta_vendor*.img) echo "VBMETA VENDOR" ;;
        vbmeta*.img) echo "VBMETA" ;;
        *) echo "FILE" ;;
    esac
}

display_label(){
    case "$1" in
        "ROM") echo "ROM" ;;
        "BOOT") echo "BOOT" ;;
        "INIT BOOT") echo "INIT BOOT" ;;
        "DTBO") echo "DTBO" ;;
        "VENDOR BOOT") echo "VENDOR BOOT" ;;
        "VENDOR KERNEL BOOT") echo "VENDOR KERNEL BOOT" ;;
        "VBMETA SYSTEM") echo "VBMETA SYSTEM" ;;
        "VBMETA VENDOR") echo "VBMETA VENDOR" ;;
        "VBMETA") echo "VBMETA" ;;
        *) echo "FILE" ;;
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

if (( MODE == 1 || MODE == 3 )); then
    mapfile -t ROMS < <(find "$DOUT" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.zip.md5' \) | sort)
    ((${#ROMS[@]})) || die "No ROM package found."
    echo
echo "ROM packages:"
    for ((i=0;i<${#ROMS[@]};i++)); do printf '  [%d] %s\n' "$((i+1))" "$(basename "${ROMS[$i]}")"; done
    n="$(choose "${#ROMS[@]}" "Select ROM: ")"
    FILES+=("${ROMS[$((n-1))]}")
fi

if (( MODE == 2 || MODE == 3 )); then
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
        good=1; seen=" "
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
echo "Variant:"
echo "  [1] GApps Full"
echo "  [2] GApps Core"
echo "  [3] GApps Pico"
echo "  [4] Vanilla"
echo "  [5] microG"
n="$(choose 5 "Select: ")"
VARIANT=("unused" "GApps Full" "GApps Core" "GApps Pico" "Vanilla" "microG")[$n]

echo
echo "Rooting method:"
echo "  [1] None"
echo "  [2] KSU"
echo "  [3] KSU Next"
echo "  [4] KSU Legacy"
echo "  [5] ReSukiSU"
echo "  [6] SukiSU"
n="$(choose 6 "Select: ")"
ROOTM=("unused" "None" "KSU" "KSU Next" "KSU Legacy" "ReSukiSU" "SukiSU")[$n]
SUSFS="Disabled"
if [[ "$ROOTM" != "None" ]]; then
    echo
echo "SUSFS:"
    echo "  [1] Without SUSFS"
    echo "  [2] With SUSFS"
    n="$(choose 2 "Select: ")"
    [[ "$n" == 2 ]] && SUSFS="Enabled"
fi

DATE="$(date +%Y-%m-%d)"
DISPLAY_DATE="$(date +%d-%m-%Y)"
RELEASE_ID="$(safe "$PROJECT")_${CODENAME}_$(safe "$VARIANT")_$(safe "$ROOTM")_$(safe "$SUSFS")_$DATE"

case "$VARIANT" in
    "GApps Full"|"GApps Core"|"GApps Pico") VARIANT_TAG="GAPPS"; GOOGLE_SERVICES="GApps included" ;;
    "microG") VARIANT_TAG="MICROG"; GOOGLE_SERVICES="microG included" ;;
    *) VARIANT_TAG="VANILLA"; GOOGLE_SERVICES="Not included" ;;
esac
if [[ "$ROOTM" == "KSU Next" ]]; then ROOT_TAG="KSU-Next"; elif [[ "$ROOTM" == "None" ]]; then ROOT_TAG=""; else ROOT_TAG="$(safe "$ROOTM")"; fi
BUILD_TAGS="[$(safe "$PROJECT")]"
[[ -n "$DISPLAY" && "$DISPLAY" != "$BUILD" ]] && BUILD_TAGS+=" [$DISPLAY]"
[[ -n "$BUILD" ]] && BUILD_TAGS+=" [$BUILD]"
BUILD_TAGS+=" [Android $ANDROID] [$VARIANT_TAG]"
[[ -n "$ROOT_TAG" ]] && BUILD_TAGS+=" [$ROOT_TAG]"
[[ "$SUSFS" == Enabled ]] && BUILD_TAGS+=" [SUSFS]"
BUILD_TAGS+=" [$DISPLAY_DATE]"

msg "Checking credentials..."
curl --fail --silent --show-error --max-time 20 -u ":$PIXELDRAIN_API_KEY" https://pixeldrain.com/api/user/files >/dev/null || die "Pixeldrain authentication failed. No files were uploaded."
curl --fail --silent --show-error --max-time 20 "https://api.telegram.org/bot$BOT_TOKEN/getMe" | jq -e '.ok == true' >/dev/null || die "Telegram bot authentication failed. No files were uploaded."
curl --fail --silent --show-error --max-time 20 -X POST https://api.telegra.ph/getPageList -d "access_token=$TELEGRAPH_TOKEN" | jq -e '.ok == true' >/dev/null || die "Telegraph authentication failed. No files were uploaded."
ok "Pixeldrain authentication OK"; ok "Telegram bot authentication OK"; ok "Telegraph authentication OK"

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
    if [[ "$base" == *.zip.md5 ]]; then name="${base%.zip.md5}_${RELEASE_ID}.zip.md5"; else name="${stem}_${RELEASE_ID}.${ext}"; fi
    size="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"
    md5="$(md5sum "$f" | awk '{print $1}')"
    sha="$(sha256sum "$f" | awk '{print $1}')"
    type="$(file_type "$f")"
    if link="$(pixeldrain_upload "$f" "$name")"; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$base" "$name" "$type" "$size" "$md5" "$sha" "$link" >>"$MANIFEST"
        SUCCESS=$((SUCCESS+1))
        ok "$type: uploaded"
    else
        warn "Pixeldrain upload failed: $base"
    fi
done
((SUCCESS > 0)) || die "No files were uploaded to Pixeldrain; Telegram publish cancelled."

GUIDE=$'Fastboot Flash Guide\n\n'
GUIDE+="Release: $PROJECT"$'\n'
GUIDE+="Device: $DEVICE_NAME ($CODENAME)"$'\n'
GUIDE+="Android: $ANDROID"$'\n'
GUIDE+="Security Patch: $PATCH"$'\n'
GUIDE+="Build: $BUILD"$'\n'
GUIDE+="Variant: $VARIANT"$'\n'
GUIDE+="Rooting method: $ROOTM"$'\n'
GUIDE+="SUSFS: $SUSFS"$'\n'
GUIDE+="Maintainer: $AUTHOR"$'\n\n'
GUIDE+=$'Files:\n'
while IFS=$'\t' read -r original uploaded type size md5 sha link; do
    mb="$(awk -v n="$size" 'BEGIN{printf "%.2f",n/1048576}')"
    GUIDE+=$'\n'"$(display_label "$type")"$'\n'
    GUIDE+="Name: $uploaded"$'\n'
    GUIDE+="Size: $mb MB"$'\n'
    GUIDE+="MD5: $md5"$'\n'
    GUIDE+="SHA256: $sha"$'\n'
    GUIDE+="Pixeldrain: $link"$'\n'
done <"$MANIFEST"
GUIDE+=$'\nFlash instructions:\n1. Reboot to bootloader: fastboot reboot bootloader\n'
step=2
while IFS=$'\t' read -r original uploaded type size md5 sha link; do
    case "$type" in
        BOOT) GUIDE+="$step. fastboot flash --slot all boot $uploaded"$'\n' ;;
        "INIT BOOT") GUIDE+="$step. fastboot flash --slot all init_boot $uploaded"$'\n' ;;
        DTBO) GUIDE+="$step. fastboot flash --slot all dtbo $uploaded"$'\n' ;;
        "VENDOR BOOT") GUIDE+="$step. fastboot flash --slot all vendor_boot $uploaded"$'\n' ;;
        "VENDOR KERNEL BOOT") GUIDE+="$step. fastboot flash --slot all vendor_kernel_boot $uploaded"$'\n' ;;
        VBMETA) GUIDE+="$step. fastboot --disable-verity --disable-verification flash vbmeta $uploaded"$'\n' ;;
        "VBMETA SYSTEM") GUIDE+="$step. fastboot --disable-verity --disable-verification flash vbmeta_system $uploaded"$'\n' ;;
        "VBMETA VENDOR") GUIDE+="$step. fastboot --disable-verity --disable-verification flash vbmeta_vendor $uploaded"$'\n' ;;
        ROM) GUIDE+="$step. adb sideload $uploaded"$'\n' ;;
    esac
    step=$((step+1))
done <"$MANIFEST"
GUIDE+=$'\nReboot after installation: fastboot reboot\n'

GUIDE_JSON="$(jq -cn --arg text "$GUIDE" '[{tag:"pre",children:[$text]}]')"
TELEGRAPH_RESPONSE="$(curl -sS -X POST https://api.telegra.ph/createPage -d "access_token=$TELEGRAPH_TOKEN" --data-urlencode "title=Flash Guide - $PROJECT - $DISPLAY_DATE" --data-urlencode "author_name=$AUTHOR" --data-urlencode "author_url=https://khaliq-repos.pages.dev/" --data-urlencode "content=$GUIDE_JSON")"
FLASH_GUIDE_URL="$(jq -r '.result.url // empty' <<<"$TELEGRAPH_RESPONSE" 2>/dev/null || true)"

# Telegram release message uses real newlines; no literal \\n text.
TELEGRAM_MESSAGE=$'<b>New Release: '"$(html "$PROJECT")"$'</b>\n\n'
TELEGRAM_MESSAGE+='<b>Device:</b> '"$(html "$DEVICE_NAME")"$'\n'
TELEGRAM_MESSAGE+='<b>Project:</b> '"$(html "$PROJECT")"$'\n'
TELEGRAM_MESSAGE+='<b>Android Version:</b> '"$(html "$ANDROID")"$'\n'
TELEGRAM_MESSAGE+='<b>Security Patch:</b> '"$(html "$PATCH")"$'\n'
TELEGRAM_MESSAGE+='<b>Build Variant:</b> '"$(html "$VARIANT_TAG")"$'\n'
TELEGRAM_MESSAGE+='<b>Google Services:</b> '"$(html "$GOOGLE_SERVICES")"$'\n'
TELEGRAM_MESSAGE+='<b>Release Date:</b> '"$(html "$DISPLAY_DATE")"$'\n'
TELEGRAM_MESSAGE+='<b>Maintainer:</b> '"$(html "$AUTHOR")"$'\n\n'
TELEGRAM_MESSAGE+='<b>Tag:</b> '"$(html "$BUILD_TAGS")"$'\n\n'
TELEGRAM_MESSAGE+='<b>Release Notes:</b>\n'
[[ "$GOOGLE_SERVICES" == "GApps included" ]] && TELEGRAM_MESSAGE+=$'✅ Google Apps included\n'
[[ "$GOOGLE_SERVICES" == "GApps included" ]] && TELEGRAM_MESSAGE+=$'✅ Google services integration\n'
[[ "$GOOGLE_SERVICES" == "microG included" ]] && TELEGRAM_MESSAGE+=$'✅ microG included\n'
[[ "$ROOTM" != "None" ]] && TELEGRAM_MESSAGE+="$(html "✅ $ROOTM support included")"$'\n'
[[ "$SUSFS" == Enabled ]] && TELEGRAM_MESSAGE+=$'✅ SUSFS (Suspicious File System) enabled\n'
TELEGRAM_MESSAGE+=$'⚠️ Always backup your data before flashing\n'
TELEGRAM_MESSAGE+=$'Follow the flash guide for proper installation\n\n'
TELEGRAM_MESSAGE+='<b>Files Size Information:</b>\n'
while IFS=$'\t' read -r original uploaded type size md5 sha link; do
    mb="$(awk -v n="$size" 'BEGIN{printf "%.1f",n/1048576}')"
    label="$(display_label "$type")"
    TELEGRAM_MESSAGE+="▫️ <b>$(html "$label")</b> – ${mb} MB | MD5: <code>${md5:0:8}</code> | SHA: <code>${sha:0:8}</code>"$'\n'
done <"$MANIFEST"
TELEGRAM_MESSAGE+=$'\nClick the buttons below to download the files'

BUTTON_JSON_LINES=()
while IFS=$'\t' read -r original uploaded type size md5 sha link; do
    label="$(display_label "$type")"
    BUTTON_JSON_LINES+=("$(jq -cn --arg text "$label" --arg url "$link" '{text:$text,url:$url}')")
done <"$MANIFEST"

KEYBOARD_JSON="$(printf '%s\n' "${BUTTON_JSON_LINES[@]}" | jq -sc '{inline_keyboard:([.[]] | to_entries | reduce .[] as $item ({rows:[],current:[]}; .current += [$item.value] | if (.current|length)==2 then .rows += [.current] | .current=[] else . end) | .rows + (if (.current|length)>0 then [.current] else [] end))}')"
if [[ -n "$FLASH_GUIDE_URL" ]]; then KEYBOARD_JSON="$(jq -c --arg url "$FLASH_GUIDE_URL" '.inline_keyboard += [[{text:"Flash Guide",url:$url}]]' <<<"$KEYBOARD_JSON")"; fi
KEYBOARD_JSON="$(jq -c '.inline_keyboard += [[{text:"About Developer",url:"https://khaliq-repos.pages.dev/"}]]' <<<"$KEYBOARD_JSON")"
jq -e . >/dev/null <<<"$KEYBOARD_JSON" || die "Generated Telegram keyboard is invalid JSON."

send_result=""
if [[ -n "$BANNER_URL" ]]; then
    send_result="$(curl -sS -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" -d chat_id="$CHAT_ID" --data-urlencode photo="$BANNER_URL" --data-urlencode caption="$TELEGRAM_MESSAGE" -d parse_mode=HTML --data-urlencode reply_markup="$KEYBOARD_JSON")"
    if ! jq -e '.ok == true' >/dev/null <<<"$send_result"; then
        warn "Banner send failed; falling back to text message."
        send_result="$(curl -sS -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$TELEGRAM_MESSAGE" -d parse_mode=HTML --data-urlencode reply_markup="$KEYBOARD_JSON")"
    fi
else
    send_result="$(curl -sS -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" --data-urlencode text="$TELEGRAM_MESSAGE" -d parse_mode=HTML --data-urlencode reply_markup="$KEYBOARD_JSON")"
fi

if jq -e '.ok == true' >/dev/null <<<"$send_result"; then
    ok "Telegram release published successfully."
else
    warn "Telegram publish failed: $(jq -r '.description // "unknown error"' <<<"$send_result" 2>/dev/null || printf '%s' "$send_result")"
    exit 1
fi

printf '%s\n' "$TELEGRAM_MESSAGE" >"$TMP/release-message.html"
printf '%s\n' "$KEYBOARD_JSON" >"$TMP/telegram-keyboard.json"
printf '%s\n' "$GUIDE" >"$TMP/flash-guide.txt"
msg "Release ID: $RELEASE_ID"
