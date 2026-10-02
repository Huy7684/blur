#!/usr/bin/env bash
# Static blur (cache) + lite blur cho AOSP RenderEngine (Skia), Android 13+ / A16+.
# Tu dong do file, ten bien, ten hang. Khong can sua tay.
#   bash patch_static_blur.sh [AOSP_ROOT]            # ap patch
#   bash patch_static_blur.sh [AOSP_ROOT] --revert   # hoan tac
#   NO_LITE=1 ... de bo qua lite blur
set -euo pipefail
ROOT="${1:-$PWD}"; MODE="${2:-apply}"
RE="$ROOT/frameworks/native/libs/renderengine"
[ -d "$RE" ] || { echo "Khong thay $RE (truyen dung AOSP root)"; exit 1; }

if [ "$MODE" = "--revert" ]; then
  n=0
  while IFS= read -r -d '' o; do cp "$o" "${o%.orig}"; rm "$o"; n=$((n+1)); done \
    < <(find "$RE" -name '*.orig' -print0)
  find "$RE" -name 'BlurCache.h' -delete
  echo "Da hoan tac $n file."; exit 0
fi

python3 - "$RE" "${NO_LITE:-0}" <<'PY'
import os, re, sys, shutil
RE, no_lite = sys.argv[1], sys.argv[2] == "1"

HEADER = r'''// BLUR_STATIC_CACHE (auto-generated)
#pragma once
#include <android-base/properties.h>
#if __has_include(<include/core/SkRect.h>)
#include <include/core/SkRect.h>
#else
#include <SkRect.h>
#endif
#include <algorithm>
#include <cstdint>
#include <list>
#include <mutex>
#include <type_traits>
#include <vector>
namespace android::renderengine::skia::blurcache {
// Ban kinh blur duoc lam tron LEN theo bac, va blur that duoc tinh o chinh ban kinh bac do.
// => keo thanh dieu huong / shade: moi bac chi blur 1 lan, cac frame con lai dung lai anh cu
// (do mo tang dan nho crossfade o drawBlurRegion, khong can blur lai).
// Chinh bac luc chay: setprop persist.sys.blur_static_step 64
//   bac lon  = it lan blur hon, gan nhu tinh ngay tu dau, nhung do mo bi lam tron manh hon
//   1        = khong gom (blur theo tung gia tri chinh xac)
inline void addKey(std::vector<int64_t>& k, const SkRect& r, int64_t) {
    k.push_back((int64_t)r.left()); k.push_back((int64_t)r.top());
    k.push_back((int64_t)r.right()); k.push_back((int64_t)r.bottom());
}
inline void addKey(std::vector<int64_t>& k, const SkIRect& r, int64_t) {
    k.push_back(r.left()); k.push_back(r.top()); k.push_back(r.right()); k.push_back(r.bottom());
}
template <class T>
inline void addKey(std::vector<int64_t>& k, const T& v, int64_t step) {
    if constexpr (std::is_arithmetic_v<std::decay_t<T>>) {
        k.push_back((static_cast<int64_t>(v) + step - 1) / step);
    }
}
template <class T>
inline std::decay_t<T> quant(const T& v, int64_t step) {
    if constexpr (std::is_arithmetic_v<std::decay_t<T>>) {
        return static_cast<std::decay_t<T>>(((static_cast<int64_t>(v) + step - 1) / step) * step);
    } else {
        return v;
    }
}
template <class F>
inline decltype(auto) deref(F&& f) {
    if constexpr (std::is_pointer_v<std::decay_t<F>>) return *f;
    else if constexpr (requires { *f; }) return *f;
    else return (f);
}
// Tat luc chay: setprop persist.sys.blur_static false
template <class F, class... A>
auto generate(F&& filterRef, A&&... args) {
    auto& filter = deref(filterRef);
    using Ret = decltype(filter.generate(args...));
    if constexpr (std::is_void_v<Ret>) {
        return filter.generate(args...);
    } else {
        if (!android::base::GetBoolProperty("persist.sys.blur_static", true)) {
            return filter.generate(args...);
        }
        const int64_t step =
                std::max<int64_t>(1, android::base::GetIntProperty("persist.sys.blur_static_step", 32));
        static std::mutex m;
        static std::list<std::pair<std::vector<int64_t>, Ret>> cache;  // LRU
        std::vector<int64_t> key;
        (addKey(key, args, step), ...);
        std::lock_guard<std::mutex> lock(m);
        for (auto it = cache.begin(); it != cache.end(); ++it) {
            if (it->first == key) { cache.splice(cache.begin(), cache, it); return it->second; }
        }
        Ret r = filter.generate(quant(args, step)...);  // blur o ban kinh da lam tron len
        if (r) { cache.emplace_front(key, r); if (cache.size() > 4) cache.pop_back(); }
        return r;
    }
}
}  // namespace android::renderengine::skia::blurcache
'''

