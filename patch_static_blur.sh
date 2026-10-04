#!/usr/bin/env bash
# blur_all_roms.sh
# Bat hieu ung blur (lam mo nen) cho device/vendor tree cua BAT KY ROM nao.
# Tuong duong patch blur goc nhung khong phu thuoc ten ROM, maintainer hay duong dan co dinh.
#
# Dung:
#   ./blur_all_roms.sh [tree]                  # blur day du (nhu patch goc)
#   ./blur_all_roms.sh --lite [tree]           # blur lite: tat blur khi mo app
#   ./blur_all_roms.sh --overlay FILE [tree]   # chi dinh file overlay config.xml
#   ./blur_all_roms.sh --revert [tree]         # hoan tac
#
# tree = device/vendor tree (vd: device/xiaomi/xxx), mac dinh la thu muc hien tai.
# KHONG tro vao root source Android (script se tu choi).
 
set -euo pipefail
 
MODE="full"; ACTION="apply"; OVERLAY=""; TREE=""
 
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lite)    MODE="lite" ;;
    --revert)  ACTION="revert" ;;
    --overlay) OVERLAY="${2:?thieu duong dan file}"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *)         TREE="$1" ;;
  esac
  shift
done
 
TREE="$(cd "${TREE:-$PWD}" && pwd)"
 
if [[ -d "$TREE/build/make" || -d "$TREE/build/soong" ]]; then
  echo "Day la root source Android. Hay tro vao device/vendor tree cua may." >&2
  exit 1
fi
 
warn() { echo "[!] $*" >&2; }
find_tree() { find "$TREE" \( -name .git -o -name out \) -prune -o "$@"; }
 
# ---------- revert ----------
if [[ "$ACTION" == "revert" ]]; then
  n=0
  while IFS= read -r -d '' bak; do
    mv -f "$bak" "${bak%.blur.bak}"
    echo "Da khoi phuc: ${bak%.blur.bak}"
    n=$((n+1))
  done < <(find_tree -type f -name '*.blur.bak' -print0)
  if [[ -f "$TREE/blur_props.mk" ]]; then
    rm -f "$TREE/blur_props.mk"
    warn "Da xoa blur_props.mk - nho go dong inherit-product tro toi no (neu da them)."
  fi
  [[ $n -gt 0 ]] || echo "Khong co gi de khoi phuc."
  exit 0
fi
 
# ---------- apply ----------
backup() { [[ -f "$1.blur.bak" ]] || cp "$1" "$1.blur.bak"; }
 
# set_prop <key> <value> <product|system_ext>
# 1) neu key da co trong .prop/.mk nao do -> sua tai ccho (giu nguyen dau '\' cuoi dong cua .mk)
# 2) neu chua co -> them vao system_ext.prop/product.prop co san, khong co thi vao blur_props.mk
set_prop() {
  local key="$1" val="$2" part="$3" esc found=0 f
  esc="${key//./\\.}"
 
  while IFS= read -r -d '' f; do
    if grep -qE "^[[:space:]]*[^#]*${esc}=" "$f"; then
      backup "$f"
      sed -i "/^[[:space:]]*#/!s|\(${esc}=\)[^[:space:]\\\\]*|\1${val}|" "$f"
      echo "  sua   $(realpath --relative-to="$TREE" "$f"): ${key}=${val}"
      found=1
    fi
  done < <(find_tree -type f \( -name '*.prop' -o -name '*.mk' \) -print0)
  [[ $found -eq 1 ]] && return 0
 
  f="$(find_tree -type f -name "${part}.prop" -print -quit)"
  if [[ -n "$f" ]]; then
    backup "$f"
    [[ -n "$(tail -c1 "$f")" ]] && echo >> "$f"
    echo "${key}=${val}" >> "$f"
    echo "  them  $(realpath --relative-to="$TREE" "$f"): ${key}=${val}"
  else
    local var="PRODUCT_SYSTEM_EXT_PROPERTIES"
    [[ "$part" == "product" ]] && var="PRODUCT_PRODUCT_PROPERTIES"
    [[ -f "$TREE/blur_props.mk" ]] || echo "# Tao boi blur_all_roms.sh" > "$TREE/blur_props.mk"
    echo "${var} += ${key}=${val}" >> "$TREE/blur_props.mk"
    echo "  them  blur_props.mk: ${key}=${val}"
    NEED_INHERIT=1
  fi
}
 
NEED_INHERIT=0
echo "Che do: $MODE | Tree: $TREE"
 
if [[ "$MODE" == "full" ]]; then APP_BLUR=1; else APP_BLUR=0; fi
set_prop ro.launcher.blur.appLaunch                  "$APP_BLUR" product
set_prop ro.surface_flinger.supports_background_blur 1           system_ext
set_prop ro.sf.blurs_are_expensive                   1           system_ext
set_prop persist.sys.sf.disable_blurs                0           system_ext
 
# Overlay framework (chi o che do full, giong patch goc)
if [[ "$MODE" == "full" ]]; then
  f="$OVERLAY"
  if [[ -z "$f" ]]; then
    f="$(grep -rlE --include=config.xml --exclude-dir=.git --exclude-dir=out \
         'config_sf_slowBlur|config_enableBlurs' "$TREE" 2>/dev/null | grep '/overlay' | head -n1 || true)"
  fi
  if [[ -n "$f" && -f "$f" ]]; then
    backup "$f"
    if grep -q 'name="config_enableBlurs"' "$f"; then
      sed -i 's|\(<bool name="config_enableBlurs">\)[^<]*|\1true|' "$f"
    else
      sed -i 's|</resources>|    <bool name="config_enableBlurs">true</bool>\n</resources>|' "$f"
    fi
    echo "  overlay $(realpath --relative-to="$TREE" "$f"): config_enableBlurs=true"
  else
    warn "Khong tim thay overlay framework config.xml - bo qua buoc overlay."
    warn "Co the chi dinh bang: --overlay duong/dan/config.xml"
  fi
fi
 
echo
if [[ $NEED_INHERIT -eq 1 ]]; then
  warn "Da tao blur_props.mk. Them dong sau vao file device .mk chinh cua may:"
  warn '  $(call inherit-product, <duong_dan_toi>/blur_props.mk)'
fi
echo "Xong. Build lai ROM de co hieu luc. Hoan tac: $0 --revert \"$TREE\""
 
