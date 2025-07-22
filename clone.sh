#!/bin/bash

# Terminal Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
BLUE="\033[0;34m"
BOLD="\033[1m"
RESET="\033[0m"

# Global variables to store selections
declare -A SELECTED_REPOS
declare -A SELECTED_BRANCHES
SELECTED_DEVICE=""
KERNELSU_OPTION=""

trap "echo; echo '[ABORTED] Process cancelled by user'; exit 1" INT

# Validate required tools
for cmd in git curl patch; do
  if ! command -v $cmd &>/dev/null; then
    echo -e "${RED}[ERROR] Required tool '$cmd' is missing. Please install it first.${RESET}"
    exit 1
  fi
done

echo
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e " === Android Source Repo Cloner ==="
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo

# Function: Show header with device info
show_header() {
  local device="$1"
  local action="$2"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e " === $action for $device ==="
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# Function: Enhanced confirmation with back option
ask_confirm_with_back() {
  local prompt="$1"
  local default_answer="${2:-y}"
  local answer
  while true; do
    echo -e "\n${prompt}"
    echo "Options: [y]es, [n]o, [b]ack"
    read -rp "Your choice [$default_answer]: " answer
    answer=${answer:-$default_answer}
    case "$answer" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      [Bb]) return 2 ;;
      *) echo -e "${YELLOW}Please answer y, n, or b.${RESET}" ;;
    esac
  done
}

# Function: Menu selection with back option
select_menu_with_back() {
  local title="$1"
  shift
  local options=("$@")
  local choice
  
  while true; do
    echo -e "\n${CYAN}$title${RESET}"
    for i in "${!options[@]}"; do
      echo "$((i+1))) ${options[i]}"
    done
    echo "b) Back to previous menu"
    echo "q) Quit"
    
    read -rp "Enter your choice: " choice
    case $choice in
      [0-9]*)
        if [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#options[@]}" ]]; then
          return $((choice-1))
        else
          echo -e "${RED}Invalid selection. Please enter a number between 1 and ${#options[@]}.${RESET}"
        fi
        ;;
      [Bb]) return 254 ;;  # Back signal
      [Qq]) exit 0 ;;
      *) echo -e "${RED}Invalid input. Please try again.${RESET}" ;;
    esac
  done
}

# Function: Select branch from repo with back option
select_branch_with_back() {
  local repo_url=$1
  local repo_name=$2
  echo -e "\n${BLUE}[INFO] Fetching branches from: $repo_name${RESET}"
  
  # Get branches and store in array
  local branches=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && branches+=("$line")
  done < <(git ls-remote --heads "$repo_url" 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||')

  if [[ ${#branches[@]} -eq 0 ]]; then
    echo -e "${RED}[✘] No branches found or failed to connect.${RESET}"
    return 1
  fi

  echo -e "\n${CYAN}Available branches for $repo_name:${RESET}"
  for i in "${!branches[@]}"; do
    echo "$((i+1))) ${branches[i]}"
  done
  echo "b) Back to repository selection"
  
  while true; do
    read -rp "Select branch [1-${#branches[@]}, b]: " choice
    case $choice in
      [0-9]*)
        if [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#branches[@]}" ]]; then
          selected_branch="${branches[$((choice-1))]}"
          echo -e "${GREEN}Selected branch: $selected_branch${RESET}"
          return 0
        else
          echo -e "${RED}Invalid selection. Please enter a number between 1 and ${#branches[@]}.${RESET}"
        fi
        ;;
      [Bb]) return 254 ;;
      *) echo -e "${RED}Invalid input. Please try again.${RESET}" ;;
    esac
  done
}

# Function: Choose repo and branch with confirmation
choose_repo_and_branch_interactive() {
  local path=$1
  local custom_repo=$2
  local official_repo=$3
  local component_name=$(basename "$path")

  while true; do
    echo -e "\n${YELLOW}━━━ Configuring: $component_name ━━━${RESET}"
    echo -e "Component path: ${BOLD}$path${RESET}"
    
    # Repository selection
    local repos=("Custom: $custom_repo" "Official: $official_repo")
    select_menu_with_back "Choose source repository:" "${repos[@]}"
    local repo_choice=$?
    
    case $repo_choice in
      254) return 254 ;;  # Back signal
      0) repo=$custom_repo ;;
      1) repo=$official_repo ;;
    esac

    # Branch selection
    while true; do
      if ! select_branch_with_back "$repo" "$component_name"; then
        if [[ $? -eq 254 ]]; then
          break  # Back to repo selection
        else
          echo -e "${RED}[✘] Failed to select branch for $repo${RESET}"
          return 1
        fi
      else
        # Confirmation
        echo -e "\n${CYAN}Selection Summary for $component_name:${RESET}"
        echo -e "Repository: ${BOLD}$repo${RESET}"
        echo -e "Branch: ${BOLD}$selected_branch${RESET}"
        echo -e "Target: ${BOLD}$path${RESET}"
        
        ask_confirm_with_back "Confirm this selection?" "y"
        local confirm_result=$?
        case $confirm_result in
          0) 
            # Store selection
            SELECTED_REPOS["$path"]="$repo"
            SELECTED_BRANCHES["$path"]="$selected_branch"
            echo -e "${GREEN}[✓] Configuration saved for $component_name${RESET}"
            return 0
            ;;
          1) continue ;;  # Try again
          2) break ;;     # Back to repo selection
        esac
      fi
    done
  done
}

