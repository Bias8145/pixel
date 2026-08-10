#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$' \t\n'

# Bias8145 multi-series release uploader
# Public script: secrets are NEVER stored here.
# Usage:
# bash <(curl -s https://raw.githubusercontent.com/Bias8145/pixel/main/release-uploader.sh | sed 's/\r$//')

C_RESET='\033[0m'; C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'
msg(){ printf '%b\n' "${C_CYAN}$*${C_RESET}"; }
ok(){ printf '%b\n' "${C_GREEN}✓ $*${C_RESET}"; }
warn(){ printf '%b\n' "${C_YELLOW}! $*${C_RESET}" >&2; }
die(){ printf '%b\n' "${C_RED}✗ $*${C_RESET}" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

for x in curl jq find sed awk sha256sum md5sum stat date mktemp; do need "$x"; done

# Credentials may already be exported by ~/.bashrc (for example ~/.build_env),
# or can be stored in a private file. Never put these values in this repository.
SECRETS_FILE="${PIXEL_UPLOADER_SECRETS:-$HOME/.config/pixel-uploader/secrets.env}"
if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" || -z "${PIXELDRAIN_API_KEY:-}" || -z "${TELEGRAPH_TOKEN:-}" ]]; then
    if [[ -f "$SECRETS_FILE" ]]; then
        perms="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || stat -f '%Lp' "$SECRETS_FILE")"
        [[ "$perms" == "600" ]] || die "Secrets file must have mode 600: $SECRETS_FILE"
        # shellcheck disable=SC1090
        source "$SECRETS_FILE"
    elif [[ -f "$HOME/.build_env" ]]; then
        perms="$(stat -c '%a' "$HOME/.build_env" 2>/dev/null || stat -f '%Lp' "$HOME/.build_env")"
        [[ "$perms" == "600" ]] || die "~/.build_env must have mode 600. Run: chmod 600 ~/.build_env"
        # shellcheck disable=SC1090
        source "$HOME/.build_env"
    fi
fi

: "${BOT_TOKEN:?Set BOT_TOKEN in the environment or private secrets file.}"
: "${CHAT_ID:?Set CHAT_ID in the environment or private secrets file.}"
: "${PIXELDRAIN_API_KEY:?Set PIXELDRAIN_API_KEY in the environment or private secrets file.}"
: "${TELEGRAPH_TOKEN:?Set TELEGRAPH_TOKEN in the environment or private secrets file.}"

ROOT="${ANDROID_BUILD_TOP:-$(pwd)}"
OUT="$ROOT/out/target/product"
[[ -d "$OUT" ]] || die "Cannot find $OUT. Run from the Android source tree or export ANDROID_BUILD_TOP."

PROJECT_AUTHOR="${PROJECT_AUTHOR:-${MAINTAINER:-Unknown}}"
SUPPORT_GROUP_URL="${SUPPORT_GROUP_URL:-}"
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
format_size(){ awk -v n="$1" 'BEGIN{if(n>=1073741824)printf "%.1f GB",n/1073741824;else if(n>=1048576)printf "%.1f MB",n/1048576;else if(n>=1024)printf "%.1f KB",n/1024;else printf "%d B",n}'; }
safe(){ printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g;s/__*/_/g;s/^_//;s/_$//'; }

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
echo; echo 'Build outputs:'
i=1
for d in "${DEVICES[@]}"; do printf '  [%d] %s\n' "$i" "$d"; ((i++)); done
n=$(choice "${#DEVICES[@]}" 'Select device: ')
DEVICE="${DEVICES[$((n-1))]}"
DOUT="$OUT/$DEVICE"
ANDROID="$(prop ro.build.version.release)"
PATCH="$(prop ro.build.version.security_patch)"
BUILD="$(prop ro.build.id)"
DISPLAY="$(prop ro.build.display.id)"
msg "Device: $DEVICE | Android: $ANDROID | Build: $BUILD | SPL: $PATCH"

echo; echo 'Upload:'; echo '  [1] ROM'; echo '  [2] Images'; echo '  [3] ROM + Images'
MODE=$(choice 3 'Select: ')
FILES=()

if ((MODE==1 || MODE==3)); then
    mapfile -t ROMS < <(find "$DOUT" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.zip.md5' \) -print | sort)
    ((${#ROMS[@]})) || die 'No ROM package found.'
    echo; echo 'ROM packages:'; i=1
    for f in "${ROMS[@]}"; do printf '  [%d] %s\n' "$i" "$(basename "$f")"; ((i++)); done
    n=$(choice "${#ROMS[@]}" 'Select ROM: ')
    FILES+=("${ROMS[$((n-1))]}")
fi

if ((MODE==2 || MODE==3)); then
    IMGS=()
    while IFS= read -r f; do
        b="$(basename "$f")"
        [[ "$b" =~ ^(boot|init_boot|dtbo|vendor_boot|vendor_kernel_boot|vbmeta|vbmeta_system|vbmeta_vendor)([-_].*)?\.img$ ]] && IMGS+=("$f")
    done < <(find "$DOUT" -maxdepth 1 -type f -iname '*.img' -print | sort)
    ((${#IMGS[@]})) || die 'No supported images found.'
    echo; echo 'Images:'; i=1
    for f in "${IMGS[@]}"; do printf '  [%d] %s\n' "$i" "$(basename "$f")"; ((i++)); done
    while :; do
        read -r -p 'Select images (e.g. 1 3 4): ' raw || exit 1
        raw="${raw//$'\t'/ }"
        [[ -n "${raw//[[:space:]]/}" ]] || continue
        IFS=' ' read -r -a sel <<< "$raw"
        good=1; seen=' '
        for n in "${sel[@]}"; do
            if ! [[ "$n" =~ ^[0-9]+$ ]] || ((n<1 || n>${#IMGS[@]})); then good=0; continue; fi
            if [[ "$seen" == *" $n "* ]]; then good=0; warn "Duplicate image selection: $n"; fi
            seen+="$n "
        done
        ((good)) || { warn "Enter valid image numbers from 1-${#IMGS[@]}, separated by spaces."; continue; }
        break
    done
    for n in "${sel[@]}"; do FILES+=("${IMGS[$((n-1))]}"); done
    echo 'Selected images:'
    for n in "${sel[@]}"; do printf '  ✓ %s\n' "$(basename "${IMGS[$((n-1))]}")"; done
fi

read -r -p "Project name [${DISPLAY:-ROM}]: " PROJECT || exit 1
PROJECT="${PROJECT:-${DISPLAY:-ROM}}"
read -r -p "Maintainer [${PROJECT_AUTHOR}]: " AUTHOR || exit 1
AUTHOR="${AUTHOR:-$PROJECT_AUTHOR}"

echo; echo 'Variant:'
echo '  [1] GApps Full'; echo '  [2] GApps Core'; echo '  [3] GApps Pico'; echo '  [4] Vanilla'; echo '  [5] microG'
n=$(choice 5 'Select: '); VARIANT=('' 'GApps Full' 'GApps Core' 'GApps Pico' 'Vanilla' 'microG')[$n]

echo; echo 'Rooting method:'
echo '  [1] None'; echo '  [2] KSU'; echo '  [3] KSU Next'; echo '  [4] KSU Legacy'; echo '  [5] ReSukiSU'; echo '  [6] SukiSU'
n=$(choice 6 'Select: '); ROOTM=('' 'None' 'KSU' 'KSU Next' 'KSU Legacy' 'ReSukiSU' 'SukiSU')[$n]
SUSFS='None'
if [[ "$ROOTM" != None ]]; then
    echo; echo 'SUSFS:'; echo '  [1] Without SUSFS'; echo '  [2] With SUSFS'
    n=$(choice 2 'Select: '); [[ $n == 2 ]] && SUSFS='Enabled' || SUSFS='Disabled'
fi

DATE_ISO=$(date +%Y-%m-%d); DATE_HUMAN=$(date +%d-%m-%Y)
PATCH_HUMAN="$PATCH"
if [[ "$PATCH" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then PATCH_HUMAN=$(date -d "$PATCH" '+%B %Y' 2>/dev/null || printf '%s' "$PATCH"); fi
RELEASE_ID="$(safe "$PROJECT")_${DEVICE}_$(safe "$VARIANT")_$(safe "$ROOTM")_$(safe "$SUSFS")_$DATE_ISO"
TAG="[$(safe "$PROJECT")][$BUILD][Android $ANDROID]"
[[ "$ROOTM" != None ]] && TAG+="[$(safe "$ROOTM")][$( [[ "$SUSFS" == Enabled ]] && printf SUSFS || printf NO-SUSFS )]"
TAG+="[$DATE_HUMAN]"

# Validate credentials before uploading any file.
msg 'Checking credentials...'
curl --fail --silent --show-error --max-time 20 -u ":$PIXELDRAIN_API_KEY" https://pixeldrain.com/api/user/files >/dev/null || die 'Pixeldrain authentication failed (401/403). No files were uploaded.'
curl --fail --silent --show-error --max-time 20 "https://api.telegram.org/bot$BOT_TOKEN/getMe" | jq -e '.ok == true' >/dev/null || die 'Telegram bot authentication failed. No files were uploaded.'
curl --fail --silent --show-error --max-time 20 -X POST https://api.telegra.ph/getPageList -d "access_token=$TELEGRAPH_TOKEN" | jq -e '.ok == true' >/dev/null || die 'Telegraph authentication failed. No files were uploaded.'
ok 'Pixeldrain authentication OK'; ok 'Telegram bot authentication OK'; ok 'Telegraph authentication OK'

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; : > "$TMP/files.tsv"
file_label(){
    local b="$(basename "$1")" lower="${b,,}"
    case "$lower" in
        *.zip|*.ozip|*.zip.md5) echo 'ROM';; boot*.img) echo 'BOOT';; init_boot*.img) echo 'INIT BOOT';; dtbo*.img) echo 'DTBO';; vendor_boot*.img) echo 'VENDOR BOOT';; vendor_kernel_boot*.img) echo 'VENDOR KERNEL BOOT';; vbmeta_system*.img) echo 'VBMETA SYSTEM';; vbmeta_vendor*.img) echo 'VBMETA VENDOR';; vbmeta*.img) echo 'VBMETA';; *) echo "${b%.*}";;
    esac
}
file_name(){
    local b="$(basename "$1")" ext base
    if [[ "$b" == *.zip.md5 ]]; then printf '%s_%s.zip.md5' "${b%.zip.md5}" "$RELEASE_ID"; else ext="${b##*.}"; base="${b%.*}"; printf '%s_%s.%s' "$base" "$RELEASE_ID" "$ext"; fi
}
pd_upload(){
    local f="$1" name="$2" response id
    response="$(curl --fail-with-body -sS --max-time 3600 -u ":$PIXELDRAIN_API_KEY" -F "file=@$f;filename=$name" https://pixeldrain.com/api/file)" || return 1
    id="$(jq -r '.id // empty' <<< "$response")"; [[ -n "$id" ]] || return 1
    printf 'https://pixeldrain.com/u/%s' "$id"
}

msg 'Uploading selected files to Pixeldrain...'
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { warn "Missing: $f"; continue; }
    base="$(basename "$f")"; name="$(file_name "$f")"; size=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f"); md5=$(md5sum "$f"|awk '{print $1}'); sha=$(sha256sum "$f"|awk '{print $1}')
    if link=$(pd_upload "$f" "$name"); then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$base" "$(file_label "$f")" "$size" "$md5" "$sha" "$link" >> "$TMP/files.tsv"
        ok "$(file_label "$f"): uploaded"
    else warn "Pixeldrain upload failed: $base"; fi
done
[[ -s "$TMP/files.tsv" ]] || die 'No files were uploaded to Pixeldrain; Telegram publish cancelled.'

# Telegraph page is optional at runtime, but the existing token is preserved and used.
TELEGRAPH_URL=''
TELEGRAPH_CONTENT=$(jq -cn --arg p "$PROJECT" --arg d "$DEVICE" --arg a "$ANDROID" --arg b "$BUILD" --arg s "$PATCH_HUMAN" --arg v "$VARIANT" --arg r "$ROOTM" --arg u "$SUSFS" --arg dt "$DATE_HUMAN" --arg m "$AUTHOR" '[{"tag":"p","children":["Release: "+$p+" for "+$d]},{"tag":"p","children":["Android "+$a+" | Build "+$b+" | SPL "+$s]},{"tag":"p","children":["Variant: "+$v+" | Root: "+$r+" | SUSFS: "+$u]},{"tag":"p","children":["Release date: "+$dt+" | Maintainer: "+$m]}]')
if response=$(curl --fail-with-body -sS -X POST https://api.telegra.ph/createPage --data-urlencode "access_token=$TELEGRAPH_TOKEN" --data-urlencode "title=$PROJECT - $DEVICE - $DATE_HUMAN" --data-urlencode "author_name=$AUTHOR" --data-urlencode "author_url=$DEVELOPERS_URL" --data-urlencode "content=$TELEGRAPH_CONTENT" --data-urlencode 'return_content=false'); then TELEGRAPH_URL=$(jq -r '.result.url // empty' <<< "$response"); else warn 'Telegraph page creation failed; publishing without Flash Guide button.'; fi

E_PROJECT=$(html_escape "$PROJECT"); E_DEVICE=$(html_escape "$DEVICE"); E_ANDROID=$(html_escape "$ANDROID"); E_PATCH=$(html_escape "$PATCH_HUMAN"); E_BUILD=$(html_escape "$BUILD"); E_VARIANT=$(html_escape "$VARIANT"); E_ROOT=$(html_escape "$ROOTM"); E_SUSFS=$(html_escape "$SUSFS"); E_DATE=$(html_escape "$DATE_HUMAN"); E_AUTHOR=$(html_escape "$AUTHOR"); E_TAG=$(html_escape "$TAG")
GOOGLE='Not included'; case "$VARIANT" in GApps*) GOOGLE='GApps included';; microG) GOOGLE='microG included';; esac
CAP="<b>📦 New Release: $E_PROJECT for $E_DEVICE</b>\n\n<b>Device:</b> $E_DEVICE\n<b>Project:</b> $E_PROJECT\n<b>Android Version:</b> $E_ANDROID\n<b>Security Patch:</b> $E_PATCH\n<b>Build:</b> $E_BUILD\n<b>Build Variant:</b> $E_VARIANT\n<b>Google Services:</b> $GOOGLE\n<b>Root:</b> $E_ROOT\n<b>SUSFS:</b> $E_SUSFS\n<b>Release Date:</b> $E_DATE\n<b>Maintainer:</b> $E_AUTHOR\n\n<b>Tag:</b> <code>$E_TAG</code>\n\n<b>Release Notes:</b>\n"
case "$VARIANT" in GApps*) CAP+="✅ $E_VARIANT included\n";; Vanilla) CAP+='✅ Vanilla build - no Google Apps\n';; microG) CAP+='✅ microG variant included\n';; esac
[[ "$ROOTM" != None ]] && CAP+="✅ $E_ROOT support included\n"
[[ "$SUSFS" == Enabled ]] && CAP+='✅ SUSFS enabled\n'
CAP+='⚠️ Always backup your data before flashing\nFollow the flash guide for proper installation\n\n<b>Files Size Information:</b>\n'

