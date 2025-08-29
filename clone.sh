#!/bin/bash

# Terminal Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
BLUE="\033[0;34m"
BOLD="\033[1m"
RESET="\033[0m"
MAGENTA="\033[0;35m"

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

# Function: Get repository info (URL and branch) from existing directory
get_existing_repo_info() {
  local target_dir="$1"
  local repo_url=""
  local repo_branch=""
  
  if [[ -d "$target_dir/.git" ]]; then
    pushd "$target_dir" > /dev/null 2>&1
    repo_url=$(git config --get remote.origin.url 2>/dev/null || echo "Unknown")
    repo_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "Unknown")
    popd > /dev/null 2>&1
  fi
  
  echo "$repo_url|$repo_branch"
}

# Function: Check if directory exists and show info
check_existing_directory() {
  local target_dir="$1"
  local component_name=$(basename "$target_dir")
  
  if [[ -d "$target_dir" ]]; then
    local info=$(get_existing_repo_info "$target_dir")
    local current_url=$(echo "$info" | cut -d'|' -f1)
    local current_branch=$(echo "$info" | cut -d'|' -f2)
    
    echo -e "\n${YELLOW}[WARNING] Directory already exists: $target_dir${RESET}"
    echo -e "${MAGENTA}Existing Repository Info:${RESET}"
    echo -e "  └─ URL: ${CYAN}$current_url${RESET}"
    echo -e "  └─ Branch: ${CYAN}$current_branch${RESET}"
    
    return 0
  fi
  
  return 1
}

# Function: Handle existing directory options (used in clone phase)
handle_existing_directory() {
  local target_dir="$1"
  local new_repo="$2"
  local new_branch="$3"
  local component_name=$(basename "$target_dir")
  
  local info=$(get_existing_repo_info "$target_dir")
  local current_url=$(echo "$info" | cut -d'|' -f1)
  local current_branch=$(echo "$info" | cut -d'|' -f2)
  
  # Check if same repo and branch
  if [[ "$current_url" == "$new_repo" && "$current_branch" == "$new_branch" ]]; then
    echo -e "${GREEN}[MATCH] Same repository and branch detected. No action needed.${RESET}"
    return 0  # Skip clone
  fi
  
  echo -e "\n${YELLOW}Repository/Branch mismatch detected!${RESET}"
  echo -e "${CYAN}Current:${RESET} $current_url (branch: $current_branch)"
  echo -e "${CYAN}Target:${RESET}  $new_repo (branch: $new_branch)"
  
  while true; do
    echo -e "\n${YELLOW}What would you like to do?${RESET}"
    echo "1) Remove existing and clone new repository"
    echo "2) Keep existing repository (skip clone)"
    echo "3) Back to repository selection"
    
    read -rp "Your choice [1-3]: " choice
    case $choice in
      1)
        echo -e "${BLUE}[ACTION] Removing existing directory...${RESET}"
        if rm -rf "$target_dir"; then
          echo -e "${GREEN}[SUCCESS] Directory removed successfully${RESET}"
          return 1  # Proceed with clone
        else
          echo -e "${RED}[ERROR] Failed to remove directory${RESET}"
          return 2  # Error
        fi
        ;;
      2)
        echo -e "${YELLOW}[SKIP] Keeping existing repository${RESET}"
        return 0  # Skip clone
        ;;
      3)
        return 3  # Back to selection
        ;;
      *)
        echo -e "${RED}Invalid choice. Please enter 1, 2, or 3.${RESET}"
        ;;
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

