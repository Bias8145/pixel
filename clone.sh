#!/bin/bash

# Terminal Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
BLUE="\033[0;34m"
WHITE="\033[1;37m"
RESET="\033[0m"

# Border Styles
BORDER="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SUB_BORDER="────────────────────────────────────────────────────"

trap "echo; echo -e '${RED}[ERROR] Process cancelled by user${RESET}'; exit 1" INT

# Validate required tools
for cmd in git curl patch python3 pip3; do
  if ! command -v $cmd &>/dev/null; then
    echo -e "${RED}[ERROR] Required tool '$cmd' is missing. Please install it first.${RESET}"
    exit 1
  fi
done

# Install Python dependencies if not already installed
pip3 install python-telegram-bot python-dotenv --quiet || {
  echo -e "${RED}[ERROR] Failed to install python-telegram-bot or python-dotenv${RESET}"
  exit 1
}

# Load environment variables
if [ -f ".env" ]; then
  export $(grep -v '^#' .env | xargs)
fi
if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
  echo -e "${RED}[ERROR] BOT_TOKEN and CHAT_ID must be set in environment or .env file${RESET}"
  exit 1
}

# Function: Generate loading bar
generate_loading_bar() {
  local percent=$1
  local width=20
  local filled=$((percent / 5))
  local empty=$((width - filled))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="-"; done
  echo "[$bar]"
}

# Function: Detect ROM name
detect_rom() {
  if [ -f ".repo/manifest.xml" ]; then
    if grep -qi "lineageos" .repo/manifest.xml; then
      echo "LineageOS"
    elif grep -qi "aosp" .repo/manifest.xml; then
      echo "AOSP"
    else
      echo "Custom ROM"
    fi
  elif [ -f "build/envsetup.sh" ]; then
    echo "LineageOS"
  else
    echo "Custom ROM"
  fi
}

# Function: Validate repository and branch
validate_repo_branch() {
  local repo_url=$1
  local branch=$2
  echo -e "${BLUE}[INFO] Validating $repo_url (branch: ${branch:-default})${RESET}"
  
  if ! git ls-remote "$repo_url" &>/dev/null; then
    echo -e "${RED}[ERROR] Cannot access $repo_url. Check the connection or URL.${RESET}"
    return 1
  fi
  
  if [ -n "$branch" ]; then
    if ! git ls-remote --heads "$repo_url" | grep -q "refs/heads/$branch"; then
      echo -e "${RED}[ERROR] Branch '$branch' not found in $repo_url${RESET}"
      return 1
    fi
  fi
  return 0
}

