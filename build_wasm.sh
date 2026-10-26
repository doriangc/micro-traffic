#!/usr/bin/sh

cd "$(dirname "$0")"
zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast -Dcpu=baseline+atomics+bulk_memory