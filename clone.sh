#!/bin/bash

# Terminal Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
RESET="\033[0m"

trap "echo; echo '[ABORTED] Process cancelled by user'; exit 1" INT

# Validate required tools
for cmd in git curl patch; do
  if ! command -v $cmd &>/dev/null; then
    echo -e "${RED}[ERROR] Required tool '$cmd' is missing. Please install it first.${RESET}"
    exit 1
  fi
done

echo
echo -e "${YELLOW}=== Android Source Repo Cloner (Interactive) ===${RESET}"
echo

# Function: Confirm yes/no
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
      *) echo "Please answer y or n." ;;
    esac
  done
}

# Function: Select branch from repo
select_branch() {
  local repo_url=$1
  echo "[INFO] Fetching branches from: $repo_url"
  
  # Get branches and store in array
  local branches=()
  while IFS= read -r line; do
    branches+=("$line")
  done < <(git ls-remote --heads "$repo_url" 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||')

  if [[ ${#branches[@]} -eq 0 ]]; then
    echo -e "${RED}[✘] No branches found or failed to connect.${RESET}"
    return 1
  fi

  echo "Available branches:"
  local PS3="Select branch: "
  select branch in "${branches[@]}"; do
    if [[ -n "$branch" ]]; then
      selected_branch="$branch"
      return 0
    else
      echo "Invalid selection. Please try again."
    fi
  done
}

# Function: Clone repo with validation
clone_repo() {
  local repo_url=$1
  local target_dir=$2
  local branch=$3

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Cloning to: $target_dir"
  echo "Repo: $repo_url"
  echo "Branch: ${branch:-default (HEAD)}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Check if directory already exists
  if [ -d "$target_dir/.git" ]; then
    echo "[INFO] Directory $target_dir already exists. Validating..."
    pushd "$target_dir" > /dev/null

    local current_url=$(git config --get remote.origin.url 2>/dev/null)
    local current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)

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
          ;;
        *)
          echo "[SKIP] Skipping $target_dir"
          popd > /dev/null
          return 0
          ;;
      esac
    else
      echo -e "${YELLOW}[WARNING] Repository mismatch detected!${RESET}"
      if ask_confirm "Delete and re-clone $target_dir? (y/n): " "n"; then
        popd > /dev/null
        rm -rf "$target_dir"
      else
        echo "[SKIP] Skipping $target_dir"
        popd > /dev/null
        return 0
      fi
    fi
  fi

  # Validate repository access
  if ! git ls-remote "$repo_url" &> /dev/null; then
    echo -e "${RED}[✘] Cannot access $repo_url. Check the connection or URL.${RESET}"
    exit 1
  fi

  # Clone repository
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
  echo
}

# Function: Ask user for repo choice and branch
choose_repo_and_branch() {
  local path=$1
  local custom_repo=$2
  local official_repo=$3

  echo
  echo "Component: $path"
  echo "Choose source:"
  select opt in "Custom ($custom_repo)" "Official ($official_repo)"; do
    case $REPLY in
      1) repo=$custom_repo; break ;;
      2) repo=$official_repo; break ;;
      *) echo "Invalid choice." ;;
    esac
  done

  # Select branch
  select_branch "$repo" || exit 1
  
  # Clone with selected branch
  clone_repo "$repo" "$path" "$selected_branch"
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

# Function: Bramble
clone_bramble() {
  echo -e "${CYAN}==> Cloning for Bramble (Pixel 4a 5G)${RESET}"
  
  choose_repo_and_branch "device/google/bramble" \
    "https://github.com/Bias8145/android_device_google_bramble.git" \
    "https://github.com/LineageOS/android_device_google_bramble.git"

  choose_repo_and_branch "device/google/redbull" \
    "https://github.com/Bias8145/android_device_google_redbull.git" \
    "https://github.com/LineageOS/android_device_google_redbull.git"

  choose_repo_and_branch "device/google/gs-common" \
    "https://github.com/Bias8145/android_device_google_gs-common.git" \
    "https://github.com/LineageOS/android_device_google_gs-common.git"

  echo
  echo "Cloning vendor tree (TheMuppets only)"
  select_branch "https://github.com/TheMuppets/proprietary_vendor_google_bramble.git" || exit 1
  clone_repo "https://github.com/TheMuppets/proprietary_vendor_google_bramble.git" "vendor/google/bramble" "$selected_branch"

  choose_repo_and_branch "kernel/google/redbull" \
    "https://github.com/Bias8145/android_kernel_google_redbull.git" \
    "https://github.com/LineageOS/android_kernel_google_redbull.git"

  echo
  echo "=== Proceed with KernelSU-Next + SUSFS patch? ==="
  if ask_confirm "Run KernelSU-Next + SUSFS setup for redbull kernel? (y/n): " "y"; then
    setup_kernelsu_susfs_redbull
  else
    echo "[SKIP] SUSFS patch was not applied."
  fi
}

