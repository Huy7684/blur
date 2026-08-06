#!/usr/bin/env bash
set -euo pipefail

# Universal blur enabler for Android device trees
# Usage:
#   ./enable_blur_universal.sh
#   ./enable_blur_universal.sh /path/to/device/xiaomi/sapphire

ROOT="${1:-$(pwd)}"
ROOT="$(realpath "$ROOT")"

echo "[*] Target: $ROOT"

backup_file() {
    local f="$1"
    if [[ ! -f "${f}.blur.bak" ]]; then
        cp -a "$f" "${f}.blur.bak"
    fi
}

set_prop() {
    local file="$1"
    local key="$2"
    local value="$3"

    backup_file "$file"

    if grep -qE "^[[:space:]]*${key//./\\.}=" "$file"; then
        sed -i -E "s|^[[:space:]]*${key//./\\.}=.*|${key}=${value}|" "$file"
        echo "[+] Updated $key in ${file#$ROOT/}"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
        echo "[+] Added $key to ${file#$ROOT/}"
    fi
}

find_prop_file() {
    local preferred="$1"
    shift

    if [[ -f "$ROOT/$preferred" ]]; then
        printf '%s\n' "$ROOT/$preferred"
        return 0
    fi

    local name
    for name in "$@"; do
        local found
        found="$(find "$ROOT" -maxdepth 6 -type f -name "$name" -print -quit 2>/dev/null || true)"
        if [[ -n "$found" ]]; then
            printf '%s\n' "$found"
            return 0
        fi
    done

    return 1
}

PRODUCT_PROP="$(find_prop_file "configs/properties/product.prop" "product.prop" || true)"
SYSTEM_EXT_PROP="$(find_prop_file "configs/properties/system_ext.prop" "system_ext.prop" || true)"

if [[ -n "$PRODUCT_PROP" ]]; then
    set_prop "$PRODUCT_PROP" "ro.launcher.blur.appLaunch" "1"
else
    echo "[!] product.prop not found; skipped launcher blur property"
fi

if [[ -n "$SYSTEM_EXT_PROP" ]]; then
    set_prop "$SYSTEM_EXT_PROP" "ro.surface_flinger.supports_background_blur" "1"
    set_prop "$SYSTEM_EXT_PROP" "ro.sf.blurs_are_expensive" "1"
    set_prop "$SYSTEM_EXT_PROP" "persist.sys.sf.disable_blurs" "0"
else
    echo "[!] system_ext.prop not found; skipped SurfaceFlinger properties"
fi

XML="$ROOT/overlay/FrameworksResCommon/res/values/config.xml"

if [[ ! -f "$XML" ]]; then
    XML="$(find "$ROOT" -maxdepth 8 -type f -path '*/res/values/config.xml' \
        -exec grep -Il 'config_sf_slowBlur\|config_enableBlurs' {} \; 2>/dev/null | head -n 1 || true)"
fi

if [[ -n "${XML:-}" && -f "$XML" ]]; then
    backup_file "$XML"

    if grep -q 'name="config_enableBlurs"' "$XML"; then
        sed -i -E 's|<bool name="config_enableBlurs">[^<]*</bool>|<bool name="config_enableBlurs">true</bool>|' "$XML"
        echo "[+] Updated config_enableBlurs in ${XML#$ROOT/}"
    elif grep -q '</resources>' "$XML"; then
        sed -i '/<\/resources>/i\    <bool name="config_enableBlurs">true</bool>' "$XML"
        echo "[+] Added config_enableBlurs to ${XML#$ROOT/}"
    else
        echo "[!] Invalid XML or missing </resources>: $XML"
    fi
else
    echo "[!] Compatible FrameworksRes config.xml not found; skipped overlay"
fi

echo
echo "[✓] Done."
echo "[i] Backup files end with .blur.bak"
echo "[i] Review changes with: git diff"
