#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

# Bias8145 multi-series release uploader
# Public script: secrets are NEVER stored here.
# Supported secrets files:
#   $PIXEL_UPLOADER_SECRETS (preferred when set)
#   ~/.config/pixel-uploader/secrets.env
#   ~/.build_env

msg(){ printf '%s\n' "$*"; }
ok(){ printf '%s\n' "$*"; }
warn(){ printf '%s\n' "! $*" >&2; }
die(){ printf '%s\n' "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

for x in curl jq find sed awk sha256sum md5sum stat date mktemp; do need "$x"; done

SECRETS_FILE="${PIXEL_UPLOADER_SECRETS:-$HOME/.config/pixel-uploader/secrets.env}"
if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" || -z "${PIXELDRAIN_API_KEY:-}" || -z "${TELEGRAPH_TOKEN:-}" ]]; then
    if [[ -f "$SECRETS_FILE" ]]; then
        perms="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || stat -f '%Lp' "$SECRETS_FILE")"
        [[ "$perms" == "600" ]] || die "Secrets file must have mode 600: $SECRETS_FILE"
        # shellcheck disable=SC1090
        source "$SECRETS_FILE"
    elif [[ -f "$HOME/.build_env" ]]; then
        perms="$(stat -c '%a' "$HOME/.build_env" 2>/dev/null || stat -f '%Lp' "$HOME/.build_env")"
        [[ "$perms" == "600" ]] || die "~/.build_env must have mode 600"
        # shellcheck disable=SC1090
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

choice(){
    local max="$1" prompt="$2" value
    while :; do
        read -r -p "$prompt" value || exit 1
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= max )); then
            printf '%s' "$value"
            return 0
        fi
        warn "Enter 1-$max."
    done
}

prop(){
    local key="$1" file value=''
    for file in \
        "$DOUT/system/build.prop" \
        "$DOUT/vendor/build.prop" \
        "$DOUT/product/build.prop" \
        "$DOUT/system/system/build.prop" \
        "$DOUT/system/etc/prop.default" \
        "$DOUT/vendor/etc/build.prop"; do
        [[ -f "$file" ]] || continue
        value="$(sed -n "s/^${key}=//p" "$file" | head -n1 | tr -d '\r')"
        [[ -n "$value" ]] && break
    done
    printf '%s' "${value:-Unknown}"
}

html(){
    printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g'
}

safe(){
    printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g;s/__*/_/g;s/^_//;s/_$//'
}