# Function: Choose repo+branch; if preferred exists, auto-select, else interactive
choose_repo_branch_with_default() {
  local path="$1"
  local preferred_repo="$2"
  local fallback_repo="$3"
  local preferred_branch="$4"
  local component_name
  component_name=$(basename "$path")

  # If dir exists, show/handle as usual via choose_repo_and_branch_interactive
  if [[ -d "$path" ]]; then
    choose_repo_and_branch_interactive "$path" "$preferred_repo" "$fallback_repo"
    return $?
  fi

  # Try preferred repo+branch
  if git ls-remote --heads "$preferred_repo" "$preferred_branch" &>/dev/null; then
    SELECTED_REPOS["$path"]="$preferred_repo"
    SELECTED_BRANCHES["$path"]="$preferred_branch"
    echo -e "${GREEN}[AUTO] $component_name → $preferred_repo ($preferred_branch)${RESET}"
    return 0
  fi

  # Try fallback repo (let user choose branch)
  echo -e "${YELLOW}[WARN] Preferred branch '$preferred_branch' not found for $component_name. Switching to interactive selection.${RESET}"
  choose_repo_and_branch_interactive "$path" "$preferred_repo" "$fallback_repo"
}

# Function: Choose repo and branch with confirmation and existing directory handling
choose_repo_and_branch_interactive() {
  local path=$1
  local custom_repo=$2
  local official_repo=$3
  local component_name=$(basename "$path")

  while true; do
    echo -e "\n${YELLOW}━━━ Configuring: $component_name ━━━${RESET}"
    echo -e "Component path: ${BOLD}$path${RESET}"
    
    # Check if directory already exists and show info
    local existing=false
    if check_existing_directory "$path"; then
      existing=true
      local info=$(get_existing_repo_info "$path")
      local current_url=$(echo "$info" | cut -d'|' -f1)
      local current_branch=$(echo "$info" | cut -d'|' -f2)
      
      # Prompt for existing directory handling
      echo -e "\n${YELLOW}Directory already exists. What would you like to do?${RESET}"
      echo "1) Replace with new repository"
      echo "2) Keep existing repository (skip clone)"
      echo "3) Back to repository selection"
      
      read -rp "Your choice [1-3]: " choice
      case $choice in
        1)
          # Proceed to repository selection for replacement
          ;;
        2)
          # Keep existing - store current info
          SELECTED_REPOS["$path"]="$current_url"
          SELECTED_BRANCHES["$path"]="$current_branch"
          echo -e "${GREEN}[✓] Keeping existing repository for $component_name${RESET}"
          return 0
          ;;
        3)
          return 254  # Back to previous menu
          ;;
        *)
          echo -e "${RED}Invalid choice. Please enter 1, 2, or 3.${RESET}"
          continue
          ;;
      esac
    fi
    
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
        # If directory exists and we're replacing, confirm removal
        if [[ "$existing" == true ]]; then
          echo -e "\n${YELLOW}[WARNING] This will remove the existing directory: $path${RESET}"
          ask_confirm_with_back "Proceed with replacing the existing repository?" "y"
          local confirm_result=$?
          case $confirm_result in
            0)
              # Proceed with removal and new clone
              echo -e "${BLUE}[ACTION] Removing existing directory...${RESET}"
              if ! rm -rf "$path"; then
                echo -e "${RED}[ERROR] Failed to remove directory${RESET}"
                continue
              fi
              echo -e "${GREEN}[SUCCESS] Existing directory removed${RESET}"
              ;;
            1) continue ;;  # Try again
            2) break ;;     # Back to repo selection
          esac
        fi
        
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

