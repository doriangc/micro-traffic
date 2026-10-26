//------------------------------------------------------------------------------
//  shapes.zig
//
//  Simple sokol.shape demo.
//------------------------------------------------------------------------------
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
const mat4 = @import("math.zig").Mat4;
const assert = @import("std").debug.assert;
const shd = @import("shaders/quad.glsl.zig");

pub const panic = std.debug.FullPanic(wasmPanic);

fn wasmPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = ret_addr;
    @trap();
}

const Shape = struct {
    pos: vec3 = vec3.zero(),
    draw: sshape.ElementRange = .{},
};

const NUM_SHAPES = 5;

const Shared = struct {
    done: std.atomic.Value(bool) = .init(false),
    result: std.atomic.Value(u32) = .init(0),
};

const state = struct {
    var pass_action: sg.PassAction = .{};
    var pip: sg.Pipeline = .{};
    var bind: sg.Bindings = .{};
    var file_buffer: [256 * 1024]u8 = undefined;
    var rx: f32 = 0.0;
    var ry: f32 = 0.0;
    const view = mat4.lookat(.{ .x = 0.0, .y = 1.5, .z = 6.0 }, vec3.zero(), vec3.up());
    var fps: f64 = 0.0;
    var shared: Shared = .{};
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
            // positions,     uv
            -0.5, 0.5,  0.5, 0.0, 0.0,
            0.5,  0.5,  0.5, 1.0, 0.0,
            0.5,  -0.5, 0.5, 1.0, 1.0,
            -0.5, -0.5, 0.5, 0.0, 1.0,
        }),
    });

    // an index buffer
    state.bind.index_buffer = sg.makeBuffer(.{
        .usage = .{ .index_buffer = true },
        .data = sg.asRange(&[_]u16{ 0, 1, 2, 0, 2, 3 }),
    });

    state.bind.views[shd.VIEW_tex] = sg.allocView();

    state.bind.samplers[shd.SMP_smp] = sg.makeSampler(.{});

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
            l.attrs[shd.ATTR_quad_position].format = .FLOAT3;
            l.attrs[shd.ATTR_quad_texcoord0].format = .FLOAT2;
            break :init l;
        },
        .index_type = .UINT16,
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
    if (frame_time > 0.0) {
        const inst_fps = 1.0 / frame_time;
        state.fps = if (state.fps == 0.0) inst_fps else state.fps * 0.95 + inst_fps * 0.05;
    }
    sdtx.pos(0.5, 0.5);
    sdtx.print("fps: {d:.0}\n", .{state.fps});
    sdtx.print("backend: {s}\n", .{@tagName(sg.queryBackend())});

    if (state.shared.done.load(.acquire)) {
        const result = state.shared.result.load(.acquire);
        sdtx.print("result: {d}\n", .{result});
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
    sg.draw(0, 6, 1);
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
        .sample_count = 4,
        .icon = .{ .sokol_default = true },
        .window_title = "shapes.zig",
        .logger = .{ .func = slog.func },
    });
}
