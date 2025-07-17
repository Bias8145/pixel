#!/bin/bash

# Terminal Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
MAGENTA="\033[0;35m"
RESET="\033[0m"

# Trap Ctrl+C to abort gracefully
trap "echo -e '\n${RED}[ABORTED] Process cancelled by user${RESET}'; exit 1" INT

# Banner
echo -e "\n${YELLOW}=== Android Source Repo Cloner ===${RESET}\n"

# Validate required tools
for cmd in git curl patch; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}[ERROR] Required tool '$cmd' is missing. Please install it first.${RESET}"
        exit 1
    fi
done

# Function for y/n confirmation
ask_confirm() {
    local prompt="$1"
    local default_answer="${2:-y}"
    local answer
    read -rp "$prompt" answer
    answer=${answer:-$default_answer}
    case "${answer,,}" in
        y) return 0 ;;
        n) return 1 ;;
        *) echo -e "${RED}Invalid answer. Please enter 'y' or 'n'.${RESET}"; return 1 ;;
    esac
}

# Function to list available branches
list_branches() {
    local repo_url=$1
    echo -e "${CYAN}[INFO] Fetching branches from $repo_url...${RESET}"
    local branches=$(git ls-remote --heads "$repo_url" 2>/dev/null | sed 's/.*refs/heads\///' | sort)
    if [ -z "$branches" ]; then
        echo -e "${RED}[ERROR] Could not fetch branches from $repo_url${RESET}"
        return 1
    fi
    echo -e "${MAGENTA}┌─────────────────── Available Branches ───────────────────┐${RESET}"
    local i=1
    declare -g branch_array=()
    while IFS= read -r branch; do
        printf "${MAGENTA}│${RESET} %-2d. %-45s ${MAGENTA}│${RESET}\n" "$i" "$branch"
        branch_array+=("$branch")
        ((i++))
    done <<< "$branches"
    echo -e "${MAGENTA}└─────────────────────────────────────────────────────────┘${RESET}"
    return 0
}

# Function to select branch interactively
select_branch() {
    local repo_url=$1
    local default_branch=$2
    local selected_branch=""
    echo -e "\n${YELLOW}=== Branch Selection for $repo_url ===${RESET}"
    if ask_confirm "Select a specific branch? (y/n) [n]: " "n"; then
        if list_branches "$repo_url"; then
            echo -e "${CYAN}Options:${RESET}"
            echo "0) Use default branch (HEAD)"
            [ -n "$default_branch" ] && echo "d) Use script default: $default_branch"
            while true; do
                read -rp "Enter choice (0, d, or branch number): " choice
                case "$choice" in
                    0)
                        selected_branch=""
                        echo -e "${GREEN}[SELECTED] Default branch (HEAD)${RESET}"
                        break
                        ;;
                    [Dd])
                        if [ -n "$default_branch" ]; then
                            selected_branch="$default_branch"
                            echo -e "${GREEN}[SELECTED] Script default: $default_branch${RESET}"
                            break
                        else
                            echo -e "${RED}No script default branch available${RESET}"
                        fi
                        ;;
                    [1-9]*)
                        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#branch_array[@]}" ]; then
                            selected_branch="${branch_array[$((choice-1))]}"
                            echo -e "${GREEN}[SELECTED] Branch: $selected_branch${RESET}"
                            break
                        else
                            echo -e "${RED}Invalid choice. Enter a number between 0 and ${#branch_array[@]}$([ -n "$default_branch" ] && echo ", or 'd'")${RESET}"
                        fi
                        ;;
                    *)
                        echo -e "${RED}Invalid choice. Enter a number between 0 and ${#branch_array[@]}$([ -n "$default_branch" ] && echo ", or 'd'")${RESET}"
                        ;;
                esac
            done
        else
            selected_branch="$default_branch"
            echo -e "${YELLOW}[WARNING] Could not fetch branches, using default: ${selected_branch:-HEAD}${RESET}"
        fi
    else
        selected_branch="$default_branch"
        echo -e "${GREEN}[SELECTED] Using ${selected_branch:-default branch}${RESET}"
    fi
    echo "$selected_branch"
}

