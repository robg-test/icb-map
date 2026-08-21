package ukmap

import rl "vendor:raylib"

// Focus mode: space takes the ICB he is standing in and shows that alone --
// the rest of the country and the sea are simply not drawn, and the camera
// slides in to frame it. Space again puts the map back.
//
// Nothing is destroyed on the way in, so leaving is instant; the only work is
// the copy of the region into its own model (see uk_region_model). The walker is
// penned into the shown region for the duration (see Walker.confined), so which
// ICB is on show cannot change while the mode is on.

// On the map every slab is the same thickness, which is what makes it read as
// one carved board. Alone in focus mode there is nothing to compare against, so
// a small ICB at 0.26 thick is just a chimney -- the slab is squashed towards
// FOCUS_SLAB_MIN as the region gets smaller. Only the drawing changes; the mesh
// on disk is untouched.
FOCUS_SLAB_MIN :: 0.55
// Region width, in world units, at which it is shown at full thickness.
FOCUS_FULL_EXTENT :: 1.5

// Camera distance as a multiple of the region's radius. The map's own overview
// sits at 1.7x, but a single ICB is a much less interesting silhouette and
// wants a little more air around it.
FOCUS_FILL :: 3.0
// How fast the camera slides in and back out, as a per-second easing rate.
FOCUS_EASE :: 5.0
// Close enough to the framed view to hand the camera back to the user. Without
// this the ease would fight the mouse wheel for as long as the mode was on.
FOCUS_SETTLED :: 0.01

Focus :: struct {
	on:       bool,
	region:   int,
	model:    rl.Model,
	built:    bool,
	centre:   rl.Vector3,
	radius:   f32,
	settling: bool, // camera is still on its way to `centre` / `dist`
	dist:     f32, // distance being eased towards
	saved:    Orbit_Camera, // the view to come back to
}

// Show `region`, remembering the current view so it can be restored. Fails
// quietly if there is no such region -- standing on sea is not an error.
focus_enter :: proc(f: ^Focus, m: Uk_Map, land: Land, cam: ^Orbit_Camera, region: int) {
	if !focus_show(f, m, land, region) {
		return
	}
	f.saved = cam^
	f.on = true
	// The whole-map minimum is further out than a single ICB is wide, so it has
	// to come down or the zoom stops short of the region.
	cam.min_dist = f.radius * 0.5
	// Following the walker would drag the target off the region he is looking at.
	cam.follow = false
}

// `look_at` is where the camera should come back out to -- the walker, so the
// map reappears around him rather than snapping back to wherever the view
// happened to be when he zoomed in. The distance does go back to the saved one:
// that is the framing of the whole map, and it is what makes it read as zooming
// back out.
focus_leave :: proc(f: ^Focus, cam: ^Orbit_Camera, look_at: rl.Vector3) {
	if !f.on {
		return
	}
	f.on = false
	cam.min_dist = f.saved.min_dist
	cam.follow = f.saved.follow
	f.centre = look_at
	f.dist = f.saved.dist
	f.settling = true
	focus_unload(f)
}

@(private = "file")
focus_show :: proc(f: ^Focus, m: Uk_Map, land: Land, region: int) -> bool {
	model, ok := uk_region_model(m, region)
	if !ok {
		return false
	}
	focus_unload(f)
	f.model = model
	f.built = true
	f.region = region
	f.centre, f.radius = uk_region_bounds(m, region)
	f.centre.y *= focus_slab_scale(land, region) // aim at the squashed slab, not the baked one
	f.dist = f.radius * FOCUS_FILL
	f.settling = true
	return true
}

// Ease the camera towards the framed view, then stop and leave it to the user.
// The target is left alone when the camera is following the walker, which does
// its own easing of the same value.
focus_update :: proc(f: ^Focus, cam: ^Orbit_Camera, dt: f32) {
	if cam.panning {
		f.settling = false // he has taken the camera off us
	}
	cam.zoom_locked = f.settling // the ease owns the distance until it is done
	if !f.settling {
		return
	}
	k := min(1, FOCUS_EASE * dt)
	if !cam.follow {
		cam.target += (f.centre - cam.target) * k
	}
	cam.dist += (f.dist - cam.dist) * k

	near := rl.Vector3Length(f.centre - cam.target) < f.radius * FOCUS_SETTLED || cam.follow
	if near && abs(f.dist - cam.dist) < f.dist * FOCUS_SETTLED {
		f.settling = false
	}
}

// How much of its baked thickness the region on show is drawn at. Slabs are
// extruded up from y = 0, so this is a plain scale on Y -- and the walker has to
// stand on the squashed top, which is why he asks for it too.
focus_slab_scale :: proc(land: Land, district: int) -> f32 {
	t := clamp(land_extent(land, district) / FOCUS_FULL_EXTENT, 0, 1)
	return FOCUS_SLAB_MIN + (1 - FOCUS_SLAB_MIN) * t
}

focus_draw :: proc(f: Focus, land: Land) {
	if f.on && f.built {
		y := focus_slab_scale(land, f.region)
		rl.DrawModelEx(f.model, {0, 0, 0}, {0, 1, 0}, 0, {1, y, 1}, rl.WHITE)
	}
}

focus_unload :: proc(f: ^Focus) {
	if f.built {
		rl.UnloadModel(f.model)
		f.built = false
	}
}
