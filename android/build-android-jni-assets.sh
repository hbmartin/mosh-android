#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Terminal emulators (e.g. Ghostty) export TERMINFO; ncurses's tic would
# then install the terminfo database there instead of into the prefix.
unset TERMINFO TERMINFO_DIRS
WORK_DIR="${WORK_DIR:-"$ROOT_DIR/build/android-jni"}"
ANDROID_PLATFORM="${ANDROID_PLATFORM:-android-24}"
ABIS="${ABIS:-arm64-v8a armeabi-v7a x86 x86_64}"

ZLIB_VERSION="${ZLIB_VERSION:-v1.3.1}"
PROTOBUF_VERSION="${PROTOBUF_VERSION:-29.1}"
NCURSES_VERSION="${NCURSES_VERSION:-v6.4}"
GMP_VERSION="${GMP_VERSION:-v6.2.1}"
NETTLE_VERSION="${NETTLE_VERSION:-nettle_3.10_release_20240616}"

die() {
  echo "error: $*" >&2
  exit 1
}

need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

resolve_ndk() {
  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    echo "$ANDROID_NDK_HOME"
    return
  fi

  local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [[ -n "$sdk_root" && -d "$sdk_root/ndk" ]]; then
    find "$sdk_root/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1
    return
  fi

  for sdk_root in /opt/android-sdk /usr/local/lib/android/sdk "$HOME/Library/Android/sdk"; do
    if [[ -d "$sdk_root/ndk" ]]; then
      find "$sdk_root/ndk" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1
      return
    fi
  done
}

host_tag() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) echo "linux-x86_64" ;;
    Linux-aarch64 | Linux-arm64) echo "linux-x86_64" ;;
    Darwin-*) echo "darwin-x86_64" ;;
    *) die "unsupported build host $(uname -s)-$(uname -m)" ;;
  esac
}

protoc_platform() {
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) echo "linux-x86_64" ;;
    Linux-aarch64 | Linux-arm64) echo "linux-aarch_64" ;;
    Darwin-*) echo "osx-universal_binary" ;;
    *) die "unsupported build host $(uname -s)-$(uname -m)" ;;
  esac
}

# BSD and GNU sed disagree about -i; use perl for in-place edits.
delete_matching_lines() {
  local pattern="$1"
  local file="$2"
  perl -ni -e "print unless /$pattern/" "$file"
}

fetch_git() {
  local dest="$1"
  local url="$2"
  local ref="$3"
  shift 3

  if [[ ! -d "$dest/.git" ]]; then
    rm -rf "$dest"
    git clone --depth 1 --branch "$ref" "$@" "$url" "$dest"
  fi
}

download_protoc() {
  local platform="$1"
  local dest="$WORK_DIR/protoc-$PROTOBUF_VERSION-$platform"
  local zip_file="$WORK_DIR/protoc-$PROTOBUF_VERSION-$platform.zip"

  if [[ ! -x "$dest/bin/protoc" ]]; then
    rm -rf "$dest" "$zip_file"
    curl -fsSL \
      "https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOBUF_VERSION/protoc-$PROTOBUF_VERSION-$platform.zip" \
      -o "$zip_file"
    mkdir -p "$dest"
    unzip -q "$zip_file" -d "$dest"
  fi

  echo "$dest"
}

abi_config() {
  case "$1" in
    arm64-v8a) echo "aarch64-linux-android aarch64-linux-android" ;;
    armeabi-v7a) echo "arm-linux-androideabi armv7a-linux-androideabi" ;;
    x86) echo "i686-linux-android i686-linux-android" ;;
    x86_64) echo "x86_64-linux-android x86_64-linux-android" ;;
    *) die "unsupported ABI $1" ;;
  esac
}

# Installing the terminfo database needs a host tic new enough (>= 6.1)
# to compile modern entries; macOS ships 6.0.  Build one from the ncurses
# sources if the host's is too old.
ensure_host_tic() {
  local ver
  ver="$(tic -V 2>/dev/null | awk '{ print $2 }')"
  case "$ver" in
    6.[1-9]* | [7-9].* | [1-9][0-9].*) return ;;
  esac

  local prefix="$WORK_DIR/host-tools"
  if [[ ! -x "$prefix/bin/tic" ]]; then
    echo "host tic ${ver:-not found} is too old; building a native one"
    rm -rf "$WORK_DIR/host-ncurses"
    mkdir -p "$WORK_DIR/host-ncurses"
    (
      cd "$WORK_DIR/host-ncurses"
      "$SOURCES_DIR/ncurses/configure" \
        --prefix="$prefix" \
        --without-shared \
        --without-debug \
        --without-manpages \
        --disable-stripping
      make -s -j"$NCPU"
      make -s install
    )
  fi
  PATH="$prefix/bin:$PATH"
}

