#!/bin/bash

# Terminal Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
RESET="\033[0m"

trap "echo; echo '[ABORTED] Process cancelled by user'; exit 1" INT

echo
echo -e "${YELLOW}=== Android Source Repo Cloner (Multi-Device) ===${RESET}"
echo

# Validate required tools
for cmd in git curl patch; do
  if ! command -v $cmd &>/dev/null; then
    echo -e "${RED}[ERROR] Required tool '$cmd' is missing. Please install it first.${RESET}"
    exit 1
  fi
done

# Function for y/n confirmation
ask_confirm() {
  local prompt="$1"
  local default_answer="${2:-y}"
  local answer

  while true; do
    read -rp "$prompt " answer
    answer=${answer:-$default_answer}
    case "$answer" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      *) echo "Invalid answer. Please enter 'y' or 'n'." ;;
    esac
  done
}

# Function to list available branches
list_branches() {
  local repo_url=$1
  echo -e "${CYAN}[INFO] Fetching available branches from repository...${RESET}"
  
  # Get remote branches, clean up output
  local branches=$(git ls-remote --heads "$repo_url" 2>/dev/null | sed 's/.*refs\/heads\///' | sort)
  
  if [ -z "$branches" ]; then
    echo -e "${RED}[ERROR] Could not fetch branches from $repo_url${RESET}"
    return 1
  fi
  
  echo -e "${BLUE}Available branches:${RESET}"
  local i=1
  declare -g branch_array=()
  
  while IFS= read -r branch; do
    echo "$i) $branch"
    branch_array+=("$branch")
    ((i++))
  done <<< "$branches"
  
  return 0
}

# Function to select branch interactively
select_branch() {
  local repo_url=$1
  local default_branch=$2
  local selected_branch=""
  
  echo
  echo -e "${YELLOW}=== Branch Selection ===${RESET}"
  echo "Repository: $repo_url"
  echo "Default branch: ${default_branch:-<HEAD>}"
  echo
  
  if ask_confirm "Do you want to select a specific branch? (y/n) [n]: " "n"; then
    if list_branches "$repo_url"; then
      echo
      echo "0) Use default branch (HEAD)"
      echo "d) Use default branch suggested by script: ${default_branch:-<none>}"
      echo
      
      while true; do
        read -rp "Enter your choice (0, d, or branch number): " choice
        
        case "$choice" in
          0)
            selected_branch=""
            echo "[SELECTED] Default branch (HEAD)"
            break
            ;;
          [Dd])
            selected_branch="$default_branch"
            echo "[SELECTED] Script default: $default_branch"
            break
            ;;
          [1-9]*)
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#branch_array[@]}" ]; then
              selected_branch="${branch_array[$((choice-1))]}"
              echo "[SELECTED] Branch: $selected_branch"
              break
            else
              echo -e "${RED}Invalid choice. Please enter a number between 0 and ${#branch_array[@]}, or 'd'${RESET}"
            fi
            ;;
          *)
            echo -e "${RED}Invalid choice. Please enter a number between 0 and ${#branch_array[@]}, or 'd'${RESET}"
            ;;
        esac
      done
    else
      echo -e "${YELLOW}[WARNING] Could not fetch branches, using default branch${RESET}"
      selected_branch="$default_branch"
    fi
  else
    selected_branch="$default_branch"
    echo "[SELECTED] Using ${selected_branch:-default branch}"
  fi
  
  echo "$selected_branch"
}

# Function to perform cloning
do_clone() {
  local repo_url=$1
  local target_dir=$2
  local branch=$3

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "[CLONE INFO]"
  echo "➤ Target Directory : $target_dir"
  echo "➤ Repository URL   : $repo_url"
  echo "➤ Branch           : ${branch:-default (HEAD)}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if ! git ls-remote "$repo_url" &> /dev/null; then
    echo -e "${RED}[✘] Cannot access $repo_url. Check the connection or URL.${RESET}"
    exit 1
  fi

  if [ -n "$branch" ]; then
    git clone -b "$branch" "$repo_url" "$target_dir"
  else
    git clone "$repo_url" "$target_dir"
  fi

  if [ $? -eq 0 ]; then
    echo -e "${GREEN}[✔] Clone completed to $target_dir${RESET}"
  else
    echo -e "${RED}[✘] Failed to clone from $repo_url${RESET}"
    exit 1
  fi
}

