#!/bin/bash

# morp_susfs.sh by Bias8145
# Automate KernelSU-Next + SUSFS patch for Redbull kernels

set -e

echo ">>> [1/9] Masuk ke direktori kernel/google/redbull"
cd kernel/google/redbull || { echo "Folder tidak ditemukan!"; exit 1; }

echo ">>> [2/9] Download & setup KernelSU-Next v1.0.3"
curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/next/kernel/setup.sh" | bash -s v1.0.3

echo ">>> [3/9] Masuk ke folder KernelSU-Next"
cd KernelSU-Next

echo ">>> [4/9] Mengambil patch SUSFS v1.5.3"
curl -o 0001-Kernel-Implement-SUSFS-v1.5.3.patch https://github.com/sidex15/KernelSU-Next/commit/1e750de25930e875612bbec0410de0088474c00b.patch

echo ">>> [5/9] Menerapkan patch SUSFS ke KernelSU-Next"
patch -p1 < 0001-Kernel-Implement-SUSFS-v1.5.3.patch

echo ">>> [6/9] Kembali ke root redbull"
cd ..

echo ">>> [7/9] Clone SUSFS dari Simonpunk untuk kernel 4.19"
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b kernel-4.19

echo ">>> [8/9] Menyalin file fs/ dan include/linux/"
cp -v susfs4ksu/kernel_patches/fs/* fs/
cp -v susfs4ksu/kernel_patches/include/linux/* include/linux/

echo ">>> [9/9] Menerapkan patch 50_add_susfs_in_kernel-4.19"
cp -v susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.19.patch .
patch -p1 < 50_add_susfs_in_kernel-4.19.patch

echo ">>> Selesai! KernelSU-Next + SUSFS sudah terpasang di redbull kernel."