# Function to perform cloning
do_clone() {
    local repo_url=$1
    local target_dir=$2
    local branch=$3
    echo -e "\n${BLUE}Cloning $repo_url to $target_dir (Branch: ${branch:-HEAD})...${RESET}"
    if ! git ls-remote "$repo_url" &>/dev/null; then
        echo -e "${RED}[ERROR] Cannot access $repo_url. Check URL or connection.${RESET}"
        exit 1
    fi
    if [ -n "$branch" ]; then
        git clone -b "$branch" "$repo_url" "$target_dir"
    else
        git clone "$repo_url" "$target_dir"
    fi
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[SUCCESS] Cloned to $target_dir${RESET}"
    else
        echo -e "${RED}[ERROR] Failed to clone $repo_url${RESET}"
        exit 1
    fi
}

# Function to validate and clone repository
clone_repo() {
    local repo_url=$1
    local target_dir=$2
    local default_branch=$3
    local selected_branch=$(select_branch "$repo_url" "$default_branch")
    if [ -d "$target_dir/.git" ]; then
        echo -e "${CYAN}[INFO] Directory $target_dir exists. Checking...${RESET}"
        pushd "$target_dir" >/dev/null
        local current_url=$(git config --get remote.origin.url)
        local current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "HEAD")
        popd >/dev/null
        if [[ "$current_url" == "$repo_url" && ( -z "$selected_branch" || "$current_branch" == "$selected_branch" ) ]]; then
            if ask_confirm "Repository matches. Skip or re-clone? (s/r) [s]: " "s"; then
                echo -e "${CYAN}[SKIP] $target_dir already up to date${RESET}"
                return
            fi
            rm -rf "$target_dir"
        else
            echo -e "${YELLOW}[WARNING] Repository or branch mismatch in $target_dir${RESET}"
            if ask_confirm "Delete and re-clone $target_dir? (y/n) [n]: " "n"; then
                rm -rf "$target_dir"
            else
                echo -e "${CYAN}[SKIP] Keeping existing $target_dir${RESET}"
                return
            fi
        fi
    fi
    do_clone "$repo_url" "$target_dir" "$selected_branch"
}

