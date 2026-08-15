package ukmap

import "core:encoding/endian"
import "core:fmt"
import "core:math"
import "core:mem"
import rl "vendor:raylib"

// Companion grid to the mesh: one district index per cell, 0 for sea. Lets the
// walker ask "can I stand here, and where am I?" with an array lookup instead of
// a raycast against 180k triangles. See tools/build_mesh.py for the format.
LAND_MAGIC :: "UKL2"
LAND_HEADER :: 4 + 8 + 16 + 2

Land :: struct {
	w:         int,
	h:         int,
	origin_x:  f32,
	origin_z:  f32,
	cell:      f32,
	surface_y: f32,
	names:     []string,
	codes:     []string, // join key for the region info table
	countries: []u8, // 'E', 'S', 'W', 'N'
	cells:     []u16,
	raw:       []byte, // backs `names`, so it outlives the load
}

@(private = "file")
get_f32le :: proc(b: []byte) -> f32 {
	return transmute(f32)endian.unchecked_get_u32le(b)
}

land_load :: proc(path: string) -> (land: Land, ok: bool) {
	data, read_ok := read_file(path)
	if !read_ok {
		return {}, false
	}
	if len(data) < LAND_HEADER || string(data[:4]) != LAND_MAGIC {
		fmt.eprintfln("%s is not a %s grid", path, LAND_MAGIC)
		rl.UnloadFileData(raw_data(data))
		return {}, false
	}

	land.raw = data
	land.w = int(endian.unchecked_get_u32le(data[4:8]))
	land.h = int(endian.unchecked_get_u32le(data[8:12]))
	land.origin_x = get_f32le(data[12:16])
	land.origin_z = get_f32le(data[16:20])
	land.cell = get_f32le(data[20:24])
	land.surface_y = get_f32le(data[24:28])
	count := int(endian.unchecked_get_u16le(data[28:30]))

	land.names = make([]string, count)
	land.codes = make([]string, count)
	land.countries = make([]u8, count)
	off := LAND_HEADER
	for i in 0 ..< count {
		if off + 1 > len(data) {
			fmt.eprintfln("%s: region table is truncated", path)
			return {}, false
		}
		code_len := int(data[off])
		off += 1
		if off + code_len + 1 > len(data) {
			fmt.eprintfln("%s: region table is truncated", path)
			return {}, false
		}
		land.codes[i] = string(data[off:off + code_len])
		land.countries[i] = data[off] // the code's first letter is the country
		off += code_len
		name_len := int(data[off])
		off += 1
		if off + name_len > len(data) {
			fmt.eprintfln("%s: region table is truncated", path)
			return {}, false
		}
		land.names[i] = string(data[off:off + name_len])
		off += name_len
	}

	cell_bytes := land.w * land.h * size_of(u16)
	if off + cell_bytes > len(data) {
		fmt.eprintfln("%s: cell data is truncated", path)
		return {}, false
	}
	// copied rather than aliased: the names are variable length, so the cells
	// start at an arbitrary offset with no alignment guarantee
	land.cells = make([]u16, land.w * land.h)
	mem.copy(raw_data(land.cells), raw_data(data[off:]), cell_bytes)

	return land, true
}

land_unload :: proc(land: Land) {
	delete(land.cells)
	delete(land.countries)
	delete(land.codes)
	delete(land.names)
	if land.raw != nil {
		rl.UnloadFileData(raw_data(land.raw)) // raylib allocated it, raylib frees it
	}
}

// District under a world position, if it is land at all.
land_at :: proc(land: Land, x, z: f32) -> (district: int, ok: bool) {
	i := int(math.floor((x - land.origin_x) / land.cell))
	j := int(math.floor((z - land.origin_z) / land.cell))
	if i < 0 || j < 0 || i >= land.w || j >= land.h {
		return 0, false
	}
	value := land.cells[j * land.w + i]
	if value == 0 {
		return 0, false
	}
	return int(value - 1), true
}

land_country :: proc(land: Land, district: int) -> string {
	switch land.countries[district] {
	case 'E':
		return "England"
	case 'S':
		return "Scotland"
	case 'W':
		return "Wales"
	case 'N':
		return "Northern Ireland"
	}
	return "UK"
}

// Where the walker starts. Somewhere with data on it beats the geometric middle
// of the map, which lands in Scotland where the NHS columns are all dashes.
SPAWN_CODE :: "E54000054" // NHS West Yorkshire ICB

land_spawn :: proc(land: Land) -> rl.Vector3 {
	for code, i in land.codes {
		if code == SPAWN_CODE {
			if centre, ok := land_region_centre(land, i); ok {
				return centre
			}
			break
		}
	}
	return land_spawn_middle(land) // unknown code: fall back to the old behaviour
}

// A point inside a given region: the mean of its cells, snapped to the nearest
// cell that actually belongs to it. The mean alone can land outside a concave
// region -- and plenty of ICBs wrap around a bay or a neighbour.
land_region_centre :: proc(land: Land, region: int) -> (rl.Vector3, bool) {
	want := u16(region + 1)
	sum_i, sum_j, count := 0, 0, 0
	for j in 0 ..< land.h {
		for i in 0 ..< land.w {
			if land.cells[j * land.w + i] == want {
				sum_i += i
				sum_j += j
				count += 1
			}
		}
	}
	if count == 0 {
		return {}, false
	}

	mean_i := sum_i / count
	mean_j := sum_j / count
	best_i, best_j, best_d := -1, -1, max(int)
	for j in 0 ..< land.h {
		for i in 0 ..< land.w {
			if land.cells[j * land.w + i] != want {
				continue
			}
			di, dj := i - mean_i, j - mean_j
			if d := di * di + dj * dj; d < best_d {
				best_d, best_i, best_j = d, i, j
			}
		}
	}

	return rl.Vector3 {
			land.origin_x + (f32(best_i) + 0.5) * land.cell,
			land.surface_y,
			land.origin_z + (f32(best_j) + 0.5) * land.cell,
		},
		true
}

// Nearest land cell to the middle of the map, for a sane spawn point.
@(private = "file")
land_spawn_middle :: proc(land: Land) -> rl.Vector3 {
	ci, cj := land.w / 2, land.h / 2
	for radius in 0 ..< max(land.w, land.h) {
		for j := cj - radius; j <= cj + radius; j += 1 {
			for i := ci - radius; i <= ci + radius; i += 1 {
				// only the ring's edge; the inside was covered by smaller radii
				if radius > 0 &&
				   i != ci - radius &&
				   i != ci + radius &&
				   j != cj - radius &&
				   j != cj + radius {
					continue
				}
				if i < 0 || j < 0 || i >= land.w || j >= land.h {
					continue
				}
				if land.cells[j * land.w + i] != 0 {
					return {
						land.origin_x + (f32(i) + 0.5) * land.cell,
						land.surface_y,
						land.origin_z + (f32(j) + 0.5) * land.cell,
					}
				}
			}
		}
	}
	return {0, land.surface_y, 0}
}
