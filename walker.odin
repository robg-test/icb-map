package ukmap

import "core:math"
import rl "vendor:raylib"

// The figure walking the map. At this scale one world unit is about 61 km, so a
// person would be far under a pixel -- he is a board-game piece, sized against
// the slab rather than against the country.
WALK_SPEED :: 1.6 // world units per second
RUN_MULT :: 2.5
TURN_RATE :: 12.0 // radians per second the model swings round to face travel

// NHS identity palette, per the NHS digital service manual.
NHS_BLUE :: rl.Color{0x00, 0x5e, 0xb8, 255}
NHS_DARK_BLUE :: rl.Color{0x00, 0x30, 0x87, 255}
NHS_PALE_GREY :: rl.Color{0xae, 0xb7, 0xbd, 255}
NHS_WHITE :: rl.Color{0xff, 0xff, 0xff, 255}

// Proportions of the piece, in world units above the map surface.
PLINTH_H :: 0.03
PLINTH_R :: 0.085
TORSO_TOP :: 0.26
SHOULDER_Y :: 0.235
ARM_SPAN :: 0.105
HEAD_Y :: 0.32
HEAD_R :: 0.058
BADGE_Y :: 0.19

Walker :: struct {
	pos:      rl.Vector3,
	facing:   f32, // radians, 0 = north (-z)
	district: int,
	on_land:  bool,
	stride:   f32, // accumulates while moving, drives the bob
	moving:   bool,
}

walker_make :: proc(land: Land) -> Walker {
	w := Walker {
		pos = land_spawn(land),
	}
	w.district, w.on_land = land_at(land, w.pos.x, w.pos.z)
	return w
}

walker_update :: proc(w: ^Walker, land: Land, cam_yaw: f32, dt: f32) {
	// movement is relative to the camera, so "forward" always means away from you
	forward := rl.Vector3{-math.sin(cam_yaw), 0, -math.cos(cam_yaw)}
	right := rl.Vector3{-forward.z, 0, forward.x}

	input: rl.Vector3
	if rl.IsKeyDown(.W) do input += forward
	if rl.IsKeyDown(.S) do input -= forward
	if rl.IsKeyDown(.D) do input += right
	if rl.IsKeyDown(.A) do input -= right

	speed: f32 = WALK_SPEED * (rl.IsKeyDown(.LEFT_SHIFT) ? RUN_MULT : 1)
	walker_step(w, land, input, speed, dt)
}

// Split out from the input handling so it can be tested without a window.
walker_step :: proc(w: ^Walker, land: Land, input: rl.Vector3, speed, dt: f32) {
	w.moving = input.x != 0 || input.z != 0
	if w.moving {
		dir := rl.Vector3Normalize(input)
		step := dir * speed * dt

		// full step first, then each axis alone, so the coastline is slid along
		// rather than stuck against
		if !walker_try_move(w, land, step.x, step.z) {
			moved := walker_try_move(w, land, step.x, 0)
			moved |= walker_try_move(w, land, 0, step.z)
			w.moving = moved
		}

		w.stride += dt * speed
		target := math.atan2(dir.x, dir.z)
		w.facing += math.angle_diff(w.facing, target) * min(1, TURN_RATE * dt)
	}

	w.pos.y = land.surface_y
	w.district, w.on_land = land_at(land, w.pos.x, w.pos.z)
}

@(private = "file")
walker_try_move :: proc(w: ^Walker, land: Land, dx, dz: f32) -> bool {
	if dx == 0 && dz == 0 {
		return false
	}
	x, z := w.pos.x + dx, w.pos.z + dz
	if _, ok := land_at(land, x, z); !ok {
		return false
	}
	w.pos.x, w.pos.z = x, z
	return true
}

walker_draw :: proc(w: Walker, cam: rl.Camera3D, fig: ^Figure, badge: Badge) {
	shadow := rl.Color{0, 0, 0, 90}

	// a walk cycle this small reads as a bob, so that is all it is
	bob := w.moving ? math.abs(math.sin(w.stride * 9)) * 0.02 : 0
	base := w.pos + rl.Vector3{0, bob, 0}

	rl.DrawCylinder(w.pos + rl.Vector3{0, 0.004, 0}, 0.115, 0.115, 0.001, 20, shadow)
	figure_draw(fig, base, w.facing)
	badge_draw(badge, cam, base + {0, BADGE_Y, 0})
}
