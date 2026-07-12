#!/usr/bin/env bash
# Linux Android cross-build of whitebelyash turnip/gen8 + RP-PAIR
# Mirrors NewDriver Windows recipe: NDK r29, API 34, platform-sdk 36, kgsl, no LTO.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${WORKDIR:-$ROOT/workdir}"
MESA_REPO="${MESA_REPO:-https://github.com/whitebelyash/mesa-unified.git}"
MESA_REF="${MESA_REF:-7fdde2f8f865dddc7dd709c8c184fd5fad014f63}"
NDK_VERSION="${NDK_VERSION:-android-ndk-r29}"
NDK_ZIP_URL="${NDK_ZIP_URL:-https://dl.google.com/android/repository/${NDK_VERSION}-linux.zip}"
API_LEVEL="${API_LEVEL:-34}"
PLATFORM_SDK="${PLATFORM_SDK:-36}"
JOBS="${JOBS:-$(nproc)}"
PACKAGE_NAME="${PACKAGE_NAME:-Turnip-NewDriver-wb-26.2-RP-PAIR-LINUX}"

echo "=== NewDriver Linux RP-PAIR build ==="
echo "MESA_REPO=$MESA_REPO"
echo "MESA_REF=$MESA_REF"
echo "NDK=$NDK_VERSION API=$API_LEVEL SDK=$PLATFORM_SDK"
echo "WORKDIR=$WORKDIR"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# --- deps (Debian/Ubuntu) ---
# SKIP_APT=1 to skip package install if you already prepared the host.
APT_PKGS=(
  git curl unzip ca-certificates ninja-build
  python3 python3-pip python3-setuptools python3-mako python3-venv
  flex bison pkg-config patchelf zip ccache
  glslang-tools
)
if [ "${SKIP_APT:-0}" != "1" ] && command -v apt-get >/dev/null 2>&1; then
  if [ "$(id -u)" -eq 0 ]; then
    APT="apt-get"
  elif command -v sudo >/dev/null 2>&1; then
    APT="sudo apt-get"
  else
    echo "Need root or sudo for apt, or set SKIP_APT=1"
    exit 1
  fi
  $APT update -qq
  # glslang-tools is optional on older Debian; continue if missing
  DEBIAN_FRONTEND=noninteractive $APT install -y -qq "${APT_PKGS[@]}" \
    > /tmp/apt-newdriver.log 2>&1 || {
      echo "Full apt set failed; retry without glslang-tools ..."
      DEBIAN_FRONTEND=noninteractive $APT install -y -qq \
        git curl unzip ca-certificates ninja-build \
        python3 python3-pip python3-setuptools python3-mako python3-venv \
        flex bison pkg-config patchelf zip ccache \
        > /tmp/apt-newdriver.log 2>&1 || {
          echo "apt install failed, see /tmp/apt-newdriver.log"
          tail -80 /tmp/apt-newdriver.log || true
          exit 1
        }
    }
fi

# meson: prefer pip (newer than Debian stable)
python3 -m pip install --user -q 'meson>=1.3' mako 2>/dev/null || \
  python3 -m pip install --user -q --break-system-packages 'meson>=1.3' mako
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# glslangValidator: package or download official release binary
if ! command -v glslangValidator >/dev/null 2>&1; then
  echo "glslangValidator missing — fetching Khronos release binary ..."
  GLS_VER="${GLSLANG_VER:-15.1.0}"
  GLS_URL="https://github.com/KhronosGroup/glslang/releases/download/${GLS_VER}/glslang-main-linux-Release.zip"
  mkdir -p "$WORKDIR/tools"
  curl -L --retry 3 -o "$WORKDIR/tools/glslang.zip" "$GLS_URL" || true
  if [ -f "$WORKDIR/tools/glslang.zip" ]; then
    unzip -qo "$WORKDIR/tools/glslang.zip" -d "$WORKDIR/tools/glslang" || true
    # find binary
    GLS_BIN="$(find "$WORKDIR/tools/glslang" -type f -name glslangValidator 2>/dev/null | head -1 || true)"
    if [ -n "${GLS_BIN:-}" ]; then
      chmod +x "$GLS_BIN"
      export PATH="$(dirname "$GLS_BIN"):$PATH"
    fi
  fi
fi

command -v meson
command -v ninja
command -v git
command -v glslangValidator || {
  echo "ERROR: glslangValidator not found. Install package glslang-tools or set PATH."
  exit 1
}
# free space hint
df -h "$WORKDIR" | tail -1 || true

# --- NDK ---
if [ ! -d "$WORKDIR/$NDK_VERSION" ]; then
  echo "Downloading $NDK_VERSION ..."
  curl -L --retry 3 -o "$NDK_VERSION-linux.zip" "$NDK_ZIP_URL"
  unzip -q "$NDK_VERSION-linux.zip"
  rm -f "$NDK_VERSION-linux.zip"
fi
export ANDROID_NDK_HOME="$WORKDIR/$NDK_VERSION"
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
NDK_SYS="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
test -x "$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang"

# --- Mesa ---
if [ ! -d mesa/.git ]; then
  echo "Cloning Mesa (blobless) ..."
  git clone --filter=blob:none "$MESA_REPO" mesa