build_zlib() {
  local abi="$1"
  local prefix="$2"
  local build_dir="$3"

  if [[ -f "$prefix/lib/libz.a" ]]; then
    return
  fi

  cmake -S "$SOURCES_DIR/zlib" -B "$build_dir/zlib" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_C_FLAGS="$CFLAGS"
  cmake --build "$build_dir/zlib" --target install --parallel "$NCPU"
}

patch_protobuf_pkg_config() {
  local prefix="$1"
  local absl_log_pc="$prefix/lib/pkgconfig/absl_log_internal_log_sink_set.pc"

  if [[ -f "$absl_log_pc" ]] &&
    ! grep -q -- '-Wl,-Bdynamic -llog -Wl,-Bstatic' "$absl_log_pc"; then
    perl -pi -e 's/ -llog/ -Wl,-Bdynamic -llog -Wl,-Bstatic/' "$absl_log_pc"
  fi
}

build_protobuf() {
  local abi="$1"
  local prefix="$2"
  local build_dir="$3"

  if [[ -f "$prefix/lib/libprotobuf.a" ]]; then
    patch_protobuf_pkg_config "$prefix"
    return
  fi

  cmake -S "$SOURCES_DIR/protobuf" -B "$build_dir/protobuf" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_PREFIX_PATH="$prefix" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$CFLAGS" \
    -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++" \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_SHARED_LIBS=OFF \
    -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
    -Dprotobuf_BUILD_LIBPROTOC=OFF \
    -Dprotobuf_WITH_ZLIB=ON \
    -DABSL_PROPAGATE_CXX_STD=ON
  cmake --build "$build_dir/protobuf" --target install --parallel "$NCPU"
  patch_protobuf_pkg_config "$prefix"
}

build_ncurses() {
  local host="$1"
  local prefix="$2"
  local build_dir="$3"

  if [[ -f "$prefix/lib/libtinfo.a" && -f "$prefix/lib/pkgconfig/tinfo.pc" && -d "$prefix/share/terminfo" ]]; then
    return
  fi

  mkdir -p "$build_dir/ncurses"
  (
    cd "$build_dir/ncurses"
    "$SOURCES_DIR/ncurses/configure" \
      --prefix="$prefix" \
      --enable-pc-files \
      --with-pkg-config-libdir="$prefix/lib/pkgconfig" \
      --without-shared \
      --without-debug \
      --without-manpages \
      --disable-stripping \
      --with-termlib \
      CC="$CC" \
      CFLAGS="$CFLAGS -DHAVE_TSEARCH=0" \
      CXX="$CXX" \
      CXXFLAGS="$CXXFLAGS" \
      LD="$CC" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      --host="$host" \
      --target="$host"
    make -s -j"$NCPU"
    make -s install
  )
}

build_gmp() {
  local host="$1"
  local prefix="$2"
  local build_dir="$3"

  if [[ -f "$prefix/lib/libgmp.a" ]]; then
    return
  fi

  local src_dir="$build_dir/gmp-src"
  rm -rf "$src_dir" "$build_dir/gmp"
  rsync -a "$SOURCES_DIR/gmp/" "$src_dir/"
  perl -pi -e 's/ doc//' "$src_dir/Makefile.in"
  mkdir -p "$build_dir/gmp"
  (
    cd "$build_dir/gmp"
    "$src_dir/configure" \
      --prefix="$prefix" \
      --enable-cxx \
      --enable-alloca=alloca \
      --disable-shared \
      --with-pic \
      CC="$CC" \
      CFLAGS="$CFLAGS" \
      CXX="$CXX" \
      CXXFLAGS="$CXXFLAGS" \
      LD="$CC" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      --host="$host" \
      --target="$host"
    make -s -j"$NCPU"
    make -s install
  )
}

build_nettle() {
  local host="$1"
  local prefix="$2"
  local build_dir="$3"

  if [[ -f "$prefix/lib/libnettle.a" ]]; then
    return
  fi

  local src_dir="$build_dir/nettle-src"
  rm -rf "$src_dir"
  rsync -a "$SOURCES_DIR/nettle/" "$src_dir/"
  (
    cd "$src_dir"
    autoreconf -fvi
    ./configure \
      --prefix="$prefix" \
      CC="$CC" \
      CFLAGS="$CFLAGS" \
      CXX="$CXX" \
      CXXFLAGS="$CXXFLAGS" \
      LD="$CC" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      ASM_FLAGS="$ASMFLAGS" \
      --host="$host" \
      --target="$host" \
      --with-include-path="$prefix/include" \
      --with-lib-path="$prefix/lib"
    make -s -j"$NCPU" libnettle.a
    make -s install
  )
}

