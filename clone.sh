#!/bin/bash

# Android Source Repo Cloner
# Custom/Official source selection with live repository/branch validation.
# Official device/kernel sources use LineageOS; official vendor sources use TheMuppets.

set -o pipefail

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
BLUE="\033[0;34m"
BOLD="\033[1m"
RESET="\033[0m"
MAGENTA="\033[0;35m"

declare -A SELECTED_REPOS=()
declare -A SELECTED_BRANCHES=()
declare -A SELECTED_SOURCES=()
SELECTED_DEVICE=""
KERNELSU_OPTION=""
DRY_RUN="no"

trap 'echo; echo "[ABORTED] Process cancelled by user"; exit 1' INT

for cmd in git curl patch; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] Required tool '$cmd' is missing. Please install it first.${RESET}"
    exit 1
  fi
done

echo
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD} === Android Source Repo Cloner ===${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

show_header() {
  local device="$1" action="$2"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD} === $action for $device ===${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

ask_confirm() {
  local prompt="$1" default="${2:-y}" answer
  while true; do
    echo -e "\n${prompt}"
    echo "Options: [y]es, [n]o, [b]ack"
    read -rp "Your choice [$default]: " answer
    answer="${answer:-$default}"
    case "$answer" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      [Bb]) return 254 ;;
      *) echo -e "${YELLOW}Please answer y, n, or b.${RESET}" ;;
    esac
  done
}

select_menu() {
  local title="$1"; shift
  local options=("$@") choice
  while true; do
    echo -e "\n${CYAN}$title${RESET}"
    local i
    for i in "${!options[@]}"; do echo "$((i + 1))) ${options[$i]}"; done
    echo "b) Back"
    echo "q) Quit"
    read -rp "Enter your choice: " choice
    case "$choice" in
      [0-9]*)
        if (( choice >= 1 && choice <= ${#options[@]} )); then return $((choice - 1)); fi
        ;;
      [Bb]) return 254 ;;
      [Qq]) exit 0 ;;
    esac
    echo -e "${RED}Invalid selection.${RESET}"
  done
}

normalize_repo_url() {
  local url="$1"
  url="${url%.git}"
  url="${url%/}"
  echo "$url"
}

get_existing_repo_info() {
  local target_dir="$1" repo_url="" repo_branch=""
  if [[ -d "$target_dir/.git" ]]; then
    pushd "$target_dir" >/dev/null 2>&1 || return 1
    repo_url=$(git config --get remote.origin.url 2>/dev/null || echo "Unknown")
    repo_branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "Unknown")
    popd >/dev/null 2>&1 || true
  fi
  echo "$repo_url|$repo_branch"
}

check_existing_directory() {
  local target_dir="$1"
  [[ -d "$target_dir" ]] || return 1
  local info current_url current_branch
  info=$(get_existing_repo_info "$target_dir")
  current_url="${info%%|*}"
  current_branch="${info#*|}"
  echo -e "\n${YELLOW}[WARNING] Directory already exists: $target_dir${RESET}"
  echo -e "${MAGENTA}Existing Repository Info:${RESET}"
  echo -e "  └─ URL: ${CYAN}$current_url${RESET}"
  echo -e "  └─ Branch: ${CYAN}$current_branch${RESET}"
  [[ -d "$target_dir/.git" ]] || echo -e "  └─ ${RED}Not a Git repository${RESET}"
  return 0
}