# KernelSU-Next + SUSFS patch for redbull
setup_kernelsu_susfs_redbull() {
    set -e
    echo -e "\n${YELLOW}=== Applying KernelSU-Next + SUSFS for Redbull ===${RESET}"
    mkdir -p kernel/google/redbull
    cd kernel/google/redbull || { echo -e "${RED}[ERROR] Directory not found${RESET}"; exit 1; }
    echo -e "${CYAN}[1/6] Downloading KernelSU-Next v1.0.3${RESET}"
    curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next/kernel/setup.sh" | bash -s v1.0.3
    cd KernelSU-Next
    echo -e "${CYAN}[2/6] Downloading SUSFS patch v1.5.3${RESET}"
    curl -o susfs.patch https://github.com/sidex15/KernelSU-Next/commit/1e750de25930e875612bbec0410de0088474c00b.patch
    if [ ! -s susfs.patch ]; then
        echo -e "${RED}[ERROR] Failed to download SUSFS patch${RESET}"
        exit 1
    fi
    echo -e "${CYAN}[3/6] Applying SUSFS patch${RESET}"
    patch -p1 < susfs.patch
    cd ..
    echo -e "${CYAN}[4/6] Cloning SUSFS for kernel 4.19${RESET}"
    git clone -b kernel-4.19 https://gitlab.com/simonpunk/susfs4ksu.git
    echo -e "${CYAN}[5/6] Copying SUSFS files${RESET}"
    cp -rv susfs4ksu/kernel_patches/fs/* fs/
    cp -rv susfs4ksu/kernel_patches/include/linux/* include/linux/
    echo -e "${CYAN}[6/6] Applying SUSFS kernel patch${RESET}"
    cp -v susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch .
    patch -p1 < 50_add_susfs_in_kernel-4.19.patch
    echo -e "${GREEN}[SUCCESS] KernelSU-Next + SUSFS applied${RESET}"
}

# Function to select repository
select_repo() {
    local component_name=$1
    local custom_repo=$2
    local custom_branch=$3
    local official_repo=$4
    local official_branch=$5
    echo -e "\n${CYAN}=== $component_name Repository Selection ===${RESET}"
    echo -e "${YELLOW}1) Custom: ${custom_repo}${RESET}"
    [ -n "$custom_branch" ] && echo -e "${BLUE}   Default Branch: $custom_branch${RESET}"
    echo -e "${YELLOW}2) Official: ${official_repo}${RESET}"
    [ -n "$official_branch" ] && echo -e "${BLUE}   Default Branch: $official_branch${RESET}"
    while true; do
        read -rp "Select repository (1 or 2): " choice
        case "$choice" in
            1) echo -e "${GREEN}[SELECTED] Custom: ${custom_repo}${RESET}"; echo "${custom_repo}|${custom_branch}"; return 0 ;;
            2) echo -e "${GREEN}[SELECTED] Official: ${official_repo}${RESET}"; echo "${official_repo}|${official_branch}"; return 0 ;;
            *) echo -e "${RED}Invalid choice. Enter 1 or 2.${RESET}" ;;
        esac
    done
}

# Clone functions per device
clone_bramble() {
    echo -e "\n${GREEN}=== Cloning for Bramble (Pixel 4a 5G) ===${RESET}"
    local bramble_repo=$(select_repo "Device Bramble" \
        "https://github.com/Bias8145/android_device_google_bramble.git" "" \
        "https://github.com/LineageOS/android_device_google_bramble.git" "")
    IFS='|' read -r bramble_url bramble_branch <<< "$bramble_repo"
    local redbull_repo=$(select_repo "Device Redbull" \
        "https://github.com/Bias8145/android_device_google_redbull.git" "" \
        "https://github.com/LineageOS/android_device_google_redbull.git" "")
    IFS='|' read -r redbull_url redbull_branch <<< "$redbull_repo"
    local gs_common_url="https://github.com/LineageOS/android_device_google_gs-common.git"
    local gs_common_branch=""
    local vendor_repo=$(select_repo "Vendor Bramble" \
        "https://github.com/Bias8145/proprietary_vendor_google_bramble.git" "" \
        "https://github.com/TheMuppets/proprietary_vendor_google_bramble.git" "")
    IFS='|' read -r vendor_url vendor_branch <<< "$vendor_repo"
    local kernel_repo=$(select_repo "Kernel Redbull" \
        "https://github.com/Bias8145/android_kernel_google_redbull.git" "susfs" \
        "https://github.com/LineageOS/android_kernel_google_redbull.git" "")
    IFS='|' read -r kernel_url kernel_branch <<< "$kernel_repo"
    clone_repo "$bramble_url" device/google/bramble "$bramble_branch"
    clone_repo "$redbull_url" device/google/redbull "$redbull_branch"
    clone_repo "$gs_common_url" device/google/gs-common "$gs_common_branch"
    clone_repo "$vendor_url" vendor/google/bramble "$vendor_branch"
    clone_repo "$kernel_url" kernel/google/redbull "$kernel_branch"
    setup_kernelsu_susfs_redbull
}

clone_coral() {
    echo -e "\n${GREEN}=== Cloning for Coral (Pixel 4 XL) ===${RESET}"
    local coral_repo=$(select_repo "Device Coral" \
        "https://github.com/Bias8145/android_device_google_coral.git" "aosp" \
        "https://github.com/LineageOS/android_device_google_coral.git" "")
    IFS='|' read -r coral_url coral_branch <<< "$coral_repo"
    local gs_common_url="https://github.com/LineageOS/android_device_google_gs-common.git"
    local gs_common_branch=""
    local vendor_repo=$(select_repo "Vendor Coral" \
        "https://github.com/Bias8145/proprietary_vendor_google_coral.git" "" \
        "https://github.com/TheMuppets/proprietary_vendor_google_coral.git" "")
    IFS='|' read -r vendor_url vendor_branch <<< "$vendor_repo"
    local kernel_repo=$(select_repo "Kernel MSM-4.14" \
        "https://github.com/Bias8145/android_kernel_google_msm-4.14.git" "eclipse-Q2" \
        "https://github.com/LineageOS/android_kernel_google_msm-4.14.git" "")
    IFS='|' read -r kernel_url kernel_branch <<< "$kernel_repo"
    clone_repo "$coral_url" device/google/coral "$coral_branch"
    clone_repo "$gs_common_url" device/google/gs-common "$gs_common_branch"
    clone_repo "$vendor_url" vendor/google/coral "$vendor_branch"
    clone_repo "$kernel_url" kernel/google/msm-4.14 "$kernel_branch"
}

clone_flame() {
    echo -e "\n${GREEN}=== Cloning for Flame (Pixel 4) ===${RESET}"
    local coral_repo=$(select_repo "Device Coral (shared)" \
        "https://github.com/Bias8145/android_device_google_coral.git" "aosp" \
        "https://github.com/LineageOS/android_device_google_coral.git" "")
    IFS='|' read -r coral_url coral_branch <<< "$coral_repo"
    local gs_common_url="https://github.com/LineageOS/android_device_google_gs-common.git"
    local gs_common_branch=""
    local vendor_repo=$(select_repo "Vendor Flame" \
        "https://github.com/Bias8145/proprietary_vendor_google_flame.git" "" \
        "https://github.com/TheMuppets/proprietary_vendor_google_flame.git" "")
    IFS='|' read -r vendor_url vendor_branch <<< "$vendor_repo"
    local kernel_repo=$(select_repo "Kernel MSM-4.14" \
        "https://github.com/Bias8145/android_kernel_google_msm-4.14.git" "eclipse-Q2" \
        "https://github.com/LineageOS/android_kernel_google_msm-4.14.git" "")
    IFS='|' read -r kernel_url kernel_branch <<< "$kernel_repo"
    clone_repo "$coral_url" device/google/coral "$coral_branch"
    clone_repo "$gs_common_url" device/google/gs-common "$gs_common_branch"
    clone_repo "$vendor_url" vendor/google/flame "$vendor_branch"
    clone_repo "$kernel_url" kernel/google/msm-4.14 "$kernel_branch"
}

clone_sunfish() {
    echo -e "\n${GREEN}=== Cloning for Sunfish (Pixel 4a 4G) ===${RESET}"
    local sunfish_repo=$(select_repo "Device Sunfish" \
        "https://github.com/Bias8145/android_device_google_sunfish.git" "" \
        "https://github.com/LineageOS/android_device_google_sunfish.git" "")
    IFS='|' read -r sunfish_url sunfish_branch <<< "$sunfish_repo"
    local gs_common_url="https://github.com/LineageOS/android_device_google_gs-common.git"
    local gs_common_branch=""
    local vendor_repo=$(select_repo "Vendor Sunfish" \
        "https://github.com/Bias8145/proprietary_vendor_google_sunfish.git" "" \
        "https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git" "")
    IFS='|' read -r vendor_url vendor_branch <<< "$vendor_repo"
    local kernel_repo=$(select_repo "Kernel MSM-4.14" \
        "https://github.com/Bias8145/android_kernel_google_msm-4.14.git" "eclipse-Q2" \
        "https://github.com/LineageOS/android_kernel_google_msm-4.14.git" "")
    IFS='|' read -r kernel_url kernel_branch <<< "$kernel_repo"
    clone_repo "$sunfish_url" device/google/sunfish "$sunfish_branch"
    clone_repo "$gs_common_url" device/google/gs-common "$gs_common_branch"
    clone_repo "$vendor_url" vendor/google/sunfish "$vendor_branch"
    clone_repo "$kernel_url" kernel/google/msm-4.14 "$kernel_branch"
}

# Interactive menu
echo -e "${CYAN}┌────────────────── Device Selection ──────────────────┐${RESET}"
echo -e "${CYAN}│${RESET} ${YELLOW}1) Bramble${RESET} - Google Pixel 4a 5G                  ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET} ${YELLOW}2) Coral${RESET}   - Google Pixel 4 XL                  ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET} ${YELLOW}3) Flame${RESET}   - Google Pixel 4                     ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET} ${YELLOW}4) Sunfish${RESET} - Google Pixel 4a 4G                 ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET} ${RED}5) Cancel${RESET}                                    ${CYAN}│${RESET}"
echo -e "${CYAN}└─────────────────────────────────────────────────────┘${RESET}"
read -rp "Enter your choice (1-5): " choice
echo

case "$choice" in
    1) echo -e "${GREEN}[SELECTED] Bramble${RESET}"; clone_bramble ;;
    2) echo -e "${GREEN}[SELECTED] Coral${RESET}"; clone_coral ;;
    3) echo -e "${GREEN}[SELECTED] Flame${RESET}"; clone_flame ;;
    4) echo -e "${GREEN}[SELECTED] Sunfish${RESET}"; clone_sunfish ;;
    *) echo -e "${RED}[CANCELLED] No repositories processed${RESET}"; exit 0 ;;
esac

echo -e "\n${GREEN}=== All operations completed ===${RESET}"
