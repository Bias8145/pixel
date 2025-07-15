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

# Function to print banner
print_banner() {
    print_colored $CYAN "╔════════════════════════════════════════════════════════════════╗"
    print_colored $CYAN "           VOLD_NAMESPACE Upload Script                                     "
    print_colored $CYAN "              Enhanced Version v2.0                                         "
    print_colored $CYAN "╚════════════════════════════════════════════════════════════════╝"
    echo ""
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
        exit 1
    fi
}

# Function to get user confirmation for KSU Next SUSFS
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
                break
                ;;
            [Nn]* ) 
                KSU_NEXT_SUSFS="false"
                print_colored $BLUE "Standard build without KSU Next SUSFS"
                break
                ;;
            * ) 
                print_colored $RED "❌ Please answer Y or N"
                ;;
        esac
    done
    echo ""
}

# Function to get user confirmation for GApps
ask_gapps_variant() {
    echo ""
    print_colored $YELLOW "GApps Variant"
    print_colored $WHITE "Is this a GApps build?"
    print_colored $CYAN "  [Y] Yes - GApps build"
    print_colored $CYAN "  [N] No  - Vanilla build"
    echo ""

    while true; do
        read -p "$(print_colored $YELLOW "Enter your choice (Y/N): ")" choice
        case $choice in
            [Yy]* )
                IS_GAPPS="true"
                print_colored $GREEN "✅ GApps build selected"
                break
                ;;
            [Nn]* )
                IS_GAPPS="false"
                print_colored $BLUE "✅ Vanilla build selected"
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
    
    # If device name is empty, try to extract from filename
    if [ -z "$DEVICE_NAME" ] || [ "$DEVICE_NAME" = "." ]; then
        DEVICE_NAME=$(basename "$first_file" | cut -d'_' -f1 | cut -d'-' -f1 | tr '[:lower:]' '[:upper:]')
    fi
    
    # Default device name if still empty
    if [ -z "$DEVICE_NAME" ]; then
        DEVICE_NAME="UNKNOWN"
    fi
    
    DEVICE_DIR="out/target/product/${DEVICE_NAME,,}"
    BUILD_PROP="$DEVICE_DIR/system/build.prop"
    
    print_colored $BLUE "Device detected: $DEVICE_NAME"
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
        
        # Format security patch date
        if [ -n "$SECURITY_PATCH" ]; then
            FORMATTED_PATCH=$(date -d "$SECURITY_PATCH" "+%B %Y" 2>/dev/null || echo "$SECURITY_PATCH")
        else
            FORMATTED_PATCH="Unknown"
        fi
        
        print_colored $GREEN "✅ Build information extracted successfully"
        print_colored $WHITE "   Android Version: $ANDROID_VERSION"
        print_colored $WHITE "   Security Patch: $FORMATTED_PATCH"
        print_colored $WHITE "   Build ID: $ROM_ID"
    else
        print_colored $YELLOW "⚠️  Build.prop not found, using default values"
        ANDROID_VERSION="15"
        FORMATTED_PATCH="Unknown"
        ROM_ID="Unknown"
        ROM_DISPLAY="Unknown"
    fi
}

# Function to build tags and notes
build_tags_and_notes() {
    EXTRA_TAGS=""
EXTRA_NOTE_RAW=""

# GApps/Vanilla Tagging
if [ "$IS_GAPPS" = "true" ]; then
    EXTRA_TAGS+=" [GAPPS]"
    EXTRA_NOTE_RAW+="✅ Google Apps included\n"
else
    EXTRA_TAGS+=" [VANILLA]"
    EXTRA_NOTE_RAW+="✅ Vanilla build (no Google Apps)\n"
fi

# KSU Tagging
if [ "$KSU_NEXT_SUSFS" = "true" ]; then
    EXTRA_TAGS+=" [KSU-NEXT] [SUSFS]"
    EXTRA_NOTE_RAW+="✅ KernelSU Next support included\n"
    EXTRA_NOTE_RAW+="✅ SUSFS (Suspicious File System) enabled\n"
fi
    
    # Build tag name
    TAG_NAME="[${PROJECT_NAME// /_}]"
    if [ "$ROM_DISPLAY" != "$ROM_ID" ] && [ -n "$ROM_DISPLAY" ] && [ "$ROM_DISPLAY" != "Unknown" ]; then
        TAG_NAME+=" [$ROM_DISPLAY] [$ROM_ID]"
    elif [ -n "$ROM_ID" ] && [ "$ROM_ID" != "Unknown" ]; then
        TAG_NAME+=" [$ROM_ID]"
    fi
    TAG_NAME+=" [Android $ANDROID_VERSION]${EXTRA_TAGS} [$RELEASE_DATE]"
    
    # Build extra notes
    EXTRA_NOTE=$(echo -e "$EXTRA_NOTE_RAW")
    if [ -z "$EXTRA_NOTE" ]; then
        EXTRA_NOTE="✅ ROM build without modifications
✅ Clean installation recommended

⚠️ Always backup your data before flashing
Follow the flash guide for proper installation"
    else
        EXTRA_NOTE+="
✅ Advanced users recommended

⚠️ Always backup your data before flashing
Follow the flash guide for proper installation"
    fi
    
    print_colored $GREEN "✅ Tags and notes built successfully"
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

# Function to get short hash (first 8 characters)
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
}