# Function: Clone repo with validation
clone_repo() {
  local repo_url=$1
  local target_dir=$2
  local branch=$3
  local skip_clone=$4
  local device=$5
  local repo_count=$6
  local repo_index=$7
  local total_percent=$(( (repo_index - 1) * 100 / repo_count ))

  echo -e "${CYAN}${BORDER}${RESET}"
  echo -e "${WHITE} Repository: $target_dir${RESET}"
  echo -e "${BLUE}URL  : $repo_url${RESET}"
  echo -e "${BLUE}Branch: ${branch:-default (HEAD)}${RESET}"
  echo -e "${CYAN}${BORDER}${RESET}"

  if [ "$skip_clone" == "skip" ]; then
    echo -e "${YELLOW}[INFO] Skipping clone of $target_dir${RESET}"
    return 0
  fi

  # Check if directory already exists
  if [ -d "$target_dir/.git" ]; then
    echo -e "${YELLOW}[INFO] Directory $target_dir already exists. Validating...${RESET}"
    pushd "$target_dir" > /dev/null

    local current_url=$(git config --get remote.origin.url 2>/dev/null)
    local current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)

    echo -e "${BLUE}Check: Current URL    : $current_url${RESET}"
    echo -e "${BLUE}Check: Expected URL   : $repo_url${RESET}"
    echo -e "${BLUE}Check: Current Branch : $current_branch${RESET}"
    echo -e "${BLUE}Check: Expected Branch: ${branch:-<default>}${RESET}"

    if [[ "$current_url" == "$repo_url" && ( -z "$branch" || "$current_branch" == "$branch" ) ]]; then
      echo -e "${YELLOW}[INFO] Repository match. Skipping $target_dir${RESET}"
      popd > /dev/null
      return 0
    else
      echo -e "${YELLOW}[WARNING] Repository mismatch detected!${RESET}"
      echo -e "${BLUE}[ACTION] Deleting and re-cloning $target_dir${RESET}"
      popd > /dev/null
      rm -rf "$target_dir"
    fi
  fi

  # Validate repository and branch
  if ! validate_repo_branch "$repo_url" "$branch"; then
    return 1
  fi

  # Clone repository
  echo -e "${BLUE}[ACTION] Cloning to $target_dir...${RESET}"
  if [ -n "$branch" ]; then
    git clone -b "$branch" "$repo_url" "$target_dir" --progress 2>&1 | while IFS= read -r line; do
      echo "$line"
      if [[ "$line" =~ Receiving\ objects:\ +([0-9]+)% ]]; then
        percent=${BASH_REMATCH[1]}
        adjusted_percent=$((total_percent + (percent / repo_count)))
        bar=$(generate_loading_bar "$adjusted_percent")
        echo -e "${BLUE}[PROGRESS] $adjusted_percent% $bar Cloning $device${RESET}"
      fi
    done
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
      echo -e "${GREEN}[SUCCESS] Clone completed to $target_dir${RESET}"
    else
      echo -e "${RED}[ERROR] Failed to clone $repo_url (branch: $branch)${RESET}"
      return 1
    fi
  else
    git clone "$repo_url" "$target_dir" --progress 2>&1 | while IFS= read -r line; do
      echo "$line"
      if [[ "$line" =~ Receiving\ objects:\ +([0-9]+)% ]]; then
        percent=${BASH_REMATCH[1]}
        adjusted_percent=$((total_percent + (percent / repo_count)))
        bar=$(generate_loading_bar "$adjusted_percent")
        echo -e "${BLUE}[PROGRESS] $adjusted_percent% $bar Cloning $device${RESET}"
      fi
    done
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
      echo -e "${GREEN}[SUCCESS] Clone completed to $target_dir${RESET}"
    else
      echo -e "${RED}[ERROR] Failed to clone $repo_url${RESET}"
      return 1
    fi
  fi
  echo -e "${CYAN}${SUB_BORDER}${RESET}"
  echo
}

