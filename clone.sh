#!/bin/bash

# Android Source Repo Cloner
# Refactored configuration flow with Custom/Official repositories and
# a Bramble (Pixel 4a 5G) LineageOS 23.2 preset.

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
BLUE="\033[0;34m"
BOLD="\033[1m"
RESET="\033[0m"
MAGENTA="\033[0;35m"

# Selected repositories are indexed by destination path.
declare -A SELECTED_REPOS=()
declare -A SELECTED_BRANCHES=()
SELECTED_DEVICE=""
KERNELSU_OPTION=""

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
    for i in "${!options[@]}"; do
      echo "$((i + 1))) ${options[$i]}"
    done
    echo "b) Back"
    echo "q) Quit"
    read -rp "Enter your choice: " choice
    case "$choice" in
      [0-9]*)
        if (( choice >= 1 && choice <= ${#options[@]} )); then
          return $((choice - 1))
        fi
        ;;
      [Bb]) return 254 ;;
      [Qq]) exit 0 ;;
    esac
    echo -e "${RED}Invalid selection.${RESET}"
  done
}

get_existing_repo_info() {
  local target_dir="$1" repo_url="" repo_branch=""
  if [[ -d "$target_dir/.git" ]]; then
    pushd "$target_dir" >/dev/null 2>&1 || return 1
    repo_url=$(git config --get remote.origin.url 2>/dev/null || echo "Unknown")
    repo_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "Unknown")
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
  return 0
}

select_branch() {
  local repo_url="$1" component="$2" selected choice branches=()
  echo -e "\n${BLUE}[INFO] Fetching branches from $repo_url${RESET}"
  mapfile -t branches < <(git ls-remote --heads "$repo_url" 2>/dev/null | awk '{print $2}' | sed 's#refs/heads/##')
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
          SELECTED_BRANCH="$selected"
          echo -e "${GREEN}Selected branch: $selected${RESET}"
          return 0
        fi
        ;;
      [Bb]) return 254 ;;
    esac
    echo -e "${RED}Invalid branch selection.${RESET}"
  done
}

# Interactive Custom/Official repository selection.
choose_repo_and_branch() {
  local path="$1" custom_repo="$2" official_repo="$3"
  local component="$(basename "$path")" repo_choice repo selected_repo rc

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
          current_url="${info%%|*}"
          current_branch="${info#*|}"
          SELECTED_REPOS["$path"]="$current_url"
          SELECTED_BRANCHES["$path"]="$current_branch"
          echo -e "${GREEN}[KEEP] $path${RESET}"
          return 0
          ;;
        3) return 254 ;;
        *) echo -e "${RED}Invalid choice.${RESET}"; continue ;;
      esac
    fi

    select_menu "Choose source repository for $path:" \
      "Custom: $custom_repo" \
      "Official: $official_repo"
    repo_choice=$?
    case "$repo_choice" in
      254) return 254 ;;
      0) selected_repo="$custom_repo" ;;
      1) selected_repo="$official_repo" ;;
      *) return 1 ;;
    esac

    select_branch "$selected_repo" "$component"
    rc=$?
    if (( rc == 254 )); then continue; fi
    if (( rc != 0 )); then return "$rc"; fi

    echo -e "\n${CYAN}Selection Summary:${RESET}"
    echo -e "Repository: ${BOLD}$selected_repo${RESET}"
    echo -e "Branch: ${BOLD}$SELECTED_BRANCH${RESET}"
    echo -e "Target: ${BOLD}$path${RESET}"
    ask_confirm "Confirm this selection?" "y"
    rc=$?
    case "$rc" in
      0)
        SELECTED_REPOS["$path"]="$selected_repo"
        SELECTED_BRANCHES["$path"]="$SELECTED_BRANCH"
        echo -e "${GREEN}[OK] Configuration saved for $component${RESET}"
        return 0
        ;;
      1) ;;
      254) return 254 ;;
    esac
  done
}

# Add a repository directly to the selection table after validating its branch.
add_preset_repo() {
  local path="$1" repo="$2" branch="$3"
  echo -e "${BLUE}[PRESET] Checking $path -> $repo [$branch]${RESET}"
  if ! git ls-remote --exit-code --heads "$repo" "$branch" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] Required branch '$branch' was not found in $repo${RESET}"
    return 1
  fi
  SELECTED_REPOS["$path"]="$repo"
  SELECTED_BRANCHES["$path"]="$branch"
  echo -e "${GREEN}[OK] $path -> $branch${RESET}"
}