# Function: Clone repo with progress simulation
clone_repo_with_progress() {
  local repo_url=$1
  local target_dir=$2
  local branch=$3
  local component_name=$(basename "$target_dir")

  echo -e "${BLUE}[INFO] Selected repository: $repo_url${RESET}"
  echo -e "${BLUE}[INFO] Selected branch: $branch${RESET}"
  echo -e "${BLUE}[ACTION] Cloning to $target_dir...${RESET}"

  # Check if directory already exists
  if [ -d "$target_dir/.git" ]; then
    echo -e "${YELLOW}[INFO] Directory $target_dir already exists. Validating...${RESET}"
    pushd "$target_dir" > /dev/null

    local current_url=$(git config --get remote.origin.url 2>/dev/null)
    local current_branch=$(git symbolic-ref --short HEAD 2>/dev/null)

    if [[ "$current_url" == "$repo_url" && "$current_branch" == "$branch" ]]; then
      echo -e "${GREEN}[SKIP] Repository already up to date${RESET}"
      popd > /dev/null
      return 0
    else
      echo -e "${YELLOW}[WARNING] Repository mismatch detected! Re-cloning...${RESET}"
      popd > /dev/null
      rm -rf "$target_dir"
    fi
  fi

  # Validate repository access
  if ! git ls-remote "$repo_url" &> /dev/null; then
    echo -e "${RED}[✘] Cannot access $repo_url. Check the connection or URL.${RESET}"
    return 1
  fi

  # Simulate progress (you can replace this with actual progress tracking)
  echo -n -e "${BLUE}[PROGRESS] 25% [█████---------------] Cloning $component_name"
  sleep 0.5
  echo -n -e "\r[PROGRESS] 50% [██████████----------] Cloning $component_name"
  
  # Clone repository
  if git clone -b "$branch" "$repo_url" "$target_dir" &>/dev/null; then
    echo -e "\r[PROGRESS] 100% [████████████████████] Cloning $component_name"
    echo -e "${GREEN}[SUCCESS] Clone completed to $target_dir${RESET}"
    return 0
  else
    echo -e "\r${RED}[✘] Failed to clone $repo_url (branch: $branch)${RESET}"
    return 1
  fi
}

# Function: Show final review and confirm
show_final_review() {
  echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e " === CONFIGURATION REVIEW ==="
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  
  echo -e "\n${CYAN}Selected Device: ${BOLD}$SELECTED_DEVICE${RESET}"
  
  if [[ -n "$KERNELSU_OPTION" ]]; then
    echo -e "${CYAN}KernelSU Option: ${BOLD}$KERNELSU_OPTION${RESET}"
  fi
  
  echo -e "\n${CYAN}Repositories to be cloned:${RESET}"
  for path in "${!SELECTED_REPOS[@]}"; do
    local repo="${SELECTED_REPOS[$path]}"
    local branch="${SELECTED_BRANCHES[$path]}"
    local component=$(basename "$path")
    
    echo -e "  ${YELLOW}├─ $component${RESET}"
    echo -e "  │  Path: $path"
    echo -e "  │  Repo: $repo"
    echo -e "  │  Branch: $branch"
    echo
  done
  
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  
  while true; do
    echo -e "\nOptions:"
    echo "1) Proceed with cloning"
    echo "2) Modify selections"
    echo "3) Cancel"
    
    read -rp "Your choice [1-3]: " choice
    case $choice in
      1) return 0 ;;     # Proceed
      2) return 1 ;;     # Modify
      3) exit 0 ;;       # Cancel
      *) echo -e "${RED}Invalid choice. Please enter 1, 2, or 3.${RESET}" ;;
    esac
  done
}

