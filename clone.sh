#!/bin/bash

# Terminal Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
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
  local branch=$3

  if [ -d "$target_dir/.git" ]; then
    echo "[INFO] Directory $target_dir already exists. Validating..."
    pushd "$target_dir" > /dev/null

    current_url=$(git config --get remote.origin.url 2>/dev/null)
    current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)

    echo "[CHECK] Current URL    : $current_url"
    echo "[CHECK] Expected URL   : $repo_url"
    echo "[CHECK] Current Branch : $current_branch"
    echo "[CHECK] Expected Branch: ${branch:-<default>}"

    if [[ "$current_url" == "$repo_url" && ( -z "$branch" || "$current_branch" == "$branch" ) ]]; then
      read -rp "Repository match. Skip or re-clone? (s = skip, r = re-clone) [s]: " action
      action=${action:-s}
      case "$action" in
        [Rr])
          echo "[ACTION] Re-cloning $target_dir ..."
          popd > /dev/null
          rm -rf "$target_dir"
          do_clone "$repo_url" "$target_dir" "$branch"
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
        do_clone "$repo_url" "$target_dir" "$branch"
      else
        echo "[SKIP] Skipping $target_dir"
        popd > /dev/null
      fi
    fi
  else
    do_clone "$repo_url" "$target_dir" "$branch"
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

# Clone functions per device
clone_bramble() {
  echo
  echo -e "🟢 Device: Bramble (Google Pixel 4a 5G)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  clone_repo https://github.com/Bias8145/android_device_google_bramble.git device/google/bramble
  clone_repo https://github.com/Bias8145/android_device_google_redbull.git device/google/redbull
  clone_repo https://github.com/LineageOS/android_device_google_gs-common.git device/google/gs-common
  clone_repo https://github.com/TheMuppets/proprietary_vendor_google_bramble.git vendor/google/bramble
  clone_repo https://github.com/Bias8145/android_kernel_google_redbull.git kernel/google/redbull susfs

  echo
  echo "=== Proceed with KernelSU-Next + SUSFS patch? ==="
  if ask_confirm "Run KernelSU-Next + SUSFS up setup for redbull kernel? (y/n): " "y"; then
    setup_kernelsu_susfs_redbull
  else
    echo "[SKIP] SUSFS patch was not applied."
  fi
}

clone_coral() {
  echo
  echo "🟢 Device: Coral (Google Pixel 4 XL)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  clone_repo https://github.com/Bias8145/android_device_google_coral.git device/google/coral aosp
  clone_repo https://github.com/LineageOS/android_device_google_gs-common.git device/google/gs-common
  clone_repo https://github.com/TheMuppets/proprietary_vendor_google_coral.git vendor/google/coral
  clone_repo https://github.com/Bias8145/android_kernel_google_msm-4.14.git kernel/google/msm-4.14 eclipse-Q2
}

clone_flame() {
  echo
  echo "🟢 Device: Flame (Google Pixel 4)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  clone_repo https://github.com/Bias8145/android_device_google_coral.git device/google/coral aosp
  clone_repo https://github.com/LineageOS/android_device_google_gs-common.git device/google/gs-common
  clone_repo https://github.com/TheMuppets/proprietary_vendor_google_flame.git vendor/google/flame
  clone_repo https://github.com/Bias8145/android_kernel_google_msm-4.14.git kernel/google/msm-4.14 eclipse-Q2
}

clone_sunfish() {
  echo
  echo "🟢 Device: Sunfish (Google Pixel 4a 4G)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  clone_repo https://github.com/Bias8145/android_device_google_sunfish.git device/google/sunfish
  clone_repo https://github.com/LineageOS/android_device_google_gs-common.git device/google/gs-common
  clone_repo https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git vendor/google/sunfish
  clone_repo https://github.com/Bias8145/android_kernel_google_msm-4.14.git kernel/google/msm-4.14 eclipse-Q2
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
