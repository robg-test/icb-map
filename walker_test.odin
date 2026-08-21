// core:testing pulls in core:os, which does not exist on wasm.
#+build !wasm32
#+build !wasm64p32

package ukmap

import "core:math"
import "core:testing"
import rl "vendor:raylib"

// Run from the repo root: `make test`. These load the generated assets, so they
// double as a check that the build tool's output is sane.

@(private = "file")
load :: proc(t: ^testing.T) -> (Land, bool) {
	land, ok := land_load(LAND_PATH)
	if !testing.expect(t, ok, "assets/uk.land failed to load -- run `make mesh`") {
		return {}, false
	}
	return land, true
}

@(test)
land_grid_is_sane :: proc(t: ^testing.T) {
	land, ok := load(t)
	if !ok do return
	defer land_unload(land)

	testing.expect(t, land.w > 0 && land.h > 0, "grid has no cells")
	testing.expect(t, land.cell > 0, "cell size must be positive")
	testing.expect(t, land.surface_y > 0, "walkable surface should sit above y=0")
	// 36 English ICBs plus Scotland, Wales and Northern Ireland
	testing.expect(t, len(land.names) == 39, "expected 39 regions")

	for name, i in land.names {
		testing.expectf(t, len(name) > 0, "district %d has no name", i)
	}

	// every cell must reference a district that exists
	for value in land.cells {
		testing.expectf(
			t,
			int(value) <= len(land.names),
			"cell references district %d of %d",
			value,
			len(land.names),
		)
	}
}

@(test)
land_at_rejects_outside_the_grid :: proc(t: ^testing.T) {
	land, ok := load(t)
	if !ok do return
	defer land_unload(land)

	far := f32(1e6)
	_, on := land_at(land, far, far)
	testing.expect(t, !on, "a point far outside the grid should not be land")
	_, on = land_at(land, -far, -far)
	testing.expect(t, !on, "a negative point outside the grid should not be land")
}

@(test)
walker_spawns_on_land :: proc(t: ^testing.T) {
	land, ok := load(t)
	if !ok do return
	defer land_unload(land)

	w := walker_make(land)
	testing.expect(t, w.on_land, "walker spawned in the sea")
	testing.expect(t, w.pos.y == land.surface_y, "walker is not on the surface")
}

@(test)
walker_spawns_in_the_configured_region :: proc(t: ^testing.T) {
	land, ok := load(t)
	if !ok do return
	defer land_unload(land)

	w := walker_make(land)
	testing.expectf(
		t,
		w.on_land && land.codes[w.district] == SPAWN_CODE,
		"spawned in %v, expected %v",
		w.on_land ? land.codes[w.district] : "the sea",
		SPAWN_CODE,
	)
}