# Function: Build device
build_device() {
  local device=$1
  echo -e "${CYAN}${BORDER}${RESET}"
  echo -e "${WHITE} === Building for $device ===${RESET}"
  echo -e "${CYAN}${BORDER}${RESET}"
  source build/envsetup.sh || { echo -e "${RED}[ERROR] Failed to source build/envsetup.sh${RESET}"; return 1; }
  breakfast "$device" || { echo -e "${RED}[ERROR] Failed to run breakfast $device${RESET}"; return 1; }
  mka bacon 2>&1 | while IFS= read -r line; do
    echo "$line"
    if [[ "$line" =~ \[\ +([0-9]+)% ]]; then
      percent=${BASH_REMATCH[1]}
      bar=$(generate_loading_bar "$percent")
      echo -e "${BLUE}[PROGRESS] $percent% $bar Building $device${RESET}"
    fi
  done
  if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo -e "${GREEN}[SUCCESS] Build completed for $device${RESET}"
  else
    echo -e "${RED}[ERROR] Build failed for $device${RESET}"
    return 1
  fi
  echo -e "${CYAN}${SUB_BORDER}${RESET}"
  echo
}

# Function: Setup KernelSU-Next + SUSFS for redbull
setup_kernelsu_susfs_redbull() {
  set -e

  echo -e "${CYAN}${BORDER}${RESET}"
  echo -e "${WHITE} Setup: KernelSU-Next + SUSFS for Redbull Kernel${RESET}"
  echo -e "${CYAN}${BORDER}${RESET}"

  echo -e "${BLUE}[ACTION] [1/9] Entering directory kernel/google/redbull${RESET}"
  cd kernel/google/redbull || { echo -e "${RED}[ERROR] Directory not found!${RESET}"; exit 1; }

  echo -e "${BLUE}[ACTION] [2/9] Downloading KernelSU-Next v1.0.3${RESET}"
  curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next/kernel/setup.sh" | bash -s v1.0.3

  echo -e "${BLUE}[ACTION] [3/9] Entering KernelSU-Next${RESET}"
  cd KernelSU-Next

  echo -e "${BLUE}[ACTION] [4/9] Downloading SUSFS patch v1.5.3${RESET}"
  curl -o 0001-Kernel-Implement-SUSFS-v1.5.3.patch https://github.com/sidex15/KernelSU-Next/commit/1e750de25930e875612bbec0410de0088474c00b.patch
  if [ ! -s 0001-Kernel-Implement-SUSFS-v1.5.3.patch ]; then
    echo -e "${RED}[ERROR] Failed to download SUSFS patch${RESET}"
    exit 1
  fi

  echo -e "${BLUE}[ACTION] [5/9] Applying SUSFS patch to KernelSU-Next${RESET}"
  patch -p1 < 0001-Kernel-Implement-SUSFS-v1.5.3.patch

  echo -e "${BLUE}[ACTION] [6/9] Returning to redbull kernel root${RESET}"
  cd ..

  echo -e "${BLUE}[ACTION] [7/9] Cloning SUSFS for kernel 4.19${RESET}"
  git clone https://gitlab.com/simonpunk/susfs4ksu.git -b kernel-4.19

  echo -e "${BLUE}[ACTION] [8/9] Copying fs/ and include/linux/ files${RESET}"
  cp -v susfs4ksu/kernel_patches/fs/* fs/
  cp -v susfs4ksu/kernel_patches/include/linux/* include/linux/

  echo -e "${BLUE}[ACTION] [9/9] Applying 50_add_susfs_in_kernel-4.19.patch${RESET}"
  cp -v susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch .
  patch -p1 < 50_add_susfs_in_kernel-4.19.patch

  echo -e "${GREEN}[SUCCESS] KernelSU-Next + SUSFS has been successfully applied${RESET}"
  echo -e "${CYAN}${SUB_BORDER}${RESET}"
  echo
}

# Function: Clone Bramble
clone_bramble() {
  local repo_configs=$1
  local vendor_branch=$2
  local susfs_enabled=$3
  local device=$4

  echo -e "${CYAN}${BORDER}${RESET}"
  echo -e "${WHITE} === Cloning for Bramble (Pixel 4a 5G) ===${RESET}"
  echo -e "${CYAN}${BORDER}${RESET}"

  local components=(
    "device/google/bramble:https://github.com/Bias8145/android_device_google_bramble.git:https://github.com/LineageOS/android_device_google_bramble.git"
    "device/google/redbull:https://github.com/Bias8145/android_device_google_redbull.git:https://github.com/LineageOS/android_device_google_redbull.git"
    "device/google/gs-common:https://github.com/Bias8145/android_device_google_gs-common.git:https://github.com/LineageOS/android_device_google_gs-common.git"
    "vendor/google/bramble:https://github.com/TheMuppets/proprietary_vendor_google_bramble.git:https://github.com/TheMuppets/proprietary_vendor_google_bramble.git"
  )

  IFS=',' read -r -a repo_array <<< "$repo_configs"
  for i in "${!components[@]}"; do
    IFS=':' read -r path custom_repo official_repo <<< "${components[i]}"
    IFS=':' read -r repo_type branch <<< "${repo_array[i]:-custom:$vendor_branch}"
    
    local repo_url
    if [ "$repo_type" == "custom" ]; then
      repo_url="$custom_repo"
    else
      repo_url="$official_repo"
    fi

    echo -e "${BLUE}[INFO] Selected repository: $repo_url${RESET}"
    echo -e "${BLUE}[INFO] Selected branch: $branch${RESET}"
    clone_repo "$repo_url" "$path" "$branch" "clone" "$device" "${#components[@]}" "$((i+1))"
  done

  if [ "$susfs_enabled" == "y" ]; then
    setup_kernelsu_susfs_redbull
  else
    echo -e "${YELLOW}[INFO] SUSFS patch was not applied${RESET}"
  fi
}

# Function: Clone Coral
clone_coral() {
  local repo_configs=$1
  local vendor_branch=$2
  local device=$3

  echo -e "${CYAN}${BORDER}${RESET}"
  echo -e "${WHITE} === Cloning for Coral (Pixel 4 XL) ===${RESET}"
  echo -e "${CYAN}${BORDER}${RESET}"

  local components=(
    "device/google/coral:https://github.com/Bias8145/android_device_google_coral.git:https://github.com/LineageOS/android_device_google_coral.git"
    "device/google/gs-common:https://github.com/Bias8145/android_device_google_gs-common.git:https://github.com/LineageOS/android_device_google_gs-common.git"
    "kernel/google/msm-4.14:https://github.com/Bias8145/android_kernel_google_msm-4.14.git:https://github.com/LineageOS/android_kernel_google_msm-4.14.git"
    "vendor/google/coral:https://github.com/TheMuppets/proprietary_vendor_google_coral.git:https://github.com/TheMuppets/proprietary_vendor_google_coral.git"
  )

  IFS=',' read -r -a repo_array <<< "$repo_configs"
  for i in "${!components[@]}"; do
    IFS=':' read -r path custom_repo official_repo <<< "${components[i]}"
    IFS=':' read -r repo_type branch <<< "${repo_array[i]:-custom:$vendor_branch}"
    
    local repo_url
    if [ "$repo_type" == "custom" ]; then
      repo_url="$custom_repo"
    else
      repo_url="$official_repo"
    fi

    echo -e "${BLUE}[INFO] Selected repository: $repo_url${RESET}"
    echo -e "${BLUE}[INFO] Selected branch: $branch${RESET}"
    clone_repo "$repo_url" "$path" "$branch" "clone" "$device" "${#components[@]}" "$((i+1))"
  done
}

# Function: Clone Flame
clone_flame() {
  local repo_configs=$1
  local vendor_branch=$2
  local device=$3

  echo -e "${CYAN}${BORDER}${RESET}"
  echo -e "${WHITE} === Cloning for Flame (Pixel 4) ===${RESET}"
  echo -e "${CYAN}${BORDER}${RESET}"

  local components=(
    "device/google/coral:https://github.com/Bias8145/android_device_google_coral.git:https://github.com/LineageOS/android_device_google_coral.git"
    "device/google/gs-common:https://github.com/Bias8145/android_device_google_gs-common.git:https://github.com/LineageOS/android_device_google_gs-common.git"
    "kernel/google/msm-4.14:https://github.com/Bias8145/android_kernel_google_msm-4.14.git:https://github.com/LineageOS/android_kernel_google_msm-4.14.git"
    "vendor/google/flame:https://github.com/TheMuppets/proprietary_vendor_google_flame.git:https://github.com/TheMuppets/proprietary_vendor_google_flame.git"
  )

  IFS=',' read -r -a repo_array <<< "$repo_configs"
  for i in "${!components[@]}"; do
    IFS=':' read -r path custom_repo official_repo <<< "${components[i]}"
    IFS=':' read -r repo_type branch <<< "${repo_array[i]:-custom:$vendor_branch}"
    
    local repo_url
    if [ "$repo_type" == "custom" ]; then
      repo_url="$custom_repo"
    else
      repo_url="$official_repo"
    fi

    echo -e "${BLUE}[INFO] Selected repository: $repo_url${RESET}"
    echo -e "${BLUE}[INFO] Selected branch: $branch${RESET}"
    clone_repo "$repo_url" "$path" "$branch" "clone" "$device" "${#components[@]}" "$((i+1))"
  done
}

# Function: Clone Sunfish
clone_sunfish() {
  local repo_configs=$1
  local vendor_branch=$2
  local device=$3

  echo -e "${CYAN}${BORDER}${RESET}"
  echo -e "${WHITE} === Cloning for Sunfish (Pixel 4a) ===${RESET}"
  echo -e "${CYAN}${BORDER}${RESET}"

  local components=(
    "device/google/sunfish:https://github.com/Bias8145/android_device_google_sunfish.git:https://github.com/LineageOS/android_device_google_sunfish.git"
    "device/google/gs-common:https://github.com/Bias8145/android_device_google_gs-common.git:https://github.com/LineageOS/android_device_google_gs-common.git"
    "kernel/google/msm-4.14:https://github.com/Bias8145/android_kernel_google_msm-4.14.git:https://github.com/LineageOS/android_kernel_google_msm-4.14.git"
    "vendor/google/sunfish:https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git:https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git"
  )

  IFS=',' read -r -a repo_array <<< "$repo_configs"
  for i in "${!components[@]}"; do
    IFS=':' read -r path custom_repo official_repo <<< "${components[i]}"
    IFS=':' read -r repo_type branch <<< "${repo_array[i]:-custom:$vendor_branch}"
    
    local repo_url
    if [ "$repo_type" == "custom" ]; then
      repo_url="$custom_repo"
    else
      repo_url="$official_repo"
    fi

    echo -e "${BLUE}[INFO] Selected repository: $repo_url${RESET}"
    echo -e "${BLUE}[INFO] Selected branch: $branch${RESET}"
    clone_repo "$repo_url" "$path" "$branch" "clone" "$device" "${#components[@]}" "$((i+1))"
  done
}

# Function: Start Telegram bot
start_telegram_bot() {
  local device=$1
  local repo_configs=$2
  local vendor_branch=$3
  local susfs_enabled=$4
  local build_enabled=$5
  local log_file=$6

  # Run Python bot in background
  python3 - <<EOF > "$log_file" 2>&1 &
import subprocess
import re
import telegram
from telegram.ext import Application, CommandHandler
import asyncio
import os
import random

# Load environment variables
from dotenv import load_dotenv
load_dotenv()
TOKEN = os.getenv("BOT_TOKEN")
CHAT_ID = os.getenv("CHAT_ID")

if not TOKEN or not CHAT_ID:
    raise ValueError("BOT_TOKEN and CHAT_ID must be set")

# Allowed user IDs
ALLOWED_USERS = [int(CHAT_ID)]

# Random creative messages
CLONE_MESSAGES = [
    "Cooking for {}... 🔄",
    "Brewing {} magic... 🔄",
    "Crafting {} masterpiece... 🔄",
    "Assembling {} awesomeness... 🔄",
    "Forging {} epic build... 🔄"
]
BUILD_MESSAGES = [
    "Baking {} ROM... 🔄",
    "Building {} brilliance... 🔄",
    "Compiling {} perfection... 🔄",
    "Constructing {} power... 🔄",
    "Sculpting {} excellence... 🔄"
]

async def main():
    app = Application.builder().token(TOKEN).build()
    
    # Simulate command handler
    class Update:
        def __init__(self):
            self.effective_user = User()
            self.effective_chat = Chat()

    class User:
        id = int(CHAT_ID)

    class Chat:
        id = int(CHAT_ID)

    update = Update()
    context = type('Context', (), {'args': ['$device', '$repo_configs', '$vendor_branch', '$susfs_enabled', '$build_enabled'], 'bot': app.bot})()

    async def clone(update, context):
        user_id = update.effective_user.id
        chat_id = update.effective_chat.id

        if user_id not in ALLOWED_USERS:
            await context.bot.send_message(chat_id=chat_id, text="[ERROR] Unauthorized user")
            return

        args = context.args
        device = args[0]
        if device not in ["bramble", "coral", "flame", "sunfish"]:
            await context.bot.send_message(chat_id=chat_id, text="[ERROR] Invalid device. Use: bramble, coral, flame, sunfish")
            return

        # Initialize message
        rom_name = "Custom ROM"
        message_content = f"=== {rom_name} Clone and Build Status ===\n\n{random.choice(CLONE_MESSAGES).format(device)}"
        message = await context.bot.send_message(chat_id=chat_id, text=message_content)
        message_id = message.message_id

        cmd = ['bash', '$0', device, args[1], args[2] if len(args) > 2 else "main", args[3] if len(args) > 3 else "n", args[4] if len(args) > 4 else "n"]
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

        last_progress = -10
        phase = "cloning"
        async def update_progress():
            nonlocal message_content, rom_name, last_progress, phase
            for line in process.stdout:
                line = line.strip()
                if line.startswith("[INFO] Detected ROM:"):
                    rom_name = line.split("Detected ROM: ")[1]
                    message_content = f"=== {rom_name} Clone and Build Status ===\n\n{message_content.split('\n\n')[1]}"
                    await context.bot.edit_message_text(chat_id=chat_id, message_id=message_id, text=message_content)
                elif "[PROGRESS]" in line and re.search(r"\b[0-9]+%", line):
                    match = re.search(r"\b([0-9]+)%", line)
                    if match:
                        percent = int(match.group(1))
                        if percent >= last_progress + 10:
                            bar = line.split(" ")[2]
                            if phase == "cloning":
                                message_content = f"=== {rom_name} Clone and Build Status ===\n\n{random.choice(CLONE_MESSAGES).format(device)}\n\n{percent}% {bar}"
                            else:
                                message_content = f"=== {rom_name} Clone and Build Status ===\n\n{random.choice(BUILD_MESSAGES).format(device)}\n\n{percent}% {bar}"
                            await context.bot.edit_message_text(chat_id=chat_id, message_id=message_id, text=message_content)
                            last_progress = percent
                elif "[SUCCESS] Build completed" in line:
                    phase = "building"
                    message_content = f"=== {rom_name} Clone and Build Status ===\n\n{random.choice(BUILD_MESSAGES).format(device)}\n\n0% [--------------------]"
                    await context.bot.edit_message_text(chat_id=chat_id, message_id=message_id, text=message_content)
                    last_progress = -10
                elif "[SUCCESS]" in line or "[ERROR]" in line:
                    message_content += f"\n\n{line}"
                    await context.bot.edit_message_text(chat_id=chat_id, message_id=message_id, text=message_content)
            process.wait()
            if process.returncode == 0:
                message_content += "\n\n[SUCCESS] Process completed successfully"
            else:
                message_content += "\n\n[ERROR] Process failed"
            await context.bot.edit_message_text(chat_id=chat_id, message_id=message_id, text=message_content)

        await update_progress()

    await clone(update, context)
    await app.run_polling()

if __name__ == "__main__":
    asyncio.run(main())
EOF
}

# Main execution
if [ $# -lt 2 ]; then
  echo -e "${RED}[ERROR] Usage: $0 <device> <repo_configs> [vendor_branch] [susfs_enabled] [build]${RESET}"
  echo -e "${BLUE}[INFO] Example: $0 bramble custom:main,official:lineage-20.0,custom:main,official:lineage-20.0 lineage-20.0 y y${RESET}"
  echo -e "${BLUE}[INFO] Devices: bramble, coral, flame, sunfish${RESET}"
  echo -e "${BLUE}[INFO] build: y to run build, n to skip (default: n)${RESET}"
  exit 1
fi

device=$1
repo_configs=$2
vendor_branch=${3:-main}
susfs_enabled=${4:-n}
build_enabled=${5:-n}
rom_name=$(detect_rom)

echo -e "${BLUE}[INFO] Detected ROM: $rom_name${RESET}"

# Start Telegram bot in background
log_file="/tmp/telegram_bot_$$.log"
start_telegram_bot "$device" "$repo_configs" "$vendor_branch" "$susfs_enabled" "$build_enabled" "$log_file"

# Wait briefly to ensure bot starts
sleep 2

case $device in
  bramble) clone_bramble "$repo_configs" "$vendor_branch" "$susfs_enabled" "$device" ;;
  coral) clone_coral "$repo_configs" "$vendor_branch" "$device" ;;
  flame) clone_flame "$repo_configs" "$vendor_branch" "$device" ;;
  sunfish) clone_sunfish "$repo_configs" "$vendor_branch" "$device" ;;
  *) echo -e "${RED}[ERROR] Invalid device: $device${RESET}" ; exit 1 ;;
esac

if [ "$build_enabled" == "y" ]; then
  build_device "$device"
fi

echo -e "${CYAN}${BORDER}${RESET}"
echo -e "${GREEN}[SUCCESS] All operations completed successfully${RESET}"
echo -e "${CYAN}${BORDER}${RESET}"
