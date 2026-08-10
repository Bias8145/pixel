#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$' \t\n'

# Bias8145 multi-series release uploader
# Usage:
#   bash <(curl -s https://raw.githubusercontent.com/Bias8145/pixel/main/release-uploader.sh | sed 's/\r$//')
# Required environment: BOT_TOKEN CHAT_ID PIXELDRAIN_API_KEY TELEGRAPH_TOKEN

C_RESET='\033[0m'; C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'
msg(){ printf '%b\n' "${C_CYAN}$*${C_RESET}"; }
ok(){ printf '%b\n' "${C_GREEN}✓ $*${C_RESET}"; }
warn(){ printf '%b\n' "${C_YELLOW}! $*${C_RESET}" >&2; }
die(){ printf '%b\n' "${C_RED}✗ $*${C_RESET}" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

for x in curl jq find sed awk sha256sum stat md5sum date; do need "$x"; done
: "${BOT_TOKEN:?Set BOT_TOKEN first.}"
: "${CHAT_ID:?Set CHAT_ID first.}"
: "${PIXELDRAIN_API_KEY:?Set PIXELDRAIN_API_KEY first.}"
: "${TELEGRAPH_TOKEN:?Set TELEGRAPH_TOKEN first.}"

ROOT="${ANDROID_BUILD_TOP:-$(pwd)}"
OUT="$ROOT/out/target/product"
[[ -d "$OUT" ]] || die "Cannot find $OUT. Run from the Android source tree or export ANDROID_BUILD_TOP."

PROJECT_AUTHOR="${PROJECT_AUTHOR:-${MAINTAINER:-Unknown}}"
SUPPORT_GROUP_URL="${SUPPORT_GROUP_URL:-https://t.me/pixel4seriesofficial}"
DEVELOPERS_URL="${DEVELOPERS_URL:-https://github.com/Bias8145}"
KSU_NEXT_MANAGER_URL="${KSU_NEXT_MANAGER_URL:-https://t.me/ksunext/728}"

choice(){
    local n="$1" prompt="$2" v
    while :; do
        read -r -p "$prompt" v || exit 1
        [[ "$v" =~ ^[0-9]+$ ]] && ((v>=1 && v<=n)) && { printf '%s' "$v"; return; }
        warn "Enter 1-$n."
    done
}

html_escape(){ printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g'; }
short_hash(){ local h="$1"; printf '%s' "${h:0:8}"; }
format_size(){
    local bytes="$1"
    awk -v n="$bytes" 'BEGIN { if(n>=1073741824) printf "%.1f GB",n/1073741824; else if(n>=1048576) printf "%.1f MB",n/1048576; else if(n>=1024) printf "%.1f KB",n/1024; else printf "%d B",n }'
}

prop(){
    local k="$1" f v=''
    for f in "$DOUT/system/build.prop" "$DOUT/vendor/build.prop" "$DOUT/product/build.prop" "$DOUT/system/system/build.prop" "$DOUT/system/etc/prop.default" "$DOUT/vendor/etc/build.prop"; do
        [[ -f "$f" ]] || continue
        v="$(sed -n "s/^${k}=//p" "$f" | head -n1 | tr -d '\r')"
        [[ -n "$v" ]] && break
    done
    printf '%s' "${v:-Unknown}"
}

mapfile -t DEVICES < <(find "$OUT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
((${#DEVICES[@]})) || die 'No device output found.'
echo
echo 'Build outputs:'
i=1
for d in "${DEVICES[@]}"; do printf '  [%d] %s\n' "$i" "$d"; ((i++)); done
n=$(choice "${#DEVICES[@]}" 'Device: ')
DEVICE="${DEVICES[$((n-1))]}"
DOUT="$OUT/$DEVICE"
ANDROID="$(prop ro.build.version.release)"
PATCH="$(prop ro.build.version.security_patch)"
BUILD="$(prop ro.build.id)"
DISPLAY="$(prop ro.build.display.id)"
msg "Device: $DEVICE | Android: $ANDROID | Build: $BUILD | SPL: $PATCH"

echo
echo 'Upload:'
echo '  [1] ROM'
echo '  [2] Images'
echo '  [3] ROM + Images'
MODE=$(choice 3 'Select: ')
FILES=()

if ((MODE==1 || MODE==3)); then
    mapfile -t ROMS < <(find "$DOUT" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.zip.md5' \) -print | sort)
    ((${#ROMS[@]})) || die 'No ROM package found.'
    echo
echo 'ROM packages:'
    i=1
    for f in "${ROMS[@]}"; do printf '  [%d] %s\n' "$i" "$(basename "$f")"; ((i++)); done
    n=$(choice "${#ROMS[@]}" 'ROM: ')
    FILES+=("${ROMS[$((n-1))]}")
fi

if ((MODE==2 || MODE==3)); then
    IMGS=()
    while IFS= read -r f; do
        b="$(basename "$f")"
        [[ "$b" =~ ^(boot|init_boot|dtbo|vendor_boot|vendor_kernel_boot|vbmeta|vbmeta_system|vbmeta_vendor)([-_].*)?\.img$ ]] && IMGS+=("$f")
    done < <(find "$DOUT" -maxdepth 1 -type f -iname '*.img' -print | sort)
    ((${#IMGS[@]})) || die 'No supported images found.'
    echo
echo 'Images:'
    i=1
    for f in "${IMGS[@]}"; do printf '  [%d] %s\n' "$i" "$(basename "$f")"; ((i++)); done
    while :; do
        read -r -p 'Select images (e.g. 1 3 4): ' raw || exit 1
        [[ -n "${raw//[[:space:]]/}" ]] || continue
        read -r -a sel <<< "$raw"
        good=1
        seen=' '
        for n in "${sel[@]}"; do
            [[ "$n" =~ ^[0-9]+$ ]] && ((n>=1 && n<=${#IMGS[@]})) || good=0
            if [[ "$seen" == *" $n "* ]]; then good=0; warn "Duplicate image selection: $n"; fi
            seen+="$n "
        done
        ((good)) && break
        warn "Enter valid image numbers from 1-${#IMGS[@]}, separated by spaces."
    done
    for n in "${sel[@]}"; do FILES+=("${IMGS[$((n-1))]}"); done
fi

read -r -p "Project name [${DISPLAY:-ROM}]: " PROJECT || exit 1
PROJECT="${PROJECT:-${DISPLAY:-ROM}}"
read -r -p "Maintainer [${PROJECT_AUTHOR}]: " AUTHOR || exit 1
AUTHOR="${AUTHOR:-$PROJECT_AUTHOR}"

echo
echo 'Variant:'
echo '  [1] GApps Full'
echo '  [2] GApps Core'
echo '  [3] GApps Pico'
echo '  [4] Vanilla'
echo '  [5] microG'
n=$(choice 5 'Select: ')
VARIANT=('' 'GApps Full' 'GApps Core' 'GApps Pico' 'Vanilla' 'microG')[$n]

echo
echo 'Rooting method:'
echo '  [1] None'
echo '  [2] KSU'
echo '  [3] KSU Next'
echo '  [4] KSU Legacy'
echo '  [5] ReSukiSU'
echo '  [6] SukiSU'
n=$(choice 6 'Select: ')
ROOTM=('' 'None' 'KSU' 'KSU Next' 'KSU Legacy' 'ReSukiSU' 'SukiSU')[$n]
SUSFS='None'
if [[ "$ROOTM" != None ]]; then
    echo
echo 'SUSFS:'
echo '  [1] Without SUSFS'
echo '  [2] With SUSFS'
    n=$(choice 2 'Select: ')
    [[ $n == 2 ]] && SUSFS='Enabled' || SUSFS='Disabled'
fi

DATE_ISO=$(date +%Y-%m-%d)
DATE_HUMAN=$(date +%d-%m-%Y)
PATCH_HUMAN="$PATCH"
if [[ "$PATCH" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then PATCH_HUMAN=$(date -d "$PATCH" '+%B %Y' 2>/dev/null || printf '%s' "$PATCH"); fi
safe(){ printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g;s/__*/_/g;s/^_//;s/_$//'; }
TAG="[$(safe "$PROJECT")][$BUILD][Android $ANDROID]"
[[ "$ROOTM" != None ]] && TAG+="[$(safe "$ROOTM")][$( [[ "$SUSFS" == Enabled ]] && printf SUSFS || printf NO-SUSFS )]"
TAG+="[$DATE_HUMAN]"
RELEASE_ID="$(safe "$PROJECT")_${DEVICE}_$(safe "$VARIANT")_$(safe "$ROOTM")_$(safe "$SUSFS")_$DATE_ISO"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/files.tsv"
: > "$TMP/links.tsv"

pd_upload(){
    local f="$1" name="$2" response id
    response="$(curl --fail-with-body -sS -u ":$PIXELDRAIN_API_KEY" -F "file=@$f;filename=$name" https://pixeldrain.com/api/file)" || return 1
    id="$(jq -r '.id // empty' <<< "$response")"
    [[ -n "$id" ]] || return 1
    printf 'https://pixeldrain.com/u/%s' "$id"
}

file_label(){
    local b="$(basename "$1")" lower="${b,,}"
    case "$lower" in
        *.zip|*.ozip|*.zip.md5) printf 'ROM';;
        boot*.img) printf 'BOOT';;
        init_boot*.img) printf 'INIT BOOT';;
        dtbo*.img) printf 'DTBO';;
        vendor_boot*.img) printf 'VENDOR BOOT';;
        vendor_kernel_boot*.img) printf 'VENDOR KERNEL BOOT';;
        vbmeta_system*.img) printf 'VBMETA SYSTEM';;
        vbmeta_vendor*.img) printf 'VBMETA VENDOR';;
        vbmeta*.img) printf 'VBMETA';;
        *) printf '%s' "${b%.*}";;
    esac
}

file_name(){
    local f="$1" b ext base
    b="$(basename "$f")"
    if [[ "$b" == *.zip.md5 ]]; then printf '%s_%s.zip.md5' "${b%.zip.md5}" "$RELEASE_ID"; return; fi
    ext="${b##*.}"; base="${b%.*}"
    printf '%s_%s.%s' "$base" "$RELEASE_ID" "$ext"
}

msg 'Uploading selected files to Pixeldrain...'
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { warn "Missing: $f"; continue; }
    base="$(basename "$f")"; name="$(file_name "$f")"
    size=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f")
    md5=$(md5sum "$f" | awk '{print $1}')
    sha=$(sha256sum "$f" | awk '{print $1}')
    if link=$(pd_upload "$f" "$name"); then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$base" "$(file_label "$f")" "$size" "$md5" "$sha" "$link" >> "$TMP/files.tsv"
        printf '%s\t%s\n' "$name" "$link" >> "$TMP/links.tsv"
        ok "$(file_label "$f"): $link"
    else
        warn "Pixeldrain upload failed: $base"
    fi
done

[[ -s "$TMP/files.tsv" ]] || die 'No files were uploaded to Pixeldrain; Telegram publish cancelled.'

# Preserve the existing Telegraph key by publishing a small release/flash-guide page.
TELEGRAPH_URL=''
TELEGRAPH_CONTENT=$(jq -cn \
    --arg project "$PROJECT" --arg device "$DEVICE" --arg android "$ANDROID" --arg patch "$PATCH_HUMAN" \
    --arg build "$BUILD" --arg variant "$VARIANT" --arg root "$ROOTM" --arg susfs "$SUSFS" --arg date "$DATE_HUMAN" --arg author "$AUTHOR" \
    '[["p",{"children":["Release: "+$project+" for "+$device]}],["p",{"children":["Android "+$android+" | Build "+$build+" | SPL "+$patch]}],["p",{"children":["Variant: "+$variant+" | Root: "+$root+" | SUSFS: "+$susfs]}],["p",{"children":["Release date: "+$date+" | Maintainer: "+$author]}]]')
if response=$(curl --fail-with-body -sS -X POST 'https://api.telegra.ph/createPage' \
    --data-urlencode "access_token=$TELEGRAPH_TOKEN" \
    --data-urlencode "title=$PROJECT - $DEVICE - $DATE_HUMAN" \
    --data-urlencode "author_name=$AUTHOR" \
    --data-urlencode "content=$TELEGRAPH_CONTENT" \
    --data-urlencode 'return_content=false'); then
    TELEGRAPH_URL=$(jq -r '.result.url // empty' <<< "$response")
fi

NOTES=()
case "$VARIANT" in
    GApps\ Full|GApps\ Core|GApps\ Pico) NOTES+=("✅ ${VARIANT} included");;
    Vanilla) NOTES+=("✅ Vanilla build - no Google Apps");;
    microG) NOTES+=("✅ microG variant included");;
esac
[[ "$ROOTM" != None ]] && NOTES+=("✅ ${ROOTM} support included")
[[ "$SUSFS" == Enabled ]] && NOTES+=("✅ SUSFS enabled")
[[ "$ROOTM" == None ]] && NOTES+=("✅ Standard build without root modifications")
NOTES+=("⚠️ Always backup your data before flashing" "Follow the flash guide for proper installation")

# Telegram publish message: text + inline download buttons, no uploaded photo/banner/file.
E_PROJECT=$(html_escape "$PROJECT"); E_DEVICE=$(html_escape "$DEVICE"); E_ANDROID=$(html_escape "$ANDROID"); E_PATCH=$(html_escape "$PATCH_HUMAN"); E_BUILD=$(html_escape "$BUILD"); E_VARIANT=$(html_escape "$VARIANT"); E_ROOT=$(html_escape "$ROOTM"); E_SUSFS=$(html_escape "$SUSFS"); E_DATE=$(html_escape "$DATE_HUMAN"); E_AUTHOR=$(html_escape "$AUTHOR"); E_TAG=$(html_escape "$TAG")
CAP="<b>📦 New Release: $E_PROJECT for $E_DEVICE</b>\n\n<b>Device:</b> $E_DEVICE\n<b>Project:</b> $E_PROJECT\n<b>Android Version:</b> $E_ANDROID\n<b>Security Patch:</b> $E_PATCH\n<b>Build:</b> $E_BUILD\n<b>Build Variant:</b> $E_VARIANT\n<b>Google Services:</b> $(case "$VARIANT" in GApps*) printf '%s' 'GApps included';; microG) printf '%s' 'microG included';; *) printf '%s' 'Not included';; esac)\n<b>Root:</b> $E_ROOT\n<b>SUSFS:</b> $E_SUSFS\n<b>Release Date:</b> $E_DATE\n<b>Maintainer:</b> $E_AUTHOR\n\n<b>Tag:</b> $E_TAG\n\n<b>Release Notes:</b>\n<pre>"
for note in "${NOTES[@]}"; do CAP+="$note\n"; done
CAP+="\n</pre>\n\n<b>Files Size Information:</b>\n"
while IFS=$'\t' read -r base label size md5 sha link; do
    CAP+="▪️ <b>$label</b> — $(format_size "$size") | MD5: $(short_hash "$md5") | SHA: $(short_hash "$sha")\n"
done < "$TMP/files.tsv"
CAP+="\nClick the buttons below to download the files."

KEYBOARD='[]'
: > "$TMP/row.json"
while IFS=$'\t' read -r base label size md5 sha link; do
    button=$(jq -cn --arg text "$label" --arg url "$link" '{text:$text,url:$url}')
    if [[ ! -s "$TMP/row.json" ]]; then
        printf '[%s]' "$button" > "$TMP/row.json"
    else
        jq --argjson b "$button" '. + [$b]' "$TMP/row.json" > "$TMP/row.tmp"
        mv "$TMP/row.tmp" "$TMP/row.json"
        KEYBOARD=$(jq -cn --argjson k "$KEYBOARD" --argjson r "$(cat "$TMP/row.json")" '$k + [$r]')
        rm -f "$TMP/row.json"
    fi
done < "$TMP/files.tsv"
if [[ -s "$TMP/row.json" ]]; then
    KEYBOARD=$(jq -cn --argjson k "$KEYBOARD" --argjson r "$(cat "$TMP/row.json")" '$k + [$r]')
fi
[[ -n "$TELEGRAPH_URL" ]] && KEYBOARD=$(jq -cn --argjson k "$KEYBOARD" --arg u "$TELEGRAPH_URL" '$k + [[{"text":"Flash Guide","url":$u}]]')
KEYBOARD=$(jq -cn --argjson k "$KEYBOARD" --arg u "$SUPPORT_GROUP_URL" --arg d "$DEVELOPERS_URL" '$k + [[{"text":"Support Group","url":$u},{"text":"About Developers","url":$d}]]')
if [[ "$ROOTM" == 'KSU Next' ]]; then
    KEYBOARD=$(jq -cn --argjson k "$KEYBOARD" --arg u "$KSU_NEXT_MANAGER_URL" '$k + [[{"text":"KernelSU Next Manager","url":$u}]]')
fi
REPLY_MARKUP=$(jq -cn --argjson k "$KEYBOARD" '{inline_keyboard:$k}')

curl --fail-with-body -sS "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -F "chat_id=$CHAT_ID" \
    -F "text=$CAP" \
    -F 'parse_mode=HTML' \
    -F "reply_markup=$REPLY_MARKUP" >/dev/null || die 'Telegram publish failed.'

ok 'Telegram PUBLISH message sent with Pixeldrain download buttons.'
ok "Release upload completed: $RELEASE_ID"
