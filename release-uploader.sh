#!/usr/bin/env bash
set -u -o pipefail

# Bias8145 multi-series release uploader
# Secrets are never stored in this public script.

msg(){ printf '%s\n' "$*"; }
ok(){ printf '%s\n' "[OK] $*"; }
warn(){ printf '%s\n' "[!] $*" >&2; }
die(){ printf '%s\n' "[ERROR] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
for x in bash curl jq find sed awk sha256sum md5sum stat date mktemp sort; do need "$x"; done

SECRETS_FILE="${PIXEL_UPLOADER_SECRETS:-$HOME/.config/pixel-uploader/secrets.env}"
if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" || -z "${PIXELDRAIN_API_KEY:-}" || -z "${TELEGRAPH_TOKEN:-}" ]]; then
    if [[ -f "$SECRETS_FILE" ]]; then
        perms="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || stat -f '%Lp' "$SECRETS_FILE")"
        [[ "$perms" == 600 ]] || die "Secrets file must have mode 600: $SECRETS_FILE"
        # shellcheck disable=SC1090
        source "$SECRETS_FILE"
    elif [[ -f "$HOME/.build_env" ]]; then
        perms="$(stat -c '%a' "$HOME/.build_env" 2>/dev/null || stat -f '%Lp' "$HOME/.build_env")"
        [[ "$perms" == 600 ]] || die "~/.build_env must have mode 600"
        # shellcheck disable=SC1090
        source "$HOME/.build_env"
    fi
fi
: "${BOT_TOKEN:?Set BOT_TOKEN}"; : "${CHAT_ID:?Set CHAT_ID}"; : "${PIXELDRAIN_API_KEY:?Set PIXELDRAIN_API_KEY}"; : "${TELEGRAPH_TOKEN:?Set TELEGRAPH_TOKEN}"

ROOT="${ANDROID_BUILD_TOP:-$(pwd)}"
OUT="$ROOT/out/target/product"
[[ -d "$OUT" ]] || die "Cannot find $OUT. Run from Android source tree or export ANDROID_BUILD_TOP."

choose(){
    local max="$1" prompt="$2" value
    while :; do
        read -r -p "$prompt" value || exit 1
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= max )); then printf '%s' "$value"; return 0; fi
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
label(){
    local b="$(basename "$1")" l="${b,,}"
    case "$l" in
        *.zip|*.ozip|*.zip.md5) printf 'ROM';;
        boot*.img) printf 'BOOT';;
        init_boot*.img) printf 'INIT BOOT';;
        dtbo*.img) printf 'DTBO';;
        vendor_boot*.img) printf 'VENDOR BOOT';;
        vendor_kernel_boot*.img) printf 'VENDOR KERNEL BOOT';;
        vbmeta_system*.img) printf 'VBMETA SYSTEM';;
        vbmeta_vendor*.img) printf 'VBMETA VENDOR';;
        vbmeta*.img) printf 'VBMETA';;
        *) printf 'FILE';;
    esac
}

