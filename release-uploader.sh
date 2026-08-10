#!/usr/bin/env bash
set -euo pipefail

# Fresh release session. This launcher never modifies the caller's Android build environment.
need(){ command -v "$1" >/dev/null 2>&1 || { printf '[ERROR] Missing command: %s\n' "$1" >&2; exit 1; }; }
for x in bash curl find dirname mktemp stat; do need "$x"; done

unset PIXEL_UPLOADER_SOURCE_ROOT PIXEL_UPLOADER_OUT
unset RELEASE_DEVICE RELEASE_ROM RELEASE_PROJECT RELEASE_METADATA

is_android_tree(){
  local d="$1"
  [[ -d "$d/out/target/product" ]] || return 1
  [[ -f "$d/build/envsetup.sh" || -f "$d/build/make/core/envsetup.mk" ]] && return 0
  [[ -d "$d/.repo" ]] && return 0
  [[ -d "$d/device" && -d "$d/vendor" && -d "$d/frameworks" ]] && return 0
  return 1
}

find_source_root(){
  local p="$PWD"
  while [[ "$p" != "/" ]]; do
    if is_android_tree "$p"; then printf '%s\n' "$p"; return 0; fi
    p="$(dirname "$p")"
  done
  return 1
}

ROOT="$(find_source_root || true)"
if [[ -z "$ROOT" && -n "${ANDROID_BUILD_TOP:-}" ]] && is_android_tree "$ANDROID_BUILD_TOP"; then
  ROOT="$ANDROID_BUILD_TOP"
fi
[[ -n "$ROOT" ]] || {
  printf '[ERROR] Android source tree not found from: %s\n' "$PWD" >&2
  printf '[ERROR] Expected out/target/product in the current tree.\n' >&2
  exit 1
}

OUT="$ROOT/out/target/product"
printf '[INFO] Fresh release session\n'
if [[ -n "${ANDROID_BUILD_TOP:-}" && "$ANDROID_BUILD_TOP" != "$ROOT" ]]; then
  printf '[INFO] Ignoring stale ANDROID_BUILD_TOP: %s\n' "$ANDROID_BUILD_TOP"
fi
printf '[INFO] Source tree: %s\n' "$ROOT"

# Private variables only; the caller's ANDROID_BUILD_TOP is not changed.
export PIXEL_UPLOADER_SOURCE_ROOT="$ROOT"
export PIXEL_UPLOADER_OUT="$OUT"

# Secrets: ~/.config/pixel-uploader/secrets.env (mode 600) is preferred, then ~/.build_env.
# Only Pixeldrain is requested interactively when it is missing.
SECRETS_FILE="${PIXEL_UPLOADER_SECRETS:-$HOME/.config/pixel-uploader/secrets.env}"
load_secrets(){
  local f="$1" mode
  [[ -f "$f" ]] || return 1
  mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || printf 0)"
  [[ "$mode" == 600 ]] || { printf '[ERROR] Secrets file must have mode 600: %s\n' "$f" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$f"
}

if [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" || -z "${TELEGRAPH_TOKEN:-}" || -z "${PIXELDRAIN_API_KEY:-}" ]]; then
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

curl --fail --silent --show-error --location \
  "${CORE_URL}?ts=$(date +%s%N)" \
  -o "$CORE"

# Never rewrite/patch the core in a temporary Python transformation. This prevents
# malformed shell syntax and makes the downloaded core exactly what was pushed.
bash -n "$CORE" || {
  printf '[ERROR] release-uploader-core.sh from GitHub failed bash syntax validation.\n' >&2
  exit 2
}

exec bash "$CORE" "$@"
