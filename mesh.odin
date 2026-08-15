package ukmap

import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import rl "vendor:raylib"

// Binary produced by tools/build_mesh.py. See that file for the format.
MESH_MAGIC :: "UKM4"
HEADER_SIZE :: 4 + 4 + 4 + 5 * 4

Uk_Map :: struct {
	model:   rl.Model,
	min_x:   f32,
	max_x:   f32,
	min_z:   f32,
	max_z:   f32,
	height:  f32,
	tris:      int,
	regions:   int,
	ranges:    [][2]u32, // first vertex and vertex count per region
	base:      []u8, // unhighlighted colours, for restoring
	highlight: int, // region currently lit up, or -1
}

// Brightness gain on the current region. A multiply rather than a lerp towards
// white: lifting towards white desaturates, and the region stops reading as its
// own colour. Deliberately small -- this should say "you are here", not
// "selected".
HIGHLIGHT_GAIN :: 1.35

@(private = "file")
get_f32le :: proc(b: []byte) -> f32 {
	return transmute(f32)endian.unchecked_get_u32le(b)
}

uk_load :: proc(path: string) -> (map_: Uk_Map, ok: bool) {
	data, read_ok := read_file(path)
	if !read_ok {
		return {}, false
	}
	defer rl.UnloadFileData(raw_data(data))

	if len(data) < HEADER_SIZE || string(data[:4]) != MESH_MAGIC {
		fmt.eprintfln("%s is not a %s mesh", path, MESH_MAGIC)
		return {}, false
	}

	count := endian.unchecked_get_u32le(data[4:8])
	map_.regions = int(endian.unchecked_get_u32le(data[8:12]))
	map_.highlight = -1
	map_.min_x = get_f32le(data[12:16])
	map_.max_x = get_f32le(data[16:20])
	map_.min_z = get_f32le(data[20:24])
	map_.max_z = get_f32le(data[24:28])
	map_.height = get_f32le(data[28:32])

	ranges_bytes := map_.regions * 8
	pos_bytes := int(count) * 3 * size_of(f32)
	nrm_bytes := pos_bytes
	col_bytes := int(count) * 4
	if count % 3 != 0 ||
	   len(data) < HEADER_SIZE + ranges_bytes + pos_bytes + nrm_bytes + col_bytes {
		fmt.eprintfln("%s is truncated (vertex count %v)", path, count)
		return {}, false
	}

	// raylib frees these itself in UnloadMesh, so they have to come from its allocator
	mesh: rl.Mesh
	mesh.vertexCount = i32(count)
	mesh.triangleCount = i32(count / 3)
	mesh.vertices = cast([^]f32)rl.MemAlloc(c.uint(pos_bytes))
	mesh.normals = cast([^]f32)rl.MemAlloc(c.uint(nrm_bytes))
	mesh.colors = cast([^]u8)rl.MemAlloc(c.uint(col_bytes))

	off := HEADER_SIZE
	map_.ranges = make([][2]u32, map_.regions)
	for i in 0 ..< map_.regions {
		map_.ranges[i] = {
			endian.unchecked_get_u32le(data[off + i * 8:]),
			endian.unchecked_get_u32le(data[off + i * 8 + 4:]),
		}
	}
	off += ranges_bytes

	mem.copy(mesh.vertices, raw_data(data[off:]), pos_bytes)
	off += pos_bytes
	mem.copy(mesh.normals, raw_data(data[off:]), nrm_bytes)
	off += nrm_bytes
	mem.copy(mesh.colors, raw_data(data[off:]), col_bytes)

	// kept so a highlighted region can be put back exactly as it was
	map_.base = make([]u8, col_bytes)
	mem.copy(raw_data(map_.base), raw_data(data[off:]), col_bytes)

	rl.UploadMesh(&mesh, true) // dynamic: highlight rewrites colour ranges
	map_.model = rl.LoadModelFromMesh(mesh)
	map_.tris = int(mesh.triangleCount)
	return map_, true
}

uk_unload :: proc(m: Uk_Map) {
	rl.UnloadModel(m.model)
	delete(m.ranges)
	delete(m.base)
}

// Lift one region's colours, restoring whichever was lit before. Only the two
// affected vertex ranges are re-uploaded, not the whole 300k-vertex buffer.
uk_set_highlight :: proc(m: ^Uk_Map, region: int) {
	if region == m.highlight {
		return
	}
	if m.highlight >= 0 {
		uk_write_region(m^, m.highlight, false)
	}
	m.highlight = region
	if region >= 0 && region < len(m.ranges) {
		uk_write_region(m^, region, true)
	}
}

@(private = "file")
uk_write_region :: proc(m: Uk_Map, region: int, lit: bool) {
	start := int(m.ranges[region][0])
	count := int(m.ranges[region][1])
	if count == 0 {
		return
	}
	colours := m.model.meshes[0].colors

	for i in start * 4 ..< (start + count) * 4 {
		if (i & 3) == 3 {
			colours[i] = m.base[i] // alpha untouched
			continue
		}
		if lit {
			colours[i] = u8(min(255, f32(m.base[i]) * HIGHLIGHT_GAIN))
		} else {
			colours[i] = m.base[i]
		}
	}

	rl.UpdateMeshBuffer(
		m.model.meshes[0],
		3, // colour buffer
		&colours[start * 4],
		i32(count * 4),
		i32(start * 4),
	)
}

uk_centre :: proc(m: Uk_Map) -> rl.Vector3 {
	return {(m.min_x + m.max_x) / 2, m.height / 2, (m.min_z + m.max_z) / 2}
}

uk_radius :: proc(m: Uk_Map) -> f32 {
	return max(m.max_x - m.min_x, m.max_z - m.min_z) / 2
}
