#!/bin/bash -eu
# Build the WASM version. Needs emscripten; point EMSDK_DIR at your emsdk
# checkout if `emcc` is not already on the PATH.
#
# Structure follows karl-zylinski/odin-raylib-web: the shared package is built
# to a wasm object, then emcc links it against raylib's wasm build and wraps it
# in the shell page.

EMSDK_DIR="${EMSDK_DIR:-$HOME/emsdk}"
OUT_DIR="build/web"

mkdir -p "$OUT_DIR"

export EMSDK_QUIET=1
[[ -f "$EMSDK_DIR/emsdk_env.sh" ]] && . "$EMSDK_DIR/emsdk_env.sh"

# RAYLIB_WASM_LIB=env.o points the bindings at an internal WASM object; the real
# library is handed to emcc below. See <odin>/vendor/raylib/raylib.odin.
odin build web \
	-target:js_wasm32 \
	-build-mode:obj \
	-define:RAYLIB_WASM_LIB=env.o \
	-o:speed \
	-out:"$OUT_DIR/ukmap.wasm.obj"

ODIN_PATH=$(odin root)
cp "$ODIN_PATH/core/sys/wasm/js/odin.js" "$OUT_DIR"

# ALLOW_MEMORY_GROWTH because the mesh is 15 MB and is copied once on upload.
emcc \
	-o "$OUT_DIR/index.html" \
	"$OUT_DIR/ukmap.wasm.obj" \
	"$ODIN_PATH/vendor/raylib/wasm/libraylib.a" \
	-sEXPORTED_RUNTIME_METHODS="['HEAPF32']" \
	-sUSE_GLFW=3 \
	-sWASM_BIGINT \
	-sWARN_ON_UNDEFINED_SYMBOLS=0 \
	-sALLOW_MEMORY_GROWTH=1 \
	-sINITIAL_MEMORY=64MB \
	-O2 \
	--shell-file web/index_template.html \
	--preload-file assets

rm "$OUT_DIR/ukmap.wasm.obj"

# The link-preview image is served as its own file. It deliberately does NOT go
# through --preload-file: that would bury it inside index.data, where no scraper
# could fetch it.
cp web/og.png "$OUT_DIR/og.png"

echo
echo "web build in $OUT_DIR -- serve it (the .wasm needs correct MIME types):"
echo "  python3 -m http.server -d $OUT_DIR 8000"
