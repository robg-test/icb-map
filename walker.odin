package ukmap

import "core:math"
import rl "vendor:raylib"

// The figure walking the map. At this scale one world unit is about 61 km, so a
// person would be far under a pixel -- he is a board-game piece, sized against
// the slab rather than against the country.
WALK_SPEED :: 1.6 // world units per second
RUN_MULT :: 2.5

// Focus mode shrinks him to the region, and it has to do the same to his pace:
// at the full 1.6 he crosses South West London in a sixth of a second, which
// zoomed in is a blur. So while he is penned in an ICB, speed is scaled so that
// crossing it takes about as long as crossing the reference region does at full
// speed -- everywhere feels like Norfolk and Suffolk, which is a comfortable
// second or so end to end.
WALK_PACE_CODE :: "E54000068" // NHS Norfolk and Suffolk ICB, 1.53 units across
WALK_PACE_MIN :: 0.15 // floor, so nothing can become an outright crawl
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
TORSO_R_BASE :: 0.072 // torso radius at the plinth
TORSO_R_TOP :: 0.048 // ...and at the shoulders; it tapers linearly between
SHOULDER_Y :: 0.235
ARM_SPAN :: 0.105
HEAD_Y :: 0.32
HEAD_R :: 0.058
BADGE_Y :: 0.19 // centre height of the logo on the chest

// Uniform shrink applied when he is drawn. The proportions above are the ones
// the mesh is built from; this is the one knob for how big the piece reads
// against the board.
FIGURE_SCALE :: 0.6
// He is that size everywhere on the map: the country is the thing with the
// scale on it, and a piece that changed size as you walked read as a bug.
//
// Focus mode is the exception. Zoomed in on one ICB there is no country to give
// him a sense of scale, and full size on South West London -- 0.27 units across
// -- is a man taller than the borough is wide. So he is cut down to the region,
// but only while it is the only thing on screen.
FIGURE_SCALE_MIN :: 0.30
FIGURE_FULL_EXTENT :: 1.5
// Squared, so the handful of city ICBs actually reach the floor instead of
// sitting halfway up a linear ramp -- most of England is between the two ends.
FIGURE_SCALE_CURVE :: 2
// Per-second easing of the size change, and of the step down onto the squashed
// slab, when focus mode opens and closes. Both look wrong as a jump-cut.
FIGURE_EASE :: 6.0

Walker :: struct {
	pos:        rl.Vector3,
	facing:     f32, // radians, 0 = north (-z)
	district:   int,
	on_land:    bool,
	stride:     f32, // accumulates while moving, drives the bob
	moving:     bool,
	scale:      f32, // fraction of FIGURE_SCALE, from the region he is on
	// Focus mode pens him inside the one ICB on show, or he would walk straight
	// off it into the space where the rest of the country is not being drawn.
	// The zero value is "anywhere on land", so an unconfigured Walker roams.
	confined:   bool,
	confine_to: int,
	pace_ref:   int, // region WALK_PACE_CODE resolved to, or -1
}

walker_make :: proc(land: Land) -> Walker {
	w := Walker {
		pos      = land_spawn(land),
		pace_ref = land_find(land, WALK_PACE_CODE),
	}
	w.district, w.on_land = land_at(land, w.pos.x, w.pos.z)
	// no easing on the way in: he is placed, not moved
	w.pos.y = walker_surface(w, land)
	w.scale = walker_scale(w, land)
	return w
}

// Full size on the map; sized to the region only when focus mode has him penned
// into it, which is the one time it is the only thing on screen.
walker_scale :: proc(w: Walker, land: Land) -> f32 {
	if !w.confined {
		return 1
	}
	t := clamp(land_extent(land, w.district) / FIGURE_FULL_EXTENT, 0, 1)
	return FIGURE_SCALE_MIN + (1 - FIGURE_SCALE_MIN) * math.pow(t, FIGURE_SCALE_CURVE)
}

// Fraction of full walking speed. 1 on the map; on a region he is penned into,
// its size against the reference region's. Falls back to full speed if the
// reference is missing, which only happens with a hand-built Land.
walker_pace :: proc(w: Walker, land: Land) -> f32 {
	reference := land_extent(land, w.pace_ref)
	if !w.confined || reference <= 0 {
		return 1
	}
	return clamp(land_extent(land, w.district) / reference, WALK_PACE_MIN, 1)
}

// The top of the slab he is standing on. Every slab is the same thickness, but
// focus mode squashes the one it shows, so he has to come down with it.
walker_surface :: proc(w: Walker, land: Land) -> f32 {
	if !w.confined {
		return land.surface_y
	}
	return land.surface_y * focus_slab_scale(land, w.district)
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
	pace := walker_pace(w^, land)

	w.moving = input.x != 0 || input.z != 0
	if w.moving {
		dir := rl.Vector3Normalize(input)
		step := dir * speed * pace * dt

		// full step first, then each axis alone, so the coastline is slid along
		// rather than stuck against
		if !walker_try_move(w, land, step.x, step.z) {
			moved := walker_try_move(w, land, step.x, 0)
			moved |= walker_try_move(w, land, 0, step.z)
			w.moving = moved
		}

		w.stride += dt * speed * pace // the bob has to slow down with him
		target := math.atan2(dir.x, dir.z)
		w.facing += math.angle_diff(w.facing, target) * min(1, TURN_RATE * dt)
	}

	w.district, w.on_land = land_at(land, w.pos.x, w.pos.z)

	// Ease onto the height and the size he should be. Both only move when focus
	// mode opens or closes, so this is doing nothing almost all of the time.
	k := min(1, FIGURE_EASE * dt)
	w.pos.y += (walker_surface(w^, land) - w.pos.y) * k
	w.scale += (walker_scale(w^, land) - w.scale) * k
}

@(private = "file")
walker_try_move :: proc(w: ^Walker, land: Land, dx, dz: f32) -> bool {
	if dx == 0 && dz == 0 {
		return false
	}
	x, z := w.pos.x + dx, w.pos.z + dz
	district, ok := land_at(land, x, z)
	if !ok {
		return false
	}
	if w.confined && district != w.confine_to {
		return false
	}
	w.pos.x, w.pos.z = x, z
	return true
}

walker_draw :: proc(w: Walker, fig: ^Figure, badge: ^Badge) {
	shadow := rl.Color{0, 0, 0, 90}

	// a walk cycle this small reads as a bob, so that is all it is
	scale := FIGURE_SCALE * w.scale
	bob := w.moving ? math.abs(math.sin(w.stride * 9)) * 0.02 * scale : 0
	base := w.pos + rl.Vector3{0, bob, 0}

	shadow_r := 0.115 * scale
	rl.DrawCylinder(w.pos + rl.Vector3{0, 0.004, 0}, shadow_r, shadow_r, 0.001, 20, shadow)
	figure_draw(fig, base, w.facing, scale)
	badge_draw(badge, base, w.facing, scale)
}
