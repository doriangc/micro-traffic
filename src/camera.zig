const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const Vec2 = @import("math.zig").Vec2;
const Mat4 = @import("math.zig").Mat4;

var cam: Vec2 = .{ .x = 0, .y = 0 };

var zoom: f32 = 0.1;
var keys: Keys = .{};
var drag: ?Vec2 = null; // last position of a single-finger drag
var touch1: ?Vec2 = null;
var touch2: ?Vec2 = null;

var pan_accum: Vec2 = .{ .x = 0, .y = 0 }; // camera movement since last frame (world units)
var pan_vel: Vec2 = .{ .x = 0, .y = 0 }; // smoothed velocity (world units/sec)
var predict: f32 = 0.0; // 0..1 blend, how much prediction is applied
var coasting: bool = false;
var last_pred: Vec2 = .{ .x = 0, .y = 0 }; // offset applied last frame

const pan_speed: f32 = 1.0;
const world_height: f32 = 10.0;
const min_zoom: f32 = -3.0;
const max_zoom: f32 = 3.0;

const lookahead: f32 = 0.02; // seconds to predict ahead; roughly your pipeline latency
const vel_tau: f32 = 0.04; // velocity smoothing time constant (seconds)
const fade_time: f32 = 0.08; // seconds to fade prediction in/out
const max_predict: f32 = 0.15; // cap, as a fraction of the visible height
const momentum_tau: f32 = 0.25; // seconds; velocity decays by 1/e every tau
const min_fling: f32 = 0.25; // visible-heights/sec needed to start a fling
const stop_speed: f32 = 0.02; // visible-heights/sec below which coasting ends

const Keys = struct { w: bool = false, a: bool = false, s: bool = false, d: bool = false };

fn releaseTouches(fling: bool) void {
    const was_touching = drag != null or touch1 != null;
    resetTouches();
    if (!was_touching) return;

    // Commit the prediction into the real camera so the view doesn't jump.
    cam.x += last_pred.x;
    cam.y += last_pred.y;
    last_pred = .{ .x = 0, .y = 0 };
    predict = 0;

    const view = world_height * @exp(zoom);
    const speed = std.math.hypot(pan_vel.x, pan_vel.y) / view;
    coasting = fling and speed > min_fling;
    if (!coasting) pan_vel = .{ .x = 0, .y = 0 };
}

fn halfExtents() Vec2 {
    const half_h = world_height * 0.5 * @exp(zoom);
    const aspect = sapp.widthf() / sapp.heightf();
    return .{ .x = half_h * aspect, .y = half_h };
}

/// sx, sy in logical window pixels (as reported by sapp events)
fn screenToWorld(sx: f32, sy: f32) Vec2 {
    const ndc_x = (sx / sapp.widthf()) * 2.0 - 1.0;
    const ndc_y = 1.0 - (sy / sapp.heightf()) * 2.0;
    const h = halfExtents();
    return .{
        .x = cam.x + ndc_x * h.x,
        .y = cam.y + ndc_y * h.y,
    };
}

/// Change zoom by `dz` (log units, positive = zoom out) keeping the
/// world point under (sx, sy) fixed on screen.
fn zoomAt(sx: f32, sy: f32, dz: f32) void {
    const before = screenToWorld(sx, sy);
    zoom = std.math.clamp(zoom + dz, min_zoom, max_zoom);
    const after = screenToWorld(sx, sy);
    cam.x += before.x - after.x;
    cam.y += before.y - after.y;
}

/// Move the camera so the world "follows" a screen-space drag of (dx, dy)
/// logical pixels. Content moves with your finger.
fn panByScreenDelta(dx: f32, dy: f32) void {
    const k = 2.0 * halfExtents().y / sapp.heightf();
    const wx = -dx * k;
    const wy = dy * k; // screen y is down, world y is up
    cam.x += wx;
    cam.y += wy;
    pan_accum.x += wx;
    pan_accum.y += wy;
}

fn resetTouches() void {
    drag = null;
    touch1 = null;
    touch2 = null;
}

fn updateKeyboardPan(dt: f32) void {
    var dx: f32 = 0;
    var dy: f32 = 0;
    if (keys.d) dx += 1;
    if (keys.a) dx -= 1;
    if (keys.w) dy += 1;
    if (keys.s) dy -= 1;
    if (dx == 0 and dy == 0) return;

    // normalize so diagonals aren't faster
    const len = @sqrt(dx * dx + dy * dy);
    // scale with zoom so panning feels the same at any zoom level
    const speed = world_height * @exp(zoom) * pan_speed;
    cam.x += dx / len * speed * dt;
    cam.y += dy / len * speed * dt;
}

