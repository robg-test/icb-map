package ukmap

import "core:math"
import rl "vendor:raylib"

// Orbital camera: the map sits at the origin and the camera swings around it on
// a sphere. Pitch is clamped above the horizon so you never end up looking at
// the open underside of the slabs.
PITCH_MIN :: 8.0 * math.PI / 180.0
PITCH_MAX :: 85.0 * math.PI / 180.0
FOVY :: 38.0 // degrees, vertical

// Right-drag slides the orbit centre across the ground. The conversion below is
// exact for a top-down view; the flatter the angle, the further along the ground
// a pixel of vertical mouse travel reaches, hence the divide by sin(pitch). That
// runs away near the horizon, so it is clamped -- at PITCH_MIN the map would
// otherwise shoot off under the cursor.
PAN_PITCH_FLOOR :: 0.25

Orbit_Camera :: struct {
	target:      rl.Vector3,
	dist:        f32,
	min_dist:    f32,
	max_dist:    f32,
	yaw:         f32, // radians, 0 looks from the south
	pitch:       f32, // radians above the horizon
	follow:      bool,
	panning:     bool, // right-drag this frame; anything easing the target defers
	// Set while something else owns the distance -- focus mode's zoom in and
	// out. A wheel event mid-flight fights the ease, and on the way out it
	// clamps against a min_dist that has already been put back to the map's,
	// which snaps the view.
	zoom_locked: bool,
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
	}

	c.panning = false
	if rl.IsMouseButtonDown(.RIGHT) {
		if d := rl.GetMouseDelta(); d.x != 0 || d.y != 0 {
			orbit_pan(c, d)
		}
	}

	if wheel := rl.GetMouseWheelMove(); wheel != 0 && !c.zoom_locked {
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

// Drag the ground, not the camera: the point under the cursor should stay under
// it. Following the walker and sliding the map by hand are the same control, so
// grabbing it hands you the camera.
@(private = "file")
orbit_pan :: proc(c: ^Orbit_Camera, delta: rl.Vector2) {
	// world units per pixel at the distance of the orbit centre
	half_fov := f32(FOVY) * math.PI / 360
	per_pixel := 2 * c.dist * math.tan(half_fov) / f32(rl.GetScreenHeight())

	// the camera's own axes, flattened onto the ground
	forward := rl.Vector3{-math.sin(c.yaw), 0, -math.cos(c.yaw)}
	right := rl.Vector3{math.cos(c.yaw), 0, -math.sin(c.yaw)}

	c.target -= right * delta.x * per_pixel
	c.target += forward * delta.y * per_pixel / max(math.sin(c.pitch), PAN_PITCH_FLOOR)
	c.follow = false
	c.panning = true
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
		fovy = FOVY,
		projection = .PERSPECTIVE,
	}
}