build_mosh_jni_lib() {
  local host="$1"
  local prefix="$2"
  local build_dir="$3"
  local package_dir="$4"
  local abi="$5"

  local src_dir="$build_dir/mosh-src"
  rm -rf "$src_dir"
  rsync -a --exclude .git --exclude build "$ROOT_DIR/" "$src_dir/"

  (
    cd "$src_dir"
    ./autogen.sh
  )

  (
    cd "$src_dir"
    env \
      PATH="$PROTOC_DIR/bin:$PATH" \
      PKG_CONFIG="pkg-config --static" \
      PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/share/pkgconfig" \
      PROTOC="$PROTOC_DIR/bin/protoc" \
      CC="$CC" \
      CXX="$CXX" \
      CFLAGS="$CFLAGS" \
      CXXFLAGS="$CXXFLAGS" \
      CPPFLAGS="-I$prefix/include" \
      LDFLAGS="$LDFLAGS -L$prefix/lib" \
      AR="$AR" \
      RANLIB="$RANLIB" \
      ./configure \
        --prefix="$prefix/mosh" \
        --host="$host" \
        --target="$host" \
        --enable-client \
        --disable-server \
        --disable-examples \
        --enable-android-jni \
        --without-utempter \
        --with-crypto-library=nettle \
        --with-curses="$prefix" \
        --enable-static-libraries \
        --enable-static-libstdc++ \
        --enable-static-protobuf \
        --enable-static-zlib \
        --enable-static-curses \
        --enable-static-crypto
    make -s -j"$NCPU"
  )

  mkdir -p "$package_dir/jniLibs/$abi"
  cp "$src_dir/src/frontend/libmosh-client.so" "$package_dir/jniLibs/$abi/libmosh-client.so"
  # Keeps .dynsym (the JNI exports); drops debug info and .symtab.
  "$STRIP" --strip-unneeded "$package_dir/jniLibs/$abi/libmosh-client.so"
  chmod 644 "$package_dir/jniLibs/$abi/libmosh-client.so"
  cp "$prefix/share/terminfo.zip" "$package_dir/terminfo.zip"
}

package_and_validate() {
  local abi="$1"
  local package_dir="$2"
  local output="$WORK_DIR/mosh-android-jni-$abi.zip"
  local lib="$package_dir/jniLibs/$abi/libmosh-client.so"

  [[ -f "$lib" ]] || die "$lib is missing"
  [[ -f "$package_dir/terminfo.zip" ]] || die "$package_dir/terminfo.zip is missing"

  local elf_header
  elf_header="$("$READELF" -h "$lib")"
  grep -q 'Type:[[:space:]]*DYN' <<<"$elf_header" \
    || die "$lib is not a shared object"

  # Capture once: grep -q's early exit would SIGPIPE readelf, which
  # pipefail would misreport as a failure.
  local dyn_syms sym
  dyn_syms="$("$READELF" --dyn-syms "$lib")"
  for sym in JNI_OnLoad Java_org_mosh_MoshClient_nativeMoshClientMain \
    Java_org_mosh_MoshClient_nativeNotifyWindowSizeChanged mosh_client_main; do
    grep -q "$sym" <<<"$dyn_syms" \
      || die "$lib does not export $sym"
  done

  local needed
  needed="$("$READELF" -d "$lib" | awk '/NEEDED/ { gsub(/[\[\]]/, "", $NF); print $NF }')"
  local entry
  for entry in $needed; do
    case "$entry" in
      libc.so | libm.so | libdl.so | liblog.so) ;;
      *) die "$lib depends on non-system library $entry; it must be self-contained" ;;
    esac
  done

  # Android 15+ requires 16 KB page-size compatible alignment.
  "$READELF" -l "$lib" | awk '/LOAD/ { print $NF }' | while read -r align; do
    [[ $((align)) -ge 16384 ]] || die "$lib has a LOAD segment aligned to $align (< 16384)"
  done

  rm -f "$output"
  (
    cd "$package_dir"
    zip -q -X -r "$output" jniLibs terminfo.zip
  )
}