# Function to generate file names
generate_file_name() {
    local file_counter=$1
    local ext=$2
    local filename=$(basename "${FILES[$((file_counter-1))]}")

    case $file_counter in
        1)
            # ROM Package - keep original naming structure
            BASE_RENAME="${PROJECT_NAME// /_}_${DEVICE_NAME}_${RELEASE_DATE}"
            ;;
        2)
            # BOOT Image - include KSU info if enabled
            if [ "$KSU_NEXT_SUSFS" = "true" ]; then
                BASE_RENAME="boot_${RELEASE_DATE}_KSU-NEXT_SUSFS"
            else
                BASE_RENAME="boot_${RELEASE_DATE}"
            fi
            ;;
        3)
            # DTBO Image - explicit name
            BASE_RENAME="dtbo_${RELEASE_DATE}"
            ;;
        4)
            # VENDOR_BOOT Image - explicit name
            BASE_RENAME="vendor_boot_${RELEASE_DATE}"
            ;;
        *)
            # Other files - include original filename base + date
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
        PIXELDRAIN_RESPONSE=$(curl -s -u :$PIXELDRAIN_API_KEY -F "file=@$file_name" https://pixeldrain.com/api/file)
        PIXELDRAIN_ID=$(echo "$PIXELDRAIN_RESPONSE" | jq -r '.id // empty' 2>/dev/null)
        
        if [ -n "$PIXELDRAIN_ID" ] && [ "$PIXELDRAIN_ID" != "null" ]; then
            print_colored $GREEN "✅ Pixeldrain upload successful" >&2
            echo "https://pixeldrain.com/u/$PIXELDRAIN_ID"
        else
            print_colored $YELLOW "⚠️ Pixeldrain upload failed, using fallback" >&2
            echo "https://pixeldrain.com"
        fi
    else
        print_colored $YELLOW "⚠️ File too large for Pixeldrain (>5GB), skipping..." >&2
        echo "https://pixeldrain.com"
    fi
}

