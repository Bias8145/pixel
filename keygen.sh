#!/bin/bash

set -e

show_header() {
    echo
    echo "=============================================="
    echo " Android Signing Key Generator"
    echo "=============================================="
}

ask_yes_no() {
    local prompt="$1"
    local answer
    while true; do
        read -r -p "$prompt [y/n]: " answer
        case "$answer" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

legacy_keygen() {
    local subject='/C=US/ST=California/L=Mountain View/O=Android/OU=Android/CN=Android/emailAddress=android@android.com'

    echo
    echo "Using legacy Android signing-key generator (Android 15 and below)."
    echo "Subject: $subject"

    ask_yes_no "Is the subject line correct?" || {
        echo "Exiting without changes."
        return 1
    }

    if [ -d "$HOME/.android-certs" ]; then
        if ask_yes_no "Existing Android certificates found. Remove them?"; then
            rm -rf "$HOME/.android-certs"
            echo "Old Android certificates removed."
        else
            echo "Exiting without changes."
            return 1
        fi
    fi

    echo
    echo "Press ENTER twice to skip password (about 10-15 enter hits total)."
    echo "Cannot use a password for inline signing!"
    mkdir -p "$HOME/.android-certs"

    for x in bluetooth media networkstack nfc platform releasekey sdk_sandbox shared testkey verifiedboot; do
        ./development/tools/make_key "$HOME/.android-certs/$x" "$subject"
    done

    mkdir -p vendor/lineage-priv
    rm -rf vendor/lineage-priv/keys
    mv "$HOME/.android-certs" vendor/lineage-priv/keys

    echo "PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey" > vendor/lineage-priv/keys/keys.mk

    cat <<EOF > vendor/lineage-priv/keys/BUILD.bazel
filegroup(
    name = "android_certificate_directory",
    srcs = glob([
        "*.pk8",
        "*.pem",
    ]),
    visibility = ["//visibility:public"],
)
EOF

    echo
    echo "Done! Build as usual."
    echo "If builds are not being signed, include vendor/lineage-priv/keys/keys.mk from the appropriate device/product makefile."
    echo "Keep vendor/lineage-priv private: it contains your signing keys."
}

a16_qpr2_keygen() {
    local default_path="vendor/lineage-priv/keys"
    local key_path
    local scripts_dir="tmp_scripts"
    local keys_mk

    echo
    echo "Android 16 QPR2+ signing-key flow"
    echo "LineageOS scripts/lineage-priv-template will be used."
    echo
    echo "The key directory is ROM-specific and can be named freely."
    echo "Examples: vendor/lineage-priv/keys, vendor/myrom-priv/keys, vendor/romname-keys"
    echo
    read -r -p "Key directory [$default_path]: " key_path
    key_path="${key_path:-$default_path}"

    if [[ "$key_path" = /* || "$key_path" == *".."* ]]; then
        echo "[ERROR] Key directory must be a safe relative path without '..'."
        return 1
    fi

    if ! [[ "$key_path" =~ ^[A-Za-z0-9._/-]+$ ]]; then
        echo "[ERROR] Invalid key directory: $key_path"
        return 1
    fi

    if [ -e "$key_path" ]; then
        echo "[WARNING] Key directory already exists: $key_path"
        if ! ask_yes_no "Remove it and recreate from the LineageOS template?"; then
            echo "Exiting without changes."
            return 1
        fi
        rm -rf -- "$key_path"
    fi

    rm -rf -- "$scripts_dir"
    echo
    echo ">>> Cloning LineageOS scripts..."
    git clone --depth=1 https://github.com/LineageOS/scripts.git "$scripts_dir"

    echo ">>> Installing key template into $key_path..."
    mkdir -p -- "$key_path"
    cp -r "$scripts_dir/lineage-priv-template/"* "$key_path/"
    rm -rf -- "$scripts_dir"

    keys_mk="$key_path/keys.mk"
    if [ ! -f "$keys_mk" ]; then
        echo "[ERROR] Missing $keys_mk"
        return 1
    fi

    echo
    echo "=============================================="
    echo " MANUAL keys.mk CONFIGURATION REQUIRED"
    echo "=============================================="
    echo "Open: $keys_mk"
    echo
    echo "1. At the top/appropriate ROM-specific entries,"
    echo "   change vendor/lineage-priv to whatever path"
    echo "   and ROM-specific namespace your ROM requires."
    echo "   Example: vendor/myrom-priv/keys"
    echo
    echo "2. Do NOT leave the default testkey certificate."
    echo "3. PRODUCT_DEFAULT_DEV_CERTIFICATE at the bottom"
    echo "   MUST point to the releasekey, using your chosen path."
    echo "   Example: PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/myrom-priv/keys/releasekey"
    echo
    echo "The script will NOT guess your ROM's namespace."
    echo "After editing keys.mk, return here and continue."
    echo
    read -r -p "Press ENTER after you have manually edited keys.mk..."

    if ! grep -Eq '^[[:space:]]*PRODUCT_DEFAULT_DEV_CERTIFICATE[[:space:]]*:=[[:space:]].*/releasekey[[:space:]]*$' "$keys_mk"; then
        echo
        echo "[ERROR] keys.mk does not contain a PRODUCT_DEFAULT_DEV_CERTIFICATE"
        echo "        pointing to */releasekey."
        echo "        Android 16 QPR2+ release signing requires releasekey here."
        return 1
    fi

    if grep -Eq '^[[:space:]]*PRODUCT_DEFAULT_DEV_CERTIFICATE[[:space:]]*:=[[:space:]].*/testkey([[:space:]]*)$' "$keys_mk"; then
        echo "[ERROR] keys.mk still points PRODUCT_DEFAULT_DEV_CERTIFICATE to testkey."
        return 1
    fi

    if [ ! -x "$key_path/keys.sh" ]; then
        chmod +x "$key_path/keys.sh" "$key_path/make_key.sh" 2>/dev/null || true
    fi

    echo
    echo ">>> Running keys.sh from $key_path..."
    (
        cd "$key_path"
        ./keys.sh
    )

    echo
    echo "Done! Android 16 QPR2+ signing keys generated in: $key_path"
    echo "Keep this directory private: it contains your signing keys."
}

show_header

echo "Select Android signing-key method:"
echo "1) Android 15 and below (legacy make_key flow)"
echo "2) Android 16 QPR2+ (LineageOS scripts/lineage-priv-template)"
echo "q) Quit"

while true; do
    read -r -p "Your choice [1-2]: " choice
    case "$choice" in
        1)
            legacy_keygen
            exit $?
            ;;
        2)
            a16_qpr2_keygen
            exit $?
            ;;
        [Qq])
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid selection."
            ;;
    esac
done
