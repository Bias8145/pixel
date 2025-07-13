#!/bin/bash

# Upload Script by VOLD_NAMESPACE

# Upload Script - Safe Version

# Usage:
#   export BOT_TOKEN="..."
#   export CHAT_ID="..."
#   export PIXELDRAIN_API_KEY="..."
#   export TELEGRAPH_TOKEN="..."
#   bash <(curl -s https://raw.githubusercontent.com/yourusername/repo/main/upload.sh) "banner" "project" path1 path2 path3

# Validate required tokens
if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" || -z "$PIXELDRAIN_API_KEY" || -z "$TELEGRAPH_TOKEN" ]]; then
  echo "❌ BOT_TOKEN, CHAT_ID, or API key is missing."
  echo "Please set them first using:"
  echo "  export BOT_TOKEN=\"your_bot_token\""
  echo "  export CHAT_ID=\"your_chat_id\""
  echo "  export PIXELDRAIN_API_KEY=\"your_pixeldrain_key\""
  echo "  export TELEGRAPH_TOKEN=\"your_telegraph_token\""
  exit 1
fi

# Color codes for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Function to print colored output
print_colored() {
    echo -e "${1}${2}${NC}"
}

# Function to log activities
log_activity() {
    local log_message="$1"
    local log_file="upload_script.log"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $log_message" >> "$log_file"
    print_colored $PURPLE "[LOG] $log_message"
}

# Function to print banner
print_banner() {
    print_colored $CYAN "╔════════════════════════════════════════════════════════════════╗"
    print_colored $CYAN "║          VOLD_NAMESPACE Upload Script                                     ║"
    print_colored $CYAN "║             Enhanced Version v2.0                                         ║"
    print_colored $CYAN "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    log_activity "Script started"
}

# Function to validate inputs
validate_inputs() {
    if [ $# -lt 3 ]; then
        print_colored $RED "❌ Error: Insufficient arguments"
        print_colored $YELLOW "Usage:"
        print_colored $WHITE "  ./upload.sh banner.jpg|https://... 'Project Name' file1 [file2 ...]"
        print_colored $YELLOW "Examples:"
        print_colored $WHITE "  ./upload.sh banner.jpg 'LineageOS 21' rom.zip boot.img"
        print_colored $WHITE "  ./upload.sh https://example.com/banner.jpg 'AOSP 15' system.img"
        log_activity "Validation failed: Insufficient arguments"
        exit 1
    fi
    log_activity "Input validation passed"
}

# Function to ask for KSU Next SUSFS
ask_ksu_next_susfs() {
    echo ""
    print_colored $YELLOW "KSU Next SUSFS Configuration"
    print_colored $WHITE "Do you want to include KSU Next SUSFS support in this build?"
    print_colored $CYAN "  [Y] Yes - Include KSU Next SUSFS support"
    print_colored $CYAN "  [N] No  - Standard build without KSU Next SUSFS"
    echo ""
    
    while true; do
        read -p "$(print_colored $YELLOW "Enter your choice (Y/N): ")" choice
        case $choice in
            [Yy]* ) 
                KSU_NEXT_SUSFS="true"
                print_colored $GREEN "✅ KSU Next SUSFS support will be included"
                log_activity "KSU Next SUSFS support enabled"
                break
                ;;
            [Nn]* ) 
                KSU_NEXT_SUSFS="false"
                print_colored $BLUE "Standard build without KSU Next SUSFS"
                log_activity "Standard build selected (no KSU Next SUSFS)"
                break
                ;;
            * ) 
                print_colored $RED "❌ Please answer Y or N"
                ;;
        esac
    done
    echo ""
}

