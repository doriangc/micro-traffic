/* quad vertex shader */
@header const m = @import("../math.zig")
@ctype mat4 m.Mat4

@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
};
in vec4 position;
in vec2 texcoord0;

out vec2 uv;

void main() {
    gl_Position = mvp * position;
    uv = texcoord0;
}
@end

/* quad fragment shader */
@fs fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;

in vec2 uv;
out vec4 frag_color;

void main() {
    frag_color = texture(sampler2D(tex, smp), uv);
}
@end

/* quad shader program */
@program quad vs fs