# Exact preset requested for Bramble / Pixel 4a 5G.
apply_bramble_lineage_23_2_preset() {
  echo -e "\n${BOLD}=== Bramble: LineageOS 23.2 preset ===${RESET}"
  local -a preset=(
    "device/google/bramble|https://github.com/LineageOS/android_device_google_bramble.git|lineage-23.2"
    "device/google/redbull|https://github.com/LineageOS/android_device_google_redbull.git|lineage-23.2"
    "device/google/gs-common|https://github.com/LineageOS/android_device_google_gs-common.git|lineage-23.2"
    "vendor/google/bramble|https://github.com/TheMuppets/proprietary_vendor_google_bramble.git|lineage-23.2"
    "kernel/google/redbull|https://github.com/Bias8145/android_kernel_google_redbull.git|sukisu-susfs-16.2"
  )
  local entry path repo branch
  for entry in "${preset[@]}"; do
    IFS='|' read -r path repo branch <<< "$entry"
    add_preset_repo "$path" "$repo" "$branch" || return 1
  done
  echo -e "${GREEN}[SUCCESS] Bramble LineageOS 23.2 preset configured.${RESET}"
  return 0
}

configure_bramble() {
  SELECTED_DEVICE="Bramble (Pixel 4a 5G)"
  while true; do
    show_header "$SELECTED_DEVICE" "Configuration"
    select_menu "Bramble source configuration:" \
      "Custom/Official repository selection" \
      "LineageOS 23.2 preset (requested)"
    local mode=$?
    case "$mode" in
      254) return 254 ;;
      0)
        local components=(
          "device/google/bramble|https://github.com/Bias8145/android_device_google_bramble.git|https://github.com/LineageOS/android_device_google_bramble.git"
          "device/google/redbull|https://github.com/Bias8145/android_device_google_redbull.git|https://github.com/LineageOS/android_device_google_redbull.git"
          "device/google/gs-common|https://github.com/Bias8145/android_device_google_gs-common.git|https://github.com/LineageOS/android_device_google_gs-common.git"
          "vendor/google/bramble|https://github.com/TheMuppets/proprietary_vendor_google_bramble.git|https://github.com/TheMuppets/proprietary_vendor_google_bramble.git"
          "kernel/google/redbull|https://github.com/Bias8145/android_kernel_google_redbull.git|https://github.com/LineageOS/android_kernel_google_redbull.git"
        )
        local entry path custom_repo official_repo rc
        for entry in "${components[@]}"; do
          IFS='|' read -r path custom_repo official_repo <<< "$entry"
          choose_repo_and_branch "$path" "$custom_repo" "$official_repo"
          rc=$?
          if (( rc == 254 )); then continue 2; fi
          if (( rc != 0 )); then return "$rc"; fi
        done
        ;;
      1)
        apply_bramble_lineage_23_2_preset || return 1
        ;;
    esac

    if [[ -z "$KERNELSU_OPTION" ]]; then
      echo -e "\n${YELLOW}━━━ KernelSU Configuration ━━━${RESET}"
      ask_confirm "Apply KernelSU-Next + SUSFS patch for redbull kernel?" "y"
      case $? in
        0) KERNELSU_OPTION="yes" ;;
        1) KERNELSU_OPTION="no" ;;
        254) continue ;;
      esac
    fi
    return 0
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
  return 0
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

clone_repo() {
  local repo="$1" target="$2" branch="$3" component="$(basename "$target")"
  echo -e "${BLUE}[ACTION] $repo [$branch] -> $target${RESET}"

  if [[ -d "$target" ]]; then
    local info current_url current_branch
    info=$(get_existing_repo_info "$target")
    current_url="${info%%|*}"
    current_branch="${info#*|}"
    if [[ "$current_url" == "$repo" && "$current_branch" == "$branch" ]]; then
      echo -e "${YELLOW}[SKIP] $component already matches.${RESET}"
      return 2
    fi
    echo -e "${YELLOW}[WARNING] Existing directory differs from target repository/branch.${RESET}"
    echo "1) Remove and clone new repository"
    echo "2) Skip"
    local choice
    read -rp "Your choice [1-2]: " choice
    case "$choice" in
      1) rm -rf "$target" || return 1 ;;
      2) return 2 ;;
      *) echo -e "${RED}Invalid choice.${RESET}"; return 1 ;;
    esac
  fi

  git ls-remote "$repo" >/dev/null 2>&1 || {
    echo -e "${RED}[ERROR] Cannot access $repo${RESET}"
    return 1
  }
  mkdir -p "$(dirname "$target")" || return 1
  if git clone -b "$branch" "$repo" "$target"; then
    echo -e "${GREEN}[SUCCESS] Clone completed: $target${RESET}"
    return 0
  fi
  echo -e "${RED}[ERROR] Failed to clone $repo [$branch]${RESET}"
  return 1
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
  curl -fLo 0001-Kernel-Implement-SUSFS-v1.5.3.patch \
    "https://github.com/sidex15/KernelSU-Next/commit/1e750de25930e875612bbec0410de0088474c00b.patch" || { cd "$original_dir"; return 1; }
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