# Function to detect device information
detect_device_info() {
    local first_file="$1"
    DEVICE_NAME=$(echo "$first_file" | awk -F '/' '{print $(NF-1)}' | tr '[:lower:]' '[:upper:]')
    
    if [ -z "$DEVICE_NAME" ] || [ "$DEVICE_NAME" = "." ]; then
        DEVICE_NAME=$(basename "$first_file" | cut -d'_' -f1 | cut -d'-' -f1 | tr '[:lower:]' '[:upper:]')
    fi
    
    if [ -z "$DEVICE_NAME" ]; then
        DEVICE_NAME="UNKNOWN"
    fi
    
    DEVICE_DIR="out/target/product/${DEVICE_NAME,,}"
    BUILD_PROP="$DEVICE_DIR/system/build.prop"
    
    print_colored $BLUE "Device detected: $DEVICE_NAME"
    log_activity "Device detected: $DEVICE_NAME"
}

# Function to extract build information
extract_build_info() {
    if [ -f "$BUILD_PROP" ]; then
        ROM_VERSION=$(grep "^ro.build.version.release=" "$BUILD_PROP" 2>/dev/null | cut -d'=' -f2)
        ROM_ID=$(grep "^ro.build.id=" "$BUILD_PROP" 2>/dev/null | cut -d'=' -f2)
        ROM_DISPLAY=$(grep "^ro.build.display.id=" "$BUILD_PROP" 2>/dev/null | cut -d'=' -f2)
        SECURITY_PATCH=$(grep "^ro.build.version.security_patch=" "$BUILD_PROP" 2>/dev/null | cut -d'=' -f2)
        ANDROID_VERSION=$(grep "^ro.build.version.release=" "$BUILD_PROP" 2>/dev/null | cut -d'=' -f2)
        SDK_VERSION=$(grep "^ro.build.version.sdk=" "$BUILD_PROP" 2>/dev/null | cut -d'=' -f2)
        
        if [ -n "$SECURITY_PATCH" ]; then
            FORMATTED_PATCH=$(date -d "$SECURITY_PATCH" "+%B %Y" 2>/dev/null || echo "$SECURITY_PATCH")
        else
            FORMATTED_PATCH="Unknown"
        fi
        
        print_colored $GREEN "✅ Build information extracted successfully"
        print_colored $WHITE "   Android Version: $ANDROID_VERSION"
        print_colored $WHITE "   Security Patch: $FORMATTED_PATCH"
        print_colored $WHITE "   Build ID: $ROM_ID"
        log_activity "Build information extracted: Android=$ANDROID_VERSION, Patch=$FORMATTED_PATCH, ID=$ROM_ID"
    else
        print_colored $YELLOW "⚠️  Build.prop not found, using default values"
        ANDROID_VERSION="15"
        FORMATTED_PATCH="Unknown"
        ROM_ID="Unknown"
        ROM_DISPLAY="Unknown"
        log_activity "Build.prop not found, using default values"
    fi
}

# Function to build tags and notes
build_tags_and_notes() {
    EXTRA_TAGS=""
    EXTRA_NOTE_RAW=""
    
    if [ "$KSU_NEXT_SUSFS" = "true" ]; then
        EXTRA_TAGS+=" [KSU-NEXT] [SUSFS]"
        EXTRA_NOTE_RAW+="✅ KernelSU Next support included\n"
        EXTRA_NOTE_RAW+="✅ SUSFS (Suspicious File System) enabled\n"
        EXTRA_NOTE_RAW+="✅ Enhanced root hiding capabilities\n"
        EXTRA_NOTE_RAW+="✅ Advanced detection bypass\n"
    fi
    
    TAG_NAME="[${PROJECT_NAME// /_}]"
    if [ "$ROM_DISPLAY" != "$ROM_ID" ] && [ -n "$ROM_DISPLAY" ] && [ "$ROM_DISPLAY" != "Unknown" ]; then
        TAG_NAME+=" [$ROM_DISPLAY] [$ROM_ID]"
    elif [ -n "$ROM_ID" ] && [ "$ROM_ID" != "Unknown" ]; then
        TAG_NAME+=" [$ROM_ID]"
    fi
    TAG_NAME+=" [Android $ANDROID_VERSION]${EXTRA_TAGS} [$RELEASE_DATE]"
    
    EXTRA_NOTE=$(echo -e "$EXTRA_NOTE_RAW")
    if [ -z "$EXTRA_NOTE" ]; then
        EXTRA_NOTE="✅ ROM build without modifications
✅ Clean installation recommended

⚠️ Always backup your data before flashing
Follow the flash guide for proper installation"
    else
        EXTRA_NOTE+="\n
✅ Custom build with enhanced features
✅ Advanced users recommended

⚠️ Always backup your data before flashing
Follow the flash guide for proper installation"
    fi
    
    print_colored $GREEN "✅ Tags and notes built successfully"
    log_activity "Tags and notes built: $TAG_NAME"
}

