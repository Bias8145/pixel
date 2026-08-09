#!/usr/bin/env bash
# Bias8145 Android Source Cloner
# High-flexibility per-tree source/branch selection.
# Interactive associative-array lookups are intentionally run without nounset.
set +u
set -Eo pipefail

readonly C_RESET='\033[0m' C_BOLD='\033[1m' C_CYAN='\033[0;36m' C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m' C_YELLOW='\033[1;33m' C_BLUE='\033[0;34m'

declare -A REPO BRANCH SOURCE
DEVICE=""; DRY_RUN=0; MENU_CHOICE=""; SELECTED_BRANCH=""

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo -e "${C_RED}[ERROR] Missing: $1${C_RESET}"; exit 1; }; }
need_cmd git; need_cmd curl

menu() {
  local title="$1"; shift; local -a opts=("$@"); local i ans
  MENU_CHOICE=""
  while :; do
    echo -e "\n${C_CYAN}${title}${C_RESET}"
    for i in "${!opts[@]}"; do echo "$((i+1))) ${opts[i]}"; done
    echo "b) Back"; echo "q) Quit"
    read -r -p "> " ans || { echo; MENU_CHOICE=254; return 0; }
    case "$ans" in
      [0-9]*) if ((ans>=1 && ans<=${#opts[@]})); then MENU_CHOICE=$((ans-1)); return 0; fi ;;
      b|B) MENU_CHOICE=254; return 0;; q|Q) exit 0;;
    esac
    echo -e "${C_RED}Invalid choice.${C_RESET}"
  done
}

normalize_url() { local u="${1%.git}"; echo "${u%/}"; }
valid_path() { [[ "$1" != /* && "$1" != *..* && "$1" =~ ^[A-Za-z0-9._/-]+$ ]]; }

list_branches() {
  local url="$1"; local -a out=()
  mapfile -t out < <(git ls-remote --heads "$url" 2>/dev/null | awk '{sub("refs/heads/","",$2); print $2}' | sort -V)
  ((${#out[@]})) || return 1
  printf '%s\n' "${out[@]}"
}

pick_branch() {
  local url="$1" component="$2"; local -a bs=(); local i ans
  mapfile -t bs < <(list_branches "$url") || { echo -e "${C_RED}[ERROR] Cannot read branches: $url${C_RESET}"; return 1; }
  echo -e "${C_CYAN}Branches for ${component}:${C_RESET}"
  for i in "${!bs[@]}"; do echo "$((i+1))) ${bs[i]}"; done
  echo "m) Manual branch/tag/ref"; echo "b) Back"
  while :; do
    read -r -p "> " ans || return 254
    case "$ans" in
      [0-9]*) if ((ans>=1 && ans<=${#bs[@]})); then SELECTED_BRANCH="${bs[ans-1]}"; return 0; fi ;;
      m|M) read -r -p "Branch/tag/ref: " SELECTED_BRANCH || return 254; [[ -n "$SELECTED_BRANCH" ]] && return 0;;
      b|B) return 254;;
    esac
    echo -e "${C_RED}Invalid branch.${C_RESET}"
  done
}

# Explicit GrapheneOS mappings. Do not derive these names from target paths.
graphene_repo_for() {
  case "$1" in
    device/google/raviole) echo "https://github.com/GrapheneOS/device_google_raviole.git";;
    device/google/gs101) echo "https://github.com/GrapheneOS/device_google_gs101.git";;
    device/google/gs-common) echo "https://github.com/GrapheneOS/device_google_gs-common.git";;
    device/google/zuma) echo "https://github.com/GrapheneOS/device_google_zuma.git";;
    device/google/raviole-kernels/6.1) echo "https://github.com/GrapheneOS/device_google_raviole-kernels_6.1.git";;
    *) return 1;;
  esac
}

repo_name_for() {
  local source="$1" path="$2" p="${2//\//_}"
  case "$source" in
    LineageOS|Bias8145) echo "https://github.com/${source}/android_${p}.git";;
    GrapheneOS) graphene_repo_for "$path";;
    TheMuppets) echo "https://github.com/TheMuppets/proprietary_${p}.git";;
  esac
}

source_repo() {
  local path="$1" component="${1##*/}" choice repo source
  while :; do
    menu "Source for ${path}" "LineageOS official" "GrapheneOS official" "Bias8145/custom source" "TheMuppets vendor source" "Manual repository URL"
    choice="$MENU_CHOICE"
    case "$choice" in
      254) return 254;;
      0) repo="$(repo_name_for LineageOS "$path")"; source="LineageOS";;
      1) repo="$(repo_name_for GrapheneOS "$path")" || { echo -e "${C_YELLOW}[WARN] No explicit GrapheneOS mapping for $path. Use Manual repository URL.${C_RESET}"; continue; }; source="GrapheneOS";;
      2) repo="$(repo_name_for Bias8145 "$path")"; source="Bias8145";;
      3) repo="$(repo_name_for TheMuppets "$path")"; source="TheMuppets";;
      4) read -r -p "Repository URL: " repo || return 254; source="Custom";;
      *) continue;;
    esac
    [[ -n "$repo" ]] || continue
    if ! git ls-remote --heads "$repo" >/dev/null 2>&1; then echo -e "${C_YELLOW}[WARN] Repository unavailable: $repo${C_RESET}"; continue; fi
    pick_branch "$repo" "$component" || continue
    echo -e "${C_GREEN}Selected:${C_RESET} $source | $repo | $SELECTED_BRANCH"
    menu "Confirm ${path}" "Confirm" "Choose another source" "Choose another branch"
    case "$MENU_CHOICE" in
      0) REPO["$path"]="$repo"; BRANCH["$path"]="$SELECTED_BRANCH"; SOURCE["$path"]="$source"; return 0;;
      1) continue;; 2) pick_branch "$repo" "$component" || continue;; 254) return 254;;
    esac
  done
}

