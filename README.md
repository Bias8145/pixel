# 📦 Pixel Builder Toolkit

A collection of scripts to simplify the setup, signing, and OTA uploading process for Pixel-based Android ROM development.

> Repository: Bias8145/pixel
Designed for maintainers and flashers building for Google Pixel 4 / 4a / 4a 5G / 4XL — including automation for cloning trees, setting up signing keys, and publishing builds to Telegram + file hosts.

---

## 📁 Available Scripts

Script	Description
- keygen.sh	Generate AOSP-compatible signing keys (no passwords)
- clone.sh Clone tree for Pixel 4a 4G (sunfish), Pixel 4 (flame), Pixel 4 XL (coral), Pixel 4a 5G (bramble)
- uploaders-V3.sh	Upload ROM builds to Telegram + Pixeldrain/Gofile



---

## ⚙️ Quick Usage
### 🧬 1. Clone Device Trees
> Run this inside your ROM build directory
```bash
bash <(curl -s https://raw.githubusercontent.com/Bias8145/pixel/main/clone.sh)
```
Each script clones the full device tree, common GS files, vendor blobs, and kernel source.

---

### 🔐 2. Generate Signing Keys
> Passwordless key generation for release-keys, ideal for automated builds
```bash
bash <(curl -s https://raw.githubusercontent.com/Bias8145/pixel/main/keygen.sh)
```

Output will be stored in:
vendor/lineage-priv/keys/
Keys include:
- releasekey
- platform
- shared
- media
- networkstack


## 💡 Recommended for LineageOS 19.1+ or any ROM using sign_target_files_apks.

---

### ☁️ 3. Auto Upload ROM Builds
Supports:
Telegram (via bot token + channel)
Pixeldrain
```bash
bash <(curl -s https://raw.githubusercontent.com/Bias8145/pixel/main/uploaders-V3.sh) \
  "<Telegram_Message_Link>" \
  "<Build Description>" \
  "out/target/product/device-name/your-rom.zip"
```
### 📌 Example:
```bash
bash <(curl -s https://raw.githubusercontent.com/Bias8145/pixel/main/uploaders-V3.sh) \
  "https://t.me/Pixel4aUpdates/123" \
  "LineageOS 20.0 - Final Release" \
  out/target/product/sunfish/lineage-20.0-sunfish-*.zip
```
You can configure:
- token.env file (to store your Telegram bot token & chat ID)
- Auto-captioning & horizontal buttons
- Optional SUSFS/KSU patch support for bramble

---

## ✅ Supported Devices

Codename	Device Name	Status

- sunfish	Google Pixel 4a 4G	✅
- flame	Google Pixel 4	✅
- coral	Google Pixel 4 XL	✅
- bramble	Google Pixel 4a 5G	✅

---

## 📦 Dependencies

Make sure you have the following tools installed:
- git
- curl
- patch
- zip (for uploading)
- openssl (for key generation)

---

## 💡 Tips

You can modify each clone.sh script to suit your ROM (e.g. changing default branches).

Combine with CI tools (GitHub Actions, Jenkins) for automated builds + uploads.

Keys are generated without password by default (useful for non-interactive builds).



---

## 📣 Credits

Maintained by Bias8145
Inspired by:

LineageOS build system
Pixel 4 Series communities
KernelSU-Next + SUSFS integrations

---

## 📄 License

This project is licensed under MIT. Feel free to fork or contribute.

✅ README.md has been updated to reflect your actual repository link: Bias8145/pixel, with direct links to each script file for easy GitHub access.

Let me know if you want a Bahasa Indonesia version or additional badges like "Build passing", "License", or "Supported Devices".