show_final_review() {
  echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD} === CONFIGURATION REVIEW ===${RESET}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}Selected Device: ${BOLD}$SELECTED_DEVICE${RESET}"
  [[ -n "$KERNELSU_OPTION" ]] && echo -e "${CYAN}KernelSU: ${BOLD}$KERNELSU_OPTION${RESET}"
  echo -e "\n${CYAN}Repositories:${RESET}"

  local path repo branch info current_url current_branch action
  for path in "${!SELECTED_REPOS[@]}"; do
    repo="${SELECTED_REPOS[$path]}"
    branch="${SELECTED_BRANCHES[$path]}"
    action="CLONE"
    if [[ -d "$path" ]]; then
      info=$(get_existing_repo_info "$path")
      current_url="${info%%|*}"
      current_branch="${info#*|}"
      if [[ "$current_url" == "$repo" && "$current_branch" == "$branch" ]]; then
        action="SKIP"
      else
        action="REPLACE"
      fi
    fi
    echo -e "  ${YELLOW}├─ $path${RESET} [${action}]"
    echo -e "  │  Repo: $repo"
    echo -e "  │  Branch: $branch"
  done

  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo "1) Proceed with cloning"
  echo "2) Skip cloning"
  echo "3) Modify selections"
  echo "4) Cancel"
  local choice
  while true; do
    read -rp "Your choice [1-4]: " choice
    case "$choice" in
      1) return 0 ;;
      2) return 2 ;;
      3) return 1 ;;
      4) exit 0 ;;
    esac
    echo -e "${RED}Invalid choice.${RESET}"
  done
}

execute_cloning() {
  local successful=() skipped=() failed=() path repo branch rc
  for path in "${!SELECTED_REPOS[@]}"; do
    repo="${SELECTED_REPOS[$path]}"
    branch="${SELECTED_BRANCHES[$path]}"
    clone_repo "$repo" "$path" "$branch"
    rc=$?
    case "$rc" in
      0) successful+=("$path") ;;
      2) skipped+=("$path") ;;
      *) failed+=("$path") ;;
    esac
    echo
  done

  if [[ "$KERNELSU_OPTION" == "yes" && "$SELECTED_DEVICE" == "Bramble (Pixel 4a 5G)" ]]; then
    setup_kernelsu_susfs_redbull || echo -e "${RED}[ERROR] KernelSU/SUSFS setup failed.${RESET}"
  fi

  echo -e "\n${BOLD}=== EXECUTION SUMMARY ===${RESET}"
  echo "Total: ${#SELECTED_REPOS[@]}"
  echo -e "${GREEN}Cloned: ${#successful[@]}${RESET}"
  echo -e "${YELLOW}Skipped: ${#skipped[@]}${RESET}"
  echo -e "${RED}Failed: ${#failed[@]}${RESET}"
  if (( ${#failed[@]} == 0 )); then
    echo -e "${GREEN}[SUCCESS] Process completed successfully!${RESET}"
  elif (( ${#successful[@]} > 0 )); then
    echo -e "${YELLOW}[PARTIAL SUCCESS] Process completed with some issues.${RESET}"
  else
    echo -e "${RED}[FAILURE] Process failed.${RESET}"
  fi
}

reset_selection() {
  SELECTED_REPOS=()
  SELECTED_BRANCHES=()
  SELECTED_DEVICE=""
  KERNELSU_OPTION=""
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
    if (( config_rc != 0 )); then
      echo -e "${RED}[ERROR] Configuration failed.${RESET}"
      reset_selection
      continue
    fi

    show_final_review
    local review_rc=$?
    case "$review_rc" in
      0) execute_cloning; return ;;
      2) echo -e "${YELLOW}[SKIP] Cloning skipped. Configuration completed.${RESET}"; return ;;
      1) reset_selection ;;
      *) return ;;
    esac
  done
}

main