INLINE='{"inline_keyboard":['; idx=0
while IFS=$'\t' read -r base label size md5 sha link; do
    [[ -z "$link" ]] && continue
    size_text=$(format_size "$size"); short_md5="${md5:0:8}..."; short_sha="${sha:0:8}..."
    CAP+="▪️ <b>$label</b> — $size_text | MD5: <code>$short_md5</code> | SHA256: <code>$short_sha</code>\n"
    [[ $idx -gt 0 ]] && INLINE+=','
    INLINE+="[{\"text\":\"Download $label\",\"url\":\"$link\"}]"; ((idx++))
done < "$TMP/files.tsv"
CAP+='\nClick the buttons below to download the files.'
if [[ -n "$TELEGRAPH_URL" ]]; then INLINE+=",[{\"text\":\"Flash Guide\",\"url\":\"$TELEGRAPH_URL\"}]"; fi
if [[ -n "$KSU_NEXT_MANAGER_URL" && "$ROOTM" == 'KSU Next' ]]; then INLINE+=",[{\"text\":\"KSU Next Manager\",\"url\":\"$KSU_NEXT_MANAGER_URL\"}]"; fi
if [[ -n "$SUPPORT_GROUP_URL" ]]; then INLINE+=",[{\"text\":\"Support Group\",\"url\":\"$SUPPORT_GROUP_URL\"}]"; fi
INLINE+=']}'

# Telegram only receives the release announcement. Files remain on Pixeldrain.
curl --fail -sS -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -F "chat_id=$CHAT_ID" --data-urlencode "text=$CAP" -F 'parse_mode=HTML' --data-urlencode "reply_markup=$INLINE" >/dev/null || die 'Telegram publish failed after Pixeldrain upload.'
ok "PUBLISH sent: $PROJECT / $DEVICE ($(( $(wc -l < "$TMP/files.tsv") )) file(s))"
echo "Release tag: $TAG"