# Function: Clone repo with progress simulation and existing directory handling
clone_repo_with_progress() {
  local repo_url=$1
  local target_dir=$2
  local branch=$3
  local component_name=$(basename "$target_dir")

  echo -e "${BLUE}[INFO] Selected repository: $repo_url${RESET}"
  echo -e "${BLUE}[INFO] Selected branch: $branch${RESET}"
  echo -e "${BLUE}[ACTION] Cloning to $target_dir...${RESET}"

  # Check if directory already exists
  if [[ -d "$target_dir" ]]; then
    local info=$(get_existing_repo_info "$target_dir")
    local current_url=$(echo "$info" | cut -d'|' -f1)
    local current_branch=$(echo "$info" | cut -d'|' -f2)

    if [[ "$current_url" == "$repo_url" && "$current_branch" == "$branch" ]]; then
      echo -e "${GREEN}[SKIP] Repository already up to date${RESET}"
      return 0
    else
      echo -e "${YELLOW}[WARNING] Directory exists with different repo/branch${RESET}"
      echo -e "${CYAN}Current:${RESET} $current_url (branch: $current_branch)"
      echo -e "${CYAN}Target:${RESET}  $repo_url (branch: $branch)"
      
      # Safety handler
      while true; do
        echo -e "\n${YELLOW}What would you like to do?${RESET}"
        echo "1) Remove existing and clone new repository"
        echo "2) Skip this clone"
        
        read -rp "Your choice [1-2]: " choice
        case $choice in
          1)
            echo -e "${BLUE}[ACTION] Removing existing directory...${RESET}"
            if ! rm -rf "$target_dir"; then
              echo -e "${RED}[ERROR] Failed to remove directory${RESET}"
              return 1
            fi
            break
            ;;
          2)
            echo -e "${YELLOW}[SKIP] Clone skipped by user${RESET}"
            return 0
            ;;
          *)
            echo -e "${RED}Invalid choice. Please enter 1 or 2.${RESET}"
            ;;
        esac
      done
    fi
  fi

  # Validate repository access
  if ! git ls-remote "$repo_url" &> /dev/null; then
    echo -e "${RED}[✘] Cannot access $repo_url. Check the connection or URL.${RESET}"
    return 1
  fi

  # Simulate progress
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

# Function: Show final review and confirm with existing repo info
show_final_review() {
  echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e " === CONFIGURATION REVIEW ==="
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  
  echo -e "\n${CYAN}Selected Device: ${BOLD}$SELECTED_DEVICE${RESET}"
  
  if [[ -n "$KERNELSU_OPTION" ]]; then
    echo -e "${CYAN}KernelSU Option: ${BOLD}$KERNELSU_OPTION${RESET}"
  fi
  
  echo -e "\n${CYAN}Repositories to be processed:${RESET}"
  for path in "${!SELECTED_REPOS[@]}"; do
    local repo="${SELECTED_REPOS[$path]}"
    local branch="${SELECTED_BRANCHES[$path]}"
    local component=$(basename "$path")
    
    # Check if directory exists and determine action
    local action="CLONE"
    local status_color="$GREEN"
    
    if [[ -d "$path" ]]; then
      local info=$(get_existing_repo_info "$path")
      local current_url=$(echo "$info" | cut -d'|' -f1)
      local current_branch=$(echo "$info" | cut -d'|' -f2)
      
      if [[ "$current_url" == "$repo" && "$current_branch" == "$branch" ]]; then
        action="SKIP (Already exists)"
        status_color="$YELLOW"
      else
        action="REPLACE (Different repo/branch)"
        status_color="$MAGENTA"
      fi
    fi
    
    echo -e "  ${YELLOW}├─ $component ${status_color}[$action]${RESET}"
    echo -e "  │  Path: $path"
    echo -e "  │  Repo: $repo"
    echo -e "  │  Branch: $branch"
    echo
  done
  
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  
  while true; do
    echo -e "\nOptions:"
    echo "1) Proceed with cloning as planned"
    echo "2) Skip cloning (configuration only)"
    echo "3) Modify selections"
    echo "4) Cancel"
    
    read -rp "Your choice [1-4]: " choice
    case $choice in
      1) return 0 ;;     # Proceed with cloning
      2) return 2 ;;     # Skip cloning
      3) return 1 ;;     # Modify
      4) exit 0 ;;       # Cancel
      *) echo -e "${RED}Invalid choice. Please enter 1, 2, 3, or 4.${RESET}" ;;
    esac
  done
}

