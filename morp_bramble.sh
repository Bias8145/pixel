#!/bin/bash

echo
echo "=== Starting Android source repositories cloning process ==="

# Function to clone a repository with informative output and error checking
clone_repo() {
  local repo_url=$1
  local target_dir=$2
  local branch=$3

  if [ -n "$branch" ]; then
    echo "[INFO] Cloning $repo_url (branch: $branch) into $target_dir ..."
    git clone -b "$branch" "$repo_url" "$target_dir"
  else
    echo "[INFO] Cloning $repo_url into $target_dir ..."
    git clone "$repo_url" "$target_dir"
  fi

  if [ $? -eq 0 ]; then
    echo "[SUCCESS] Cloned into $target_dir successfully."
  else
    echo "[ERROR] Failed to clone $repo_url."
    exit 1
  fi

  echo
}

# Clone the repositories
clone_repo https://github.com/Bias8145/android_device_google_bramble.git device/google/bramble
clone_repo https://github.com/Bias8145/android_device_google_redbull.git device/google/redbull
clone_repo https://github.com/LineageOS/android_device_google_gs-common.git device/google/gs-common
clone_repo https://github.com/TheMuppets/proprietary_vendor_google_bramble.git vendor/google/bramble
clone_repo https://github.com/Bias8145/android_kernel_google_redbull.git kernel/google/redbull

echo "=== All repositories cloned successfully ==="