call_re = re.compile(r'\b([A-Za-z_]*[Bb]lur[A-Za-z_]*)\s*(?:->|\.)\s*generate\(')
patched, skipped, already = [], [], []
for dp, _, fns in os.walk(RE):
    if re.search(r'/(tests?|benchmark)(/|$)', dp + "/"): continue
    for fn in fns:
        if not fn.endswith((".cpp", ".cc")): continue
        p = os.path.join(dp, fn)
        src = open(p, errors="ignore").read()
        if "blurcache::generate" in src: already.append(p); continue
        if "BlurFilter" not in src: continue
        if not call_re.search(src): continue
        # Chi thay khi doi tuong la filter (mBlurFilter...), khong dung ten ham trong chinh BlurFilter
        if re.search(r'\b(Kawase|Gaussian)?BlurFilter::generate\(', src): skipped.append(p); continue
        hdr_dir = os.path.join(RE, "skia", "filters")
        os.makedirs(hdr_dir, exist_ok=True)
        hdr = os.path.join(hdr_dir, "BlurCache.h")
        if not os.path.exists(hdr): open(hdr, "w").write(HEADER)
        rel = os.path.relpath(hdr, dp).replace(os.sep, "/")
        shutil.copy(p, p + ".orig")
        new, n = call_re.subn(lambda m: f"android::renderengine::skia::blurcache::generate({m.group(1)}, ", src)
        lines = new.split("\n")
        inc = [i for i, l in enumerate(lines[:200]) if l.startswith("#include")]
        lines.insert((inc[-1] + 1) if inc else 0, f'#include "{rel}"')
        open(p, "w").write("\n".join(lines))
        patched.append((os.path.relpath(p, RE), n))

print("== STATIC BLUR ==")
if patched:
    for f, n in patched: print(f"  OK  {f}: {n} loi goi")
elif already:
    print(f"  Da patch truoc do ({len(already)} file), bo qua.")
    sys.exit(0)
else:
    print("  KHONG tim thay loi goi generate() nao de patch.")

print("== LITE BLUR ==")
if no_lite:
    print("  Bo qua (NO_LITE=1)")
else:
    lite = []
    def edit(p, rules):
        src = open(p, errors="ignore").read(); new = src
        for pat, rep, desc in rules:
            new2, c = re.subn(pat, rep, new, count=1)
            if c:
                new = new2; lite.append(f"{os.path.basename(p)}: {desc}")
        if new != src:
            if not os.path.exists(p + ".orig"): shutil.copy(p, p + ".orig")
            open(p, "w").write(new)
    def cut(m):  # kMaxSurfaces N -> N-1 (toi thieu 2)
        n = max(2, int(m.group(2)) - 1)
        return f"{m.group(1)}{n}"
    for dp, _, fns in os.walk(RE):
        for fn in fns:
            p = os.path.join(dp, fn)
            if fn in ("KawaseBlurFilter.h", "KawaseBlurFilter.cpp"):
                # Kawase thuong: giam downscale va so pass
                edit(p, [
                    (r'(\bkInputScale\s*=\s*)0?\.25(f?)\b', r'\g<1>0.125\2', "kInputScale 0.25 -> 0.125"),
                    (r'(\bkMaxPasses\s*=\s*)4\b', r'\g<1>2', "kMaxPasses 4 -> 2"),
                ])
            elif fn in ("KawaseBlurDualFilter.cpp", "KawaseBlurDualFilterV2.cpp"):
                # Dual/V2: shader hardcode 4x downscale -> KHONG doi kInputScale, chi giam so surface
                edit(p, [(r'(constexpr\s+int\s+kMaxSurfaces\s*=\s*)(\d+)', cut, "kMaxSurfaces giam 1 bac")])
    if lite:
        for l in lite: print("  OK ", l)
    else:
        print("  Khong thay hang nao de giam. Static blur van hoat dong.")

sys.exit(0 if patched else 2)
PY
rc=$?
[ $rc -eq 0 ] && echo "Xong. Build lai: mm trong frameworks/native/libs/renderengine (hoac make surfaceflinger)."