add_component() {
  local path="$1"
  valid_path "$path" || { echo -e "${C_RED}[ERROR] Invalid target path: $path${C_RESET}"; return 1; }
  source_repo "$path"
}

discover_dependencies() {
  local path="$1" url="${REPO[$path]-}" branch="${BRANCH[$path]-}" raw tmp repo_path
  [[ -n "$url" && -n "$branch" ]] || return 0
  repo_path="${url#https://github.com/}"; repo_path="${repo_path%.git}"
  raw="https://raw.githubusercontent.com/${repo_path}/${branch}/lineage.dependencies"
  tmp="$(curl -fsSL "$raw" 2>/dev/null || true)"; [[ -n "$tmp" ]] || return 0
  echo "$tmp" | sed -n 's/.*"repository":[[:space:]]*"\([^"]*\)".*"target_path":[[:space:]]*"\([^"]*\)".*/\1|\2/p'
}

clone_one() {
  local path="$1"
  local url="${REPO[$path]-}" branch="${BRANCH[$path]-}" current_url current_branch
  [[ -n "$path" && -n "$url" && -n "$branch" ]] || { echo -e "${C_RED}[ERROR] Invalid clone entry.${C_RESET}"; return 1; }
  echo -e "${C_BLUE}[CLONE]${C_RESET} $url [$branch] -> $path"
  if ((DRY_RUN)); then echo "       git clone --depth=1 -b '$branch' '$url' '$path'"; return 0; fi
  if [[ -d "$path/.git" ]]; then
    current_url="$(git -C "$path" remote get-url origin 2>/dev/null || true)"; current_branch="$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null || true)"
    if [[ "$(normalize_url "$current_url")" == "$(normalize_url "$url")" && "$current_branch" == "$branch" ]]; then echo -e "${C_YELLOW}[SKIP] Already matches.${C_RESET}"; return 2; fi
    menu "Existing repository" "Keep existing" "Remove and clone selected" "Cancel"
    case "$MENU_CHOICE" in 0) return 2;; 1) rm -rf -- "$path";; 2|254) return 3;; esac
  elif [[ -e "$path" ]]; then echo -e "${C_RED}[ERROR] Target exists and is not a Git repository: $path${C_RESET}"; return 1; fi
  mkdir -p "$(dirname "$path")"; git clone --depth=1 --branch "$branch" --single-branch "$url" "$path"
}

show_config() {
  local p; echo -e "\n${C_BOLD}========== FINAL CONFIGURATION ==========${C_RESET}"; echo "Device: $DEVICE"
  for p in "${!REPO[@]}"; do printf '  %-42s %-12s %s [%s]\n' "$p" "${SOURCE[$p]}" "${BRANCH[$p]}" "${REPO[$p]}"; done | sort
  echo -e "${C_BOLD}==========================================${C_RESET}"
}

