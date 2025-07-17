#!/bin/bash

Terminal Colors

GREEN="\033[0;32m" RED="\033[0;31m" YELLOW="\033[1;33m" CYAN="\033[0;36m" RESET="\033[0m"

trap "echo; echo '[ABORTED] Process cancelled by user'; exit 1" INT

Validate required tools

for cmd in git curl patch; do if ! command -v $cmd &>/dev/null; then echo -e "${RED}[ERROR] Required tool '$cmd' is missing. Please install it first.${RESET}" exit 1 fi done

echo echo -e "${YELLOW}=== Android Source Repo Cloner (Interactive) ===${RESET}" echo

Function: Select branch from repo

select_branch() { local repo_url=$1 echo "[INFO] Fetching branches from: $repo_url" mapfile -t branches < <(git ls-remote --heads "$repo_url" 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||')

if [[ ${#branches[@]} -eq 0 ]]; then echo -e "${RED}[✘] No branches found or failed to connect.${RESET}" return 1 fi

echo "Available branches:" select branch in "${branches[@]}"; do if [[ -n "$branch" ]]; then echo "$branch" return 0 fi done }

Function: Confirm yes/no

ask_confirm() { local prompt="$1" local default_answer="${2:-y}" local answer while true; do read -rp "$prompt " answer answer=${answer:-$default_answer} case "$answer" in [Yy]) return 0 ;; [Nn]) return 1 ;; *) echo "Please answer y or n." ;; esac done }

Function: Clone repo with validation

clone_repo() { local repo_url=$1 local target_dir=$2 local branch=$3

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" echo "Cloning to: $target_dir" echo "Repo: $repo_url" echo "Branch: ${branch:-default (HEAD)}" echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -d "$target_dir/.git" ]; then echo "[SKIP] Repo already exists at $target_dir" return fi

if [ -n "$branch" ]; then git clone -b "$branch" "$repo_url" "$target_dir" else git clone "$repo_url" "$target_dir" fi

if [ $? -ne 0 ]; then echo -e "${RED}[✘] Failed to clone $repo_url${RESET}" exit 1 fi }

Function: Ask user for repo choice and branch

choose_repo_and_branch() { local path=$1 local custom_repo=$2 local official_repo=$3

echo echo "Component: $path" echo "Choose source:" select opt in "Custom ($custom_repo)" "Official ($official_repo)"; do case $REPLY in 1) repo=$custom_repo; break ;; 2) repo=$official_repo; break ;; *) echo "Invalid choice." ;; esac done

branch=$(select_branch "$repo") || exit 1 clone_repo "$repo" "$path" "$branch" }

Function: Bramble

clone_bramble() { echo -e "${CYAN}==> Cloning for Bramble (Pixel 4a 5G)${RESET}" choose_repo_and_branch "device/google/bramble" 
"https://github.com/Bias8145/android_device_google_bramble.git" 
"https://github.com/LineageOS/android_device_google_bramble.git"

choose_repo_and_branch "device/google/redbull" 
"https://github.com/Bias8145/android_device_google_redbull.git" 
"https://github.com/LineageOS/android_device_google_redbull.git"

choose_repo_and_branch "device/google/gs-common" 
"https://github.com/Bias8145/android_device_google_gs-common.git" 
"https://github.com/LineageOS/android_device_google_gs-common.git"

echo echo "Cloning vendor tree (TheMuppets only)" vendor_branch=$(select_branch "https://github.com/TheMuppets/proprietary_vendor_google_bramble.git") || exit 1 clone_repo "https://github.com/TheMuppets/proprietary_vendor_google_bramble.git" "vendor/google/bramble" "$vendor_branch"

choose_repo_and_branch "kernel/google/redbull" 
"https://github.com/Bias8145/android_kernel_google_redbull.git" 
"https://github.com/LineageOS/android_kernel_google_redbull.git" }

Function: Coral

clone_coral() { echo -e "${CYAN}==> Cloning for Coral (Pixel 4 XL)${RESET}" choose_repo_and_branch "device/google/coral" 
"https://github.com/Bias8145/android_device_google_coral.git" 
"https://github.com/LineageOS/android_device_google_coral.git"

choose_repo_and_branch "device/google/gs-common" 
"https://github.com/Bias8145/android_device_google_gs-common.git" 
"https://github.com/LineageOS/android_device_google_gs-common.git"

echo echo "Cloning vendor tree (TheMuppets only)" vendor_branch=$(select_branch "https://github.com/TheMuppets/proprietary_vendor_google_coral.git") || exit 1 clone_repo "https://github.com/TheMuppets/proprietary_vendor_google_coral.git" "vendor/google/coral" "$vendor_branch"

choose_repo_and_branch "kernel/google/msm-4.14" 
"https://github.com/Bias8145/android_kernel_google_msm-4.14.git" 
"https://github.com/LineageOS/android_kernel_google_msm-4.14.git" }

Function: Flame

clone_flame() { echo -e "${CYAN}==> Cloning for Flame (Pixel 4)${RESET}" clone_coral  # Share same tree with Coral echo "[INFO] Flame uses Coral tree as device base." }

Function: Sunfish

clone_sunfish() { echo -e "${CYAN}==> Cloning for Sunfish (Pixel 4a)${RESET}" choose_repo_and_branch "device/google/sunfish" 
"https://github.com/Bias8145/android_device_google_sunfish.git" 
"https://github.com/LineageOS/android_device_google_sunfish.git"

choose_repo_and_branch "device/google/gs-common" 
"https://github.com/Bias8145/android_device_google_gs-common.git" 
"https://github.com/LineageOS/android_device_google_gs-common.git"

echo echo "Cloning vendor tree (TheMuppets only)" vendor_branch=$(select_branch "https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git") || exit 1 clone_repo "https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git" "vendor/google/sunfish" "$vendor_branch"

choose_repo_and_branch "kernel/google/msm-4.14" 
"https://github.com/Bias8145/android_kernel_google_msm-4.14.git" 
"https://github.com/LineageOS/android_kernel_google_msm-4.14.git" }

Main menu

echo "Select device to clone:" echo "1) Bramble (Pixel 4a 5G)" echo "2) Coral   (Pixel 4 XL)" echo "3) Flame   (Pixel 4)" echo "4) Sunfish (Pixel 4a)" echo "5) Cancel"

read -rp "Enter your choice [1-5]: " choice

case $choice in

1. clone_bramble ;;


2. clone_coral   ;;


3. clone_flame   ;;


4. clone_sunfish ;; *) echo "${YELLOW}[EXIT] No device selected.${RESET}" ; exit 0 ;; esac



echo -e "\n${GREEN}[✔] All operations completed.${RESET}"