# Function to validate before cloning
clone_repo() {
  local repo_url=$1
  local target_dir=$2
  local default_branch=$3
  
  # Select branch interactively
  local selected_branch=$(select_branch "$repo_url" "$default_branch")

  if [ -d "$target_dir/.git" ]; then
    echo "[INFO] Directory $target_dir already exists. Validating..."
    pushd "$target_dir" > /dev/null

    current_url=$(git config --get remote.origin.url 2>/dev/null)
    current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)

    echo "[CHECK] Current URL    : $current_url"
    echo "[CHECK] Expected URL   : $repo_url"
    echo "[CHECK] Current Branch : $current_branch"
    echo "[CHECK] Expected Branch: ${selected_branch:-<default>}"

    if [[ "$current_url" == "$repo_url" && ( -z "$selected_branch" || "$current_branch" == "$selected_branch" ) ]]; then
      read -rp "Repository match. Skip or re-clone? (s = skip, r = re-clone) [s]: " action
      action=${action:-s}
      case "$action" in
        [Rr])
          echo "[ACTION] Re-cloning $target_dir ..."
          popd > /dev/null
          rm -rf "$target_dir"
          do_clone "$repo_url" "$target_dir" "$selected_branch"
          ;;
        *)
          echo "[SKIP] Skipping $target_dir"
          popd > /dev/null
          ;;
      esac
    else
      echo -e "${YELLOW}[WARNING] Repository mismatch detected!${RESET}"
      if ask_confirm "Delete and re-clone $target_dir? (y/n): " "n"; then
        popd > /dev/null
        rm -rf "$target_dir"
        do_clone "$repo_url" "$target_dir" "$selected_branch"
      else
        echo "[SKIP] Skipping $target_dir"
        popd > /dev/null
      fi
    fi
  else
    do_clone "$repo_url" "$target_dir" "$selected_branch"
  fi

  echo
}