# Function to process files
process_files() {
    MAIN_URLS=()
    FILE_COUNTER=0
    FILES=("$@")  # Store original file paths
    
    print_colored $BLUE "Processing files..."
    
    for FILE in "$@"; do
        FILE_COUNTER=$((FILE_COUNTER + 1))
        
        if [ ! -f "$FILE" ]; then
            print_colored $RED "❌ File not found: $FILE"
            continue
        fi
        
        EXT="${FILE##*.}"
        NEW_NAME=$(generate_file_name $FILE_COUNTER $EXT)
        
        print_colored $PURPLE "Processing file $FILE_COUNTER: $(basename "$FILE")"
        
        # Copy file with new name
        cp "$FILE" "$NEW_NAME"
        
        # Get file information
        FILE_SIZE=$(stat -c%s "$NEW_NAME" 2>/dev/null || stat -f%z "$NEW_NAME" 2>/dev/null || echo "0")
        
        # Calculate hashes
        print_colored $CYAN "Calculating file hashes..." >&2
        MD5_HASH=$(calculate_file_hash "$NEW_NAME" "md5")
        SHA256_HASH=$(calculate_file_hash "$NEW_NAME" "sha256")
        
        # Get short hashes for display
        SHORT_MD5=$(get_short_hash "$MD5_HASH")
        SHORT_SHA256=$(get_short_hash "$SHA256_HASH")
        
        print_colored $GREEN "✅ Hash calculated: MD5=${SHORT_MD5}, SHA256=${SHORT_SHA256}" >&2
        
        # Upload files and capture URLs properly
        print_colored $CYAN "Uploading to Pixeldrain..." >&2
        PIXELDRAIN_URL=$(upload_to_pixeldrain "$NEW_NAME" "$FILE_SIZE")
        
        # Validate URLs
        if [[ ! "$PIXELDRAIN_URL" =~ ^https?:// ]]; then
            PIXELDRAIN_URL="https://pixeldrain.com"
        fi
        
        MAIN_URLS+=("$PIXELDRAIN_URL")
        
        # Add to telegram message with hash information
        DISPLAY_NAME=$(get_file_display_name $FILE_COUNTER)
        SIZE_DISPLAY=$(format_file_size $FILE_SIZE)
        
        # Build hash display string
        HASH_INFO=""
        if [ "$SHORT_MD5" != "N/A" ] && [ "$SHORT_SHA256" != "N/A" ]; then
            HASH_INFO=" | MD5: ${SHORT_MD5} | SHA: ${SHORT_SHA256}"
        elif [ "$SHORT_MD5" != "N/A" ]; then
            HASH_INFO=" | MD5: ${SHORT_MD5}"
        elif [ "$SHORT_SHA256" != "N/A" ]; then
            HASH_INFO=" | SHA: ${SHORT_SHA256}"
        fi
        
        TELEGRAM_MESSAGE+="
▫️ <b>${DISPLAY_NAME}</b> – ${SIZE_DISPLAY}${HASH_INFO}"
        
        # Clean up renamed file
        rm "$NEW_NAME"
        
        print_colored $GREEN "✅ File $FILE_COUNTER processed successfully"
    done
    
    TELEGRAM_MESSAGE+="

<b>Click the buttons below to download the files</b>"
    
    print_colored $GREEN "✅ All files processed successfully ($FILE_COUNTER files)"
}

# Function to create flash guide
create_flash_guide() {
    print_colored $BLUE "Creating flash guide..."
    
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
   fastboot flash vendor_boor vendor_boot.img
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
        FLASH_GUIDE_TEXT+="
• KernelSU Next with SUSFS is pre-installed
• Download KSU Next Manager from official channel
• No additional flashing required
• Enhanced root hiding capabilities
• Advanced detection bypass included
• SUSFS provides superior stealth mode"
    else
        FLASH_GUIDE_TEXT+="
• No root solution pre-installed
• You can flash KernelSU/Magisk separately if needed
• This is a clean build without modifications
• Root access requires separate installation"
    fi

    FLASH_GUIDE_TEXT+="

SUPPORT & COMMUNITY:
• Support Us: https://splendid-creponne-182b60.netlify.app
• Maintainer: @VOLD_NAMESPACE
• Report bugs with detailed logs
• Share your feedback and experience

USEFUL LINKS:
• Platform Tools: https://developer.android.com/tools/releases/platform-tools
• KSU Next: https://t.me/ksunext"

    FLASH_GUIDE_TEXT+="

⚖️ DISCLAIMER:
Flashing custom ROMs may void warranty and could potentially brick your device. 
The maintainer is not responsible for any damage caused by flashing this ROM.
Flash at your own risk and ensure you understand the process!"

    # Create Telegraph page
    print_colored $CYAN "Creating Telegraph page..."
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
    else
        print_colored $YELLOW "⚠️ Flash guide creation failed"
        FLASH_GUIDE_URL=""
    fi
}

# Function to build inline keyboard - Modified Layout
build_inline_keyboard() {
    print_colored $BLUE "Building inline keyboard..."
    
    # URLs for additional downloads
    KSU_NEXT_MANAGER_URL="https://t.me/ksunext/728"
    SUPPORT_GROUP_URL="https://t.me/pixel4seriesofficial"
    
    INLINE_KEYBOARD='{"inline_keyboard":['
    
    # First row: ROM | BOOT
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
    fi

    # Second row: DTBO | VENDOR_BOOT
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
    fi

    # Row 3: Flash Guide | Support Group
    INLINE_KEYBOARD+=",[{\"text\":\"Flash Guide\",\"url\":\"${FLASH_GUIDE_URL}\"},{\"text\":\"Support Group\",\"url\":\"${SUPPORT_GROUP_URL}\"}]"

    # Row 4: KernelSU Manager (only if enabled)
    if [ "$KSU_NEXT_SUSFS" = "true" ]; then
        INLINE_KEYBOARD+=",[{\"text\":\"KernelSU Next Manager\",\"url\":\"${KSU_NEXT_MANAGER_URL}\"}]"
    fi

    # Row 5: Support Our Work
    INLINE_KEYBOARD+=",[{\"text\":\"Support Our Work\",\"url\":\"https://donate-morph.netlify.app/\"}]"

    # Close keyboard structure
    INLINE_KEYBOARD+="]}"

    print_colored $GREEN "✅ Inline keyboard built successfully"

    # Debug: Show keyboard structure
    print_colored $YELLOW "Keyboard layout:"

    # Row 1: ROM | BOOT
    ROW1_CONTENT="   Row 1: "
    BUTTON_COUNT=0
    [ ${#MAIN_URLS[@]} -gt 0 ] && { ROW1_CONTENT+="ROM"; BUTTON_COUNT=$((BUTTON_COUNT+1)); }
    [ ${#MAIN_URLS[@]} -gt 1 ] && { [ $BUTTON_COUNT -gt 0 ] && ROW1_CONTENT+=" | "; ROW1_CONTENT+="BOOT"; }
    print_colored $WHITE "$ROW1_CONTENT"

    # Row 2: DTBO | VENDOR BOOT
    ROW2_CONTENT="   Row 2: "
    BUTTON_COUNT=0
    [ ${#MAIN_URLS[@]} -gt 2 ] && { ROW2_CONTENT+="DTBO"; BUTTON_COUNT=$((BUTTON_COUNT+1)); }
    [ ${#MAIN_URLS[@]} -gt 3 ] && { [ $BUTTON_COUNT -gt 0 ] && ROW2_CONTENT+=" | "; ROW2_CONTENT+="VENDOR BOOT"; }
    print_colored $WHITE "$ROW2_CONTENT"

    # Row 3: Flash Guide | Support Group
    print_colored $WHITE "   Row 3: Flash Guide | Support Group"

    # Row 4: KernelSU or Support
    if [ "$KSU_NEXT_SUSFS" = "true" ]; then
        print_colored $WHITE "   Row 4: KernelSU Next Manager"
        print_colored $WHITE "   Row 5: Support Our Work"
    else
        print_colored $WHITE "   Row 4: Support Our Work"
    fi
}

# Function to send message to Telegram
send_telegram_message() {
    print_colored $BLUE "Preparing to send message to Telegram..."
    
    # Create temporary file for message
    TEMP_MSG_FILE=$(mktemp)
    echo -n "$TELEGRAM_MESSAGE" > "$TEMP_MSG_FILE"
    
    # Show preview
    print_colored $YELLOW "Message Preview:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Project: $PROJECT_NAME"
    echo "Device: $DEVICE_NAME"
    echo "Files: $FILE_COUNTER"
    if [ "$KSU_NEXT_SUSFS" = "true" ]; then
        echo "Features: KSU Next + SUSFS"
    else
        echo "Features: Standard build"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Ask for confirmation
    echo ""
    while true; do
        read -p "$(print_colored $YELLOW "Send this message with banner to Telegram? (Y/N): ")" CONFIRM
        case $CONFIRM in
            [Yy]* ) 
                print_colored $GREEN "✅ Proceeding with upload..."
                break
                ;;
            [Nn]* ) 
                print_colored $RED "❌ Upload canceled by user"
                rm "$TEMP_MSG_FILE"
                exit 0
                ;;
            * ) 
                print_colored $RED "❌ Please answer Y or N"
                ;;
        esac
    done
    
    # Send message
    print_colored $CYAN "Sending message to Telegram..."
    
    if [ "$BANNER_MODE" == "url" ]; then
        RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
            -d chat_id="${CHAT_ID}" \
            --data-urlencode photo="$BANNER_FILE_URL" \
            --data-urlencode caption@"$TEMP_MSG_FILE" \
            --data-urlencode parse_mode="HTML" \
            --data-urlencode reply_markup="$INLINE_KEYBOARD")
    else
        RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
            -F chat_id="${CHAT_ID}" \
            -F photo=@"$BANNER_FILE" \
            -F caption=@"$TEMP_MSG_FILE" \
            -F parse_mode="HTML" \
            -F reply_markup="$INLINE_KEYBOARD")
    fi
    
    # Clean up
    rm "$TEMP_MSG_FILE"
    
    # Check response
    if echo "$RESPONSE" | grep -q '"ok":true'; then
        print_colored $GREEN "✅ Message sent successfully to Telegram!"
    else
        print_colored $RED "❌ Failed to send Telegram message"
        print_colored $YELLOW "Response: $RESPONSE"
    fi
}

# Function to log upload
log_upload() {
    print_colored $BLUE "Logging upload information..."
    
    {
        echo "=== Upload Log - $(date) ==="
        echo "Project: $PROJECT_NAME"
        echo "Device: $DEVICE_NAME"
        echo "Android Version: $ANDROID_VERSION"
        echo "Security Patch: $FORMATTED_PATCH"
        echo "KSU Next SUSFS: $KSU_NEXT_SUSFS"
        echo "Files uploaded: $FILE_COUNTER"
        echo "Tag: $TAG_NAME"
        echo "Telegram Response: $RESPONSE"
        if [ -n "$FLASH_GUIDE_URL" ]; then
            echo "Flash Guide: $FLASH_GUIDE_URL"
        fi
        echo "================================"
        echo ""
    } >> "$UPLOAD_LOG"
    
    print_colored $GREEN "✅ Upload logged to: $UPLOAD_LOG"
}

# Function to show final summary
show_summary() {
    echo ""
    print_colored $GREEN "╔════════════════════════════════════════════════════════════════╗"
    print_colored $GREEN "║                      UPLOAD COMPLETED.                                     ║"
    print_colored $GREEN "╚════════════════════════════════════════════════════════════════╝"
    print_colored $WHITE "Project: $PROJECT_NAME"
    print_colored $WHITE "Device: $DEVICE_NAME"
    print_colored $WHITE "Files: $FILE_COUNTER uploaded successfully"
    if [ "$KSU_NEXT_SUSFS" = "true" ]; then
        print_colored $WHITE "Features: KSU Next + SUSFS enabled"
    else
        print_colored $WHITE "Features: Standard build"
    fi
    print_colored $WHITE "Log: $UPLOAD_LOG"
    if [ -n "$FLASH_GUIDE_URL" ]; then
        print_colored $WHITE "Flash Guide: $FLASH_GUIDE_URL"
    fi
    print_colored $GREEN "✅ All tasks completed successfully!"
    echo ""
}

# Main execution
main() {
    print_banner
    validate_inputs "$@"
    
    # Process arguments
    BANNER_INPUT="$1"
    shift
    
    # Validate banner
    if [[ "$BANNER_INPUT" =~ ^https?:// ]]; then
        BANNER_MODE="url"
        BANNER_FILE_URL="$BANNER_INPUT"
        print_colored $BLUE "Banner: Using URL - $BANNER_FILE_URL"
    else
        if [ ! -f "$BANNER_INPUT" ]; then
            print_colored $RED "❌ Banner file not found: $BANNER_INPUT"
            exit 1
        fi
        BANNER_MODE="file"
        BANNER_FILE="$BANNER_INPUT"
        print_colored $BLUE "Banner: Using file - $BANNER_FILE"
    fi
    
    PROJECT_NAME="$1"
    shift
    RELEASE_DATE=$(date +"%d-%m-%Y")
    PROJECT_AUTHOR="@VOLD_NAMESPACE"
    UPLOAD_LOG="upload_log.txt"
    
    print_colored $BLUE "Project: $PROJECT_NAME"
    print_colored $BLUE "Release Date: $RELEASE_DATE"
    
    # Ask for KSU Next SUSFS configuration
    ask_ksu_next_susfs

    # Ask for GAPPS Varians configuration
    ask_gapps_variant
    
    # Detect device and build info
    detect_device_info "$1"
    extract_build_info
    build_tags_and_notes
    build_telegram_message
    
    # Process files
    process_files "$@"
    
    # Create flash guide
    create_flash_guide
    
    # Build keyboard and send message
    build_inline_keyboard
    send_telegram_message
    
    # Log and show summary
    log_upload
    show_summary
}

# Run main function with all arguments
main "$@"
