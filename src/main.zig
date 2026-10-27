const std = @import("std");
const sokol = @import("sokol");
const slog = sokol.log;
const sfetch = sokol.fetch;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const sdtx = sokol.debugtext;
const sshape = sokol.shape;
const zigimg = @import("zigimg");

const vec3 = @import("math.zig").Vec3;
const vec2 = @import("math.zig").Vec2;
const mat4 = @import("math.zig").Mat4;
const assert = @import("std").debug.assert;
const shd = @import("shaders/quad.glsl.zig");

pub const panic = std.debug.FullPanic(wasmPanic);

fn wasmPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = ret_addr;
    @trap();
}

const SpriteInstance = extern struct {
    pos: [2]f32, // world position (or [3] if you want z-sorting)
    size: [2]f32, // world-space width/height
    uv_rect: [4]f32, // u0, v0, u1, v1 into the atlas
    color: [4]u8, // tint, normalized
    rotation: f32 = 0.0, // optional
};

const Shared = struct {
    done: std.atomic.Value(bool) = .init(false),
    result: std.atomic.Value(u32) = .init(0),
};

const max_sprite_count = 255;
const state = struct {
    var pass_action: sg.PassAction = .{};
    var pip: sg.Pipeline = .{};
    var bind: sg.Bindings = .{};
    var file_buffer: [256 * 1024]u8 = undefined;
    var shared: Shared = .{};

    var instances: [max_sprite_count]SpriteInstance = undefined;
    var sprite_count: u32 = 0;
};

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    sfetch.setup(.{
        .max_requests = 1,
        .num_channels = 1,
        .num_lanes = 1,
        .logger = .{ .func = slog.func },
    });

    state.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .data = sg.asRange(&[_]f32{
            // pos,     uv
            -0.5, 0.5,  0.0, 0.0,
            0.5,  0.5,  1.0, 0.0,
            0.5,  -0.5, 1.0, 1.0,
            -0.5, -0.5, 0.0, 1.0,
        }),
    });

    state.bind.vertex_buffers[1] = sg.makeBuffer(.{
        .size = max_sprite_count * @sizeOf(SpriteInstance),
        .usage = .{ .vertex_buffer = true, .write_transient = true },
    });

    state.instances[0] = .{
        .pos = .{ 0.0, 0.0 },
        .size = .{ 1.0, 2.0 },
        .uv_rect = .{ 0.0, 0.0, 1.0, 1.0 },
        .color = .{ 20, 63, 255, 255 },
    };
    state.instances[1] = .{
        .pos = .{ 1.0, 0.0 },
        .size = .{ 1.0, 2.0 },
        .uv_rect = .{ 0.0, 0.0, 1.0, 1.0 },
        .color = .{ 40, 255, 40, 255 },
    };
    state.instances[2] = .{
        .pos = .{ 2.0, 0.0 },
        .size = .{ 1.0, 2.0 },
        .uv_rect = .{ 0.0, 0.0, 1.0, 1.0 },
        .color = .{ 40, 255, 255, 255 },
    };
    state.instances[3] = .{
        .pos = .{ -1.0, 0.0 },
        .size = .{ 1.0, 2.0 },
        .uv_rect = .{ 0.0, 0.0, 1.0, 1.0 },
        .color = .{ 255, 255, 40, 255 },
    };
    state.sprite_count = 4;

    // an index buffer
    state.bind.index_buffer = sg.makeBuffer(.{
        .usage = .{ .index_buffer = true },
        .data = sg.asRange(&[_]u16{ 0, 1, 2, 0, 2, 3 }),
    });

    state.bind.views[shd.VIEW_tex] = sg.allocView();

    state.bind.samplers[shd.SMP_smp] = sg.makeSampler(.{
        .min_filter = .NEAREST,
    });

    var sdtx_desc: sdtx.Desc = .{
        .logger = .{ .func = slog.func },
    };
    sdtx_desc.fonts[0] = sdtx.fontOric();
    sdtx.setup(sdtx_desc);

    // a shader and pipeline state object
    state.pip = sg.makePipeline(.{
        .shader = sg.makeShader(shd.quadShaderDesc(sg.queryBackend())),
        .layout = init: {
            var l = sg.VertexLayoutState{};
            l.attrs[shd.ATTR_quad_vert_pos].format = .FLOAT2;
            l.attrs[shd.ATTR_quad_texcoord0].format = .FLOAT2;

            l.attrs[shd.ATTR_quad_inst_pos] = .{ .format = .FLOAT2, .buffer_index = 1 };
            l.attrs[shd.ATTR_quad_inst_size] = .{ .format = .FLOAT2, .buffer_index = 1 };
            l.attrs[shd.ATTR_quad_inst_uv] = .{ .format = .FLOAT4, .buffer_index = 1 };
            l.attrs[shd.ATTR_quad_inst_color] = .{ .format = .UBYTE4N, .buffer_index = 1 };
            l.attrs[shd.ATTR_quad_inst_rot] = .{ .format = .FLOAT, .buffer_index = 1 };

            l.buffers[1].step_func = .PER_INSTANCE;
            break :init l;
        },
        .index_type = .UINT16,
        .colors = init: {
            var c: [8]sg.ColorTargetState = @splat(.{});
            c[0].blend = .{
                .enabled = true,
                .src_factor_rgb = .SRC_ALPHA,
                .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                .src_factor_alpha = .ONE,
                .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
            };
            break :init c;
        },
    });

    // clear to black
    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    };

    _ = sfetch.send(.{
        .path = "assets/car.png", // native: relative to cwd; web: relative URL
        .callback = fetchCallback,
        .buffer = sfetch.asRange(&state.file_buffer),
    });
}