# Function: Execute cloning process
execute_cloning() {
  local rom_type="LineageOS"  # You can make this dynamic if needed
  
  echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e " === Android Source Repo Cloner ==="
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  
  echo -e "\n${BLUE}[INFO] Detected ROM: $rom_type${RESET}"
  
  show_header "$SELECTED_DEVICE" "Cloning"
  
  local failed_repos=()
  local successful_repos=()
  
  # Clone each repository
  for path in "${!SELECTED_REPOS[@]}"; do
    local repo="${SELECTED_REPOS[$path]}"
    local branch="${SELECTED_BRANCHES[$path]}"
    
    if clone_repo_with_progress "$repo" "$path" "$branch"; then
      successful_repos+=("$path")
    else
      failed_repos+=("$path")
    fi
    echo
  done
  
  # Handle KernelSU setup if selected
  if [[ "$KERNELSU_OPTION" == "yes" && "$SELECTED_DEVICE" == "Bramble (Pixel 4a 5G)" ]]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e " === KernelSU-Next + SUSFS Setup ==="
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    setup_kernelsu_susfs_redbull
  fi
  
  # Final summary
  echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ ${#failed_repos[@]} -eq 0 ]]; then
    echo -e "${GREEN}[SUCCESS] All repositories cloned successfully${RESET}"
  else
    echo -e "${YELLOW}[PARTIAL SUCCESS] Some repositories failed to clone${RESET}"
    echo -e "\n${RED}Failed repositories:${RESET}"
    for repo in "${failed_repos[@]}"; do
      echo -e "  - $repo"
    done
  fi
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  
  echo -e "\n${GREEN}[SUCCESS] Process completed!${RESET}"
  echo -e "Successfully cloned: ${#successful_repos[@]} repositories"
  if [[ ${#failed_repos[@]} -gt 0 ]]; then
    echo -e "Failed to clone: ${#failed_repos[@]} repositories"
  fi
}

# KernelSU-Next + SUSFS patch for redbull (unchanged)
setup_kernelsu_susfs_redbull() {
  set -e

  echo -e "\n${YELLOW}=== Setting up KernelSU-Next + SUSFS for Redbull Kernel ===${RESET}"

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

# Device configuration functions
configure_bramble() {
  SELECTED_DEVICE="Bramble (Pixel 4a 5G)"
  
  while true; do
    show_header "$SELECTED_DEVICE" "Configuration"
    
    # Configure each component
    local components=(
      "device/google/bramble https://github.com/Bias8145/android_device_google_bramble.git https://github.com/LineageOS/android_device_google_bramble.git"
      "device/google/redbull https://github.com/Bias8145/android_device_google_redbull.git https://github.com/LineageOS/android_device_google_redbull.git"
      "device/google/gs-common https://github.com/Bias8145/android_device_google_gs-common.git https://github.com/LineageOS/android_device_google_gs-common.git"
      "vendor/google/bramble https://github.com/TheMuppets/proprietary_vendor_google_bramble.git https://github.com/TheMuppets/proprietary_vendor_google_bramble.git"
      "kernel/google/redbull https://github.com/Bias8145/android_kernel_google_redbull.git https://github.com/LineageOS/android_kernel_google_redbull.git"
    )
    
    local all_configured=true
    for component in "${components[@]}"; do
      read -r path custom_repo official_repo <<< "$component"
      
      if [[ -z "${SELECTED_REPOS[$path]:-}" ]]; then
        if ! choose_repo_and_branch_interactive "$path" "$custom_repo" "$official_repo"; then
          if [[ $? -eq 254 ]]; then
            return 254  # Back to device selection
          else
            all_configured=false
            break
          fi
        fi
      fi
    done
    
    if [[ "$all_configured" == true ]]; then
      # Ask about KernelSU option
      if [[ -z "$KERNELSU_OPTION" ]]; then
        echo -e "\n${YELLOW}━━━ KernelSU Configuration ━━━${RESET}"
        ask_confirm_with_back "Apply KernelSU-Next + SUSFS patch for redbull kernel?" "y"
        case $? in
          0) KERNELSU_OPTION="yes" ;;
          1) KERNELSU_OPTION="no" ;;
          2) continue ;;  # Back to configuration
        esac
      fi
      break
    fi
  done
  
  return 0
}

configure_coral() {
  SELECTED_DEVICE="Coral (Pixel 4 XL)"
  
  while true; do
    show_header "$SELECTED_DEVICE" "Configuration"
    
    local components=(
      "device/google/coral https://github.com/Bias8145/android_device_google_coral.git https://github.com/LineageOS/android_device_google_coral.git"
      "device/google/gs-common https://github.com/Bias8145/android_device_google_gs-common.git https://github.com/LineageOS/android_device_google_gs-common.git"
      "vendor/google/coral https://github.com/TheMuppets/proprietary_vendor_google_coral.git https://github.com/TheMuppets/proprietary_vendor_google_coral.git"
      "kernel/google/msm-4.14 https://github.com/Bias8145/android_kernel_google_msm-4.14.git https://github.com/LineageOS/android_kernel_google_msm-4.14.git"
    )
    
    local all_configured=true
    for component in "${components[@]}"; do
      read -r path custom_repo official_repo <<< "$component"
      
      if [[ -z "${SELECTED_REPOS[$path]:-}" ]]; then
        if ! choose_repo_and_branch_interactive "$path" "$custom_repo" "$official_repo"; then
          if [[ $? -eq 254 ]]; then
            return 254
          else
            all_configured=false
            break
          fi
        fi
      fi
    done
    
    [[ "$all_configured" == true ]] && break
  done
  
  return 0
}

configure_flame() {
  SELECTED_DEVICE="Flame (Pixel 4)"
  
  while true; do
    show_header "$SELECTED_DEVICE" "Configuration"
    
    local components=(
      "device/google/coral https://github.com/Bias8145/android_device_google_coral.git https://github.com/LineageOS/android_device_google_coral.git"
      "device/google/gs-common https://github.com/Bias8145/android_device_google_gs-common.git https://github.com/LineageOS/android_device_google_gs-common.git"
      "vendor/google/flame https://github.com/TheMuppets/proprietary_vendor_google_flame.git https://github.com/TheMuppets/proprietary_vendor_google_flame.git"
      "kernel/google/msm-4.14 https://github.com/Bias8145/android_kernel_google_msm-4.14.git https://github.com/LineageOS/android_kernel_google_msm-4.14.git"
    )
    
    local all_configured=true
    for component in "${components[@]}"; do
      read -r path custom_repo official_repo <<< "$component"
      
      if [[ -z "${SELECTED_REPOS[$path]:-}" ]]; then
        if ! choose_repo_and_branch_interactive "$path" "$custom_repo" "$official_repo"; then
          if [[ $? -eq 254 ]]; then
            return 254
          else
            all_configured=false
            break
          fi
        fi
      fi
    done
    
    [[ "$all_configured" == true ]] && break
  done
  
  return 0
}

configure_sunfish() {
  SELECTED_DEVICE="Sunfish (Pixel 4a)"
  
  while true; do
    show_header "$SELECTED_DEVICE" "Configuration"
    
    local components=(
      "device/google/sunfish https://github.com/Bias8145/android_device_google_sunfish.git https://github.com/LineageOS/android_device_google_sunfish.git"
      "device/google/gs-common https://github.com/Bias8145/android_device_google_gs-common.git https://github.com/LineageOS/android_device_google_gs-common.git"
      "vendor/google/sunfish https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git https://github.com/TheMuppets/proprietary_vendor_google_sunfish.git"
      "kernel/google/msm-4.14 https://github.com/Bias8145/android_kernel_google_msm-4.14.git https://github.com/LineageOS/android_kernel_google_msm-4.14.git"
    )
    
    local all_configured=true
    for component in "${components[@]}"; do
      read -r path custom_repo official_repo <<< "$component"
      
      if [[ -z "${SELECTED_REPOS[$path]:-}" ]]; then
        if ! choose_repo_and_branch_interactive "$path" "$custom_repo" "$official_repo"; then
          if [[ $? -eq 254 ]]; then
            return 254
          else
            all_configured=false
            break
          fi
        fi
      fi
    done
    
    [[ "$all_configured" == true ]] && break
  done
  
  return 0
}

# Main execution flow
main() {
  while true; do
    # Device selection
    if [[ -z "$SELECTED_DEVICE" ]]; then
      local devices=("Bramble (Pixel 4a 5G)" "Coral (Pixel 4 XL)" "Flame (Pixel 4)" "Sunfish (Pixel 4a)")
      select_menu_with_back "Select device to configure:" "${devices[@]}"
      local device_choice=$?
      
      case $device_choice in
        254) echo -e "${YELLOW}[EXIT] No device selected.${RESET}"; exit 0 ;;
        0) if ! configure_bramble; then [[ $? -eq 254 ]] && continue; fi ;;
        1) if ! configure_coral; then [[ $? -eq 254 ]] && continue; fi ;;
        2) if ! configure_flame; then [[ $? -eq 254 ]] && continue; fi ;;
        3) if ! configure_sunfish; then [[ $? -eq 254 ]] && continue; fi ;;
      esac
    fi
    
    # Show review and get confirmation
    if show_final_review; then
      execute_cloning
      break
    else
      # User wants to modify - reset selections
      SELECTED_REPOS=()
      SELECTED_BRANCHES=()
      SELECTED_DEVICE=""
      KERNELSU_OPTION=""
    fi
  done
}

# Start the script
main