label(){
    local base="$(basename "$1")" lower="${base,,}"
    case "$lower" in
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

mapfile -t DEVICES < <(find "$OUT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
((${#DEVICES[@]})) || die "No device output found."

echo
echo "Build outputs:"
i=1
for device in "${DEVICES[@]}"; do
    printf '  [%d] %s\n' "$i" "$device"
    i=$((i + 1))
done

n="$(choice "${#DEVICES[@]}" 'Select device: ')"
CODENAME="${DEVICES[$((n - 1))]}"
DOUT="$OUT/$CODENAME"

ANDROID="$(prop ro.build.version.release)"
PATCH="$(prop ro.build.version.security_patch)"
BUILD="$(prop ro.build.id)"
DISPLAY="$(prop ro.build.display.id)"
DETECTED_NAME="$(prop ro.product.model)"
[[ "$DETECTED_NAME" == "Unknown" ]] && DETECTED_NAME="$(prop ro.product.name)"
[[ "$DETECTED_NAME" == "Unknown" ]] && DETECTED_NAME="$CODENAME"

msg "Device: $CODENAME | Android: $ANDROID | Build: $BUILD | SPL: $PATCH"

echo
echo "Upload:"
echo "  [1] ROM"
echo "  [2] Images"
echo "  [3] ROM + Images"
MODE="$(choice 3 'Select: ')"
FILES=()

if (( MODE == 1 || MODE == 3 )); then
    mapfile -t ROMS < <(find "$DOUT" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.zip.md5' \) | sort)
    ((${#ROMS[@]})) || die "No ROM package found."
    echo
echo "ROM packages:"
    i=1
    for file in "${ROMS[@]}"; do
        printf '  [%d] %s\n' "$i" "$(basename "$file")"
        i=$((i + 1))
    done
    n="$(choice "${#ROMS[@]}" 'Select ROM: ')"
    FILES+=("${ROMS[$((n - 1))]}")
fi

if (( MODE == 2 || MODE == 3 )); then
    IMGS=()
    while IFS= read -r file; do
        base="$(basename "$file")"
        if [[ "$base" =~ ^(boot|init_boot|dtbo|vendor_boot|vendor_kernel_boot|vbmeta|vbmeta_system|vbmeta_vendor)([-_].*)?\.img$ ]]; then
            IMGS+=("$file")
        fi
    done < <(find "$DOUT" -maxdepth 1 -type f -iname '*.img' | sort)

    ((${#IMGS[@]})) || die "No supported images found."
    echo
echo "Images:"
    i=1
    for file in "${IMGS[@]}"; do
        printf '  [%d] %s\n' "$i" "$(basename "$file")"
        i=$((i + 1))
    done

    while :; do
        read -r -p 'Select images (e.g. 1 3 4): ' raw || exit 1
        read -r -a selected <<< "${raw//,/ }"
        good=1
        seen=' '
        for number in "${selected[@]}"; do
            if [[ ! "$number" =~ ^[0-9]+$ ]] || (( number < 1 || number > ${#IMGS[@]} )); then
                good=0
            fi
            if [[ "$seen" == *" $number "* ]]; then
                good=0
            fi
            seen+="$number "
        done
        if (( good == 1 && ${#selected[@]} > 0 )); then
            break
        fi
        warn "Enter valid image numbers from 1-${#IMGS[@]}, separated by spaces."
    done

    for number in "${selected[@]}"; do
        FILES+=("${IMGS[$((number - 1))]}")
    done

    echo "Selected images:"
    for number in "${selected[@]}"; do
        printf '  - %s\n' "$(basename "${IMGS[$((number - 1))]}")"
    done
fi

read -r -p "Project name [${DISPLAY:-ROM}]: " PROJECT || exit 1
PROJECT="${PROJECT:-${DISPLAY:-ROM}}"

read -r -p 'Maintainer [Unknown]: ' AUTHOR || exit 1
AUTHOR="${AUTHOR:-Unknown}"

read -r -p "Device name [${DETECTED_NAME}]: " DEVICE_NAME || exit 1
DEVICE_NAME="${DEVICE_NAME:-$DETECTED_NAME}"

read -r -p 'Banner URL [optional]: ' BANNER_URL || exit 1
if [[ -n "$BANNER_URL" && ! "$BANNER_URL" =~ ^https?:// ]]; then
    die "Banner URL must start with http:// or https://"
fi

echo
echo "Variant:"
echo "  [1] GApps Full"
echo "  [2] GApps Core"
echo "  [3] GApps Pico"
echo "  [4] Vanilla"
echo "  [5] microG"
n="$(choice 5 'Select: ')"
VARIANT=('' 'GApps Full' 'GApps Core' 'GApps Pico' 'Vanilla' 'microG')[$n]

echo
echo "Rooting method:"
echo "  [1] None"
echo "  [2] KSU"
echo "  [3] KSU Next"
echo "  [4] KSU Legacy"
echo "  [5] ReSukiSU"
echo "  [6] SukiSU"
n="$(choice 6 'Select: ')"
ROOTM=('' 'None' 'KSU' 'KSU Next' 'KSU Legacy' 'ReSukiSU' 'SukiSU')[$n]
SUSFS='Disabled'

if [[ "$ROOTM" != "None" ]]; then
    echo
echo "SUSFS:"
    echo "  [1] Without SUSFS"
    echo "  [2] With SUSFS"
    n="$(choice 2 'Select: ')"
    [[ "$n" == "2" ]] && SUSFS='Enabled'
fi

DATE="$(date +%Y-%m-%d)"
RELEASE_ID="$(safe "$PROJECT")_${CODENAME}_$(safe "$VARIANT")_$(safe "$ROOTM")_$(safe "$SUSFS")_$DATE"

msg "Checking credentials..."
if ! curl --fail --silent --show-error --max-time 20 -u ":$PIXELDRAIN_API_KEY" https://pixeldrain.com/api/user/files >/dev/null; then
    die "Pixeldrain authentication failed. No files were uploaded."
fi
if ! curl --fail --silent --show-error --max-time 20 "https://api.telegram.org/bot$BOT_TOKEN/getMe" | jq -e '.ok == true' >/dev/null; then
    die "Telegram bot authentication failed. No files were uploaded."
fi
if ! curl --fail --silent --show-error --max-time 20 -X POST https://api.telegra.ph/getPageList -d "access_token=$TELEGRAPH_TOKEN" | jq -e '.ok == true' >/dev/null; then
    die "Telegraph authentication failed. No files were uploaded."
fi
ok "Pixeldrain authentication OK"
ok "Telegram bot authentication OK"
ok "Telegraph authentication OK"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MANIFEST="$TMP/files.tsv"
: > "$MANIFEST"

pixeldrain_upload(){
    local file="$1" upload_name="$2" response id
    response="$(curl --fail-with-body -sS --max-time 3600 \
        -u ":$PIXELDRAIN_API_KEY" \
        -F "file=@$file;filename=$upload_name" \
        https://pixeldrain.com/api/file)" || return 1
    id="$(jq -r '.id // empty' <<< "$response")"
    [[ -n "$id" ]] || return 1
    printf 'https://pixeldrain.com/u/%s' "$id"
}

echo
echo "Uploading selected files to Pixeldrain..."
SUCCESS=0
for file in "${FILES[@]}"; do
    [[ -f "$file" ]] || { warn "Missing file: $file"; continue; }
    base="$(basename "$file")"
    ext="${base##*.}"
    stem="${base%.*}"
    if [[ "$base" == *.zip.md5 ]]; then
        upload_name="${base%.zip.md5}_${RELEASE_ID}.zip.md5"
    else
        upload_name="${stem}_${RELEASE_ID}.${ext}"
    fi

    size="$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file")"
    md5="$(md5sum "$file" | awk '{print $1}')"
    sha256="$(sha256sum "$file" | awk '{print $1}')"
    type="$(label "$file")"

    if link="$(pixeldrain_upload "$file" "$upload_name")"; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$base" "$upload_name" "$type" "$size" "$md5" "$sha256" "$link" >> "$MANIFEST"
        SUCCESS=$((SUCCESS + 1))
        ok "$type: uploaded"
    else
        warn "Pixeldrain upload failed: $base"
    fi
done

(( SUCCESS > 0 )) || die "No files were uploaded to Pixeldrain; Telegram publish cancelled."

# Build Telegraph content entirely from the selected/uploaded files.
GUIDE_TEXT="Fastboot Flash Guide for $DEVICE_NAME ($CODENAME)\n\n"
GUIDE_TEXT+="Project: $PROJECT\nAndroid: $ANDROID\nBuild: $BUILD\nSecurity Patch: $PATCH\nVariant: $VARIANT\nRooting method: $ROOTM\nSUSFS: $SUSFS\nMaintainer: $AUTHOR\n\n"
GUIDE_TEXT+="Selected files:\n"

while IFS=$'\t' read -r original uploaded type size md5 sha256 link; do
    mb="$(awk -v bytes="$size" 'BEGIN { printf "%.2f", bytes / 1048576 }')"
    GUIDE_TEXT+="\n$type\nName: $uploaded\nSize: ${mb} MB\nMD5: $md5\nSHA256: $sha256\nPixeldrain: $link\n"
done < "$MANIFEST"

GUIDE_TEXT+="\nFlash instructions:\n1. Reboot to bootloader: fastboot reboot bootloader\n"
STEP=2
while IFS=$'\t' read -r original uploaded type size md5 sha256 link; do
    case "$type" in
        BOOT) GUIDE_TEXT+="$STEP. Flash boot: fastboot flash --slot all boot $uploaded\n"; STEP=$((STEP + 1)) ;;
        'INIT BOOT') GUIDE_TEXT+="$STEP. Flash init_boot: fastboot flash --slot all init_boot $uploaded\n"; STEP=$((STEP + 1)) ;;
        DTBO) GUIDE_TEXT+="$STEP. Flash dtbo: fastboot flash --slot all dtbo $uploaded\n"; STEP=$((STEP + 1)) ;;
        'VENDOR BOOT') GUIDE_TEXT+="$STEP. Flash vendor_boot: fastboot flash --slot all vendor_boot $uploaded\n"; STEP=$((STEP + 1)) ;;
        'VENDOR KERNEL BOOT') GUIDE_TEXT+="$STEP. Flash vendor_kernel_boot: fastboot flash --slot all vendor_kernel_boot $uploaded\n"; STEP=$((STEP + 1)) ;;
        VBMETA) GUIDE_TEXT+="$STEP. Flash vbmeta: fastboot --disable-verity --disable-verification flash vbmeta $uploaded\n"; STEP=$((STEP + 1)) ;;
        'VBMETA SYSTEM') GUIDE_TEXT+="$STEP. Flash vbmeta_system: fastboot --disable-verity --disable-verification flash vbmeta_system $uploaded\n"; STEP=$((STEP + 1)) ;;
        'VBMETA VENDOR') GUIDE_TEXT+="$STEP. Flash vbmeta_vendor: fastboot --disable-verity --disable-verification flash vbmeta_vendor $uploaded\n"; STEP=$((STEP + 1)) ;;
esac
done < "$MANIFEST"

HAS_ROM=0
while IFS=$'\t' read -r original uploaded type size md5 sha256 link; do
    if [[ "$type" == "ROM" ]]; then
        HAS_ROM=1
        GUIDE_TEXT+="$STEP. Reboot to recovery: fastboot reboot recovery\n$((STEP + 1)). Apply ROM via ADB sideload: adb sideload $uploaded\n"
        STEP=$((STEP + 2))
        break
    fi
done < "$MANIFEST"

GUIDE_TEXT+="\nOnly the files selected and successfully uploaded for this release are listed above."

TELEGRAPH_URL=''
TELEGRAPH_CONTENT="$(jq -cn \
    --arg project "$PROJECT" \
    --arg device "$DEVICE_NAME" \
    --arg codename "$CODENAME" \
    --arg android "$ANDROID" \
    --arg build "$BUILD" \
    --arg patch "$PATCH" \
    --arg variant "$VARIANT" \
    --arg root "$ROOTM" \
    --arg susfs "$SUSFS" \
    --arg maintainer "$AUTHOR" \
    --arg guide "$GUIDE_TEXT" \
    --arg about 'https://khaliq-repos.pages.dev/' \
    '[
      {tag:"h3",children:[$project]},
      {tag:"p",children:[("Device: " + $device + " (" + $codename + ")")]},
      {tag:"p",children:[("Android: " + $android + " | Build: " + $build + " | SPL: " + $patch)]},
      {tag:"p",children:[("Variant: " + $variant + " | Root: " + $root + " | SUSFS: " + $susfs)]},
      {tag:"p",children:[("Maintainer: " + $maintainer)]},
      {tag:"pre",children:[$guide]},
      {tag:"p",children:["About Developer: "]},
      {tag:"a",attrs:{href:$about},children:["khaliq-repos.pages.dev"]}
    ]')"

if response="$(curl --fail-with-body -sS -X POST https://api.telegra.ph/createPage \
    --data-urlencode "access_token=$TELEGRAPH_TOKEN" \
    --data-urlencode "title=$PROJECT - $DEVICE_NAME - $DATE" \
    --data-urlencode "author_name=$AUTHOR" \
    --data-urlencode 'author_url=https://github.com/Bias8145' \
    --data-urlencode "content=$TELEGRAPH_CONTENT" \
    --data-urlencode 'return_content=false')"; then
    TELEGRAPH_URL="$(jq -r '.result.url // empty' <<< "$response")"
else
    warn "Telegraph page creation failed; Telegram publish will continue without Flash Guide button."
fi

E_PROJECT="$(html "$PROJECT")"
E_DEVICE="$(html "$DEVICE_NAME")"
E_AUTHOR="$(html "$AUTHOR")"
E_VARIANT="$(html "$VARIANT")"
E_ROOT="$(html "$ROOTM")"
E_SUSFS="$(html "$SUSFS")"

MESSAGE="<b>New Release: $E_PROJECT</b>\n\nDevice: $E_DEVICE\nCodename: <code>$CODENAME</code>\nAndroid: $ANDROID\nBuild: $BUILD\nSecurity Patch: $PATCH\nVariant: $E_VARIANT\nRoot: $E_ROOT\nSUSFS: $E_SUSFS\nMaintainer: $E_AUTHOR\n\n<b>Files:</b>"

KEYBOARD='{"inline_keyboard":['
BUTTON_COUNT=0
while IFS=$'\t' read -r original uploaded type size md5 sha256 link; do
    mb="$(awk -v bytes="$size" 'BEGIN { printf "%.2f", bytes / 1048576 }')"
    MESSAGE+="\n\n<b>$type</b>\nName: <code>$(html "$uploaded")</code>\nSize: ${mb} MB\nMD5: <code>$md5</code>\nSHA256: <code>$sha256</code>"
    [[ $BUTTON_COUNT -gt 0 ]] && KEYBOARD+=','
    KEYBOARD+="[{\"text\":\"Download $(html "$type")\",\"url\":\"$link\"}]"
    BUTTON_COUNT=$((BUTTON_COUNT + 1))
done < "$MANIFEST"

if [[ -n "$TELEGRAPH_URL" ]]; then
    [[ $BUTTON_COUNT -gt 0 ]] && KEYBOARD+=','
    KEYBOARD+="[{\"text\":\"Flash Guide\",\"url\":\"$TELEGRAPH_URL\"}]"
    BUTTON_COUNT=$((BUTTON_COUNT + 1))
fi

[[ $BUTTON_COUNT -gt 0 ]] && KEYBOARD+=','
KEYBOARD+='[{"text":"About Developer","url":"https://khaliq-repos.pages.dev/"}]'
KEYBOARD+=']}'
MESSAGE+="\n\nRelease published successfully."

PUBLISH_OK=0
if [[ -n "$BANNER_URL" ]]; then
    if curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" \
        -F "chat_id=$CHAT_ID" \
        --data-urlencode "photo=$BANNER_URL" \
        --data-urlencode "caption=$MESSAGE" \
        -F 'parse_mode=HTML' \
        --data-urlencode "reply_markup=$KEYBOARD" >/dev/null; then
        PUBLISH_OK=1
    else
        warn "Banner publish failed; retrying as text message."
    fi
fi

if (( PUBLISH_OK == 0 )); then
    if curl --fail --silent --show-error -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -F "chat_id=$CHAT_ID" \
        --data-urlencode "text=$MESSAGE" \
        -F 'parse_mode=HTML' \
        --data-urlencode "reply_markup=$KEYBOARD" >/dev/null; then
        PUBLISH_OK=1
    fi
fi

(( PUBLISH_OK == 1 )) || die "Telegram publish failed after Pixeldrain upload."
ok "Release published successfully."
