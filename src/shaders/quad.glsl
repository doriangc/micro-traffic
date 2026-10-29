/* quad vertex shader */
@header const m = @import("../math.zig")
@ctype mat4 m.Mat4

@vs vs
layout(binding=0) uniform vs_params {
    mat4 mvp;
};

/* per vert */
in vec2 vert_pos;
in vec2 texcoord0;

/* per instance */
in vec2 inst_pos;
in vec2 inst_size;
in vec4 inst_uv;
in vec4 inst_color;
in vec4 inst_rot;

out vec2 uv;
out vec4 color;

void main() {
    mat2 rot = mat2(inst_rot.xy, inst_rot.zw);
    gl_Position = mvp * vec4(rot * (vert_pos * inst_size) + inst_pos, 0.0, 1.0);

    uv = mix(inst_uv.xy, inst_uv.zw, texcoord0);
    color = inst_color;
}
@end

/* quad fragment shader */
@fs fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;

in vec2 uv;
in vec4 color;

out vec4 frag_color;

void main() {
    frag_color = color * texture(sampler2D(tex, smp), uv);
}
@end

/* quad shader program */
@program quad vs fs