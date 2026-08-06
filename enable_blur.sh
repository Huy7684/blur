#!/usr/bin/env bash
# Enable cross-window/background blur in an AOSP-based Android device tree.
# Works with common Android 12+ device-tree layouts and is safe to run again.

set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
DRY_RUN=0
CHANGE_COUNT=0
TARGET_INPUT=""

usage() {
    printf '%s\n' \
        "Usage:" \
        "  bash $SCRIPT_NAME [--dry-run] [DEVICE_TREE_OR_CODENAME]" \
        "" \
        "Examples:" \
        "  bash $SCRIPT_NAME device/xiaomi/sapphire" \
        "  bash $SCRIPT_NAME sapphire" \
        "  cd device/xiaomi/sapphire && bash /path/to/$SCRIPT_NAME" \
        "" \
        "Options:" \
        "  -n, --dry-run   Show changes without writing files" \
        "  -h, --help      Show this help"
}

info() {
    printf '[+] %s\n' "$*"
}

warn() {
    printf '[!] %s\n' "$*" >&2
}

die() {
    printf '[x] %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            (($# == 1)) || die "Pass exactly one device tree after --."
            [[ -z "$TARGET_INPUT" ]] || die "Only one device tree may be selected."
            TARGET_INPUT=$1
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            [[ -z "$TARGET_INPUT" ]] || die "Only one device tree may be selected."
            TARGET_INPUT=$1
            ;;
    esac
    shift
done

looks_like_device_tree() {
    local path=$1
    [[ -f "$path/BoardConfig.mk" ||
       -f "$path/AndroidProducts.mk" ||
       -f "$path/device.mk" ||
       -d "$path/configs/properties" ||
       -d "$path/overlay" ]]
}

find_source_root() {
    local path=$PWD
    while [[ "$path" != / ]]; do
        if [[ -d "$path/device" && ( -d "$path/.repo" || -d "$path/build" ) ]]; then
            printf '%s\n' "$path"
            return 0
        fi
        path=${path%/*}
        [[ -n "$path" ]] || path=/
    done
    return 1
}

resolve_codename() {
    local codename=$1 root
    local -a matches=()

    root=$(find_source_root) || return 1
    mapfile -d '' -t matches < <(
        find "$root/device" -mindepth 2 -maxdepth 2 -type d -name "$codename" -print0
    )

    if ((${#matches[@]} == 1)); then
        printf '%s\n' "${matches[0]}"
        return 0
    fi
    if ((${#matches[@]} > 1)); then
        warn "More than one tree matches '$codename':"
        printf '  %s\n' "${matches[@]}" >&2
    fi
    return 1
}

resolve_target() {
    local candidate=""

    if [[ -n "$TARGET_INPUT" ]]; then
        if [[ -d "$TARGET_INPUT" ]]; then
            candidate=$TARGET_INPUT
        else
            candidate=$(resolve_codename "$TARGET_INPUT") ||
                die "Cannot find device tree '$TARGET_INPUT'. Pass its full path."
        fi
    elif looks_like_device_tree "$PWD"; then
        candidate=$PWD
    elif [[ -n "${TARGET_DEVICE:-}" ]]; then
        candidate=$(resolve_codename "$TARGET_DEVICE") ||
            die "Cannot locate device/$TARGET_DEVICE. Pass the device-tree path."
    elif [[ -n "${DEVICE:-}" ]]; then
        candidate=$(resolve_codename "$DEVICE") ||
            die "Cannot locate device/$DEVICE. Pass the device-tree path."
    else
        die "Run this inside a device tree or pass one, e.g. device/xiaomi/sapphire."
    fi

    candidate=$(cd -- "$candidate" && pwd -P)
    looks_like_device_tree "$candidate" ||
        die "Not a recognizable Android device tree: $candidate"
    printf '%s\n' "$candidate"
}

TARGET=$(resolve_target)
info "Device tree: $TARGET"
((DRY_RUN)) && info "Dry-run mode: no files will be written"

declare -a PROPERTY_FILES=()
mapfile -d '' -t PROPERTY_FILES < <(
    find "$TARGET" \
        \( -type d \( -name .git -o -name out -o -name .blur-backup \) -prune \) -o \
        \( -type f \( -name '*.prop' -o -name '*.mk' \) -print0 \)
)

escape_ere() {
    printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g'
}

file_has_property() {
    local file=$1 key=$2 key_re
    key_re=$(escape_ere "$key")
    grep -Ev '^[[:space:]]*#' "$file" |
        grep -Eq "(^|[[:space:]])${key_re}[[:space:]]*(\\?=|=)"
}

tree_has_property_value() {
    local key=$1 value=$2 file key_re
    key_re=$(escape_ere "$key")
    for file in "${PROPERTY_FILES[@]}"; do
        if grep -Ev '^[[:space:]]*#' "$file" |
            grep -Eq "(^|[[:space:]])${key_re}[[:space:]]*=[[:space:]]*${value}([[:space:]#\\\\]|$)"; then
            return 0
        fi
    done
    return 1
}

commit_temp() {
    local target=$1 temp=$2

    if cmp -s -- "$target" "$temp"; then
        rm -f -- "$temp"
        return 1
    fi

    if ((DRY_RUN)); then
        diff -u --label "$target (before)" --label "$target (after)" "$target" "$temp" || true
        rm -f -- "$temp"
    else
        chmod --reference="$target" "$temp" || true
        mv -- "$temp" "$target"
        info "Updated: ${target#"$TARGET"/}"
    fi
    ((CHANGE_COUNT += 1))
    return 0
}

replace_property() {
    local file=$1 key=$2 value=$3 key_re temp
    key_re=$(escape_ere "$key")
    temp=$(mktemp "${TMPDIR:-/tmp}/enable-blur.XXXXXX")

    sed -E "/^[[:space:]]*#/! s@(^|[[:space:]])${key_re}[[:space:]]*(\\?=|=)[[:space:]]*[^[:space:]#\\\\]+@\\1${key}=${value}@g" \
        "$file" > "$temp"
    commit_temp "$file" "$temp" || true
}

select_main_makefile() {
    local file
    local -a top_makefiles=()

    for file in "$TARGET/device.mk" "$TARGET/common.mk"; do
        [[ -f "$file" ]] && { printf '%s\n' "$file"; return 0; }
    done

    mapfile -d '' -t top_makefiles < <(
        find "$TARGET" -maxdepth 1 -type f -name '*.mk' \
            ! -name 'AndroidProducts.mk' ! -name 'BoardConfig.mk' -print0 | sort -z
    )
    for file in "${top_makefiles[@]}"; do
        if grep -Eq 'PRODUCT_(PACKAGES|COPY_FILES|NAME|DEVICE)' "$file"; then
            printf '%s\n' "$file"
            return 0
        fi
    done
    ((${#top_makefiles[@]})) && { printf '%s\n' "${top_makefiles[0]}"; return 0; }
    return 1
}

select_prop_file() {
    local scope=$1 preferred=$2 path
    local -a candidates=()

    if [[ -n "$preferred" && -f "$preferred" ]]; then
        printf '%s\n' "$preferred"
        return 0
    fi

    if [[ "$scope" == product ]]; then
        candidates=(
            "$TARGET/configs/properties/product.prop"
            "$TARGET/configs/product.prop"
            "$TARGET/properties/product.prop"
            "$TARGET/product.prop"
        )
    else
        candidates=(
            "$TARGET/configs/properties/system_ext.prop"
            "$TARGET/configs/system_ext.prop"
            "$TARGET/properties/system_ext.prop"
            "$TARGET/system_ext.prop"
            "$TARGET/configs/properties/system.prop"
            "$TARGET/system.prop"
            "$TARGET/configs/properties/product.prop"
            "$TARGET/product.prop"
        )
    fi

    for path in "${candidates[@]}"; do
        [[ -f "$path" ]] && { printf '%s\n' "$path"; return 0; }
    done
    return 1
}

append_properties_to_prop() {
    local file=$1 label=$2
    shift 2
    local temp pair
    temp=$(mktemp "${TMPDIR:-/tmp}/enable-blur.XXXXXX")
    cp -- "$file" "$temp"
    printf '\n# Background blur - managed by %s (%s)\n' "$SCRIPT_NAME" "$label" >> "$temp"
    for pair in "$@"; do
        printf '%s\n' "$pair" >> "$temp"
    done
    commit_temp "$file" "$temp" || true
}

append_properties_to_makefile() {
    local file=$1 variable=$2 label=$3
    shift 3
    local temp pair index total
    temp=$(mktemp "${TMPDIR:-/tmp}/enable-blur.XXXXXX")
    cp -- "$file" "$temp"
    printf '\n# Background blur - managed by %s (%s)\n' "$SCRIPT_NAME" "$label" >> "$temp"
    printf '%s += \\\n' "$variable" >> "$temp"
    total=$#
    index=0
    for pair in "$@"; do
        ((index += 1))
        if ((index < total)); then
            printf '    %s \\\n' "$pair" >> "$temp"
        else
            printf '    %s\n' "$pair" >> "$temp"
        fi
    done
    commit_temp "$file" "$temp" || true
}

declare -a KEYS=(
    'ro.launcher.blur.appLaunch'
    'ro.surface_flinger.supports_background_blur'
    'ro.sf.blurs_are_expensive'
    'persist.sys.sf.disable_blurs'
)
declare -a VALUES=('1' '1' '1' '0')
declare -a SCOPES=('product' 'system_ext' 'system_ext' 'system_ext')
declare -a MISSING_PRODUCT=()
declare -a MISSING_SYSTEM_EXT=()
PREFERRED_PRODUCT_PROP=""
PREFERRED_SYSTEM_EXT_PROP=""

# Preflight: identify existing assignments and destinations for missing ones.
for i in "${!KEYS[@]}"; do
    key=${KEYS[$i]}
    scope=${SCOPES[$i]}
    found=0
    for file in "${PROPERTY_FILES[@]}"; do
        if file_has_property "$file" "$key"; then
            found=1
            if [[ "$file" == *.prop ]]; then
                if [[ "$scope" == product && -z "$PREFERRED_PRODUCT_PROP" ]]; then
                    PREFERRED_PRODUCT_PROP=$file
                elif [[ "$scope" == system_ext && -z "$PREFERRED_SYSTEM_EXT_PROP" ]]; then
                    PREFERRED_SYSTEM_EXT_PROP=$file
                fi
            fi
        fi
    done
    if ((found == 0)); then
        pair="${key}=${VALUES[$i]}"
        if [[ "$scope" == product ]]; then
            MISSING_PRODUCT+=("$pair")
        else
            MISSING_SYSTEM_EXT+=("$pair")
        fi
    fi
done

MAIN_MAKEFILE=$(select_main_makefile || true)
PRODUCT_DEST=""
SYSTEM_EXT_DEST=""

if ((${#MISSING_PRODUCT[@]})); then
    PRODUCT_DEST=$(select_prop_file product "$PREFERRED_PRODUCT_PROP" || true)
    [[ -n "$PRODUCT_DEST" || -n "$MAIN_MAKEFILE" ]] ||
        die "No product.prop or usable product makefile was found."
fi
if ((${#MISSING_SYSTEM_EXT[@]})); then
    SYSTEM_EXT_DEST=$(select_prop_file system_ext "$PREFERRED_SYSTEM_EXT_PROP" || true)
    [[ -n "$SYSTEM_EXT_DEST" || -n "$MAIN_MAKEFILE" ]] ||
        die "No system_ext.prop or usable product makefile was found."
fi

declare -a XML_FILES=()
declare -a BLUR_XML_FILES=()
mapfile -d '' -t XML_FILES < <(
    find "$TARGET" \
        \( -type d \( -name .git -o -name out \) -prune \) -o \
        \( -type f -path '*/res/values/*.xml' -print0 \)
)
for file in "${XML_FILES[@]}"; do
    grep -q 'name="config_enableBlurs"' "$file" && BLUR_XML_FILES+=("$file")
done

OVERLAY_INSERT_FILE=""
CREATE_OVERLAY_FILE=0
REGISTER_OVERLAY=0

if ((${#BLUR_XML_FILES[@]} == 0)); then
    for file in \
        "$TARGET/overlay/FrameworksResCommon/res/values/config.xml" \
        "$TARGET/overlay/frameworks/base/core/res/res/values/config.xml"; do
        if [[ -f "$file" ]]; then
            OVERLAY_INSERT_FILE=$file
            break
        fi
    done

    if [[ -z "$OVERLAY_INSERT_FILE" ]]; then
        for file in "${XML_FILES[@]}"; do
            if grep -q 'name="config_sf_slowBlur"' "$file"; then
                OVERLAY_INSERT_FILE=$file
                break
            fi
        done
    fi

    if [[ -z "$OVERLAY_INSERT_FILE" ]]; then
        for file in "${XML_FILES[@]}"; do
            if [[ "$file" == *overlay* && "$file" == *Framework*config.xml ]]; then
                OVERLAY_INSERT_FILE=$file
                break
            fi
        done
    fi

    if [[ -z "$OVERLAY_INSERT_FILE" ]]; then
        OVERLAY_INSERT_FILE="$TARGET/overlay/frameworks/base/core/res/res/values/config.xml"
        CREATE_OVERLAY_FILE=1
        if ! grep -R -q -E --include='*.mk' '([$][(][A-Za-z0-9_]+[)]|device/[^[:space:]\\]+)/overlay([[:space:]\\]|$)' \
            "$TARGET"; then
            REGISTER_OVERLAY=1
            [[ -n "$MAIN_MAKEFILE" ]] ||
                die "A framework overlay must be created, but no product makefile was found to register it."
        fi
    fi
fi

# Apply property changes already present in the tree.
for i in "${!KEYS[@]}"; do
    key=${KEYS[$i]}
    for file in "${PROPERTY_FILES[@]}"; do
        file_has_property "$file" "$key" && replace_property "$file" "$key" "${VALUES[$i]}"
    done
done

# Add properties not defined anywhere in the tree.
if ((${#MISSING_PRODUCT[@]})); then
    if [[ -n "$PRODUCT_DEST" ]]; then
        append_properties_to_prop "$PRODUCT_DEST" product "${MISSING_PRODUCT[@]}"
    else
        append_properties_to_makefile "$MAIN_MAKEFILE" PRODUCT_PRODUCT_PROPERTIES product \
            "${MISSING_PRODUCT[@]}"
    fi
fi
if ((${#MISSING_SYSTEM_EXT[@]})); then
    if [[ -n "$SYSTEM_EXT_DEST" ]]; then
        append_properties_to_prop "$SYSTEM_EXT_DEST" system_ext "${MISSING_SYSTEM_EXT[@]}"
    else
        append_properties_to_makefile "$MAIN_MAKEFILE" PRODUCT_SYSTEM_EXT_PROPERTIES system_ext \
            "${MISSING_SYSTEM_EXT[@]}"
    fi
fi

replace_blur_bool() {
    local file=$1 temp
    temp=$(mktemp "${TMPDIR:-/tmp}/enable-blur.XXXXXX")
    sed -E 's@(<bool[[:space:]][^>]*name="config_enableBlurs"[^>]*>)[[:space:]]*(true|false)[[:space:]]*(</bool>)@\1true\3@g' \
        "$file" > "$temp"
    commit_temp "$file" "$temp" || true
}

insert_blur_bool() {
    local file=$1 temp
    temp=$(mktemp "${TMPDIR:-/tmp}/enable-blur.XXXXXX")
    awk '
        /^[[:space:]]*<\/resources>[[:space:]]*$/ && !inserted {
            print ""
            print "    <!-- Enable window-level (cross-window) background blur. -->"
            print "    <bool name=\"config_enableBlurs\">true</bool>"
            inserted=1
        }
        { print }
        END { if (!inserted) exit 42 }
    ' "$file" > "$temp" || {
        rm -f -- "$temp"
        die "Cannot find </resources> in $file"
    }
    commit_temp "$file" "$temp" || true
}

create_blur_overlay() {
    local file=$1
    if ((DRY_RUN)); then
        info "Would create: ${file#"$TARGET"/}"
    else
        mkdir -p -- "${file%/*}"
        printf '%s\n' \
            '<?xml version="1.0" encoding="utf-8"?>' \
            '<resources>' \
            '    <!-- Enable window-level (cross-window) background blur. -->' \
            '    <bool name="config_enableBlurs">true</bool>' \
            '</resources>' > "$file"
        info "Created: ${file#"$TARGET"/}"
    fi
    ((CHANGE_COUNT += 1))
}

register_legacy_overlay() {
    local file=$1 temp
    temp=$(mktemp "${TMPDIR:-/tmp}/enable-blur.XXXXXX")
    cp -- "$file" "$temp"
    printf '\n# Background blur overlay - managed by %s\n' "$SCRIPT_NAME" >> "$temp"
    printf '%s\n' \
        'BLUR_DEVICE_OVERLAY_PATH := $(call my-dir)/overlay' \
        'PRODUCT_PACKAGE_OVERLAYS += $(BLUR_DEVICE_OVERLAY_PATH)' >> "$temp"
    commit_temp "$file" "$temp" || true
}

if ((${#BLUR_XML_FILES[@]})); then
    for file in "${BLUR_XML_FILES[@]}"; do
        replace_blur_bool "$file"
    done
elif ((CREATE_OVERLAY_FILE)); then
    create_blur_overlay "$OVERLAY_INSERT_FILE"
    ((REGISTER_OVERLAY)) && register_legacy_overlay "$MAIN_MAKEFILE"
else
    insert_blur_bool "$OVERLAY_INSERT_FILE"
fi

if ((DRY_RUN)); then
    if ((CHANGE_COUNT)); then
        info "$CHANGE_COUNT change(s) would be applied."
    else
        info "Blur is already enabled; no change is needed."
    fi
    exit 0
fi

# Final sanity checks.
for i in "${!KEYS[@]}"; do
    tree_has_property_value "${KEYS[$i]}" "${VALUES[$i]}" ||
        die "Verification failed for property ${KEYS[$i]}=${VALUES[$i]}"
done

declare -a VERIFY_XML_FILES=()
if ((${#BLUR_XML_FILES[@]})); then
    VERIFY_XML_FILES=("${BLUR_XML_FILES[@]}")
else
    VERIFY_XML_FILES=("$OVERLAY_INSERT_FILE")
fi
for file in "${VERIFY_XML_FILES[@]}"; do
    grep -Eq '<bool[[:space:]][^>]*name="config_enableBlurs"[^>]*>[[:space:]]*true[[:space:]]*</bool>' \
        "$file" || die "Verification failed for config_enableBlurs=true in $file"
done

if ((CHANGE_COUNT)); then
    info "Done. Background blur is enabled."
else
    info "Blur is already enabled; no change is needed."
fi