# Function: Execute cloning process with enhanced handling
execute_cloning() {
  local rom_type="LineageOS"
  
  echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e " === Android Source Repo Cloner ==="
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  
  echo -e "\n${BLUE}[INFO] Detected ROM: $rom_type${RESET}"
  
  show_header "$SELECTED_DEVICE" "Cloning"
  
  local failed_repos=()
  local successful_repos=()
  local skipped_repos=()
  local replaced_repos=()
  
  # Clone each repository
  for path in "${!SELECTED_REPOS[@]}"; do
    local repo="${SELECTED_REPOS[$path]}"
    local branch="${SELECTED_BRANCHES[$path]}"
    local component_name=$(basename "$path")
    
    # Check if directory exists and determine action needed
    if [[ -d "$path" ]]; then
      local info=$(get_existing_repo_info "$path")
      local current_url=$(echo "$info" | cut -d'|' -f1)
      local current_branch=$(echo "$info" | cut -d'|' -f2)
      
      if [[ "$current_url" == "$repo" && "$current_branch" == "$branch" ]]; then
        echo -e "${YELLOW}[SKIP] $component_name - Already up to date${RESET}"
        skipped_repos+=("$path")
        continue
      else
        echo -e "${MAGENTA}[REPLACE] $component_name - Different repo/branch detected${RESET}"
        replaced_repos+=("$path")
      fi
    fi
    
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
    
    if setup_kernelsu_susfs_redbull; then
      echo -e "${GREEN}[SUCCESS] KernelSU-Next + SUSFS setup completed${RESET}"
    else
      echo -e "${RED}[ERROR] KernelSU-Next + SUSFS setup failed${RESET}"
    fi
  fi
  
  # Final summary with detailed statistics
  echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e " === EXECUTION SUMMARY ==="
  echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  
  local total_repos=${#SELECTED_REPOS[@]}
  local success_count=${#successful_repos[@]}
  local skip_count=${#skipped_repos[@]}
  local replace_count=${#replaced_repos[@]}
  local fail_count=${#failed_repos[@]}
  
  echo -e "\n${CYAN}Statistics:${RESET}"
  echo -e "  Total repositories: $total_repos"
  echo -e "  ${GREEN}Successfully cloned: $success_count${RESET}"
  echo -e "  ${YELLOW}Skipped (up-to-date): $skip_count${RESET}"
  echo -e "  ${MAGENTA}Replaced: $replace_count${RESET}"
  echo -e "  ${RED}Failed: $fail_count${RESET}"
  
  if [[ ${#successful_repos[@]} -gt 0 ]]; then
    echo -e "\n${GREEN}Successfully processed:${RESET}"
    for repo in "${successful_repos[@]}"; do
      echo -e "  ✓ $(basename "$repo")"
    done
  fi
  
  if [[ ${#skipped_repos[@]} -gt 0 ]]; then
    echo -e "\n${YELLOW}Skipped repositories:${RESET}"
    for repo in "${skipped_repos[@]}"; do
      echo -e "  ⊝ $(basename "$repo")"
    done
  fi
  
  if [[ ${#failed_repos[@]} -gt 0 ]]; then
    echo -e "\n${RED}Failed repositories:${RESET}"
    for repo in "${failed_repos[@]}"; do
      echo -e "  ✗ $(basename "$repo")"
    done
  fi
  
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  
  # Overall result
  if [[ ${#failed_repos[@]} -eq 0 ]]; then
    echo -e "\n${GREEN}[SUCCESS] Process completed successfully!${RESET}"
  elif [[ ${#successful_repos[@]} -gt 0 ]]; then
    echo -e "\n${YELLOW}[PARTIAL SUCCESS] Process completed with some issues${RESET}"
  else
    echo -e "\n${RED}[FAILURE] Process failed${RESET}"
  fi
  
  echo -e "\n${BLUE}[INFO] You can now proceed with your ROM build.${RESET}"
}

# Enhanced KernelSU-Next + SUSFS patch for redbull with better error handling
setup_kernelsu_susfs_redbull() {
  local kernel_dir="kernel/google/redbull"
  
  echo -e "\n${YELLOW}=== Setting up KernelSU-Next + SUSFS for Redbull Kernel ===${RESET}"
  
  if [[ ! -d "$kernel_dir" ]]; then
    echo -e "${RED}[✘] Kernel directory not found: $kernel_dir${RESET}"
    echo -e "${YELLOW}[INFO] Make sure the redbull kernel is cloned first.${RESET}"
    return 1
  fi

  echo ">>> [1/9] Entering directory $kernel_dir"
  if ! cd "$kernel_dir"; then
    echo -e "${RED}[✘] Failed to enter directory: $kernel_dir${RESET}"
    return 1
  fi

  echo ">>> [2/9] Downloading KernelSU-Next v1.0.3"
  if ! curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next/kernel/setup.sh" | bash -s v1.0.3; then
    echo -e "${RED}[✘] Failed to download/setup KernelSU-Next${RESET}"
    return 1
  fi

  echo ">>> [3/9] Entering KernelSU-Next directory"
  if ! cd KernelSU-Next; then
    echo -e "${RED}[✘] KernelSU-Next directory not found${RESET}"
    return 1
  fi

  echo ">>> [4/9] Downloading SUSFS patch v1.5.3"
  if ! curl -o 0001-Kernel-Implement-SUSFS-v1.5.3.patch https://github.com/sidex15/KernelSU-Next/commit/1e750de25930e875612bbec0410de0088474c00b.patch; then
    echo -e "${RED}[✘] Failed to download SUSFS patch${RESET}"
    return 1
  fi
  
  if [[ ! -s 0001-Kernel-Implement-SUSFS-v1.5.3.patch ]]; then
    echo -e "${RED}[✘] SUSFS patch file is empty or invalid${RESET}"
    return 1
  fi

  echo ">>> [5/9] Applying SUSFS patch to KernelSU-Next"
  if ! patch -p1 < 0001-Kernel-Implement-SUSFS-v1.5.3.patch; then
    echo -e "${RED}[✘] Failed to apply SUSFS patch${RESET}"
    return 1
  fi

  echo ">>> [6/9] Returning to redbull kernel root"
  cd ..

  echo ">>> [7/9] Cloning SUSFS for kernel 4.19"
  if [[ -d "susfs4ksu" ]]; then
    echo -e "${YELLOW}[INFO] SUSFS directory already exists, removing...${RESET}"
    rm -rf susfs4ksu
  fi
  
  if ! git clone https://gitlab.com/simonpunk/susfs4ksu.git -b kernel-4.19; then
    echo -e "${RED}[✘] Failed to clone SUSFS repository${RESET}"
    return 1
  fi

  echo ">>> [8/9] Copying fs/ and include/linux/ files"
  if ! cp -v susfs4ksu/kernel_patches/fs/* fs/ 2>/dev/null; then
    echo -e "${RED}[✘] Failed to copy fs/ files${RESET}"
    return 1
  fi
  
  if ! cp -v susfs4ksu/kernel_patches/include/linux/* include/linux/ 2>/dev/null; then
    echo -e "${RED}[✘] Failed to copy include/linux/ files${RESET}"
    return 1
  fi

  echo ">>> [9/9] Applying 50_add_susfs_in_kernel-4.19.patch"
  if ! cp -v susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch .; then
    echo -e "${RED}[✘] Failed to copy kernel patch${RESET}"
    return 1
  fi
  
  if ! patch -p1 < 50_add_susfs_in_kernel-4.19.patch; then
    echo -e "${RED}[✘] Failed to apply kernel patch${RESET}"
    return 1
  fi

  # Cleanup
  echo ">>> [CLEANUP] Removing temporary files"
  rm -rf susfs4ksu

  echo -e "${GREEN}>>> ✅ Done! KernelSU-Next + SUSFS has been successfully applied.${RESET}"
  return 0
}

# Device configuration functions with enhanced existing directory handling
configure_bramble() {
  SELECTED_DEVICE="Bramble (Pixel 4a 5G)"
  
  while true; do
    show_header "$SELECTED_DEVICE" "Configuration"
    
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
      if [[ -z "$KERNELSU_OPTION" ]]; then
        echo -e "\n${YELLOW}━━━ KernelSU Configuration ━━━${RESET}"
        ask_confirm_with_back "Apply KernelSU-Next + SUSFS patch for redbull kernel?" "y"
        case $? in
          0) KERNELSU_OPTION="yes" ;;
          1) KERNELSU_OPTION="no" ;;
          2) continue ;;
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

# === NEW: Raviole (Pixel 6/Pro) ===
configure_raviole() {
  SELECTED_DEVICE="Raviole (Pixel 6/Pro)"
  while true; do
    show_header "$SELECTED_DEVICE" "Configuration"

    # path | preferred_repo | fallback_repo | preferred_branch
    choose_repo_branch_with_default \
      "device/google/raviole" \
      "https://github.com/xioyo/android_device_google_raviole.git" \
      "https://github.com/LineageOS/android_device_google_raviole.git" \
      "android16" || return $?

    choose_repo_branch_with_default \
      "device/google/gs101" \
      "https://github.com/xioyo/android_device_google_gs101.git" \
      "https://github.com/LineageOS/android_device_google_gs101.git" \
      "sixteen" || return $?

    choose_repo_branch_with_default \
      "device/google/gs-common" \
      "https://github.com/LineageOS/android_device_google_gs-common.git" \
      "https://github.com/LineageOS/android_device_google_gs-common.git" \
      "lineage-23.0" || return $?

    choose_repo_branch_with_default \
      "vendor/google/oriole" \
      "https://github.com/xioyo/proprietary_vendor_google_oriole.git" \
      "https://github.com/TheMuppets/proprietary_vendor_google_oriole.git" \
      "lineage-23.0" || return $?

    choose_repo_branch_with_default \
      "vendor/google/raven" \
      "https://github.com/TheMuppets/proprietary_vendor_google_raven.git" \
      "https://github.com/TheMuppets/proprietary_vendor_google_raven.git" \
      "lineage-23.0" || return $?

    choose_repo_branch_with_default \
      "device/google/raviole-kernels/lineage" \
      "https://git.evolution-x.org/Evolution-X-Tensor/device_google_raviole-kernels_evolution.git" \
      "https://git.evolution-x.org/Evolution-X-Tensor/device_google_raviole-kernels_evolution.git" \
      "bka" || return $?

    choose_repo_branch_with_default \
      "packages/apps/PixelParts" \
      "https://github.com/Evolution-X-Devices/packages_apps_PixelParts.git" \
      "https://github.com/LineageOS/android_packages_apps_PixelParts.git" \
      "bka" || return $?

    break
  done
  return 0
}

# Enhanced main execution flow
main() {
  while true; do
    # Device selection
    if [[ -z "$SELECTED_DEVICE" ]]; then
      local devices=("Bramble (Pixel 4a 5G)" "Coral (Pixel 4 XL)" "Flame (Pixel 4)" "Sunfish (Pixel 4a)" "Raviole (Pixel 6/Pro)")
      select_menu_with_back "Select device to configure:" "${devices[@]}"
      local device_choice=$?
      
      case $device_choice in
        254) echo -e "${YELLOW}[EXIT] No device selected.${RESET}"; exit 0 ;;
        0) if ! configure_bramble; then [[ $? -eq 254 ]] && continue; fi ;;
        1) if ! configure_coral; then [[ $? -eq 254 ]] && continue; fi ;;
        2) if ! configure_flame; then [[ $? -eq 254 ]] && continue; fi ;;
        3) if ! configure_sunfish; then [[ $? -eq 254 ]] && continue; fi ;;
        4) if ! configure_raviole; then [[ $? -eq 254 ]] && continue; fi ;;
      esac
    fi
    
    # Show review and get confirmation
    show_final_review
    local review_result=$?
    if [[ $review_result -eq 0 ]]; then
      execute_cloning
      break
    elif [[ $review_result -eq 2 ]]; then
      echo -e "\n${YELLOW}[SKIP] Cloning skipped. Configuration completed.${RESET}"
      break
    else
      # User wants to modify - reset selections
      unset SELECTED_REPOS
      declare -A SELECTED_REPOS
      unset SELECTED_BRANCHES
      declare -A SELECTED_BRANCHES
      SELECTED_DEVICE=""
      KERNELSU_OPTION=""
    fi
  done
}

# Start the script
main