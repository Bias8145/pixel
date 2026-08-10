#!/bin/bash

echo "This script will generate Android keys for signing builds."

# Define the subject line
subject='/C=US/ST=California/L=Mountain View/O=Android/OU=Android/CN=Android/emailAddress=android@android.com'

# Print the subject line
echo "Using Subject Line:"
echo "$subject"

# Prompt the user to verify if the subject line is correct
read -p "Is the subject line correct? (y/n): " confirmation

# Check the user's response
if [[ $confirmation != "y" && $confirmation != "Y" ]]; then
    echo "Exiting without changes."
    exit 1
fi
clear

# Check for existing Android certs and prompt for removal
if [ -d "$HOME/.android-certs" ]; then
    read -p "Existing Android certificates found. Do you want to remove them? (y/n): " remove_confirmation
    if [[ $remove_confirmation == "y" || $remove_confirmation == "Y" ]]; then
        rm -rf "$HOME/.android-certs"
        echo "Old Android certificates removed."
    else
        echo "Exiting without changes."
        exit 1
    fi
fi

# Create Key
echo "Press ENTER TWICE to skip password (about 10-15 enter hits total). Cannot use a password for inline signing!"
mkdir ~/.android-certs

for x in bluetooth media networkstack nfc platform releasekey sdk_sandbox shared testkey verifiedboot; do 
    ./development/tools/make_key ~/.android-certs/$x "$subject"
done

# Create vendor directory for keys
mkdir -p vendor/lineage-priv
mv ~/.android-certs vendor/lineage-priv/keys
echo "PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey" > vendor/lineage-priv/keys/keys.mk

# Create BUILD.bazel file
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

echo "Done! Now build as usual. If builds aren't being signed, add '-include vendor/lineage-priv/keys/keys.mk' to your device mk file"
echo "Make copies of your vendor/lineage-priv folder or upload it to a private repository as it contains your keys!"
sleep 3