# Function to calculate file hash (MD5 and SHA256)
calculate_file_hash() {
    local file="$1"
    local hash_type="$2"
    
    case "$hash_type" in
        "md5")
            if command -v md5sum > /dev/null 2>&1; then
                md5sum "$file" | cut -d' ' -f1
            elif command -v md5 > /dev/null 2>&1; then
                md5 -q "$file"
            else
                echo "N/A"
            fi
            ;;
        "sha256")
            if command -v sha256sum > /dev/null 2>&1; then
                sha256sum "$file" | cut -d' ' -f1
            elif command -v shasum > /dev/null 2>&1; then
                shasum -a 256 "$file" | cut -d' ' -f1
            else
                echo "N/A"
            fi
            ;;
        *)
            echo "N/A"
            ;;
    esac
}

# Function to get short hash
get_short_hash() {
    local full_hash="$1"
    if [ "$full_hash" != "N/A" ] && [ -n "$full_hash" ]; then
        echo "${full_hash:0:8}"
    else
        echo "N/A"
    fi
}

# Function to build Telegram message
build_telegram_message() {
    TELEGRAM_MESSAGE="<b>New Release: ${PROJECT_NAME} for ${DEVICE_NAME}</b>

<b>Device:</b> ${DEVICE_NAME}
<b>Project:</b> ${PROJECT_NAME}
<b>Android Version:</b> ${ANDROID_VERSION}
<b>Security Patch:</b> ${FORMATTED_PATCH}
<b>Release Date:</b> ${RELEASE_DATE}
<b>Maintainer:</b> ${PROJECT_AUTHOR}

<b>Tag:</b> ${TAG_NAME}

<b>Release Notes:</b>
<pre>${EXTRA_NOTE}</pre>

<b>Files Size Information:</b>"
    log_activity "Telegram message built"
}

# Function to generate file names
generate_file_name() {
    local file_counter=$1
    local ext=$2
    local filename=$(basename "${FILES[$((file_counter-1))]}")

    case $file_counter in
        1)
            BASE_RENAME="${PROJECT_NAME// /_}_${DEVICE_NAME}_${RELEASE_DATE}"
            ;;
        2)
            if [ "$KSU_NEXT_SUSFS" = "true" ]; then
                BASE_RENAME="boot_${RELEASE_DATE}_KSU-NEXT_SUSFS"
            else
                BASE_RENAME="boot_${RELEASE_DATE}"
            fi
            ;;
        3)
            BASE_RENAME="dtbo_${RELEASE_DATE}"
            ;;
        4)
            BASE_RENAME="vendor_boot_${RELEASE_DATE}"
            ;;
        *)
            BASE_RENAME="$(basename "$filename" ."$ext")_${RELEASE_DATE}"
            ;;
    esac

    echo "${BASE_RENAME}.${ext}"
}

# Function to get file display name
get_file_display_name() {
    local file_counter=$1
    local filename=$(basename "${FILES[$((file_counter-1))]}")
    
    case $file_counter in
        1) echo "ROM";;
        2) echo "BOOT";;
        3) echo "DTBO";;
        4) echo "VENDOR_BOOT";;
        *) echo "FILE${file_counter}";;
    esac
}

# Function to format file size
format_file_size() {
    local file_size=$1
    if [ "$file_size" -gt 1073741824 ]; then
        awk "BEGIN {printf \"%.1f GB\", $file_size/1073741824}"
    else
        awk "BEGIN {printf \"%.1f MB\", $file_size/1048576}"
    fi
}