configure_pixel() {
  local codename="$1" p rc; DEVICE="$codename"; REPO=(); BRANCH=(); SOURCE=(); local -a defaults=()
  case "$codename" in
    bramble) defaults=("device/google/bramble" "device/google/redbull" "device/google/gs-common" "vendor/google/bramble" "kernel/google/redbull");;
    coral) defaults=("device/google/coral" "device/google/gs-common" "vendor/google/coral" "kernel/google/msm-4.14");;
    flame) defaults=("device/google/coral" "device/google/gs-common" "vendor/google/flame" "kernel/google/msm-4.14");;
    sunfish) defaults=("device/google/sunfish" "device/google/gs-common" "vendor/google/sunfish" "kernel/google/msm-4.14");;
    redfin) defaults=("device/google/redfin" "device/google/redbull" "device/google/gs-common" "vendor/google/redfin" "kernel/google/redbull");;
    oriole) defaults=("device/google/raviole" "device/google/gs101" "device/google/gs-common" "device/google/zuma" "device/google/raviole-kernels/6.1" "vendor/google/oriole");;
    raven) defaults=("device/google/raviole" "device/google/gs101" "device/google/gs-common" "device/google/zuma" "device/google/raviole-kernels/6.1" "vendor/google/raven");;
    *) return 1;;
  esac
  echo -e "\n${C_BOLD}${C_CYAN}Every component is independent.${C_RESET}"; echo "Mix LineageOS, GrapheneOS, Bias8145, TheMuppets and manual repositories as desired."; echo "Each component has its own repository and branch selection."
  for p in "${defaults[@]}"; do add_component "$p"; rc=$?; case "$rc" in 0) ;; 254) return 254;; *) return "$rc";; esac; done
  while :; do
    show_config; menu "Component editor" "Add another component/path" "Reconfigure an existing component" "Remove a component" "Auto-discover Lineage dependencies" "Continue"
    case "$MENU_CHOICE" in
      0) read -r -p "Target path: " p || return 254; add_component "$p" || true;;
      1) read -r -p "Target path: " p || return 254; [[ -n "${REPO[$p]+x}" ]] && { add_component "$p" || true; } || echo "Unknown component.";;
      2) read -r -p "Target path to remove: " p || return 254; unset 'REPO[$p]' 'BRANCH[$p]' 'SOURCE[$p]';;
      3) echo -e "${C_CYAN}Dependency candidates:${C_RESET}"; for p in "${!REPO[@]}"; do discover_dependencies "$p" || true; done;;
      4) return 0;; 254) return 254;;
    esac
  done
}

execute() {
  local p rc failed=0; show_config; menu "Execution" "Clone selected repositories" "Dry run" "Edit configuration" "Cancel"
  case "$MENU_CHOICE" in 0) DRY_RUN=0;; 1) DRY_RUN=1;; 2) return 10;; 3|254) return 11;; esac
  for p in $(printf '%s\n' "${!REPO[@]}" | sort); do clone_one "$p"; rc=$?; case "$rc" in 0|2) ;; 3) return 11;; *) failed=1;; esac; done
  ((failed==0)) && echo -e "${C_GREEN}[SUCCESS] Clone process completed.${C_RESET}" || echo -e "${C_YELLOW}[PARTIAL] Some components failed.${C_RESET}"; return 0
}

main() {
  echo -e "${C_BOLD}=== Bias8145 Android Source Cloner ===${C_RESET}"
  while :; do
    echo -e "\n${C_CYAN}Select device${C_RESET}"; echo "1) Bramble (Pixel 4a 5G)"; echo "2) Coral (Pixel 4 XL)"; echo "3) Flame (Pixel 4)"; echo "4) Sunfish (Pixel 4a)"; echo "5) Redfin (Pixel 5)"; echo "6) Oriole (Pixel 6)"; echo "7) Raven (Pixel 6 Pro)"; echo "b) Back"; echo "q) Quit"
    local device_choice rc; read -r -p "> " device_choice || exit 0
    case "$device_choice" in 1) configure_pixel bramble;; 2) configure_pixel coral;; 3) configure_pixel flame;; 4) configure_pixel sunfish;; 5) configure_pixel redfin;; 6) configure_pixel oriole;; 7) configure_pixel raven;; b|B|q|Q) exit 0;; *) echo -e "${C_RED}Invalid choice.${C_RESET}"; continue;; esac
    rc=$?; if ((rc!=0 && rc!=254)); then echo -e "${C_YELLOW}[WARN] Configuration returned $rc.${C_RESET}"; fi; if ((rc==254)); then continue; fi
    while :; do execute; rc=$?; ((rc==10)) && continue; ((rc==11)) && break; break; done
  done
}
main
