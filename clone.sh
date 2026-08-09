#!/usr/bin/env bash
# Android Source Repo Cloner - high flexibility edition
# Per-tree source + per-tree branch selection. Nothing is globally locked to LOS/GrapheneOS.
# Sources: LineageOS, GrapheneOS, Bias8145, TheMuppets, or any manual repository.
set -Euo pipefail

readonly C_RESET='\033[0m' C_BOLD='\033[1m' C_CYAN='\033[0;36m' C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m' C_YELLOW='\033[1;33m' C_BLUE='\033[0;34m' C_MAGENTA='\033[0;35m'

declare -A REPO BRANCH SOURCE
DEVICE=""
DRY_RUN=0

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo -e "${C_RED}[ERROR] Missing: $1${C_RESET}"; exit 1; }; }
need_cmd git
need_cmd curl

menu() {
  local title="$1"; shift
  local -a opts=("$@") n
  while :; do
    echo -e "\n${C_CYAN}${title}${C_RESET}"
    for n in "${!opts[@]}"; do echo "$((n+1))) ${opts[n]}"; done
    echo "b) Back"
    echo "q) Quit"
    read -r -p "> " ans
    case "$ans" in
      [0-9]*) if ((ans>=1 && ans<=${#opts[@]})); then return $((ans-1)); fi ;;
      b|B) return 254 ;;
      q|Q) exit 0 ;;
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
  local url="$1" component="$2"; local -a bs=(); local i
  mapfile -t bs < <(list_branches "$url") || { echo -e "${C_RED}[ERROR] Cannot read branches: $url${C_RESET}"; return 1; }
  echo -e "${C_CYAN}Branches for ${component}:${C_RESET}"
  for i in "${!bs[@]}"; do echo "$((i+1))) ${bs[i]}"; done
  echo "m) Manual branch/tag/ref"
  echo "b) Back"
  while :; do
    read -r -p "> " ans
    case "$ans" in
      [0-9]*) if ((ans>=1 && ans<=${#bs[@]})); then SELECTED_BRANCH="${bs[ans-1]}"; return 0; fi ;;
      m|M) read -r -p "Branch/tag/ref: " SELECTED_BRANCH; [[ -n "$SELECTED_BRANCH" ]] && return 0 ;;
      b|B) return 254 ;;
    esac
    echo -e "${C_RED}Invalid branch.${C_RESET}"
  done
}

repo_name_for() {
  local source="$1" path="$2" p="${2//\//_}"
  case "$source" in
    LineageOS|Bias8145) echo "https://github.com/${source}/android_${p}.git" ;;
    GrapheneOS) echo "https://github.com/GrapheneOS/${p}.git" ;;
    TheMuppets) echo "https://github.com/TheMuppets/proprietary_${p}.git" ;;
  esac
}

source_repo() {
  local path="$1" component="${1##*/}" choice repo source
  while :; do
    menu "Source for ${path}" \
      "LineageOS official" \
      "GrapheneOS official (if a standalone tree is published)" \
      "Bias8145/custom source" \
      "TheMuppets vendor source" \
      "Manual repository URL"
    choice=$?
    case "$choice" in
      254) return 254 ;;
      0) repo="$(repo_name_for LineageOS "$path")"; source="LineageOS" ;;
      1) repo="$(repo_name_for GrapheneOS "$path")"; source="GrapheneOS" ;;
      2) repo="$(repo_name_for Bias8145 "$path")"; source="Bias8145" ;;
      3) repo="$(repo_name_for TheMuppets "$path")"; source="TheMuppets" ;;
      4) read -r -p "Repository URL: " repo; source="Custom" ;;
      *) continue ;;
    esac
    [[ -n "$repo" ]] || continue
    if ! git ls-remote --heads "$repo" >/dev/null 2>&1; then
      echo -e "${C_YELLOW}[WARN] Repository unavailable: $repo${C_RESET}"
      continue
    fi
    pick_branch "$repo" "$component" || continue
    echo -e "${C_GREEN}Selected:${C_RESET} $source | $repo | $SELECTED_BRANCH"
    menu "Confirm ${path}" "Confirm" "Choose another source" "Choose another branch"
    case "$?" in
      0) REPO["$path"]="$repo"; BRANCH["$path"]="$SELECTED_BRANCH"; SOURCE["$path"]="$source"; return 0 ;;
      1) continue ;;
      2) pick_branch "$repo" "$component" || continue ;;
    esac
  done
}

add_component() {
  local path="$1"
  valid_path "$path" || { echo -e "${C_RED}[ERROR] Invalid target path: $path${C_RESET}"; return 1; }
  source_repo "$path"
}

discover_dependencies() {
  local path="$1" url="${REPO[$path]}" branch="${BRANCH[$path]}" raw tmp repo_path
  repo_path="${url#https://github.com/}"; repo_path="${repo_path%.git}"
  raw="https://raw.githubusercontent.com/${repo_path}/${branch}/lineage.dependencies"
  tmp="$(curl -fsSL "$raw" 2>/dev/null || true)"
  [[ -n "$tmp" ]] || return 0
  echo "$tmp" | sed -n 's/.*"repository":[[:space:]]*"\([^"]*\)".*"target_path":[[:space:]]*"\([^"]*\)".*/\1|\2/p'
}

