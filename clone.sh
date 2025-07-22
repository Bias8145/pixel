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
for cmd in git; do
  if ! command -v $cmd &>/dev/null; then
    echo -e "${RED}[ERROR] Required tool '$cmd' is missing. Please install it first.${RESET}"
    exit 1
  fi
done

echo
echo -e "${CYAN}${BORDER}${RESET}"
echo -e "${WHITE} === Android Source Repo Cloner ===${RESET}"
echo -e "${CYAN}${BORDER}${RESET}"
echo

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

# Function: Clone Bramble
clone_bramble() {
  local repo_configs=$1
  local vendor_branch=$2
  local device=$3

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

# Main execution
if [ $# -lt 2 ]; then
  echo -e "${RED}[ERROR] Usage: $0 <device> <repo_configs> [vendor_branch]${RESET}"
  echo -e "${BLUE}[INFO] Example: $0 bramble custom:main,official:lineage-20.0,custom:main,official:lineage-20.0 lineage-20.0${RESET}"
  echo -e "${BLUE}[INFO] Devices: bramble, coral, flame, sunfish${RESET}"
  exit 1
fi

device=$1
repo_configs=$2
vendor_branch=${3:-main}
rom_name=$(detect_rom)

echo -e "${BLUE}[INFO] Detected ROM: $rom_name${RESET}"

case $device in
  bramble) clone_bramble "$repo_configs" "$vendor_branch" "$device" ;;
  coral) clone_coral "$repo_configs" "$vendor_branch" "$device" ;;
  flame) clone_flame "$repo_configs" "$vendor_branch" "$device" ;;
  sunfish) clone_sunfish "$repo_configs" "$vendor_branch" "$device" ;;
  *) echo -e "${RED}[ERROR] Invalid device: $device${RESET}" ; exit 1 ;;
esac

echo -e "${CYAN}${BORDER}${RESET}"
echo -e "${GREEN}[SUCCESS] All repositories cloned successfully${RESET}"
echo -e "${CYAN}${BORDER}${RESET}"