# Function to upload file to Pixeldrain
upload_to_pixeldrain() {
    local file_name=$1
    local file_size=$2
    local max_size=$((5 * 1024 * 1024 * 1024)) # 5GB
    
    if [ "$file_size" -le "$max_size" ]; then
        print_colored $CYAN "Uploading $file_name to Pixeldrain..." >&2
        log_activity "Uploading $file_name to Pixeldrain"
        PIXELDRAIN_RESPONSE=$(curl -s -u :$PIXELDRAIN_API_KEY -F "file=@$file_name" https://pixeldrain.com/api/file)
        PIXELDRAIN_ID=$(echo "$PIXELDRAIN_RESPONSE" | jq -r '.id // empty' 2>/dev/null)
        
        if [ -n "$PIXELDRAIN_ID" ] && [ "$PIXELDRAIN_ID" != "null" ]; then
            print_colored $GREEN "✅ Pixeldrain upload successful" >&2
            log_activity "Pixeldrain upload successful: https://pixeldrain.com/u/$PIXELDRAIN_ID"
            echo "https://pixeldrain.com/u/$PIXELDRAIN_ID"
        else
            print_colored $YELLOW "⚠️ Pixeldrain upload failed, using fallback" >&2
            log_activity "Pixeldrain upload failed for $file_name"
            echo "https://pixeldrain.com"
        fi
    else
        print_colored $YELLOW "⚠️ File too large for Pixeldrain (>5GB), skipping..." >&2
        log_activity "File $file_name too large for Pixeldrain (>5GB)"
        echo "https://pixeldrain.com"
    fi
}

# Function to process files
process_files() {
    MAIN_URLS=()
    FILE_COUNTER=0
    FILES=("$@")
    
    print_colored $BLUE "Processing files..."
    log_activity "Processing ${#FILES[@]} files"
    
    for FILE in "$@"; do
        FILE_COUNTER=$((FILE_COUNTER + 1))
        
        if [ ! -f "$FILE" ]; then
            print_colored $RED "❌ File not found: $FILE"
            log_activity "File not found: $FILE"
            continue
        fi
        
        EXT="${FILE##*.}"
        NEW_NAME=$(generate_file_name $FILE_COUNTER $EXT)
        
        print_colored $PURPLE "Processing file $FILE_COUNTER: $(basename "$FILE")"
        log_activity "Processing file $FILE_COUNTER: $(basename "$FILE")"
        
        cp "$FILE" "$NEW_NAME"
        
        FILE_SIZE=$(stat -c%s "$NEW_NAME" 2>/dev/null || stat -f%z "$NEW_NAME" 2>/dev/null || echo "0")
        
        print_colored $CYAN "Calculating file hashes..." >&2
        MD5_HASH=$(calculate_file_hash "$NEW_NAME" "md5")
        SHA256_HASH=$(calculate_file_hash "$NEW_NAME" "sha256")
        
        SHORT_MD5=$(get_short_hash "$MD5_HASH")
        SHORT_SHA256=$(get_short_hash "$SHA256_HASH")
        
        print_colored $GREEN "✅ Hash calculated: MD5=${SHORT_MD5}, SHA256=${SHORT_SHA256}" >&2
        log_activity "Hashes for $NEW_NAME: MD5=$SHORT_MD5, SHA256=$SHORT_SHA256"
        
        PIXELDRAIN_URL=$(upload_to_pixeldrain "$NEW_NAME" "$FILE_SIZE")
        
        if [[ ! "$PIXELDRAIN_URL" =~ ^https?:// ]]; then
            PIXELDRAIN_URL="https://pixeldrain.com"
        fi
        
        MAIN_URLS+=("$PIXELDRAIN_URL")
        
        DISPLAY_NAME=$(get_file_display_name $FILE_COUNTER)
        SIZE_DISPLAY=$(format_file_size $FILE_SIZE)
        
        HASH_INFO=""
        if [ "$SHORT_MD5" != "N/A" ] && [ "$SHORT_SHA256" != "N/A" ]; then
            HASH_INFO=" | MD5: ${SHORT_MD5} | SHA: ${SHORT_SHA256}"
        elif [ "$SHORT_MD5" != "N/A" ]; then
            HASH_INFO=" | MD5: ${SHORT_MD5}"
        elif [ "$SHORT_SHA256" != "N/A" ]; then
            HASH_INFO=" | SHA: ${SHORT_SHA256}"
        fi
        
        TELEGRAM_MESSAGE+="\n▫️ <b>${DISPLAY_NAME}</b> – ${SIZE_DISPLAY}${HASH_INFO}"
        
        rm "$NEW_NAME"
        
        print_colored $GREEN "✅ File $FILE_COUNTER processed successfully"
        log_activity "File $FILE_COUNTER processed successfully"
    done
    
    TELEGRAM_MESSAGE+="\n\n<b>Click the buttons below to download the files</b>"
    
    print_colored $GREEN "✅ All files processed successfully ($FILE_COUNTER files)"
    log_activity "All files processed successfully ($FILE_COUNTER files)"
}

# Function to create flash guide
create_flash_guide() {
    print_colored $BLUE "Creating flash guide..."
    log_activity "Starting creation of flash guide for $PROJECT_NAME on $DEVICE_NAME"
    
    FLASH_GUIDE_TEXT="Complete Flash Guide for $DEVICE_NAME

⚠️ IMPORTANT WARNINGS:
• Always backup your data before flashing
• Ensure bootloader is unlocked
• Use latest platform-tools (ADB/Fastboot)
• Battery should be >50%
• Disable antivirus during flashing

FASTBOOT METHOD:
1. Download and extract all files
2. Enable USB debugging and OEM unlocking
3. Reboot to bootloader:
   adb reboot bootloader
   OR
   fastboot reboot bootloader
4. Flash boot image (if available):
   fastboot flash --slot all boot boot.img
5. Flash dtbo image (if available):
   fastboot flash dtbo dtbo.img
6. Flash vendor image (if available):
   fastboot flash vendor vendor.img
   OR
   fastboot flash vendor_boot vendor_boot.img
7. Reboot to recovery:
   fastboot reboot recovery
8. Apply ROM via ADB sideload:
   adb sideload rom.zip

TROUBLESHOOTING:
• If stuck in bootloop: Flash stock firmware
• If no signal: Flash modem/radio firmware
• If storage issues: Format data in recovery
• If bootloader locked: Unlock bootloader first

⚡ ROOT INFORMATION:"

    if [ "$KSU_NEXT_SUSFS" = "true" ]; then
        FLASH_GUIDE_TEXT+="\n
• KernelSU Next with SUSFS is pre-installed
• Download KSU Next Manager from official channel
• No additional flashing required
• Enhanced root hiding capabilities
• Advanced detection bypass included
• SUSFS provides superior stealth mode"
        log_activity "Added KSU Next SUSFS information to flash guide"
    else
        FLASH_GUIDE_TEXT+="\n
• No root solution pre-installed
• You can flash KernelSU/Magisk separately if needed
• This is a clean build without modifications
• Root access requires separate installation"
        log_activity "Added standard build information to flash guide"
    fi

    FLASH_GUIDE_TEXT+="\n
SUPPORT & COMMUNITY:
• Flash Guide: https://telegra.ph/Flash-Guide-${PROJECT_NAME// /_}-for-${DEVICE_NAME// /_}
• Support Group: https://t.me/pixel4seriesofficial
• Support Our Work: https://donate-morpheus.netlify.app
• Maintainer: @VOLD_NAMESPACE
• Report bugs with detailed logs
• Share your feedback and experience

USEFUL LINKS:
• Platform Tools: https://developer.android.com/tools/releases/platform-tools
• KSU Next: https://t.me/ksunext"

    FLASH_GUIDE_TEXT+="\n
⚖️ DISCLAIMER:
Flashing custom ROMs may void warranty and could potentially brick your device. 
The maintainer is not responsible for any damage caused by flashing this ROM.
Flash at your own risk and ensure you understand the process!"

    log_activity "Added entries to SUPPORT & COMMUNITY: Flash Guide, Support Group, Support Our Work"

    print_colored $CYAN "Creating Telegraph page..."
    log_activity "Sending request to create Telegraph page"
    FLASH_GUIDE_RESPONSE=$(curl -s -X POST https://api.telegra.ph/createPage \
        -d access_token="$TELEGRAPH_TOKEN" \
        --data-urlencode "title=Flash Guide - $PROJECT_NAME for $DEVICE_NAME" \
        --data-urlencode "author_name=VOLD_NAMESPACE" \
        --data-urlencode "author_url=https://t.me/VOLD_NAMESPACE" \
        --data-urlencode "content=[{\"tag\":\"pre\",\"children\":[\"$FLASH_GUIDE_TEXT\"]}]")

    FLASH_GUIDE_URL=$(echo "$FLASH_GUIDE_RESPONSE" | jq -r '.result.url // empty' 2>/dev/null)
    
    if [ -n "$FLASH_GUIDE_URL" ] && [ "$FLASH_GUIDE_URL" != "null" ]; then
        print_colored $GREEN "✅ Flash guide created successfully"
        print_colored $WHITE " URL: $FLASH_GUIDE_URL"
        log_activity "Flash guide created successfully: $FLASH_GUIDE_URL"
    else
        print_colored $YELLOW "⚠️ Flash guide creation failed"
        FLASH_GUIDE_URL="https://telegra.ph/Flash-Guide-${PROJECT_NAME// /_}-for-${DEVICE_NAME// /_}"
        log_activity "Flash guide creation failed, using fallback URL: $FLASH_GUIDE_URL"
    fi
}

# Function to build inline keyboard
build_inline_keyboard() {
    print_colored $BLUE "Building inline keyboard..."
    log_activity "Starting inline keyboard creation for $PROJECT_NAME"
    
    KSU_NEXT_MANAGER_URL="https://t.me/ksunext/728"
    SUPPORT_GROUP_URL="https://t.me/pixel4seriesofficial"
    SUPPORT_WORK_URL="https://donate-morpheus.netlify.app"
    
    INLINE_KEYBOARD='{"inline_keyboard":['
    
    FIRST_ROW_BUTTONS=()
    
    if [ ${#MAIN_URLS[@]} -gt 0 ]; then
        ROM_URL_ESCAPED=$(echo "${MAIN_URLS[0]}" | sed 's/"/\\"/g')
        FIRST_ROW_BUTTONS+=("{\"text\":\"ROM\",\"url\":\"${ROM_URL_ESCAPED}\"}")
    fi
    
    if [ ${#MAIN_URLS[@]} -gt 1 ]; then
        BOOT_URL_ESCAPED=$(echo "${MAIN_URLS[1]}" | sed 's/"/\\"/g')
        FIRST_ROW_BUTTONS+=("{\"text\":\"BOOT\",\"url\":\"${BOOT_URL_ESCAPED}\"}")
    fi
    
    if [ ${#FIRST_ROW_BUTTONS[@]} -gt 0 ]; then
        INLINE_KEYBOARD+="["
        for i in "${!FIRST_ROW_BUTTONS[@]}"; do
            [ $i -gt 0 ] && INLINE_KEYBOARD+=","
            INLINE_KEYBOARD+="${FIRST_ROW_BUTTONS[$i]}"
        done
        INLINE_KEYBOARD+="]"
        log_activity "Added first row to inline keyboard: ${FIRST_ROW_BUTTONS[*]}"
    fi
    
    SECOND_ROW_BUTTONS=()
    
    if [ ${#MAIN_URLS[@]} -gt 2 ]; then
        DTBO_URL_ESCAPED=$(echo "${MAIN_URLS[2]}" | sed 's/"/\\"/g')
        SECOND_ROW_BUTTONS+=("{\"text\":\"DTBO\",\"url\":\"${DTBO_URL_ESCAPED}\"}")
    fi
    
    if [ ${#MAIN_URLS[@]} -gt 3 ]; then
        VENDOR_BOOT_URL_ESCAPED=$(echo "${MAIN_URLS[3]}" | sed 's/"/\\"/g')
        SECOND_ROW_BUTTONS+=("{\"text\":\"VENDOR BOOT\",\"url\":\"${VENDOR_BOOT_URL_ESCAPED}\"}")
    fi
    
    if [ ${#SECOND_ROW_BUTTONS[@]} -gt 0 ]; then
        INLINE_KEYBOARD+=",["
        for i in "${!SECOND_ROW_BUTTONS[@]}"; do
            [ $i -gt 0 ] && INLINE_KEYBOARD+=","
            INLINE_KEYBOARD+="${SECOND_ROW_BUTTONS[$i]}"
        done
        INLINE_KEYBOARD+="]"
        log_activity "Added second row to inline keyboard: ${SECOND_ROW_BUTTONS[*]}"
    fi
    
    if [ "$KSU_NEXT_SUSFS" = "true" ]; then
        INLINE_KEYBOARD+=",[{\"text\":\"KernelSU Next Manager\",\"url\":\"${KSU_NEXT_MANAGER_URL}\"}]"
        log_activity "Added KernelSU Next Manager button to inline keyboard"
    fi
    
    INLINE_KEYBOARD+=",["
    INLINE_KEYBOARD+="{\"text\":\"Flash Guide\",\"url\":\"${FLASH_GUIDE_URL}\"}"
    INLINE_KEYBOARD+=",{\"text\":\"Support Group\",\"url\":\"${SUPPORT_GROUP_URL}\"}"
    INLINE_KEYBOARD+=",{\"text\":\"Support Our Work\",\"url\":\"${SUPPORT_WORK_URL}\"}"
    INLINE_KEYBOARD+="]"
    log_activity "Added fourth row to inline keyboard: Flash Guide, Support Group, Support Our Work"
    
    INLINE_KEYBOARD+="]}"
    
    print_colored $GREEN "✅ Inline keyboard built successfully"
    log_activity "Inline keyboard built successfully: $INLINE_KEYBOARD"
    
    print_colored $YELLOW "Keyboard layout:"
    print_colored $WHITE "   Row 1: ${FIRST_ROW_BUTTONS[*]}"
    print_colored $WHITE "   Row 2: ${SECOND_ROW_BUTTONS[*]}"
    [ "$KSU_NEXT_SUSFS" = "true" ] && print_colored $WHITE "   Row 3: KernelSU Next Manager"
    print_colored $WHITE "   Row 4: Flash Guide | Support Group | Support Our Work"
}

# Main execution
print_banner
validate_inputs "$@"
BANNER="$1"
PROJECT_NAME="$2"
shift 2
RELEASE_DATE=$(date '+%Y%m%d')
PROJECT_AUTHOR="@VOLD_NAMESPACE"

ask_ksu_next_susfs
detect_device_info "$1"
extract_build_info
build_tags_and_notes
build_telegram_message
process_files "$@"
create_flash_guide
build_inline_keyboard

# Send to Telegram
print_colored $CYAN "Sending to Telegram..."
log_activity "Sending message to Telegram"
TELEGRAM_RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" \
    -F chat_id="$CHAT_ID" \
    -F photo="$BANNER" \
    -F caption="$TELEGRAM_MESSAGE" \
    -F parse_mode="HTML" \
    -F reply_markup="$INLINE_KEYBOARD")

if echo "$TELEGRAM_RESPONSE" | grep -q '"ok":true'; then
    print_colored $GREEN "✅ Successfully sent to Telegram"
    log_activity "Successfully sent to Telegram"
else
    print_colored $RED "❌ Failed to send to Telegram"
    log_activity "Failed to send to Telegram: $TELEGRAM_RESPONSE"
fi