# Function: Coral
clone_coral() {
  echo -e "${CYAN}==> Cloning for Coral (Pixel 4 XL)${RESET}"
  
  choose_repo_and_branch "device/google/coral" \
    "https://github.com/Bias8145/android_device_google_coral.git" \
    "https://github.com/LineageOS/android_device_google_coral.git"

  choose_repo_and_branch "device/google/gs-common" \
    "https://github.com/Bias8145/android_device_google_gs-common.git" \
    "https://github.com/LineageOS/android_device_google_gs-common.git"

  echo
  echo "Cloning vendor tree (TheMuppets only)"
  select_branch "https://github.com/TheMuppets/proprietary_vendor_google_coral.git" || exit 1
  clone_repo "https://github.com/TheMuppets/proprietary_vendor_google_coral.git" "vendor/google/coral" "$selected_branch"

  choose_repo_and_branch "kernel/google/msm-4.14" \
    "https://github.com/Bias8145/android_kernel_google_msm-4.14.git" \
    "https://github.com/LineageOS/android_kernel_google_msm-4.14.git"
}

# Function: Flame
clone_flame() {
  echo -e "${CYAN}==> Cloning for Flame (Pixel 4)${RESET}"
  
  choose_repo_and_branch "device/google/coral" \
    "https://github.com/Bias8145/android_device_google_coral.git" \
    "https://github.com/LineageOS/android_device_google_coral.git"

  choose_repo_and_branch "device/google/gs-common" \
    "https://github.com/Bias8145/android_device_google_gs-common.git" \
    "https://github.com/LineageOS/android_device_google_gs-common.git"

  echo
  echo "Cloning vendor tree (TheMuppets only)"
  select_branch "https://github.com/TheMuppets/proprietary_vendor_google_flame.git" || exit 1
  clone_repo "https://github.com/TheMuppets/proprietary_vendor_google_flame.git" "vendor/google/flame" "$selected_branch"

  choose_repo_and_branch "kernel/google/msm-4.14" \
    "https://github.com/Bias8145/android_kernel_google_msm-4.14.git" \
    "https://github.com/LineageOS/android_kernel_google_msm-4.14.git"
}

# Function: Sunfish
clone_sunfish() {
  echo -e "${CYAN}==> Cloning for Sunfish (Pixel 4a)${RESET}"
  
  choose_repo_and_branch "device/google/sunfish" \
    "https://github.com/Bias8145/android_device_google_sunfish.git" \
    "https://github.com/LineageOS/android_device_google_sunfish.git"

  choose_repo_and_branch "device/google/gs-common" \
    "https://github.com/Bias8145/android_device_google_gs-common.git" \
    "https://github.com/LineageOS/android_device_google_gs-common.git"

  echo
  echo "Cloning vendor tree (TheMuppets only)"
  select_branch "https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git" || exit 1
  clone_repo "https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git" "vendor/google/sunfish" "$selected_branch"

  choose_repo_and_branch "kernel/google/msm-4.14" \
    "https://github.com/Bias8145/android_kernel_google_msm-4.14.git" \
    "https://github.com/LineageOS/android_kernel_google_msm-4.14.git"
}

# Main menu
echo "Select device to clone:"
echo "1) Bramble (Pixel 4a 5G)"
echo "2) Coral   (Pixel 4 XL)"
echo "3) Flame   (Pixel 4)"
echo "4) Sunfish (Pixel 4a)"
echo "5) Cancel"

read -rp "Enter your choice [1-5]: " choice

case $choice in
  1) clone_bramble ;;
  2) clone_coral ;;
  3) clone_flame ;;
  4) clone_sunfish ;;
  *) echo -e "${YELLOW}[EXIT] No device selected.${RESET}" ; exit 0 ;;
esac

echo -e "\n${GREEN}[✔] All operations completed.${RESET}"
