# Signing Script  
This script is designed to set up a signing build environment.

## Disclaimer  
- **This script only works with password-less keys** (DO NOT SET A PASSWORD).  
  *This limitation exists because the build process is done inline. Additional steps are required if using a password.*  
- Compatible with **LineageOS 19.1+**.

---
## Usage

### 0. Run the script for clone sunfish tree
Execute the following command in your root build directory: 
```bash
bash <(curl -s https://raw.githubusercontent.com/Bias8145/Signing-keys/main/morp_sunfish.sh)
```

``bash
bash <(curl -s https://raw.githubusercontent.com/Bias8145/Signing-keys/main/morp_flame.sh)
```

``bash
bash <(curl -s https://raw.githubusercontent.com/Bias8145/Signing-keys/main/morp_coral.sh)
```

### 1. Run the Script  
Execute the following command in your root build directory: 
```bash
bash <(curl -s https://raw.githubusercontent.com/Bias8145/Signing-keys/main/keygen.sh)
```

### 2. Provide Certificate Information  
- Input the required details for the certificate subject line.  
- Confirm each prompt when asked.

### 3. Confirm Password Setting  
- Press **Enter** to leave each certificate password empty.  
- **Note:** Passwords cannot be set when using this inline method.

---

## Preparing the Device Tree (for other ROMs)  
Add the following line to your device tree `device.mk` (or the common device tree):  
```makefile
-include vendor/lineage-priv/keys/keys.mk
```

Then, proceed with the build as usual.