@(test)
walker_cannot_walk_into_the_sea :: proc(t: ^testing.T) {
	land, ok := load(t)
	if !ok do return
	defer land_unload(land)

	// push hard in each of the four directions for far longer than it takes to
	// cross the country; he must never end up off land
	for dir in ([?]rl.Vector3{{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}) {
		w := walker_make(land)
		start := w.pos
		for _ in 0 ..< 4000 {
			walker_step(&w, land, dir, WALK_SPEED * RUN_MULT, 1.0 / 60)
			if !testing.expectf(
				t,
				w.on_land,
				"walked into the sea heading %v at %v",
				dir,
				w.pos,
			) {
				break
			}
		}
		// and the coast has to stop him eventually, or the land test is a no-op
		testing.expectf(
			t,
			rl.Vector3Distance(start, w.pos) < 30,
			"heading %v he ran clean off the map",
			dir,
		)
	}
}

// A synthetic island: land west of x = 3.2, sea east of it. The real coastline
// is full of inlets a walker can wedge into, which makes it a bad place to test
// the sliding rule -- a straight edge makes the expected behaviour exact.
@(private = "file")
test_land :: proc() -> Land {
	land := Land {
		w         = 64,
		h         = 128,
		cell      = 0.1,
		surface_y = 0.26,
		names     = make([]string, 1),
		countries = make([]u8, 1),
		extents   = make([]f32, 1),
		cells     = make([]u16, 64 * 128),
		raw       = nil, // no file behind this one, so nothing for raylib to free
	}
	land.names[0] = "Testshire"
	land.countries[0] = 'E'
	land.extents[0] = 3.2
	for j in 0 ..< land.h {
		for i in 0 ..< 32 {
			land.cells[j * land.w + i] = 1
		}
	}
	return land
}

@(test)
walker_stops_at_the_coast :: proc(t: ^testing.T) {
	land := test_land()
	defer land_unload(land)

	w := Walker {
		pos = {1.0, land.surface_y, 6.4},
	}
	for _ in 0 ..< 600 {
		walker_step(&w, land, {1, 0, 0}, WALK_SPEED, 1.0 / 60)
	}

	testing.expect(t, w.on_land, "walked off the east coast")
	testing.expectf(
		t,
		w.pos.x > 3.2 - land.cell && w.pos.x <= 3.2,
		"stopped at x=%v, expected to be against the coast at 3.2",
		w.pos.x,
	)
	testing.expect(t, !w.moving, "should report being blocked, not walking")
}

@(test)
walker_slides_along_the_coast :: proc(t: ^testing.T) {
	land := test_land()
	defer land_unload(land)

	// pinned against the east coast...
	w := Walker {
		pos = {1.0, land.surface_y, 6.4},
	}
	for _ in 0 ..< 600 {
		walker_step(&w, land, {1, 0, 0}, WALK_SPEED, 1.0 / 60)
	}
	pinned := w.pos

	// ...then pushed north-east: east is blocked, so he should still travel north
	for _ in 0 ..< 200 {
		walker_step(&w, land, {1, 0, -1}, WALK_SPEED, 1.0 / 60)
	}

	testing.expect(t, w.on_land, "slid off the coast into the sea")
	testing.expectf(
		t,
		pinned.z - w.pos.z > 1.0,
		"blocked eastward but only moved %v north",
		pinned.z - w.pos.z,
	)
	testing.expectf(
		t,
		abs(w.pos.x - pinned.x) < land.cell,
		"leaked %v eastward through the coast",
		w.pos.x - pinned.x,
	)
}

@(test)
walker_faces_where_he_walks :: proc(t: ^testing.T) {
	land, ok := load(t)
	if !ok do return
	defer land_unload(land)

	w := walker_make(land)
	for _ in 0 ..< 120 {
		walker_step(&w, land, {1, 0, 0}, WALK_SPEED, 1.0 / 60)
	}
	// facing is measured as atan2(x, z), so due east is +pi/2
	testing.expectf(
		t,
		abs(math.angle_diff(w.facing, math.PI / 2)) < 0.05,
		"walking east he faces %v rad",
		w.facing,
	)
}

@(test)
walker_stays_inside_the_region_he_is_penned_to :: proc(t: ^testing.T) {
	land, ok := load(t)
	if !ok do return
	defer land_unload(land)

	// what focus mode does: pen him into the ICB he is standing in
	for dir in ([?]rl.Vector3{{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}) {
		w := walker_make(land)
		w.confined = true
		w.confine_to = w.district
		for _ in 0 ..< 4000 {
			walker_step(&w, land, dir, WALK_SPEED * RUN_MULT, 1.0 / 60)
			if !testing.expectf(
				t,
				w.on_land && w.district == w.confine_to,
				"left %v for %v heading %v",
				land.names[w.confine_to],
				w.on_land ? land.names[w.district] : "the sea",
				dir,
			) {
				break
			}
		}
	}
}

@(test)
walker_roams_between_regions_when_not_penned :: proc(t: ^testing.T) {
	land, ok := load(t)
	if !ok do return
	defer land_unload(land)

	// the confinement must be opt-in, or focus mode would break the whole map
	w := walker_make(land)
	start := w.district
	crossed := false
	for _ in 0 ..< 4000 {
		walker_step(&w, land, {0, 0, -1}, WALK_SPEED * RUN_MULT, 1.0 / 60)
		if w.on_land && w.district != start {
			crossed = true
			break
		}
	}
	testing.expect(t, crossed, "walking north never left the spawn region")
}

@(test)
pace_only_changes_when_he_is_penned_in :: proc(t: ^testing.T) {
	land, ok := load(t)
	if !ok do return
	defer land_unload(land)

	w := walker_make(land)
	testing.expect(t, walker_pace(w, land) == 1, "roaming the map should be full speed")

	w.confined = true
	w.confine_to = w.district
	testing.expect(t, walker_pace(w, land) < 1, "penned into an ICB he should slow down")
}

@(test)
penned_crossings_take_the_same_time_as_the_reference :: proc(t: ^testing.T) {
	land, ok := load(t)
	if !ok do return
	defer land_unload(land)

	reference := land_find(land, WALK_PACE_CODE)
	if !testing.expectf(t, reference >= 0, "%v is not a region any more", WALK_PACE_CODE) {
		return
	}
	want := land_extent(land, reference) / WALK_SPEED

	// Anything up to the reference's size should take the same time to cross;
	// bigger regions keep full speed and simply take longer.
	for extent, region in land.extents {
		if extent > land_extent(land, reference) {
			continue
		}
		w := Walker {
			district   = region,
			confined   = true,
			confine_to = region,
			pace_ref   = reference,
		}
		crossing := extent / (WALK_SPEED * walker_pace(w, land))
		testing.expectf(
			t,
			abs(crossing - want) < want * 0.01,
			"%v takes %.2fs to cross, the reference takes %.2fs",
			land.names[region],
			crossing,
			want,
		)
	}
}