need_tool curl
need_tool git
need_tool make
need_tool perl
need_tool rsync
need_tool unzip
need_tool zip
need_tool cmake
need_tool ninja
need_tool autoreconf
need_tool pkg-config

if [[ "${KEEP_WORK_DIR:-0}" != "1" ]]; then
  rm -rf "$WORK_DIR"
fi
mkdir -p "$WORK_DIR"

ANDROID_NDK_HOME="$(resolve_ndk)"
[[ -n "$ANDROID_NDK_HOME" && -d "$ANDROID_NDK_HOME" ]] || die "ANDROID_NDK_HOME must point to an Android NDK installation"

ANDROID_API="${ANDROID_PLATFORM#android-}"
[[ "$ANDROID_API" =~ ^[0-9]+$ ]] || die "ANDROID_PLATFORM must look like android-24"

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$(host_tag)"
[[ -d "$TOOLCHAIN" ]] || die "could not find NDK LLVM toolchain at $TOOLCHAIN"

NCPU="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
SOURCES_DIR="$WORK_DIR/sources"
mkdir -p "$SOURCES_DIR"
# Only clear the zips being rebuilt; a partial-ABI run (ABIS=...) must
# not delete the other ABIs' outputs.
for abi in $ABIS; do
  rm -f "$WORK_DIR/mosh-android-jni-$abi.zip"
done

PROTOC_DIR="$(download_protoc "$(protoc_platform)")"

fetch_git "$SOURCES_DIR/zlib" https://github.com/madler/zlib.git "$ZLIB_VERSION"
fetch_git "$SOURCES_DIR/protobuf" https://github.com/protocolbuffers/protobuf.git "v$PROTOBUF_VERSION" --recurse-submodules --shallow-submodules
fetch_git "$SOURCES_DIR/ncurses" https://github.com/mirror/ncurses.git "$NCURSES_VERSION"
fetch_git "$SOURCES_DIR/gmp" https://github.com/alisw/GMP.git "$GMP_VERSION"
fetch_git "$SOURCES_DIR/nettle" https://gitlab.com/gnutls/nettle.git "$NETTLE_VERSION" --config core.autocrlf=input

delete_matching_lines tsearch "$SOURCES_DIR/ncurses/configure"

ensure_host_tic

for abi in $ABIS; do
  read -r HOST CLANG_TARGET <<<"$(abi_config "$abi")"

  CC="$TOOLCHAIN/bin/${CLANG_TARGET}${ANDROID_API}-clang"
  CXX="$TOOLCHAIN/bin/${CLANG_TARGET}${ANDROID_API}-clang++"
  AR="$TOOLCHAIN/bin/llvm-ar"
  RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
  READELF="$TOOLCHAIN/bin/llvm-readelf"
  STRIP="$TOOLCHAIN/bin/llvm-strip"

  [[ -x "$CC" ]] || die "missing compiler $CC"
  [[ -x "$CXX" ]] || die "missing compiler $CXX"

  # -fPIC (not -fPIE) so every object can be linked into libmosh-client.so;
  # configure's hardening checks still add -fPIE/-pie for plain executables.
  COMMON_FLAGS="-fPIC -D_FORTIFY_SOURCE=2 -fstack-protector-all -fno-strict-overflow -w"
  CFLAGS="$COMMON_FLAGS -std=gnu17"
  CXXFLAGS="$COMMON_FLAGS -std=gnu++17"
  ASMFLAGS="--target=$HOST -w -D_FORTIFY_SOURCE=2 -fPIC"
  LDFLAGS="-Wl,-z,max-page-size=16384"

  build_dir="$WORK_DIR/build-$abi"
  prefix="$WORK_DIR/prefix-$abi"
  package_dir="$WORK_DIR/package-$abi"
  rm -rf "$package_dir"
  mkdir -p "$build_dir" "$prefix" "$package_dir"

  build_zlib "$abi" "$prefix" "$build_dir"
  build_protobuf "$abi" "$prefix" "$build_dir"
  build_ncurses "$HOST" "$prefix" "$build_dir"
  rm -f "$prefix/share/terminfo.zip"
  (
    cd "$prefix"
    zip -q -X -r "$prefix/share/terminfo.zip" share/terminfo
  )
  build_gmp "$HOST" "$prefix" "$build_dir"
  build_nettle "$HOST" "$prefix" "$build_dir"
  build_mosh_jni_lib "$HOST" "$prefix" "$build_dir" "$package_dir" "$abi"
  package_and_validate "$abi" "$package_dir"
done

ls -lh "$WORK_DIR"/mosh-android-jni-*.zip