export fn frame() void {
    sfetch.dowork();
    // help text
    sdtx.canvas(sapp.widthf() * 0.5, sapp.heightf() * 0.5);

    const frame_time = sapp.frameDuration();
    const inst_fps = 1.0 / @max(frame_time, 0.0000001);
    sdtx.pos(0.5, 0.5);
    sdtx.print("fps: {d:.0}\n", .{inst_fps});
    sdtx.print("backend: {s}\n", .{@tagName(sg.queryBackend())});

    if (state.shared.done.load(.acquire)) {
        const result = state.shared.result.load(.acquire);
        sdtx.print("result: {d}\n", .{result});
    }

    if (state.sprite_count > 0) {
        sg.writeBufferTransient(.{
            .src = .{
                .data = sg.asRange(state.instances[0..state.sprite_count]),
            },
            .dst = .{
                .buffer = state.bind.vertex_buffers[1],
            },
        });
    }

    const world_height: f32 = 10.0; // units visible vertically
    const aspect = sapp.widthf() / sapp.heightf();
    const half_h = world_height * 0.5;
    const half_w = half_h * aspect;
    const proj = mat4.ortho(-half_w, half_w, -half_h, half_h, -1.0, 1.0);

    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.pip);
    sg.applyBindings(state.bind);
    sg.applyUniforms(shd.UB_vs_params, sg.asRange(&shd.VsParams{ .mvp = proj }));
    sg.draw(0, 6, state.sprite_count);
    sdtx.draw();
    sg.endPass();
    sg.commit();
}

export fn input(event: ?*const sapp.Event) void {
    _ = event;
}

export fn cleanup() void {
    sdtx.shutdown();
    sg.shutdown();
}

fn worker(shared: *Shared, io: std.Io) void {
    io.sleep(.fromSeconds(10), .awake) catch {};

    // heavy computation, no sokol/GL calls in here
    shared.result.store(1, .release);
    shared.done.store(true, .release);
}

fn fetchCallback(response: [*c]const sfetch.Response) callconv(.c) void {
    if (response.*.fetched) {
        const bytes: [*]const u8 = @ptrCast(response.*.data.ptr);
        const png = bytes[0..response.*.data.size];

        var rs = zigimg.io.ReadStream.initMemory(png);

        const decoded_img = zigimg.formats.png.load(
            &rs,
            std.heap.c_allocator,
            zigimg.formats.png.ReaderOptions.init(std.heap.c_allocator),
        ) catch |err| {
            std.log.err("decoding png failed: {}", .{err});
            return;
        };

        var data: sg.ImageData = .{};
        data.mip_levels[0] = sg.asRange(decoded_img.rawBytes());

        const img = sg.makeImage(.{
            .width = @intCast(decoded_img.width),
            .height = @intCast(decoded_img.height),
            .pixel_format = .RGBA8,
            .data = data,
        });

        sg.initView(
            state.bind.views[shd.VIEW_tex],
            .{ .texture = .{ .image = img } },
        );
    } else if (response.*.failed) {
        // response.*.error_code tells you why (FILE_NOT_FOUND, BUFFER_TOO_SMALL, ...)
        switch (response.*.error_code) {
            .BUFFER_TOO_SMALL => std.log.err("Buffer too small", .{}),
            .CANCELLED => std.log.err("Cancelled", .{}),
            .FILE_NOT_FOUND => std.log.err("File not found", .{}),
            .INVALID_HTTP_STATUS => std.log.err("Invalid HTTP status", .{}),
            .JS_OTHER => std.log.err("JS Other Error", .{}),
            .NO_BUFFER => std.log.err("No Buffer", .{}),
            .NO_ERROR => std.log.err("Failed without error", .{}),
            .UNEXPECTED_EOF => std.log.err("Unexpected EOF", .{}),
        }
    }
}

pub fn main(proc_init: std.process.Init) void {
    const io = proc_init.io;
    _ = io;

    // const t = std.Thread.spawn(.{}, worker, .{ &state.shared, io }) catch |err| {
    //     std.log.err("thread spawn failed: {}", .{err});
    //     return;
    // };
    // t.detach();

    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .event_cb = input,
        .cleanup_cb = cleanup,
        .width = 1920,
        .height = 1080,
        .high_dpi = true,
        .html5 = .{
            // .canvas_resize = true,
            .update_document_title = true,
        },
        .sample_count = 1,
        .icon = .{ .sokol_default = true },
        .window_title = "shapes.zig",
        .logger = .{ .func = slog.func },
    });
}