fn predictionOffset(dt_raw: f32) Vec2 {
    const dt = @max(dt_raw, 0.001);
    const touching = drag != null or touch1 != null;

    if (!touching) {
        pan_accum = .{ .x = 0, .y = 0 };
        last_pred = .{ .x = 0, .y = 0 };
        return .{ .x = 0, .y = 0 };
    }

    const ix = pan_accum.x / dt;
    const iy = pan_accum.y / dt;
    pan_accum = .{ .x = 0, .y = 0 };

    const a = 1.0 - @exp(-dt / vel_tau);
    pan_vel.x += (ix - pan_vel.x) * a;
    pan_vel.y += (iy - pan_vel.y) * a;
    predict = @min(1.0, predict + dt / fade_time);

    const limit = world_height * @exp(zoom) * max_predict;
    const s = lookahead * predict;
    last_pred = .{
        .x = std.math.clamp(pan_vel.x * s, -limit, limit),
        .y = std.math.clamp(pan_vel.y * s, -limit, limit),
    };
    return last_pred;
}

fn updateMomentum(dt: f32) void {
    // A new touch cancels the glide.
    if (drag != null or touch1 != null) {
        coasting = false;
        return;
    }
    if (!coasting) return;

    // Exact integral of v * exp(-t/tau) over this frame, so it's frame-rate independent.
    const decay = @exp(-dt / momentum_tau);
    const travel = momentum_tau * (1.0 - decay);
    cam.x += pan_vel.x * travel;
    cam.y += pan_vel.y * travel;
    pan_vel.x *= decay;
    pan_vel.y *= decay;

    const view = world_height * @exp(zoom);
    if (std.math.hypot(pan_vel.x, pan_vel.y) / view < stop_speed) {
        coasting = false;
        pan_vel = .{ .x = 0, .y = 0 };
    }
}

pub export fn input(event: ?*const sapp.Event) void {
    const e = event orelse return;

    switch (e.type) {
        .MOUSE_SCROLL => {
            const s = std.math.clamp(e.scroll_y, -5.0, 5.0);
            zoomAt(e.mouse_x, e.mouse_y, -s * 0.05);
        },

        .KEY_DOWN, .KEY_UP => {
            const down = e.type == .KEY_DOWN;
            switch (e.key_code) {
                .W, .UP => keys.w = down,
                .A, .LEFT => keys.a = down,
                .S, .DOWN => keys.s = down,
                .D, .RIGHT => keys.d = down,
                else => {},
            }
        },

        // otherwise a key released while unfocused stays "held" forever
        .UNFOCUSED => keys = .{},

        .TOUCHES_MOVED => {
            if (e.num_touches == 1) {
                const p = Vec2{ .x = e.touches[0].pos_x, .y = e.touches[0].pos_y };
                if (drag) |last| {
                    panByScreenDelta(p.x - last.x, p.y - last.y);
                }
                drag = p;
                touch1 = null;
                touch2 = null;
            } else if (e.num_touches == 2) {
                drag = null;

                const t1 = Vec2{ .x = e.touches[0].pos_x, .y = e.touches[0].pos_y };
                const t2 = Vec2{ .x = e.touches[1].pos_x, .y = e.touches[1].pos_y };
                const mid = Vec2{ .x = (t1.x + t2.x) * 0.5, .y = (t1.y + t2.y) * 0.5 };

                if (touch1) |o1| {
                    if (touch2) |o2| {
                        const old_mid = Vec2{ .x = (o1.x + o2.x) * 0.5, .y = (o1.y + o2.y) * 0.5 };
                        panByScreenDelta(mid.x - old_mid.x, mid.y - old_mid.y);

                        const old_d = std.math.hypot(o2.x - o1.x, o2.y - o1.y);
                        const cur_d = std.math.hypot(t2.x - t1.x, t2.y - t1.y);
                        if (old_d > 1.0 and cur_d > 1.0) {
                            zoomAt(mid.x, mid.y, @log(old_d / cur_d));
                        }
                    }
                }
                touch1 = t1;
                touch2 = t2;
            }
        },

        // finger count changed: forget everything so we don't jump
        .TOUCHES_BEGAN => {
            releaseTouches(false); // commit any prediction, no fling
            coasting = false; // touching the screen stops the glide
            pan_vel = .{ .x = 0, .y = 0 };
        },
        .TOUCHES_ENDED => releaseTouches(true),
        .TOUCHES_CANCELLED => releaseTouches(false),

        else => {},
    }
}

pub fn update(dt: f32) Mat4 {
    updateKeyboardPan(dt);
    updateMomentum(dt);
    const pred = predictionOffset(dt);

    const h = halfExtents();
    const cx = cam.x + pred.x; // render camera = true camera + prediction
    const cy = cam.y + pred.y;
    const proj = Mat4.ortho(
        cx - h.x,
        cx + h.x,
        cy - h.y,
        cy + h.y,
        -1.0,
        1.0,
    );

    return proj;
}
