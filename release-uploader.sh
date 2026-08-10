#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Bias8145 multi-series release uploader
# Usage: bash <(curl -s https://raw.githubusercontent.com/Bias8145/pixel/main/release-uploader.sh | sed 's/\r$//')

C_RESET='\033[0m'; C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'
msg(){ printf '%b\n' "${C_CYAN}$*${C_RESET}"; }; ok(){ printf '%b\n' "${C_GREEN}✓ $*${C_RESET}"; }; warn(){ printf '%b\n' "${C_YELLOW}! $*${C_RESET}" >&2; }; die(){ printf '%b\n' "${C_RED}✗ $*${C_RESET}" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
for x in curl jq find sed awk sha256sum stat date; do need "$x"; done
[[ -n "${BOT_TOKEN:-}" && -n "${CHAT_ID:-}" && -n "${PIXELDRAIN_API_KEY:-}" ]] || die 'Set BOT_TOKEN, CHAT_ID and PIXELDRAIN_API_KEY first.'

ROOT="${ANDROID_BUILD_TOP:-$(pwd)}"; OUT="$ROOT/out/target/product"
[[ -d "$OUT" ]] || die "Cannot find $OUT. Run from the Android source tree or export ANDROID_BUILD_TOP."

choice(){ local n="$1" v; while :; do read -r -p "$2" v || exit 1; [[ "$v" =~ ^[0-9]+$ ]] && ((v>=1&&v<=n)) && { printf '%s' "$v"; return; }; warn "Enter 1-$n."; done; }

mapfile -t DEVICES < <(find "$OUT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
((${#DEVICES[@]})) || die 'No device output found.'
echo; echo 'Build outputs:'; i=1; for d in "${DEVICES[@]}"; do printf '  [%d] %s\n' "$i" "$d"; ((i++)); done
n=$(choice "${#DEVICES[@]}" 'Device: '); DEVICE="${DEVICES[$((n-1))]}"; DOUT="$OUT/$DEVICE"

prop(){ local k="$1" f v=''; for f in "$DOUT/system/build.prop" "$DOUT/vendor/build.prop" "$DOUT/product/build.prop" "$DOUT/system/system/build.prop"; do [[ -f "$f" ]] && { v="$(sed -n "s/^$k=//p" "$f" | head -n1 | tr -d '\r')"; [[ -n "$v" ]] && break; }; done; printf '%s' "${v:-Unknown}"; }
ANDROID="$(prop ro.build.version.release)"; PATCH="$(prop ro.build.version.security_patch)"; BUILD="$(prop ro.build.id)"; DISPLAY="$(prop ro.build.display.id)"
msg "Device: $DEVICE | Android: $ANDROID | Build: $BUILD | SPL: $PATCH"

echo; echo 'Upload:'; echo '  [1] ROM'; echo '  [2] Images'; echo '  [3] ROM + Images'; MODE=$(choice 3 'Select: ')
FILES=()
if ((MODE==1||MODE==3)); then
  mapfile -t ROMS < <(find "$DOUT" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.zip.md5' \) -print | sort)
  ((${#ROMS[@]})) || die 'No ROM package found.'
  echo; echo 'ROM packages:'; i=1; for f in "${ROMS[@]}"; do printf '  [%d] %s\n' "$i" "$(basename "$f")"; ((i++)); done
  n=$(choice "${#ROMS[@]}" 'ROM: '); FILES+=("${ROMS[$((n-1))]}")
fi
if ((MODE==2||MODE==3)); then
  IMGS=(); while IFS= read -r f; do b="$(basename "$f")"; [[ "$b" =~ ^(boot|init_boot|dtbo|vendor_boot|vendor_kernel_boot|vbmeta|vbmeta_system|vbmeta_vendor)([-_].*)?\.img$ ]] && IMGS+=("$f"); done < <(find "$DOUT" -maxdepth 1 -type f -iname '*.img' -print | sort)
  ((${#IMGS[@]})) || die 'No supported images found.'
  echo; echo 'Images:'; i=1; for f in "${IMGS[@]}"; do printf '  [%d] %s\n' "$i" "$(basename "$f")"; ((i++)); done
  while :; do read -r -p 'Select images (e.g. 1 3 4): ' raw || exit 1; read -r -a sel <<< "$raw"; [[ ${#sel[@]} -gt 0 ]] || continue; good=1; seen=' '; for n in "${sel[@]}"; do [[ "$n" =~ ^[0-9]+$ ]] && ((n>=1&&n<=${#IMGS[@]})) || good=0; [[ "$seen" != *" $n "* ]] || { good=0; warn 'Duplicate image selection.'; }; seen+="$n "; done; ((good)) && break; warn "Enter valid image numbers from 1-${#IMGS[@]}, separated by spaces."; done
  for n in "${sel[@]}"; do FILES+=("${IMGS[$((n-1))]}"); done
fi

read -r -p 'ROM/project name [auto: '"${DISPLAY:-ROM}"']: ' PROJECT || exit 1; PROJECT="${PROJECT:-${DISPLAY:-ROM}}"
echo; echo 'Variant:'; echo '  [1] GApps Full'; echo '  [2] GApps Core'; echo '  [3] GApps Pico'; echo '  [4] Vanilla'; echo '  [5] microG'; n=$(choice 5 'Select: '); VARIANT=('' 'GApps-Full' 'GApps-Core' 'GApps-Pico' 'Vanilla' 'microG')[$n]
echo; echo 'Rooting method:'; echo '  [1] None'; echo '  [2] KSU'; echo '  [3] KSU Next'; echo '  [4] KSU Legacy'; echo '  [5] ReSukiSU'; echo '  [6] SukiSU'; n=$(choice 6 'Select: '); ROOTM=('' 'None' 'KSU' 'KSU-Next' 'KSU-Legacy' 'ReSukiSU' 'SukiSU')[$n]; SUSFS='None'
if [[ "$ROOTM" != None ]]; then echo; echo 'SUSFS:'; echo '  [1] Without SUSFS'; echo '  [2] With SUSFS'; n=$(choice 2 'Select: '); [[ $n == 2 ]] && SUSFS='SUSFS' || SUSFS='No-SUSFS'; fi

safe(){ printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g;s/__*/_/g;s/^_//;s/_$//'; }
DATE=$(date +%Y-%m-%d); TAG="$(safe "$PROJECT")_${DEVICE}_$(safe "$VARIANT")_$(safe "$ROOTM")_$(safe "$SUSFS")_$DATE"
msg "Selected: $PROJECT | $DEVICE | $VARIANT | $ROOTM | $SUSFS | ${#FILES[@]} file(s)"
read -r -p 'Continue upload? [Y/n]: ' yes || exit 1; [[ -z "$yes" || "$yes" =~ ^[Yy]$ ]] || exit 0

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT; : > "$TMP/links"; : > "$TMP/manifest"
pd(){ local f="$1" name="$2" r id; r="$(curl --fail-with-body -sS -u ":$PIXELDRAIN_API_KEY" -F "file=@$f;filename=$name" https://pixeldrain.com/api/file)" || return 1; id="$(jq -r '.id // empty' <<<"$r")"; [[ -n "$id" ]] || return 1; printf 'https://pixeldrain.com/u/%s' "$id"; }

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { warn "Missing: $f"; continue; }; base="$(basename "$f")"; if [[ $base == *.zip.md5 ]]; then name="${base%.zip.md5}_${TAG}.zip.md5"; else name="${base%.*}_${TAG}.${base##*.}"; fi
  size=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f"); sha=$(sha256sum "$f"|awk '{print $1}'); printf '%s | %s bytes | SHA256:%s\n' "$base" "$size" "$sha" >> "$TMP/manifest"
  if link=$(pd "$f" "$name"); then ok "Pixeldrain: $link"; printf '%s → %s\n' "$name" "$link" >> "$TMP/links"; else warn "Pixeldrain failed: $base"; fi
done

[[ -s "$TMP/links" ]] || die 'No files were uploaded to Pixeldrain; Telegram publish cancelled.'
ESC=$(sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$TMP/links")
CAP=$(printf '<b>📦 PUBLISH</b>\n\n<b>%s</b>\n\n<b>Device:</b> %s\n<b>Android:</b> %s\n<b>Build:</b> %s\n<b>SPL:</b> %s\n<b>Variant:</b> %s\n<b>Root:</b> %s\n<b>SUSFS:</b> %s\n<b>Release:</b> %s\n\n<b>Download:</b>\n%s' "$PROJECT" "$DEVICE" "$ANDROID" "$BUILD" "$PATCH" "$VARIANT" "$ROOTM" "$SUSFS" "$DATE" "$ESC")
curl --fail-with-body -sS "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -F "chat_id=$CHAT_ID" -F "text=$CAP" -F 'parse_mode=HTML' >/dev/null || die 'Telegram publish failed.'
ok 'Telegram publish sent with Pixeldrain download links.'
ok "Release upload completed: $TAG"
