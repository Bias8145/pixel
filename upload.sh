#!/bin/bash
# Upload Script by VOLD_NAMESPACE – Final Professional Version

# === TELEGRAM BOT CONFIGURATION ===
BOT_TOKEN="8157524153:AAFSjN8imNmN7bG5acTOVZtB5znqmF9uV-E"
CHAT_ID="7158489417"

# === CHECK INPUT FILES ===
if [ $# -lt 2 ]; then
  echo -e "Usage:\n  ./upload.sh 'Project Name' file1 [file2 ...]"
  exit 1
fi

PROJECT_NAME="$1"
shift

RELEASE_DATE=$(date +"%d-%m-%Y")
TAG_NAME="[${PROJECT_NAME// /_}] [SUNFISH] [KSU] [${RELEASE_DATE}]"
PROJECT_AUTHOR="@VOLD_NAMESPACE"
UPLOAD_LOG="upload_log.txt"

echo "Upload started: $(date)" > "$UPLOAD_LOG"
echo "===============================================" >> "$UPLOAD_LOG"

# === INITIAL TELEGRAM MESSAGE ===
TELEGRAM_MESSAGE="<b>NEW RELEASE UPDATE</b>

<b>Device:</b> SUNFISH
<b>Project:</b> ${PROJECT_NAME}
<b>Date:</b> ${RELEASE_DATE}
<b>Maintainer:</b> ${PROJECT_AUTHOR}
<b>Tag:</b> ${TAG_NAME}

<b>Note:</b> KernelSU Next (SUSFS) is already included in this ROM.

<b>FILE INFORMATION:</b>"

DOWNLOAD_URLS=()
FILE_COUNTER=0

# === PROCESS EACH FILE ===
for FILE in "$@"; do
  FILE_COUNTER=$((FILE_COUNTER + 1))

  if [ ! -f "$FILE" ]; then
    echo "File not found: $FILE"
    continue
  fi

  # === DYNAMIC AUTO RENAME ===
  BASENAME=$(basename "$FILE")
  EXT="${BASENAME##*.}"
  BASE_RENAME="${PROJECT_NAME// /_}_KSU_${RELEASE_DATE}"

  case $FILE_COUNTER in
    1) SUFFIX="ROM";;
    2) SUFFIX="BOOT";;
    *) SUFFIX="File${FILE_COUNTER}";;
  esac

  NEW_NAME="${BASE_RENAME}_${SUFFIX}.${EXT}"
  cp "$FILE" "$NEW_NAME"
  echo "Renamed: $BASENAME → $NEW_NAME"

  # === UPLOAD TO GOFILE ===
  echo "Uploading: $NEW_NAME"
  UPLOAD_RESPONSE=$(curl -s -F "file=@$NEW_NAME" https://upload.gofile.io/uploadFile)

  DOWNLOAD_URL=$(echo "$UPLOAD_RESPONSE" | grep -o '"downloadPage":"[^"]*' | cut -d'"' -f4)
  FILE_SIZE=$(echo "$UPLOAD_RESPONSE" | grep -o '"size":[^,}]*' | cut -d':' -f2)

  if command -v bc >/dev/null 2>&1; then
    FILE_SIZE_MB=$(echo "scale=2; $FILE_SIZE/1048576" | bc)
    SIZE_INFO="${FILE_SIZE_MB} MB"
  else
    SIZE_INFO="${FILE_SIZE} bytes"
  fi

  FILE_HASH=$(sha256sum "$NEW_NAME" | cut -d' ' -f1)
  SHORT_HASH="${FILE_HASH:0:6}...${FILE_HASH: -6}"

  # === FILE DISPLAY LABELING ===
  DISPLAY_NAME="FILE ${FILE_COUNTER}"
  [ $FILE_COUNTER -eq 1 ] && DISPLAY_NAME="ROM Package"
  [ $FILE_COUNTER -eq 2 ] && DISPLAY_NAME="BOOT Image"

  TELEGRAM_MESSAGE="${TELEGRAM_MESSAGE}

<b>${DISPLAY_NAME}:</b>
• Name: <code>${NEW_NAME}</code>
• Size: ${SIZE_INFO}
• SHA256: <code>${SHORT_HASH}</code>
• Status: Uploaded"

  DOWNLOAD_URLS+=("$DOWNLOAD_URL")

  echo "Uploaded: $NEW_NAME"
  echo -e "File: $NEW_NAME\nSize: $SIZE_INFO\nHash: $FILE_HASH\nURL: $DOWNLOAD_URL\n------------------------------------------------" >> "$UPLOAD_LOG"
done

# === ADD DOWNLOAD LINKS TO MESSAGE ===
TELEGRAM_MESSAGE="${TELEGRAM_MESSAGE}

<b>Download Links Below</b>
────────────────────────────"

INLINE_KEYBOARD='{"inline_keyboard":['
for i in "${!DOWNLOAD_URLS[@]}"; do
  BUTTON_TEXT="Download File $((i+1))"
  [ $i -eq 0 ] && BUTTON_TEXT="Download ROM"
  [ $i -eq 1 ] && BUTTON_TEXT="Download BOOT"
  [ $i -gt 0 ] && INLINE_KEYBOARD="${INLINE_KEYBOARD},"
  INLINE_KEYBOARD="${INLINE_KEYBOARD}[{\"text\":\"${BUTTON_TEXT}\",\"url\":\"${DOWNLOAD_URLS[$i]}\"}]"
done
INLINE_KEYBOARD="${INLINE_KEYBOARD}]}"

# === PREVIEW MESSAGE ===
TEMP_MSG_FILE=$(mktemp)
echo -n "$TELEGRAM_MESSAGE" > "$TEMP_MSG_FILE"

echo ""
echo "--- TELEGRAM MESSAGE PREVIEW ---"
echo ""
sed 's/<[^>]*>//g' "$TEMP_MSG_FILE"
echo ""
echo "Download Buttons:"
for i in "${!DOWNLOAD_URLS[@]}"; do
  LABEL="Download File $((i+1))"
  [ $i -eq 0 ] && LABEL="Download ROM"
  [ $i -eq 1 ] && LABEL="Download BOOT"
  echo "- ${LABEL}: ${DOWNLOAD_URLS[$i]}"
done

echo ""
read -p "Send this message to Telegram? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Upload canceled by user."
  rm "$TEMP_MSG_FILE"
  exit 0
fi

# === SEND TO TELEGRAM ===
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "text@${TEMP_MSG_FILE}" \
  --data-urlencode "parse_mode=HTML" \
  -d "reply_markup=${INLINE_KEYBOARD}"

rm "$TEMP_MSG_FILE"

echo -e "\nUpload complete and message sent to Telegram."
echo "Log saved at: $UPLOAD_LOG"
