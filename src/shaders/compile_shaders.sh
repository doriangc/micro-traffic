#!/usr/bin/sh

cd "$(dirname "$0")"
sokol-shdc -i quad.glsl -f sokol_zig -l glsl300es:wgsl:glsl410 -o quad.glsl.zig