package ukmap

import "core:math"
import rl "vendor:raylib"

// Orbital camera: the map sits at the origin and the camera swings around it on
// a sphere. Pitch is clamped above the horizon so you never end up looking at
// the open underside of the slabs.
PITCH_MIN :: 8.0 * math.PI / 180.0
PITCH_MAX :: 85.0 * math.PI / 180.0

Orbit_Camera :: struct {
	target:    rl.Vector3,
	dist:      f32,
	min_dist:  f32,
	max_dist:  f32,
	yaw:       f32, // radians, 0 looks from the south
	pitch:     f32, // radians above the horizon
	auto_spin: bool,
	follow:    bool,
}

// Ease the orbit centre onto a moving target instead of snapping to it.
orbit_follow :: proc(c: ^Orbit_Camera, target: rl.Vector3, dt: f32) {
	c.target += (target - c.target) * min(1, 6 * dt)
}

// Defaults chosen to open on a low, close, three-quarter view: shallow enough
// that the extruded sides read, close enough to fill the frame, and still wide
// enough to hold the whole country from Cornwall to Shetland.
orbit_make :: proc(target: rl.Vector3, radius: f32) -> Orbit_Camera {
	return Orbit_Camera {
		target = target,
		dist = radius * 1.70,
		min_dist = radius * 0.35,
		max_dist = radius * 8,
		yaw = -14.0 * math.PI / 180.0,
		pitch = 21.0 * math.PI / 180.0,
	}
}

orbit_update :: proc(c: ^Orbit_Camera, dt: f32) {
	if rl.IsMouseButtonDown(.LEFT) {
		d := rl.GetMouseDelta()
		c.yaw -= d.x * 0.006
		c.pitch = clamp(c.pitch + d.y * 0.006, PITCH_MIN, PITCH_MAX)
	} else if c.auto_spin {
		c.yaw += 0.15 * dt
	}

	if wheel := rl.GetMouseWheelMove(); wheel != 0 {
		c.dist = clamp(c.dist * math.pow(0.88, wheel), c.min_dist, c.max_dist)
	}

	// keyboard mirrors the mouse so it works without one
	turn := f32(0)
	if rl.IsKeyDown(.LEFT) do turn -= 1
	if rl.IsKeyDown(.RIGHT) do turn += 1
	c.yaw += turn * 1.2 * dt

	tilt := f32(0)
	if rl.IsKeyDown(.UP) do tilt += 1
	if rl.IsKeyDown(.DOWN) do tilt -= 1
	c.pitch = clamp(c.pitch + tilt * 0.9 * dt, PITCH_MIN, PITCH_MAX)
}

orbit_rl :: proc(c: Orbit_Camera) -> rl.Camera3D {
	cp := math.cos(c.pitch)
	offset := rl.Vector3 {
		math.sin(c.yaw) * cp * c.dist,
		math.sin(c.pitch) * c.dist,
		math.cos(c.yaw) * cp * c.dist,
	}
	return rl.Camera3D {
		position = c.target + offset,
		target = c.target,
		up = {0, 1, 0},
		fovy = 38,
		projection = .PERSPECTIVE,
	}
}
