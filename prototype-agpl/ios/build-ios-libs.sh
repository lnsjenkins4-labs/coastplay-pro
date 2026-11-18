#!/bin/bash
# PRIVATE PROTOTYPE (AGPL). Cross-compiles chiaki-ng and its dependencies for iOS.
#   ./build-ios-libs.sh iphonesimulator     (arm64 simulator)
#   ./build-ios-libs.sh iphoneos            (arm64 device)
# Output: ios/out/<sdk>/libchiaki-all.a and ios/out/<sdk>/include
set -euo pipefail
SDK="${1:-iphonesimulator}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
# Intermediate files live outside the project because pkg-config cannot handle the space in "Claude 1".
WORK="${RGP_IOS_WORK:-$HOME/Library/Caches/rgp-prototype-ios}"
SRC="$WORK/src"; PREFIX="$WORK/deps/$SDK"; BUILD="$WORK/build/$SDK"; OUT="$HERE/out/$SDK"
mkdir -p "$SRC" "$PREFIX" "$BUILD" "$OUT"

COMMON=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX"
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO)
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_PATH=""

fetch() { # name url tag
  [ -d "$SRC/$1" ] || git clone -q --depth 1 --branch "$3" "$2" "$SRC/$1"
}

echo "== libevent"
fetch libevent https://github.com/libevent/libevent.git release-2.1.12-stable
if [ ! -f "$PREFIX/lib/libevent.a" ]; then
  cmake -S "$SRC/libevent" -B "$BUILD/libevent" "${COMMON[@]}" -DEVENT__LIBRARY_TYPE=STATIC \
    -DEVENT__DISABLE_OPENSSL=ON -DEVENT__DISABLE_MBEDTLS=ON -DEVENT__DISABLE_TESTS=ON -DEVENT__DISABLE_REGRESS=ON \
    -DEVENT__DISABLE_BENCHMARK=ON -DEVENT__DISABLE_SAMPLES=ON >"$BUILD/libevent.log" 2>&1
  cmake --build "$BUILD/libevent" -j8 --target install >>"$BUILD/libevent.log" 2>&1
fi

echo "== opus"
fetch opus https://github.com/xiph/opus.git v1.5.2
if [ ! -f "$PREFIX/lib/libopus.a" ]; then
  cmake -S "$SRC/opus" -B "$BUILD/opus" "${COMMON[@]}" -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF \
    -DOPUS_BUILD_SHARED_LIBRARY=OFF >"$BUILD/opus.log" 2>&1
  cmake --build "$BUILD/opus" -j8 --target install >>"$BUILD/opus.log" 2>&1
fi

echo "== chiaki-ng"
cmake -S "$HERE" -B "$BUILD/chiaki" "${COMMON[@]}" -DPYTHON_EXECUTABLE="$ROOT/.venv/bin/python" \
  -DMBEDTLS_FATAL_WARNINGS=OFF -DCURL_ENABLE_SSL=ON -DCURL_USE_SECTRANSP=ON -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF \
  -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF >"$BUILD/chiaki-configure.log" 2>&1
cmake --build "$BUILD/chiaki" -j8 --target chiaki-lib >"$BUILD/chiaki-build.log" 2>&1

echo "== merge"
LIBS=$(find "$BUILD/chiaki" -name '*.a' -not -path '*/CMakeFiles/*')
# shellcheck disable=SC2086
libtool -static -o "$OUT/libchiaki-all.a" $LIBS "$PREFIX/lib/libevent.a" "$PREFIX/lib/libevent_core.a" \
  "$PREFIX/lib/libevent_extra.a" "$PREFIX/lib/libevent_pthreads.a" "$PREFIX/lib/libopus.a" 2>"$BUILD/libtool.log"
rm -rf "$OUT/include"; mkdir -p "$OUT/include"
cp -R "$ROOT/chiaki-ng/lib/include/chiaki" "$OUT/include/"
# ecdh.h pulls in mbedTLS headers when the library is built with mbedTLS.
cp -R "$BUILD/chiaki/_deps/mbedtls-src/include/mbedtls" "$OUT/include/"
[ -d "$BUILD/chiaki/_deps/mbedtls-src/include/psa" ] && cp -R "$BUILD/chiaki/_deps/mbedtls-src/include/psa" "$OUT/include/"
ls -la "$OUT/libchiaki-all.a"
lipo -info "$OUT/libchiaki-all.a"
echo "DONE $SDK"