fi
cd mesa
git fetch --filter=blob:none origin "$MESA_REF" 2>/dev/null || true
git checkout --force --detach "$MESA_REF"
git reset --hard "$MESA_REF"
git clean -fdx -e build || true
echo "Mesa commit: $(git rev-parse HEAD) ($(cat VERSION))"

# RP-PAIR patch
PATCH="$ROOT/patches/0010-renderpass-clean-wfm-pair.patch"
if [ ! -f "$PATCH" ]; then
  echo "ERROR: missing $PATCH"
  exit 1
fi
# drop any previous apply residue
git checkout -- src/freedreno/vulkan/tu_cmd_buffer.cc 2>/dev/null || true
echo "Applying RP-PAIR ..."
if ! git apply --check "$PATCH" 2>/tmp/rp-pair-check.err; then
  # fallback: patch(1) with fuzz
  if ! patch -p1 --forward --dry-run < "$PATCH" >/tmp/rp-pair-dry.log 2>&1; then
    echo "Patch does not apply cleanly:"
    cat /tmp/rp-pair-check.err || true
    cat /tmp/rp-pair-dry.log || true
    exit 1
  fi
  patch -p1 --forward < "$PATCH"
else
  git apply "$PATCH"
fi
grep -n "CACHE_CLEAN | TU_CMD_FLAG_WAIT_FOR_ME" src/freedreno/vulkan/tu_cmd_buffer.cc

# cross file
cat > "$WORKDIR/android-cross-api${API_LEVEL}.ini" <<EOF
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = ['ccache', '$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang', '--sysroot=$NDK_SYS']
cpp = ['ccache', '$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang++', '--sysroot=$NDK_SYS']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$NDK_BIN/llvm-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[built-in options]
c_args = ['-D__ANDROID__', '-Wno-error', '-Wno-deprecated-declarations']
cpp_args = ['-D__ANDROID__', '-Wno-error', '-Wno-deprecated-declarations', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables']
cpp_link_args = ['-static-libstdc++']
EOF

BUILD_DIR="$WORKDIR/mesa/build-rp-pair"
rm -rf "$BUILD_DIR"

echo "Meson setup ..."
meson setup "$BUILD_DIR" \
  --cross-file "$WORKDIR/android-cross-api${API_LEVEL}.ini" \
  -Dbuildtype=release \
  -Db_lto=false \
  -Dplatforms=android \
  -Dplatform-sdk-version="$PLATFORM_SDK" \
  -Dandroid-stub=true \
  -Dgallium-drivers= \
  -Dvulkan-drivers=freedreno \
  -Dfreedreno-kmds=kgsl \
  -Degl=disabled \
  -Dglx=disabled \
  -Dvulkan-beta=true \
  -Ddefault_library=shared \
  -Dzstd=disabled \
  -Dspirv-tools=disabled \
  -Dwerror=false \
  -Dandroid-libbacktrace=disabled

echo "Ninja (jobs=$JOBS) ..."
ninja -C "$BUILD_DIR" -j"$JOBS" src/freedreno/vulkan/libvulkan_freedreno.so

LIB="$BUILD_DIR/src/freedreno/vulkan/libvulkan_freedreno.so"
test -f "$LIB"
"$NDK_BIN/llvm-strip" --strip-unneeded "$LIB" || true

# package
OUT="$WORKDIR/package"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$LIB" "$OUT/libvulkan_freedreno.so"
SHA="$(sha256sum "$OUT/libvulkan_freedreno.so" | awk '{print $1}')"
SIZE="$(stat -c%s "$OUT/libvulkan_freedreno.so")"
GIT_SHORT="$(git rev-parse --short=10 HEAD)"
MESA_VER="$(cat VERSION)"

cat > "$OUT/meta.json" <<EOF
{
  "schemaVersion": 1,
  "name": "$PACKAGE_NAME",
  "description": "whitebelyash turnip/gen8 @ $GIT_SHORT + RP-PAIR, Linux NDK $NDK_VERSION API$API_LEVEL SDK$PLATFORM_SDK kgsl no-LTO",
  "author": "NewDriver",
  "packageVersion": "wb-rp-pair-linux-1",
  "vendor": "Mesa",
  "driverVersion": "wb-$GIT_SHORT-rp-pair-linux",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so",
  "mesaVersion": "$MESA_VER",
  "mesaCommit": "$(git rev-parse HEAD)",
  "soSize": $SIZE,
  "soSha256": "$SHA"
}
EOF

ZIP="$WORKDIR/${PACKAGE_NAME}.zip"
rm -f "$ZIP"
( cd "$OUT" && zip -9 "$ZIP" libvulkan_freedreno.so meta.json )
cp "$LIB" "$WORKDIR/vulkan.newdriver_wb_rp_pair_linux.so"

echo ""
echo "=== BUILD OK ==="
echo "ZIP:  $ZIP"
echo "SO:   $LIB"
echo "size: $SIZE"
echo "sha:  $SHA"
echo "git:  $(git rev-parse HEAD)"
ls -la "$ZIP" "$OUT/libvulkan_freedreno.so"