clone_one() {
  local path="$1" url="${REPO[$path]}" branch="${BRANCH[$path]}" current_url current_branch
  echo -e "${C_BLUE}[CLONE]${C_RESET} $url [$branch] -> $path"
  if ((DRY_RUN)); then echo "       git clone --depth=1 -b '$branch' '$url' '$path'"; return 0; fi
  if [[ -d "$path/.git" ]]; then
    current_url="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
    current_branch="$(git -C "$path" symbolic-ref --short HEAD 2>/dev/null || true)"
    if [[ "$(normalize_url "$current_url")" == "$(normalize_url "$url")" && "$current_branch" == "$branch" ]]; then
      echo -e "${C_YELLOW}[SKIP] Already matches.${C_RESET}"; return 2
    fi
    echo -e "${C_YELLOW}[EXISTS] $path${C_RESET}"
    menu "Existing repository" "Keep existing" "Remove and clone selected" "Cancel"
    case "$?" in
      0) return 2 ;;
      1) rm -rf -- "$path" ;;
      2) return 3 ;;
    esac
  elif [[ -e "$path" ]]; then
    echo -e "${C_RED}[ERROR] Target exists and is not a Git repository: $path${C_RESET}"; return 1
  fi
  mkdir -p "$(dirname "$path")"
  git clone --depth=1 --branch "$branch" --single-branch "$url" "$path"
}

show_config() {
  local p
  echo -e "\n${C_BOLD}========== FINAL CONFIGURATION ==========${C_RESET}"
  echo "Device: $DEVICE"
  for p in "${!REPO[@]}"; do
    printf '  %-42s %-12s %s [%s]\n' "$p" "${SOURCE[$p]}" "${BRANCH[$p]}" "${REPO[$p]}"
  done | sort
  echo -e "${C_BOLD}==========================================${C_RESET}"
}

configure_pixel() {
  local codename="$1"
  DEVICE="$codename"
  REPO=(); BRANCH=(); SOURCE=()
  local -a defaults=()
  case "$codename" in
    bramble) defaults=("device/google/bramble" "device/google/redbull" "device/google/gs-common" "vendor/google/bramble" "kernel/google/redbull") ;;
    coral) defaults=("device/google/coral" "device/google/gs-common" "vendor/google/coral" "kernel/google/msm-4.14") ;;
    flame) defaults=("device/google/coral" "device/google/gs-common" "vendor/google/flame" "kernel/google/msm-4.14") ;;
    sunfish) defaults=("device/google/sunfish" "device/google/gs-common" "vendor/google/sunfish" "kernel/google/msm-4.14") ;;
    redfin) defaults=("device/google/redfin" "device/google/redbull" "device/google/gs-common" "vendor/google/redfin" "kernel/google/redbull") ;;
    oriole) defaults=("device/google/oriole" "device/google/raviole" "device/google/gs101" "device/google/gs-common" "device/google/raviole-kernels" "vendor/google/oriole") ;;
    raven) defaults=("device/google/raven" "device/google/raviole" "device/google/gs101" "device/google/gs-common" "device/google/raviole-kernels" "vendor/google/raven") ;;
    *) return 1 ;;
  esac
  echo -e "\n${C_BOLD}${C_CYAN}Every component is independent.${C_RESET}"
  echo "Mix LineageOS, GrapheneOS, Bias8145, TheMuppets and manual repositories as desired."
  echo "Each component has its own repository and branch selection."
  local p
  for p in "${defaults[@]}"; do add_component "$p" || return $?; done
  while :; do
    show_config
    menu "Component editor" \
      "Add another component/path" \
      "Reconfigure an existing component" \
      "Remove a component" \
      "Auto-discover Lineage dependencies" \
      "Continue"
    case "$?" in
      0) read -r -p "Target path: " p; add_component "$p" || true ;;
      1) read -r -p "Target path: " p; [[ -n "${REPO[$p]+x}" ]] && add_component "$p" || echo "Unknown component." ;;
      2) read -r -p "Target path to remove: " p; unset 'REPO[$p]' 'BRANCH[$p]' 'SOURCE[$p]' ;;
      3) echo -e "${C_CYAN}Dependency candidates:${C_RESET}"; for p in "${!REPO[@]}"; do discover_dependencies "$p" || true; done ;;
      4) break ;;
    esac
  done
}

execute() {
  local p rc failed=0
  show_config
  menu "Execution" "Clone selected repositories" "Dry run" "Edit configuration" "Cancel"
  case "$?" in
    0) DRY_RUN=0 ;;
    1) DRY_RUN=1 ;;
    2) return 10 ;;
    3) return 11 ;;
  esac
  for p in $(printf '%s\n' "${!REPO[@]}" | sort); do
    clone_one "$p"; rc=$?
    case "$rc" in 0|2) ;; 3) return 11 ;; *) failed=1 ;; esac
  done
  if ((failed==0)); then
    echo -e "${C_GREEN}[SUCCESS] Clone process completed.${C_RESET}"
  else
    echo -e "${C_YELLOW}[PARTIAL] Some components failed.${C_RESET}"
  fi
}

main() {
  echo -e "${C_BOLD}=== Bias8145 Android Source Cloner ===${C_RESET}"
  while :; do
    menu "Select device" \
      "Bramble (Pixel 4a 5G)" "Coral (Pixel 4 XL)" "Flame (Pixel 4)" \
      "Sunfish (Pixel 4a)" "Redfin (Pixel 5)" "Oriole (Pixel 6)" "Raven (Pixel 6 Pro)"
    case "$?" in
      254) exit 0 ;;
      0) configure_pixel bramble ;;
      1) configure_pixel coral ;;
      2) configure_pixel flame ;;
      3) configure_pixel sunfish ;;
      4) configure_pixel redfin ;;
      5) configure_pixel oriole ;;
      6) configure_pixel raven ;;
    esac
    while :; do
      execute
      rc=$?
      [[ "$rc" == 10 ]] && continue
      [[ "$rc" == 11 ]] && break
      break
    done
  done
}
main