mapfile -t DEVICES < <(find "$OUT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
((${#DEVICES[@]})) || die 'No device output found.'
echo; echo 'Build outputs:'
for ((i=0; i<${#DEVICES[@]}; i++)); do printf '  [%d] %s\n' "$((i+1))" "${DEVICES[$i]}"; done
n="$(choose "${#DEVICES[@]}" 'Select device: ')"
CODENAME="${DEVICES[$((n-1))]}"; DOUT="$OUT/$CODENAME"
ANDROID="$(prop ro.build.version.release)"; PATCH="$(prop ro.build.version.security_patch)"; BUILD="$(prop ro.build.id)"; DISPLAY="$(prop ro.build.display.id)"
DEVICE_DETECTED="$(prop ro.product.model)"; [[ "$DEVICE_DETECTED" == Unknown ]] && DEVICE_DETECTED="$(prop ro.product.name)"; [[ "$DEVICE_DETECTED" == Unknown ]] && DEVICE_DETECTED="$CODENAME"
msg "Device: $CODENAME | Android: $ANDROID | Build: $BUILD | SPL: $PATCH"

echo; echo 'Upload:'; echo '  [1] ROM'; echo '  [2] Images'; echo '  [3] ROM + Images'
MODE="$(choose 3 'Select: ')"; FILES=()

if (( MODE == 1 || MODE == 3 )); then
    mapfile -t ROMS < <(find "$DOUT" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.zip.md5' \) | sort)
    ((${#ROMS[@]})) || die 'No ROM package found.'
    echo; echo 'ROM packages:'
    for ((i=0; i<${#ROMS[@]}; i++)); do printf '  [%d] %s\n' "$((i+1))" "$(basename "${ROMS[$i]}")"; done
    n="$(choose "${#ROMS[@]}" 'Select ROM: ')"; FILES+=("${ROMS[$((n-1))]}")
fi

if (( MODE == 2 || MODE == 3 )); then
    IMGS=()
    while IFS= read -r -d '' f; do
        b="$(basename "$f")"
        [[ "$b" =~ ^(boot|init_boot|dtbo|vendor_boot|vendor_kernel_boot|vbmeta|vbmeta_system|vbmeta_vendor)([-_].*)?\.img$ ]] && IMGS+=("$f")
    done < <(find "$DOUT" -maxdepth 1 -type f -iname '*.img' -print0 | sort -z)
    ((${#IMGS[@]})) || die 'No supported images found.'
    echo; echo 'Images:'
    for ((i=0; i<${#IMGS[@]}; i++)); do printf '  [%d] %s\n' "$((i+1))" "$(basename "${IMGS[$i]}")"; done
    while :; do
        read -r -p 'Select images (e.g. 1 3 4): ' raw || exit 1
        normalized="$(printf '%s' "$raw" | tr ',\t\r' '   ' | sed -E 's/[[:space:]]+/ /g;s/^ +//;s/ +$//')"
        [[ -n "$normalized" ]] || { warn 'Select at least one image.'; continue; }
        [[ "$normalized" =~ ^[0-9]+( [0-9]+)*$ ]] || { warn 'Use space-separated numbers, for example: 1 2 6'; continue; }
        selected=(); while read -r number; do selected+=("$number"); done < <(printf '%s\n' "$normalized" | awk '{for(i=1;i<=NF;i++) print $i}')
        good=1; seen=' '
        for number in "${selected[@]}"; do
            (( number >= 1 && number <= ${#IMGS[@]} )) || { good=0; break; }
            [[ "$seen" == *" $number "* ]] && { good=0; break; }
            seen+="$number "
        done
        (( good == 1 && ${#selected[@]} > 0 )) && break
        warn "Enter valid image numbers from 1-${#IMGS[@]}, separated by spaces."
    done
    echo 'Selected images:'
    for number in "${selected[@]}"; do FILES+=("${IMGS[$((number-1))]}"); printf '  - %s\n' "$(basename "${IMGS[$((number-1))]}")"; done
fi

read -r -p "Project name [${DISPLAY:-ROM}]: " PROJECT || exit 1; PROJECT="${PROJECT:-${DISPLAY:-ROM}}"
read -r -p 'Maintainer [Unknown]: ' AUTHOR || exit 1; AUTHOR="${AUTHOR:-Unknown}"
read -r -p "Device name [${DEVICE_DETECTED}]: " DEVICE_NAME || exit 1; DEVICE_NAME="${DEVICE_NAME:-$DEVICE_DETECTED}"
read -r -p 'Banner URL [optional]: ' BANNER_URL || exit 1
[[ -z "$BANNER_URL" || "$BANNER_URL" =~ ^https?:// ]] || die 'Banner URL must start with http:// or https://'

echo; echo 'Variant:'; echo '  [1] GApps Full'; echo '  [2] GApps Core'; echo '  [3] GApps Pico'; echo '  [4] Vanilla'; echo '  [5] microG'
n="$(choose 5 'Select: ')"; VARIANT=('' 'GApps Full' 'GApps Core' 'GApps Pico' 'Vanilla' 'microG')[$n]
echo; echo 'Rooting method:'; echo '  [1] None'; echo '  [2] KSU'; echo '  [3] KSU Next'; echo '  [4] KSU Legacy'; echo '  [5] ReSukiSU'; echo '  [6] SukiSU'
n="$(choose 6 'Select: ')"; ROOTM=('' 'None' 'KSU' 'KSU Next' 'KSU Legacy' 'ReSukiSU' 'SukiSU')[$n]
SUSFS=Disabled
if [[ "$ROOTM" != None ]]; then echo; echo 'SUSFS:'; echo '  [1] Without SUSFS'; echo '  [2] With SUSFS'; n="$(choose 2 'Select: ')"; [[ "$n" == 2 ]] && SUSFS=Enabled; fi

DATE="$(date +%Y-%m-%d)"; RELEASE_ID="$(safe "$PROJECT")_${CODENAME}_$(safe "$VARIANT")_$(safe "$ROOTM")_$(safe "$SUSFS")_$DATE"

msg 'Checking credentials...'
curl --fail --silent --show-error --max-time 20 -u ":$PIXELDRAIN_API_KEY" https://pixeldrain.com/api/user/files >/dev/null || die 'Pixeldrain authentication failed. No files were uploaded.'
curl --fail --silent --show-error --max-time 20 "https://api.telegram.org/bot$BOT_TOKEN/getMe" | jq -e '.ok == true' >/dev/null || die 'Telegram bot authentication failed. No files were uploaded.'
curl --fail --silent --show-error --max-time 20 -X POST https://api.telegra.ph/getPageList -d "access_token=$TELEGRAPH_TOKEN" | jq -e '.ok == true' >/dev/null || die 'Telegraph authentication failed. No files were uploaded.'
ok 'Pixeldrain authentication OK'; ok 'Telegram bot authentication OK'; ok 'Telegraph authentication OK'

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT; MANIFEST="$TMP/files.tsv"; : > "$MANIFEST"
pixeldrain_upload(){
    local f="$1" name="$2" response id
    response="$(curl --fail-with-body -sS --max-time 3600 -u ":$PIXELDRAIN_API_KEY" -F "file=@$f;filename=$name" https://pixeldrain.com/api/file)" || return 1
    id="$(jq -r '.id // empty' <<< "$response")"; [[ -n "$id" ]] || return 1
    printf 'https://pixeldrain.com/u/%s' "$id"
}

echo; echo 'Uploading selected files to Pixeldrain...'; SUCCESS=0
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { warn "Missing file: $f"; continue; }
    base="$(basename "$f")"; ext="${base##*.}"; stem="${base%.*}"
    if [[ "$base" == *.zip.md5 ]]; then name="${base%.zip.md5}_${RELEASE_ID}.zip.md5"; else name="${stem}_${RELEASE_ID}.${ext}"; fi
    size="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")"; md5="$(md5sum "$f" | awk '{print $1}')"; sha="$(sha256sum "$f" | awk '{print $1}')"; type="$(label "$f")"
    if link="$(pixeldrain_upload "$f" "$name")"; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$base" "$name" "$type" "$size" "$md5" "$sha" "$link" >> "$MANIFEST"
        SUCCESS=$((SUCCESS + 1)); ok "$type: uploaded"
    else warn "Pixeldrain upload failed: $base"; fi
done
(( SUCCESS > 0 )) || die 'No files were uploaded to Pixeldrain; Telegram publish cancelled.'

GUIDE="Fastboot Flash Guide for $DEVICE_NAME ($CODENAME)\n\nProject: $PROJECT\nAndroid: $ANDROID\nBuild: $BUILD\nSecurity Patch: $PATCH\nVariant: $VARIANT\nRooting method: $ROOTM\nSUSFS: $SUSFS\nMaintainer: $AUTHOR\n\nFiles:\n"
while IFS=$'\t' read -r original uploaded type size md5 sha link; do
    mb="$(awk -v n="$size" 'BEGIN{printf "%.2f",n/1048576}')"
    GUIDE+="\n$type\nName: $uploaded\nSize: ${mb} MB\nMD5: $md5\nSHA256: $sha\nPixeldrain: $link\n"
done < "$MANIFEST"
GUIDE+='\nFlash instructions:\n1. Reboot to bootloader: fastboot reboot bootloader\n'
step=2
while IFS=$'\t' read -r original uploaded type size md5 sha link; do
    case "$type" in
        BOOT) GUIDE+="$step. Flash boot: fastboot flash --slot all boot $uploaded\n";;
        'INIT BOOT') GUIDE+="$step. Flash init_boot: fastboot flash --slot all init_boot $uploaded\n";;
        DTBO) GUIDE+="$step. Flash dtbo: fastboot flash --slot all dtbo $uploaded\n";;
        'VENDOR BOOT') GUIDE+="$step. Flash vendor_boot: fastboot flash --slot all vendor_boot $uploaded\n";;
        'VENDOR KERNEL BOOT') GUIDE+="$step. Flash vendor_kernel_boot: fastboot flash --slot all vendor_kernel_boot $uploaded\n";;
        VBMETA) GUIDE+="$step. Flash vbmeta: fastboot --disable-verity --disable-verification flash vbmeta $uploaded\n";;
        'VBMETA SYSTEM') GUIDE+="$step. Flash vbmeta_system: fastboot --disable-verity --disable-verification flash vbmeta_system $uploaded\n";;
        'VBMETA VENDOR') GUIDE+="$step. Flash vbmeta_vendor: fastboot --disable-verity --disable-verification flash vbmeta_vendor $uploaded\n";;
        ROM) GUIDE+="$step. Install ROM from recovery: adb sideload $uploaded\n";;
    esac
    step=$((step + 1))
done < "$MANIFEST"
GUIDE+='\nReboot after installation: fastboot reboot recovery\n'

# Build Telegraph JSON with jq instead of hand-written JSON.
TELEGRAPH_CONTENT="$(jq -cn --arg text "$GUIDE" '[{tag:"pre",children:[$text]}]')" || die 'Failed to build Telegraph content JSON.'
TELEGRAPH_RESPONSE="$(curl --fail-with-body -sS -X POST https://api.telegra.ph/createPage \
    --data-urlencode "access_token=$TELEGRAPH_TOKEN" \
    --data-urlencode "title=$PROJECT - $DEVICE_NAME - $DATE" \
    --data-urlencode "author_name=$AUTHOR" \
    --data-urlencode 'author_url=https://khaliq-repos.pages.dev/' \
    --data-urlencode "content=$TELEGRAPH_CONTENT" \
    --data-urlencode 'return_content=false')" || TELEGRAPH_RESPONSE=''
TELEGRAPH_URL=''
if [[ -n "$TELEGRAPH_RESPONSE" ]]; then TELEGRAPH_URL="$(jq -r '.result.url // empty' <<< "$TELEGRAPH_RESPONSE" 2>/dev/null || true)"; fi
[[ -n "$TELEGRAPH_URL" ]] && ok 'Telegraph release guide created.' || warn 'Telegraph guide could not be created; publishing Telegram without Flash Guide button.'

MESSAGE="$(jq -nr --arg project "$PROJECT" --arg device "$DEVICE_NAME" --arg code "$CODENAME" --arg android "$ANDROID" --arg build "$BUILD" --arg spl "$PATCH" --arg variant "$VARIANT" --arg root "$ROOTM" --arg susfs "$SUSFS" --arg author "$AUTHOR" '"<b>New Release: \($project|@html)</b>\n\nDevice: \($device|@html)\nCodename: <code>\($code|@html)</code>\nAndroid: \($android|@html)\nBuild: \($build|@html)\nSecurity Patch: \($spl|@html)\nVariant: \($variant|@html)\nRoot: \($root|@html)\nSUSFS: \($susfs|@html)\nMaintainer: \($author|@html)\n\n<b>Files:</b>"')" 

KEY_ROWS="$TMP/keyrows.ndjson"; : > "$KEY_ROWS"
while IFS=$'\t' read -r original uploaded type size md5 sha link; do
    jq -cn --arg text "Download $type" --arg url "$link" '[{text:$text,url:$url}]' >> "$KEY_ROWS"
    mb="$(awk -v n="$size" 'BEGIN{printf "%.2f MB",n/1048576}')"
    file_block="$(jq -nr --arg type "$type" --arg name "$uploaded" --arg mb "$mb" --arg md5 "$md5" --arg sha "$sha" '"\n\n<b>\($type|@html)</b>\nName: <code>\($name|@html)</code>\nSize: \($mb)\nMD5: <code>\($md5)</code>\nSHA256: <code>\($sha)</code>"')"
    MESSAGE+="$file_block"
done < "$MANIFEST"
if [[ -n "$TELEGRAPH_URL" ]]; then jq -cn --arg url "$TELEGRAPH_URL" '[{text:"Flash Guide",url:$url}]' >> "$KEY_ROWS"; fi
jq -cn '[{text:"About Developer",url:"https://khaliq-repos.pages.dev/"}]' >> "$KEY_ROWS"
REPLY_MARKUP="$(jq -sc '{inline_keyboard:.}' "$KEY_ROWS")" || die 'Failed to build Telegram keyboard JSON.'
# Validate once before sending so malformed JSON can never reach Telegram.
printf '%s' "$REPLY_MARKUP" | jq -e '.inline_keyboard|type=="array"' >/dev/null || die 'Telegram keyboard JSON validation failed.'

MESSAGE+="\n\nRelease published successfully."

if [[ -n "$BANNER_URL" ]]; then
    if curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "photo=$BANNER_URL" \
        --data-urlencode "caption=$MESSAGE" \
        --data-urlencode 'parse_mode=HTML' \
        --data-urlencode "reply_markup=$REPLY_MARKUP" >/dev/null; then
        ok 'Telegram release published with banner.'
    else
        warn 'Banner publish failed; retrying as text message.'
        curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$MESSAGE" \
            --data-urlencode 'parse_mode=HTML' --data-urlencode "reply_markup=$REPLY_MARKUP" >/dev/null || die 'Telegram publish failed.'
        ok 'Telegram release published without banner.'
    fi
else
    curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$MESSAGE" \
        --data-urlencode 'parse_mode=HTML' --data-urlencode "reply_markup=$REPLY_MARKUP" >/dev/null || die 'Telegram publish failed.'
    ok 'Telegram release published.'
fi
