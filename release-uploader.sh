#!/usr/bin/env bash
set -euo pipefail

# Fresh release session. The current working tree is the release context.
need(){ command -v "$1" >/dev/null 2>&1 || { printf '[ERROR] Missing command: %s\n' "$1" >&2; exit 1; }; }
for x in bash curl find dirname mktemp stat sed date; do need "$x"; done

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

# Do not consult a stale ANDROID_BUILD_TOP first. The directory where the
# uploader is executed is always the release context.
if ! is_android_tree "$PWD"; then
  printf '[ERROR] Current directory is not an Android source root: %s\n' "$PWD" >&2
  printf '[ERROR] Run the uploader directly from the ROM source root.\n' >&2
  exit 1
fi

ROOT="$PWD"
OUT="$ROOT/out/target/product"
printf '[INFO] Fresh release session\n'
printf '[INFO] Source tree: %s\n' "$ROOT"

export PIXEL_UPLOADER_SOURCE_ROOT="$ROOT"
export PIXEL_UPLOADER_OUT="$OUT"

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

# The current core contains banner-parser expressions with shell quote syntax
# that older revisions generated incorrectly. Normalize only those known lines,
# then validate the complete downloaded script before executing it.
sed -i \
  '/image_url=.*property=.*og:image/c\    image_url="$(sed -nE "s/.*property=\\\"og:image\\\"[^>]+content=\\\"([^\\\"]+)\\\".*/\\1/ip" "$page" | head -n1)' \
  '/image_url=.*content=.*og:image.*property=/c\    [[ -n "$image_url" ]] || image_url="$(sed -nE "s/.*content=\\\"([^\\\"]+)\\\"[^>]+property=\\\"og:image\\\".*/\\1/ip" "$page" | head -n1)' \
  '/image_url=.*name=.*twitter:image/c\    [[ -n "$image_url" ]] || image_url="$(sed -nE "s/.*name=\\\"twitter:image\\\"[^>]+content=\\\"([^\\\"]+)\\\".*/\\1/ip" "$page" | head -n1)' \
  '/image_url=.*content=.*twitter:image.*name=/c\    [[ -n "$image_url" ]] || image_url="$(sed -nE "s/.*content=\\\"([^\\\"]+)\\\"[^>]+name=\\\"twitter:image\\\".*/\\1/ip" "$page" | head -n1)' \
  "$CORE"

# Fix the multipart caption form field if an older core revision is present.
sed -i 's/-F "caption=<$TEMP_MSG_FILE"/-F "caption=@$TEMP_MSG_FILE"/' "$CORE"

bash -n "$CORE" || {
  printf '[ERROR] release-uploader-core.sh failed syntax validation.\n' >&2
  printf '[ERROR] The release was not started.\n' >&2
  exit 2
}

exec bash "$CORE" "$@"