# KernelSU-Next + SUSFS patch for redbull
setup_kernelsu_susfs_redbull() {
  set -e

  echo
  echo -e "${YELLOW}=== Setting up KernelSU-Next + SUSFS for Redbull Kernel ===${RESET}"

  echo ">>> [1/9] Entering directory kernel/google/redbull"
  cd kernel/google/redbull || { echo -e "${RED}Directory not found!${RESET}"; exit 1; }

  echo ">>> [2/9] Downloading KernelSU-Next v1.0.3"
  curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next/kernel/setup.sh" | bash -s v1.0.3

  echo ">>> [3/9] Entering KernelSU-Next"
  cd KernelSU-Next

  echo ">>> [4/9] Downloading SUSFS patch v1.5.3"
  curl -o 0001-Kernel-Implement-SUSFS-v1.5.3.patch https://github.com/sidex15/KernelSU-Next/commit/1e750de25930e875612bbec0410de0088474c00b.patch
  if [ ! -s 0001-Kernel-Implement-SUSFS-v1.5.3.patch ]; then
    echo -e "${RED}[✘] Failed to download SUSFS patch${RESET}"
    exit 1
  fi

  echo ">>> [5/9] Applying SUSFS patch to KernelSU-Next"
  patch -p1 < 0001-Kernel-Implement-SUSFS-v1.5.3.patch

  echo ">>> [6/9] Returning to redbull kernel root"
  cd ..

  echo ">>> [7/9] Cloning SUSFS for kernel 4.19"
  git clone https://gitlab.com/simonpunk/susfs4ksu.git -b kernel-4.19

  echo ">>> [8/9] Copying fs/ and include/linux/ files"
  cp -v susfs4ksu/kernel_patches/fs/* fs/
  cp -v susfs4ksu/kernel_patches/include/linux/* include/linux/

  echo ">>> [9/9] Applying 50_add_susfs_in_kernel-4.19.patch"
  cp -v susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch .
  patch -p1 < 50_add_susfs_in_kernel-4.19.patch

  echo -e "${GREEN}>>> ✅ Done! KernelSU-Next + SUSFS has been successfully applied.${RESET}"
  echo
}

# Function to select repository for each component
select_repo() {
  local component_name=$1
  local custom_repo=$2
  local custom_branch=$3
  local official_repo=$4
  local official_branch=$5
  
  echo
  echo -e "${CYAN}=== $component_name Repository Selection ===${RESET}"
  echo "1) Custom  : $custom_repo"
  echo "2) Official: $official_repo"
  echo
  
  while true; do
    read -rp "Select repository for $component_name (1-2): " choice
    case "$choice" in
      1)
        echo "[SELECTED] Custom: $custom_repo"
        echo "$custom_repo|$custom_branch"
        return 0
        ;;
      2)
        echo "[SELECTED] Official: $official_repo"
        echo "$official_repo|$official_branch"
        return 0
        ;;
      *)
        echo -e "${RED}Invalid choice. Please enter 1 or 2.${RESET}"
        ;;
    esac
  done
}

# Clone functions per device
clone_bramble() {
  echo
  echo -e "🟢 Device: Bramble (Google Pixel 4a 5G)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # Device Bramble
  local bramble_repo=$(select_repo "Device Bramble" \
    "https://github.com/Bias8145/android_device_google_bramble.git" "" \
    "https://github.com/LineageOS/android_device_google_bramble.git" "")
  IFS='|' read -r bramble_url bramble_branch <<< "$bramble_repo"
  
  # Device Redbull
  local redbull_repo=$(select_repo "Device Redbull" \
    "https://github.com/Bias8145/android_device_google_redbull.git" "" \
    "https://github.com/LineageOS/android_device_google_redbull.git" "")
  IFS='|' read -r redbull_url redbull_branch <<< "$redbull_repo"
  
  # GS Common (always LineageOS)
  echo
  echo -e "${CYAN}=== Device GS-Common Repository ===${RESET}"
  echo "Using LineageOS (standard for all devices)"
  
  # Vendor Bramble
  local vendor_repo=$(select_repo "Vendor Bramble" \
    "https://github.com/Bias8145/proprietary_vendor_google_bramble.git" "" \
    "https://github.com/TheMuppets/proprietary_vendor_google_bramble.git" "")
  IFS='|' read -r vendor_url vendor_branch <<< "$vendor_repo"
  
  # Kernel Redbull
  local kernel_repo=$(select_repo "Kernel Redbull" \
    "https://github.com/Bias8145/android_kernel_google_redbull.git" "susfs" \
    "https://github.com/LineageOS/android_kernel_google_redbull.git" "")
  IFS='|' read -r kernel_url kernel_branch <<< "$kernel_repo"
  
  echo
  echo -e "${YELLOW}=== Starting Clone Process ===${RESET}"
  
  # Execute cloning
  clone_repo "$bramble_url" device/google/bramble "$bramble_branch"
  clone_repo "$redbull_url" device/google/redbull "$redbull_branch"
  clone_repo https://github.com/LineageOS/android_device_google_gs-common.git device/google/gs-common
  clone_repo "$vendor_url" vendor/google/bramble "$vendor_branch"
  clone_repo "$kernel_url" kernel/google/redbull "$kernel_branch"
}

clone_coral() {
  echo
  echo "🟢 Device: Coral (Google Pixel 4 XL)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # Device Coral
  local coral_repo=$(select_repo "Device Coral" \
    "https://github.com/Bias8145/android_device_google_coral.git" "aosp" \
    "https://github.com/LineageOS/android_device_google_coral.git" "")
  IFS='|' read -r coral_url coral_branch <<< "$coral_repo"
  
  # GS Common (always LineageOS)
  echo
  echo -e "${CYAN}=== Device GS-Common Repository ===${RESET}"
  echo "Using LineageOS (standard for all devices)"
  
  # Vendor Coral
  local vendor_repo=$(select_repo "Vendor Coral" \
    "https://github.com/Bias8145/proprietary_vendor_google_coral.git" "" \
    "https://github.com/TheMuppets/proprietary_vendor_google_coral.git" "")
  IFS='|' read -r vendor_url vendor_branch <<< "$vendor_repo"
  
  # Kernel MSM-4.14
  local kernel_repo=$(select_repo "Kernel MSM-4.14" \
    "https://github.com/Bias8145/android_kernel_google_msm-4.14.git" "eclipse-Q2" \
    "https://github.com/LineageOS/android_kernel_google_msm-4.14.git" "")
  IFS='|' read -r kernel_url kernel_branch <<< "$kernel_repo"
  
  echo
  echo -e "${YELLOW}=== Starting Clone Process ===${RESET}"
  
  # Execute cloning
  clone_repo "$coral_url" device/google/coral "$coral_branch"
  clone_repo https://github.com/LineageOS/android_device_google_gs-common.git device/google/gs-common
  clone_repo "$vendor_url" vendor/google/coral "$vendor_branch"
  clone_repo "$kernel_url" kernel/google/msm-4.14 "$kernel_branch"
}

clone_flame() {
  echo
  echo "🟢 Device: Flame (Google Pixel 4)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # Device Coral (shared with Flame)
  local coral_repo=$(select_repo "Device Coral (shared)" \
    "https://github.com/Bias8145/android_device_google_coral.git" "aosp" \
    "https://github.com/LineageOS/android_device_google_coral.git" "")
  IFS='|' read -r coral_url coral_branch <<< "$coral_repo"
  
  # GS Common (always LineageOS)
  echo
  echo -e "${CYAN}=== Device GS-Common Repository ===${RESET}"
  echo "Using LineageOS (standard for all devices)"
  
  # Vendor Flame
  local vendor_repo=$(select_repo "Vendor Flame" \
    "https://github.com/Bias8145/proprietary_vendor_google_flame.git" "" \
    "https://github.com/TheMuppets/proprietary_vendor_google_flame.git" "")
  IFS='|' read -r vendor_url vendor_branch <<< "$vendor_repo"
  
  # Kernel MSM-4.14
  local kernel_repo=$(select_repo "Kernel MSM-4.14" \
    "https://github.com/Bias8145/android_kernel_google_msm-4.14.git" "eclipse-Q2" \
    "https://github.com/LineageOS/android_kernel_google_msm-4.14.git" "")
  IFS='|' read -r kernel_url kernel_branch <<< "$kernel_repo"
  
  echo
  echo -e "${YELLOW}=== Starting Clone Process ===${RESET}"
  
  # Execute cloning
  clone_repo "$coral_url" device/google/coral "$coral_branch"
  clone_repo https://github.com/LineageOS/android_device_google_gs-common.git device/google/gs-common
  clone_repo "$vendor_url" vendor/google/flame "$vendor_branch"
  clone_repo "$kernel_url" kernel/google/msm-4.14 "$kernel_branch"
}

clone_sunfish() {
  echo
  echo "🟢 Device: Sunfish (Google Pixel 4a 4G)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # Device Sunfish
  local sunfish_repo=$(select_repo "Device Sunfish" \
    "https://github.com/Bias8145/android_device_google_sunfish.git" "" \
    "https://github.com/LineageOS/android_device_google_sunfish.git" "")
  IFS='|' read -r sunfish_url sunfish_branch <<< "$sunfish_repo"
  
  # GS Common (always LineageOS)
  echo
  echo -e "${CYAN}=== Device GS-Common Repository ===${RESET}"
  echo "Using LineageOS (standard for all devices)"
  
  # Vendor Sunfish
  local vendor_repo=$(select_repo "Vendor Sunfish" \
    "https://github.com/Bias8145/proprietary_vendor_google_sunfish.git" "" \
    "https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git" "")
  IFS='|' read -r vendor_url vendor_branch <<< "$vendor_repo"
  
  # Kernel MSM-4.14
  local kernel_repo=$(select_repo "Kernel MSM-4.14" \
    "https://github.com/Bias8145/android_kernel_google_msm-4.14.git" "eclipse-Q2" \
    "https://github.com/LineageOS/android_kernel_google_msm-4.14.git" "")
  IFS='|' read -r kernel_url kernel_branch <<< "$kernel_repo"
  
  echo
  echo -e "${YELLOW}=== Starting Clone Process ===${RESET}"
  
  # Execute cloning
  clone_repo "$sunfish_url" device/google/sunfish "$sunfish_branch"
  clone_repo https://github.com/LineageOS/android_device_google_gs-common.git device/google/gs-common
  clone_repo "$vendor_url" vendor/google/sunfish "$vendor_branch"
  clone_repo "$kernel_url" kernel/google/msm-4.14 "$kernel_branch"
}

# Interactive menu
echo "Select device to clone:"
echo "1) Bramble (Pixel 4a 5G)"
echo "2) Coral   (Pixel 4 XL)"
echo "3) Flame   (Pixel 4)"
echo "4) Sunfish (Pixel 4a 4G)"
echo "5) Cancel"

read -rp "Enter your choice (1-5): " choice
echo

case "$choice" in
  1) echo "[SELECTED] Bramble" ; clone_bramble ;;
  2) echo "[SELECTED] Coral"   ; clone_coral ;;
  3) echo "[SELECTED] Flame"   ; clone_flame ;;
  4) echo "[SELECTED] Sunfish" ; clone_sunfish ;;
  *) echo "[CANCELLED] No repo was processed." ;;
esac

echo -e "${GREEN}=== All operations completed ===${RESET}"
