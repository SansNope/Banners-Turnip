#!/bin/bash -e
set -o pipefail

deps="ninja patchelf unzip curl pip flex bison zip git perl glslangValidator python3"
workdir="$(pwd)/turnip_workdir"
repo_root="$(pwd)"
ndkver="android-ndk-r28"
target_sdk="35"
mesa_ref="${MESA_REF:-26.1}"
variant="${VARIANT:-wfm}"

check_deps(){
	for dep in $deps; do
		if ! command -v $dep >/dev/null 2>&1; then echo "Missing: $dep"; exit 1; fi
	done
	pip install meson mako --break-system-packages &> /dev/null || true
}

prepare_ndk(){
	mkdir -p "$workdir" && cd "$workdir"
	if [ ! -d "$ndkver" ]; then
		curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
		unzip -q "${ndkver}-linux.zip" &> /dev/null
	fi
    export ANDROID_NDK_HOME="$workdir/$ndkver"
}

compile_mesa() {
    local repo_url="https://gitlab.freedesktop.org/mesa/mesa.git"
    local branch="$mesa_ref"
    local build_name="Turnip-Unleashed-$variant"
    local output_tag="unleashed-$variant"

    echo "Cloning Mesa ($branch)..."

    cd "$workdir"
    rm -rf mesa

    if [[ "$branch" =~ ^[0-9a-f]{7,40}$ ]]; then
        # MESA_REF is an exact commit SHA. A blobless partial clone pulls the full commit
        # graph cheaply (blobs on demand at checkout), so any main commit is reachable -
        # unlike "-b <sha>" which git rejects, or a shallow clone that may not include it.
        echo "Fetching Mesa at commit $branch (blobless partial clone)..."
        git clone --filter=blob:none "$repo_url" mesa
        cd mesa
        git checkout --detach "$branch"
    else
        git clone --depth 100 -b "$branch" "$repo_url" mesa
        cd mesa
    fi
    echo "Mesa commit: $(git rev-parse HEAD) ($(cat VERSION))"

    local plist=""
    case "$variant" in
        clean)          plist="" ;;  # pristine upstream, no patches (for Mesa-maintainer repro)
        wfm)            plist="0001" ;;
        wfm-nogenclear) plist="0001 0002" ;;
        wfm-novpcattr)  plist="0001 0003" ;;
        wfm-a732)       plist="0001 0004" ;;
        wfm-a710)       plist="0001 0008" ;;
        wfm-univ)       plist="0001 0004 0009" ;;
        wfm-smart1)     plist="0005" ;;
        wfm-smart2)     plist="0006" ;;
        wfm-smart3)     plist="0007" ;;
        *) echo "Unknown VARIANT=$variant"; exit 1 ;;
    esac
    for p in $plist; do
        echo "Applying patch ${p}..."
        patch -p1 -N --fuzz=3 < "$repo_root"/patches-unleashed/${p}-*.patch
    done

    mkdir -p subprojects && cd subprojects
    rm -rf spirv-tools spirv-headers
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
    cd ..

    local build_dir="$workdir/mesa/build"
    rm -rf "$build_dir"

    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sys="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    local cver="35"
    [ ! -f "$ndk_bin/aarch64-linux-android${cver}-clang" ] && cver="34"

    cat <<EOF > android-cross.txt
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android${cver}-clang', '--sysroot=$ndk_sys']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android${cver}-clang++', '--sysroot=$ndk_sys']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin/aarch64-linux-android-strip'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
[built-in options]
c_link_args = ['-static-libstdc++']
cpp_link_args = ['-static-libstdc++']
EOF
    
    export CFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"
    export CXXFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"

    meson setup "$build_dir" --cross-file android-cross.txt \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=35 \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dglx=disabled \
        -Dvulkan-beta=true \
        -Ddefault_library=shared \
        -Dzstd=disabled \
        -Dwerror=false \
        --force-fallback-for=spirv-tools,spirv-headers
    
    ninja -C "$build_dir"

    local lib="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
    if [ ! -f "$lib" ]; then echo "Build Failed"; exit 1; fi
    
    local pkg_dir="$workdir/pkg_$output_tag"
    mkdir -p "$pkg_dir"
    cp "$lib" "$pkg_dir/vulkan.ad07XX.so"
    cd "$pkg_dir"
    patchelf --set-soname "vulkan.adreno.so" vulkan.ad07XX.so
    
    echo "{
  \"schemaVersion\": 1,
  \"name\": \"$build_name\",
  \"description\": \"Mesa Main Clean Build (SDK 35)\",
  \"author\": \"StevenMX\",
  \"packageVersion\": \"1\",
  \"vendor\": \"Mesa\",
  \"driverVersion\": \"$output_tag\",
  \"minApi\": 28,
  \"libraryName\": \"vulkan.ad07XX.so\"
}" > meta.json
    
    zip -9 "$workdir/Turnip-${output_tag}.zip" vulkan.ad07XX.so meta.json
    echo "Done: Turnip-${output_tag}.zip"
}

check_deps
prepare_ndk
compile_mesa
