#!/usr/bin/env bash
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { printf '[ERROR] Missing command: %s\n' "$1" >&2; exit 1; }; }
for x in bash curl python3 find sed sort stat dirname mktemp; do need "$x"; done

# Fresh uploader session: never reuse uploader state from a previous execution.
unset PIXEL_UPLOADER_SOURCE_ROOT PIXEL_UPLOADER_OUT
unset RELEASE_DEVICE RELEASE_ROM RELEASE_PROJECT RELEASE_METADATA

is_android_tree(){
  local d="$1"
  [[ -d "$d/.repo" ]] && return 0
  [[ -f "$d/build/envsetup.sh" ]] && return 0
  [[ -f "$d/build/make/core/envsetup.mk" ]] && return 0
  [[ -d "$d/device" && -d "$d/vendor" && -d "$d/frameworks" ]] && return 0
  return 1
}

find_source_root(){
  local p="$PWD"
  while [[ "$p" != "/" ]]; do
    if is_android_tree "$p" && [[ -d "$p/out/target/product" ]]; then
      printf '%s\n' "$p"; return 0
    fi
    p="$(dirname "$p")"
  done
  return 1
}

# Current directory wins. ANDROID_BUILD_TOP is only a fallback.
ROOT="$(find_source_root || true)"
if [[ -z "$ROOT" && -n "${ANDROID_BUILD_TOP:-}" ]] && is_android_tree "$ANDROID_BUILD_TOP" && [[ -d "$ANDROID_BUILD_TOP/out/target/product" ]]; then
  ROOT="$ANDROID_BUILD_TOP"
fi
[[ -n "$ROOT" ]] || { printf '[ERROR] Cannot identify Android source tree from %s\n' "$PWD" >&2; exit 1; }
OUT="$ROOT/out/target/product"
[[ -d "$OUT" ]] || { printf '[ERROR] Missing output directory: %s\n' "$OUT" >&2; exit 1; }
[[ -z "${ANDROID_BUILD_TOP:-}" || "$ANDROID_BUILD_TOP" == "$ROOT" ]] || printf '[INFO] Ignoring stale ANDROID_BUILD_TOP: %s\n' "$ANDROID_BUILD_TOP"
printf '[INFO] Fresh release session\n[INFO] Source tree: %s\n' "$ROOT"

# Do not export/modify ANDROID_BUILD_TOP. These are private uploader variables only.
export PIXEL_UPLOADER_SOURCE_ROOT="$ROOT"
export PIXEL_UPLOADER_OUT="$OUT"

# Credentials are read from the protected secrets file or ~/.build_env. The Pixeldrain
# key can be supplied for this invocation; if absent, only that key is requested interactively.
SECRETS_FILE="${PIXEL_UPLOADER_SECRETS:-$HOME/.config/pixel-uploader/secrets.env}"
load_secrets(){
  local f="$1" mode
  [[ -f "$f" ]] || return 1
  mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || printf 0)"
  [[ "$mode" == 600 ]] || { printf '[ERROR] Secrets file must have mode 600: %s\n' "$f" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$f"
}
if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" || -z "${TELEGRAPH_TOKEN:-}" ]]; then
  load_secrets "$SECRETS_FILE" || load_secrets "$HOME/.build_env" || true
fi
if [[ -z "${PIXELDRAIN_API_KEY:-}" ]]; then
  printf 'Pixeldrain API key: '
  read -r -s PIXELDRAIN_API_KEY || exit 1
  printf '\n'
  [[ -n "$PIXELDRAIN_API_KEY" ]] || { printf '[ERROR] Pixeldrain API key is required.\n' >&2; exit 1; }
  export PIXELDRAIN_API_KEY
fi
: "${BOT_TOKEN:?Set BOT_TOKEN in ~/.config/pixel-uploader/secrets.env or ~/.build_env}"
: "${CHAT_ID:?Set CHAT_ID in ~/.config/pixel-uploader/secrets.env or ~/.build_env}"
: "${TELEGRAPH_TOKEN:?Set TELEGRAPH_TOKEN in ~/.config/pixel-uploader/secrets.env or ~/.build_env}"

CORE_URL="https://raw.githubusercontent.com/Bias8145/pixel/main/release-uploader-core.sh"
TMP="$(mktemp -d)"
trap 'unset PIXEL_UPLOADER_SOURCE_ROOT PIXEL_UPLOADER_OUT PIXELDRAIN_API_KEY; rm -rf "$TMP"' EXIT
CORE="$TMP/release-uploader-core.sh"
PATCHED="$TMP/release-uploader-patched.sh"
curl --fail --silent --show-error --location "${CORE_URL}?ts=$(date +%s%N)" -o "$CORE"

python3 - "$CORE" "$PATCHED" <<'PY'
import re, sys
src, dst = sys.argv[1:]
s = open(src, encoding='utf-8').read()
s = re.sub(r'ROOT="\$\{PIXEL_UPLOADER_SOURCE_ROOT:-\$\{ANDROID_BUILD_TOP:-\$\(pwd\)\}\}"', 'ROOT="${PIXEL_UPLOADER_SOURCE_ROOT}"', s, count=1)
s = re.sub(r'ROOT="\$\{ANDROID_BUILD_TOP:-\$\(pwd\)\}"', 'ROOT="${PIXEL_UPLOADER_SOURCE_ROOT}"', s, count=1)
s = re.sub(r'OUT="\$\{PIXEL_UPLOADER_OUT:-\$ROOT/out/target/product\}"', 'OUT="${PIXEL_UPLOADER_OUT}"', s, count=1)
s = re.sub(r'OUT="\$ROOT/out/target/product"', 'OUT="${PIXEL_UPLOADER_OUT}"', s, count=1)
s = s.replace("sel=(); while read -r x; do sel+=(\"$x\"); done < <(printf '%s\\n' \"$norm\" | awk '{for(i=1;i<=NF;i++)print $i}')", 'read -r -a sel <<< "$norm"')

# Dynamic device discovery: only the resolved source tree's output is considered.
pat = r'mapfile -t DEVICES <\(.*?\)'
replacement = r'''mapfile -t DEVICES < <(for d in "$OUT"/*; do
  [[ -d "$d" ]] || continue
  meta=""
  for f in "$d/build.prop" "$d/prop.default" "$d/system/build.prop" "$d/system/etc/prop.default" "$d/vendor/build.prop" "$d/vendor/etc/prop.default" "$d/product/build.prop"; do
    [[ -f "$f" ]] && { meta="$f"; break; }
  done
  [[ -n "$meta" ]] || continue
  find "$d" -maxdepth 1 -type f \( -iname '*.zip' -o -iname '*.ozip' -o -iname '*.img' \) -print -quit | grep -q . || continue
  printf '%s\n' "${d##*/}"
done | sort -u)'''
s, _ = re.subn(pat, replacement, s, count=1, flags=re.S)

# ROM discovery: only files in the selected device output. No hard-coded ROM identity.
pat2 = r'mapfile -t ROMS <\(.*?\)'
replacement2 = r'''mapfile -t ROMS < <(for f in "$DOUT"/*; do
  [[ -f "$f" ]] || continue
  case "${f,,}" in
    *.zip|*.ozip) printf '%s\n' "$f";;
  esac
done | sort)'''
s, _ = re.subn(pat2, replacement2, s, count=1, flags=re.S)

open(dst, 'w', encoding='utf-8', newline='\n').write(s)
PY

bash -n "$PATCHED"
exec bash "$PATCHED" "$@"
