package ukmap

import "core:c"
import "core:encoding/endian"
import "core:fmt"
import rl "vendor:raylib"

// A baked bathymetry texture drawn on one quad at sea level, plus a large flat
// plane in the deepest colour so the water does not simply stop at the texture's
// edge. Baking the depth ramp means no custom shader, which is what keeps this
// identical on desktop GL and WebGL. See tools/build_mesh.py for the format.
SEA_MAGIC :: "UKS1"
SEA_HEADER :: 4 + 8 + 16 + 4

// how far the flat water extends past the texture, in world units
SEA_PLANE_SIZE :: 600.0

Sea :: struct {
	model:   rl.Model,
	texture: rl.Texture2D,
	level:   f32,
	deep:    rl.Color,
	loaded:  bool,
}

@(private = "file")
get_f32le :: proc(b: []byte) -> f32 {
	return transmute(f32)endian.unchecked_get_u32le(b)
}

sea_load :: proc(path: string) -> (sea: Sea, ok: bool) {
	data, read_ok := read_file(path)
	if !read_ok {
		return {}, false
	}
	defer rl.UnloadFileData(raw_data(data))

	if len(data) < SEA_HEADER || string(data[:4]) != SEA_MAGIC {
		fmt.eprintfln("%s is not a %s texture", path, SEA_MAGIC)
		return {}, false
	}

	w := int(endian.unchecked_get_u32le(data[4:8]))
	h := int(endian.unchecked_get_u32le(data[8:12]))
	origin_x := get_f32le(data[12:16])
	origin_z := get_f32le(data[16:20])
	cell := get_f32le(data[20:24])
	sea.level = get_f32le(data[24:28])
	sea.deep = {data[28], data[29], data[30], data[31]}

	pixels := SEA_HEADER
	if len(data) < pixels + w * h * 4 {
		fmt.eprintfln("%s is truncated (%vx%v texels)", path, w, h)
		return {}, false
	}

	image := rl.Image {
		data    = raw_data(data[pixels:]),
		width   = i32(w),
		height  = i32(h),
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	sea.texture = rl.LoadTextureFromImage(image) // copies to the GPU
	rl.SetTextureFilter(sea.texture, .BILINEAR)

	x0 := origin_x
	x1 := origin_x + f32(w) * cell
	z0 := origin_z
	z1 := origin_z + f32(h) * cell
	sea.model = sea_quad(x0, x1, z0, z1, sea.level)
	sea.model.materials[0].maps[rl.MaterialMapIndex.ALBEDO].texture = sea.texture

	sea.loaded = true
	return sea, true
}

// Two triangles, wound so the lit side faces up, with the texture's rows running
// north to south.
@(private = "file")
sea_quad :: proc(x0, x1, z0, z1, y: f32) -> rl.Model {
	positions := [18]f32 {
		x0, y, z0,
		x0, y, z1,
		x1, y, z1,
		x0, y, z0,
		x1, y, z1,
		x1, y, z0,
	}
	uvs := [12]f32{0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0}

	mesh: rl.Mesh
	mesh.vertexCount = 6
	mesh.triangleCount = 2
	mesh.vertices = cast([^]f32)rl.MemAlloc(size_of(positions))
	mesh.texcoords = cast([^]f32)rl.MemAlloc(size_of(uvs))
	for v, i in positions do mesh.vertices[i] = v
	for v, i in uvs do mesh.texcoords[i] = v

	rl.UploadMesh(&mesh, false)
	return rl.LoadModelFromMesh(mesh)
}

sea_unload :: proc(sea: Sea) {
	if !sea.loaded {
		return
	}
	// the model does not own the texture here, so drop it first
	sea.model.materials[0].maps[rl.MaterialMapIndex.ALBEDO].texture = {}
	rl.UnloadModel(sea.model)
	rl.UnloadTexture(sea.texture)
}

sea_draw :: proc(sea: Sea) {
	if !sea.loaded {
		return
	}
	// Open water, then the charted part above it. The gap has to be generous:
	// DrawPlane goes through rlgl's batch and only flushes at EndMode3D, so it
	// can land after the quad, and a hairline offset just z-fights instead.
	// 0.02 is invisible at any camera angle the pitch clamp allows.
	rl.DrawPlane({0, sea.level - 0.02, 0}, {SEA_PLANE_SIZE, SEA_PLANE_SIZE}, sea.deep)
	rl.DrawModel(sea.model, {0, 0, 0}, 1, rl.WHITE)
}