validate_repo() {
  local repo_url="$1"
  [[ -n "$repo_url" ]] || { echo -e "${RED}[ERROR] Repository URL is empty.${RESET}"; return 1; }
  echo -e "${BLUE}[VALIDATE] Checking repository: $repo_url${RESET}"
  local heads
  heads=$(git ls-remote --heads "$repo_url" 2>/dev/null) || {
    echo -e "${RED}[ERROR] Repository is unreachable or inaccessible: $repo_url${RESET}"
    return 1
  }
  [[ -n "$heads" ]] || {
    echo -e "${RED}[ERROR] Repository has no visible branches: $repo_url${RESET}"
    return 1
  }
  local default_branch=""
  default_branch=$(git ls-remote --symref "$repo_url" HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')
  echo -e "${GREEN}[OK] Repository accessible.${RESET}"
  [[ -n "$default_branch" ]] && echo -e "  └─ Default branch: ${CYAN}$default_branch${RESET}"
  return 0
}

select_branch() {
  local repo_url="$1" component="$2" selected choice
  local -a branches=()
  echo -e "\n${BLUE}[INFO] Fetching branches from $repo_url${RESET}"
  mapfile -t branches < <(git ls-remote --heads "$repo_url" 2>/dev/null | awk '{print $2}' | sed 's#refs/heads/##' | sort -V)
  if (( ${#branches[@]} == 0 )); then
    echo -e "${RED}[ERROR] No branches found or repository is unreachable.${RESET}"
    return 1
  fi
  echo -e "\n${CYAN}Available branches for $component:${RESET}"
  local i
  for i in "${!branches[@]}"; do echo "$((i + 1))) ${branches[$i]}"; done
  echo "b) Back"
  while true; do
    read -rp "Select branch [1-${#branches[@]}, b]: " choice
    case "$choice" in
      [0-9]*)
        if (( choice >= 1 && choice <= ${#branches[@]} )); then
          selected="${branches[$((choice - 1))]}"
          if ! git ls-remote --exit-code --heads "$repo_url" "refs/heads/$selected" >/dev/null 2>&1; then
            echo -e "${RED}[ERROR] Branch '$selected' is no longer available. Refreshing...${RESET}"
            continue
          fi
          SELECTED_BRANCH="$selected"
          echo -e "${GREEN}[OK] Selected branch: $selected${RESET}"
          return 0
        fi
        ;;
      [Bb]) return 254 ;;
    esac
    echo -e "${RED}Invalid branch selection.${RESET}"
  done
}

validate_target_path() {
  local path="$1"
  [[ "$path" != /* ]] || { echo -e "${RED}[ERROR] Target path must be relative: $path${RESET}"; return 1; }
  [[ "$path" != *".."* ]] || { echo -e "${RED}[ERROR] Target path contains '..': $path${RESET}"; return 1; }
  [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo -e "${RED}[ERROR] Invalid target path: $path${RESET}"; return 1; }
}

validate_component_source() {
  local path="$1" source="$2" repo="$3"
  case "$path" in
    vendor/*)
      if [[ "$source" == "official" && "$repo" != *TheMuppets/* ]]; then
        echo -e "${RED}[ERROR] Official vendor repositories must come from TheMuppets.${RESET}"; return 1
      fi
      ;;
    device/*|kernel/*)
      if [[ "$source" == "official" && "$repo" != *LineageOS/* ]]; then
        echo -e "${RED}[ERROR] Official device/kernel repositories must come from LineageOS.${RESET}"; return 1
      fi
      ;;
  esac
  return 0
}

choose_repo_and_branch() {
  local path="$1" custom_repo="$2" official_repo="$3"
  local component="$(basename "$path")" repo_choice selected_repo source_label source_key rc
  validate_target_path "$path" || return 1

  while true; do
    show_header "$SELECTED_DEVICE" "Configuring $component"
    if check_existing_directory "$path"; then
      echo "1) Replace with a new repository"
      echo "2) Keep existing repository"
      echo "3) Back"
      read -rp "Your choice [1-3]: " rc
      case "$rc" in
        1) ;;
        2)
          local info current_url current_branch
          info=$(get_existing_repo_info "$path")
          current_url="${info%%|*}"; current_branch="${info#*|}"
          if [[ "$current_url" == "Unknown" || "$current_branch" == "Unknown" ]]; then
            echo -e "${RED}[ERROR] Cannot safely keep this directory.${RESET}"; continue
          fi
          SELECTED_REPOS["$path"]="$current_url"
          SELECTED_BRANCHES["$path"]="$current_branch"
          SELECTED_SOURCES["$path"]="existing"
          echo -e "${GREEN}[KEEP] $path${RESET}"
          return 0
          ;;
        3) return 254 ;;
        *) echo -e "${RED}Invalid choice.${RESET}"; continue ;;
      esac
    fi

    if [[ "$path" == vendor/* ]]; then
      source_label="Official / Custom (Official = TheMuppets)"
      select_menu "Choose source repository for $path:" \
        "Custom: $custom_repo" \
        "Official: $official_repo (TheMuppets)"
    else
      source_label="Official / Custom (Official = LineageOS)"
      select_menu "Choose source repository for $path:" \
        "Custom: $custom_repo" \
        "Official: $official_repo (LineageOS)"
    fi
    repo_choice=$?
    case "$repo_choice" in
      254) return 254 ;;
      0) selected_repo="$custom_repo"; source_key="custom" ;;
      1) selected_repo="$official_repo"; source_key="official" ;;
      *) return 1 ;;
    esac

    if ! validate_component_source "$path" "$source_key" "$selected_repo"; then continue; fi
    if ! validate_repo "$selected_repo"; then continue; fi
    select_branch "$selected_repo" "$component"
    rc=$?
    if (( rc == 254 )); then continue; fi
    if (( rc != 0 )); then continue; fi

    echo -e "\n${CYAN}━━━━━━━━ COMPONENT REVIEW ━━━━━━━━${RESET}"
    echo -e "Component : ${BOLD}$component${RESET}"
    echo -e "Source    : ${BOLD}$source_label${RESET}"
    echo -e "Repository: ${BOLD}$selected_repo${RESET}"
    echo -e "Branch    : ${BOLD}$SELECTED_BRANCH${RESET}"
    echo -e "Target    : ${BOLD}$path${RESET}"
    echo -e "Repo      : ${GREEN}✓ accessible${RESET}"
    echo -e "Branch    : ${GREEN}✓ exists${RESET}"
    echo -e "Target    : ${GREEN}✓ valid${RESET}"
    echo "1) Confirm this selection"
    echo "2) Re-select repository"
    echo "3) Re-select branch"
    echo "4) Back"
    read -rp "Your choice [1-4]: " rc
    case "$rc" in
      1)
        SELECTED_REPOS["$path"]="$selected_repo"
        SELECTED_BRANCHES["$path"]="$SELECTED_BRANCH"
        SELECTED_SOURCES["$path"]="$source_key"
        echo -e "${GREEN}[OK] Configuration saved for $component${RESET}"
        return 0
        ;;
      2) continue ;;
      3) select_branch "$selected_repo" "$component" || continue ;;
      4) return 254 ;;
      *) echo -e "${RED}Invalid choice.${RESET}" ;;
    esac
  done
}

configure_standard_device() {
  local device="$1"; shift
  SELECTED_DEVICE="$device"
  local components=("$@") entry path custom_repo official_repo rc
  for entry in "${components[@]}"; do
    IFS='|' read -r path custom_repo official_repo <<< "$entry"
    choose_repo_and_branch "$path" "$custom_repo" "$official_repo"
    rc=$?
    if (( rc != 0 )); then return "$rc"; fi
  done
}

configure_bramble() {
  configure_standard_device "Bramble (Pixel 4a 5G)" \
    "device/google/bramble|https://github.com/Bias8145/android_device_google_bramble.git|https://github.com/LineageOS/android_device_google_bramble.git" \
    "device/google/redbull|https://github.com/Bias8145/android_device_google_redbull.git|https://github.com/LineageOS/android_device_google_redbull.git" \
    "device/google/gs-common|https://github.com/Bias8145/android_device_google_gs-common.git|https://github.com/LineageOS/android_device_google_gs-common.git" \
    "vendor/google/bramble|https://github.com/TheMuppets/proprietary_vendor_google_bramble.git|https://github.com/TheMuppets/proprietary_vendor_google_bramble.git" \
    "kernel/google/redbull|https://github.com/Bias8145/android_kernel_google_redbull.git|https://github.com/LineageOS/android_kernel_google_redbull.git"
}

configure_coral() {
  configure_standard_device "Coral (Pixel 4 XL)" \
    "device/google/coral|https://github.com/Bias8145/android_device_google_coral.git|https://github.com/LineageOS/android_device_google_coral.git" \
    "device/google/gs-common|https://github.com/Bias8145/android_device_google_gs-common.git|https://github.com/LineageOS/android_device_google_gs-common.git" \
    "vendor/google/coral|https://github.com/TheMuppets/proprietary_vendor_google_coral.git|https://github.com/TheMuppets/proprietary_vendor_google_coral.git" \
    "kernel/google/msm-4.14|https://github.com/Bias8145/android_kernel_google_msm-4.14.git|https://github.com/LineageOS/android_kernel_google_msm-4.14.git"
}

configure_flame() {
  configure_standard_device "Flame (Pixel 4)" \
    "device/google/coral|https://github.com/Bias8145/android_device_google_coral.git|https://github.com/LineageOS/android_device_google_coral.git" \
    "device/google/gs-common|https://github.com/Bias8145/android_device_google_gs-common.git|https://github.com/LineageOS/android_device_google_gs-common.git" \
    "vendor/google/flame|https://github.com/TheMuppets/proprietary_vendor_google_flame.git|https://github.com/TheMuppets/proprietary_vendor_google_flame.git" \
    "kernel/google/msm-4.14|https://github.com/Bias8145/android_kernel_google_msm-4.14.git|https://github.com/LineageOS/android_kernel_google_msm-4.14.git"
}

configure_sunfish() {
  configure_standard_device "Sunfish (Pixel 4a)" \
    "device/google/sunfish|https://github.com/Bias8145/android_device_google_sunfish.git|https://github.com/LineageOS/android_device_google_sunfish.git" \
    "device/google/gs-common|https://github.com/Bias8145/android_device_google_gs-common.git|https://github.com/LineageOS/android_device_google_gs-common.git" \
    "vendor/google/sunfish|https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git|https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git" \
    "kernel/google/msm-4.14|https://github.com/Bias8145/android_kernel_google_msm-4.14.git|https://github.com/LineageOS/android_kernel_google_msm-4.14.git"
}

configure_raviole() {
  SELECTED_DEVICE="Raviole (Pixel 6/Pro)"
  local components=(
    "device/google/raviole|https://github.com/xioyo/android_device_google_raviole.git|https://github.com/LineageOS/android_device_google_raviole.git"
    "device/google/gs101|https://github.com/xioyo/android_device_google_gs101.git|https://github.com/LineageOS/android_device_google_gs101.git"
    "device/google/gs-common|https://github.com/LineageOS/android_device_google_gs-common.git|https://github.com/LineageOS/android_device_google_gs-common.git"
    "vendor/google/oriole|https://github.com/xioyo/proprietary_vendor_google_oriole.git|https://github.com/TheMuppets/proprietary_vendor_google_oriole.git"
    "vendor/google/raven|https://github.com/TheMuppets/proprietary_vendor_google_raven.git|https://github.com/TheMuppets/proprietary_vendor_google_raven.git"
    "device/google/raviole-kernels/lineage|https://git.evolution-x.org/Evolution-X-Tensor/device_google_raviole-kernels_evolution.git|https://git.evolution-x.org/Evolution-X-Tensor/device_google_raviole-kernels_evolution.git"
    "packages/apps/PixelParts|https://github.com/Evolution-X-Devices/packages_apps_PixelParts.git|https://github.com/LineageOS/android_packages_apps_PixelParts.git"
  )
  local entry path custom_repo official_repo rc
  for entry in "${components[@]}"; do
    IFS='|' read -r path custom_repo official_repo <<< "$entry"
    choose_repo_and_branch "$path" "$custom_repo" "$official_repo"
    rc=$?
    if (( rc != 0 )); then return "$rc"; fi
  done
}

validate_all_configuration() {
  local -a paths=() errors=() targets=()
  local path repo branch source
  for path in "${!SELECTED_REPOS[@]}"; do paths+=("$path"); done
  (( ${#paths[@]} > 0 )) || { echo -e "${RED}[ERROR] No repositories selected.${RESET}"; return 1; }
  for path in "${paths[@]}"; do
    repo="${SELECTED_REPOS[$path]}"; branch="${SELECTED_BRANCHES[$path]}"; source="${SELECTED_SOURCES[$path]}"
    validate_target_path "$path" >/dev/null || errors+=("Invalid target: $path")
    for target in "${targets[@]}"; do [[ "$target" == "$path" ]] && errors+=("Duplicate target: $path"); done
    targets+=("$path")
    if [[ "$source" != "existing" ]]; then
      validate_component_source "$path" "$source" "$repo" >/dev/null || errors+=("Invalid source: $path")
      git ls-remote --exit-code --heads "$repo" "refs/heads/$branch" >/dev/null 2>&1 || errors+=("Repository/branch unavailable: $repo [$branch]")
    fi
    [[ -n "$repo" && -n "$branch" ]] || errors+=("Missing repository or branch: $path")
  done
  if (( ${#errors[@]} > 0 )); then
    echo -e "${RED}[ERROR] Configuration validation failed:${RESET}"
    printf '  - %s\n' "${errors[@]}"
    return 1
  fi
  echo -e "${GREEN}[SUCCESS] All selected repositories and branches validated.${RESET}"
  return 0
}

show_final_review() {
  echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD} === FINAL CONFIGURATION REVIEW ===${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}Selected Device: ${BOLD}$SELECTED_DEVICE${RESET}"
  [[ -n "$KERNELSU_OPTION" ]] && echo -e "${CYAN}KernelSU: ${BOLD}$KERNELSU_OPTION${RESET}"
  echo -e "\n${CYAN}Repositories:${RESET}"
  local -a paths=() sorted=()
  local path repo branch source info current_url current_branch action
  for path in "${!SELECTED_REPOS[@]}"; do paths+=("$path"); done
  mapfile -t sorted < <(printf '%s\n' "${paths[@]}" | sort)
  for path in "${sorted[@]}"; do
    repo="${SELECTED_REPOS[$path]}"; branch="${SELECTED_BRANCHES[$path]}"; source="${SELECTED_SOURCES[$path]}"; action="CLONE"
    if [[ -d "$path" ]]; then
      info=$(get_existing_repo_info "$path"); current_url="${info%%|*}"; current_branch="${info#*|}"
      if [[ "$(normalize_repo_url "$current_url")" == "$(normalize_repo_url "$repo")" && "$current_branch" == "$branch" ]]; then action="SKIP"; else action="REPLACE"; fi
    fi
    echo -e "  ${YELLOW}├─ $path${RESET} [${action}]"
    echo -e "  │  Source: $source"
    echo -e "  │  Repo: $repo"
    echo -e "  │  Branch: $branch"
  done
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo "1) Proceed to clone"
  echo "2) Dry run (show commands only)"
  echo "3) Modify selections"
  echo "4) Cancel"
  local choice
  while true; do
    read -rp "Your choice [1-4]: " choice
    case "$choice" in
      1) DRY_RUN="no"; return 0 ;;
      2) DRY_RUN="yes"; return 0 ;;
      3) return 1 ;;
      4) return 2 ;;
      *) echo -e "${RED}Invalid choice.${RESET}" ;;
    esac
  done
}

final_clone_confirmation() {
  echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD} === CLONE CONFIRMATION ===${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${YELLOW}WARNING: The selected actions may create, replace, or modify directories in the current source tree.${RESET}"
  echo -e "${CYAN}Configuration has passed repository, branch, and target validation.${RESET}\n"
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo -e "${CYAN}DRY RUN: no filesystem changes will be made.${RESET}"
    ask_confirm "Run dry-run now?" "y"
    return $?
  fi
  echo "1) YES - CLONE EVERYTHING"
  echo "2) EDIT CONFIGURATION"
  echo "3) CANCEL"
  local choice
  while true; do
    read -rp "Your choice [1-3]: " choice
    case "$choice" in
      1) return 0 ;;
      2) return 1 ;;
      3) return 2 ;;
      *) echo -e "${RED}Invalid choice.${RESET}" ;;
    esac
  done
}

clone_repo() {
  local repo="$1" target="$2" branch="$3" component="$(basename "$target")"
  echo -e "${BLUE}[ACTION] $repo [$branch] -> $target${RESET}"
  if [[ "$DRY_RUN" == "yes" ]]; then
    echo "DRY-RUN: git clone --branch '$branch' --single-branch '$repo' '$target'"
    return 0
  fi
  if [[ -d "$target" ]]; then
    local info current_url current_branch
    info=$(get_existing_repo_info "$target"); current_url="${info%%|*}"; current_branch="${info#*|}"
    if [[ "$(normalize_repo_url "$current_url")" == "$(normalize_repo_url "$repo")" && "$current_branch" == "$branch" ]]; then
      echo -e "${YELLOW}[SKIP] $component already matches.${RESET}"; return 2
    fi
    echo -e "${YELLOW}[WARNING] Existing directory differs from target repository/branch.${RESET}"
    echo "1) Remove and clone new repository"
    echo "2) Skip"
    echo "3) Cancel entire process"
    local choice
    read -rp "Your choice [1-3]: " choice
    case "$choice" in
      1) rm -rf -- "$target" || return 1 ;;
      2) return 2 ;;
      3) return 3 ;;
      *) echo -e "${RED}Invalid choice.${RESET}"; return 1 ;;
    esac
  fi
  git ls-remote --exit-code --heads "$repo" "refs/heads/$branch" >/dev/null 2>&1 || {
    echo -e "${RED}[ERROR] Repository/branch is no longer available: $repo [$branch]${RESET}"; return 1;
  }
  mkdir -p "$(dirname "$target")" || return 1
  if git clone --branch "$branch" --single-branch "$repo" "$target"; then
    echo -e "${GREEN}[SUCCESS] Clone completed: $target${RESET}"; return 0
  fi
  echo -e "${RED}[ERROR] Failed to clone $repo [$branch]${RESET}"; return 1
}

setup_kernelsu_susfs_redbull() {
  local kernel_dir="kernel/google/redbull"
  [[ -d "$kernel_dir" ]] || { echo -e "${RED}[ERROR] Kernel directory not found: $kernel_dir${RESET}"; return 1; }
  local original_dir="$PWD"
  cd "$kernel_dir" || return 1
  echo ">>> [1/9] Setting up KernelSU-Next v1.0.3"
  curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next/kernel/setup.sh" | bash -s v1.0.3 || { cd "$original_dir"; return 1; }
  cd KernelSU-Next || { cd "$original_dir"; return 1; }
  echo ">>> [4/9] Downloading SUSFS patch v1.5.3"
  curl -fLo 0001-Kernel-Implement-SUSFS-v1.5.3.patch "https://github.com/sidex15/KernelSU-Next/commit/1e750de25930e875612bbec0410de0088474c00b.patch" || { cd "$original_dir"; return 1; }
  [[ -s 0001-Kernel-Implement-SUSFS-v1.5.3.patch ]] || { cd "$original_dir"; return 1; }
  patch -p1 < 0001-Kernel-Implement-SUSFS-v1.5.3.patch || { cd "$original_dir"; return 1; }
  cd .. || { cd "$original_dir"; return 1; }
  echo ">>> [7/9] Cloning SUSFS for kernel 4.19"
  rm -rf susfs4ksu
  git clone -b kernel-4.19 https://gitlab.com/simonpunk/susfs4ksu.git || { cd "$original_dir"; return 1; }
  cp -v susfs4ksu/kernel_patches/fs/* fs/ || { cd "$original_dir"; return 1; }
  cp -v susfs4ksu/kernel_patches/include/linux/* include/linux/ || { cd "$original_dir"; return 1; }
  cp -v susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch . || { cd "$original_dir"; return 1; }
  patch -p1 < 50_add_susfs_in_kernel-4.19.patch || { cd "$original_dir"; return 1; }
  rm -rf susfs4ksu
  cd "$original_dir" || return 1
  echo -e "${GREEN}[SUCCESS] KernelSU-Next + SUSFS setup completed.${RESET}"
}

execute_cloning() {
  local successful=() skipped=() failed=() path repo branch rc
  local -a paths=() sorted=()
  for path in "${!SELECTED_REPOS[@]}"; do paths+=("$path"); done
  mapfile -t sorted < <(printf '%s\n' "${paths[@]}" | sort)
  for path in "${sorted[@]}"; do
    repo="${SELECTED_REPOS[$path]}"; branch="${SELECTED_BRANCHES[$path]}"
    clone_repo "$repo" "$path" "$branch"; rc=$?
    case "$rc" in
      0) successful+=("$path") ;;
      2) skipped+=("$path") ;;
      3) echo -e "${RED}[CANCELLED] Clone process stopped by user.${RESET}"; return 1 ;;
      *) failed+=("$path") ;;
    esac
    echo
  done
  if [[ "$DRY_RUN" == "no" && "$KERNELSU_OPTION" == "yes" && "$SELECTED_DEVICE" == "Bramble (Pixel 4a 5G)" ]]; then
    setup_kernelsu_susfs_redbull || echo -e "${RED}[ERROR] KernelSU/SUSFS setup failed.${RESET}"
  fi
  echo -e "\n${BOLD}=== EXECUTION SUMMARY ===${RESET}"
  echo "Total: ${#SELECTED_REPOS[@]}"
  echo -e "${GREEN}Cloned/Planned: ${#successful[@]}${RESET}"
  echo -e "${YELLOW}Skipped: ${#skipped[@]}${RESET}"
  echo -e "${RED}Failed: ${#failed[@]}${RESET}"
  if (( ${#failed[@]} == 0 )); then echo -e "${GREEN}[SUCCESS] Process completed successfully!${RESET}"; elif (( ${#successful[@]} > 0 )); then echo -e "${YELLOW}[PARTIAL SUCCESS] Process completed with some issues.${RESET}"; else echo -e "${RED}[FAILURE] Process failed.${RESET}"; fi
}

reset_selection() {
  SELECTED_REPOS=()
  SELECTED_BRANCHES=()
  SELECTED_SOURCES=()
  SELECTED_DEVICE=""
  KERNELSU_OPTION=""
  DRY_RUN="no"
}

main() {
  while true; do
    select_menu "Select device to configure:" \
      "Bramble (Pixel 4a 5G)" \
      "Coral (Pixel 4 XL)" \
      "Flame (Pixel 4)" \
      "Sunfish (Pixel 4a)" \
      "Raviole (Pixel 6/Pro)"
    local device_choice=$?
    case "$device_choice" in
      254) exit 0 ;;
      0) configure_bramble ;;
      1) configure_coral ;;
      2) configure_flame ;;
      3) configure_sunfish ;;
      4) configure_raviole ;;
      *) continue ;;
    esac
    local config_rc=$?
    if (( config_rc == 254 )); then reset_selection; continue; fi
    if (( config_rc != 0 )); then echo -e "${RED}[ERROR] Configuration failed.${RESET}"; reset_selection; continue; fi
    validate_all_configuration || { echo -e "${RED}[ERROR] Cannot continue until configuration is fixed.${RESET}"; reset_selection; continue; }
    show_final_review
    local review_rc=$?
    case "$review_rc" in
      0)
        final_clone_confirmation
        local confirm_rc=$?
        case "$confirm_rc" in
          0) execute_cloning; return ;;
          1) reset_selection ;;
          2) return ;;
        esac
        ;;
      1) reset_selection ;;
      2) return ;;
    esac
  done
}

main
