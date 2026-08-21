package ukmap

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

// The logo the walker wears, applied to his torso like the front of a jumper:
// a thin shell of geometry that follows the taper of the chest, curving the
// artwork round the body rather than pasting it on flat.
//
// This deliberately loads artwork from disk rather than drawing anything itself.
// The NHS logo is a UK trade mark owned by the Secretary of State for Health and
// Social Care, and the NHS identity guidelines are explicit that only the
// original artwork files should be used and that you should not attempt to
// recreate it. So: drop the official PNG in as assets/logo.png and it gets worn;
// leave it out and he goes without. Nothing here fabricates a facsimile.
//
// The panel is its own model because the figure's mesh is untextured vertex
// colour with a single material; giving it UVs would mean an atlas, and an atlas
// would mean re-cutting the supplied artwork. A second draw is cheaper than that.
//
// Whoever supplies the artwork is responsible for being licensed to use it.
BADGE_PATH :: "assets/logo.png"

// How far round the chest the logo wraps, in radians, centred on the direction
// he faces. Wide enough that the curve is visible from three-quarter on; much
// past this and the artwork starts to disappear round his sides.
BADGE_ARC :: 140 * math.PI / 180
// Segments across that arc. The chest is only ~0.06 units across, so this is
// about smoothing the silhouette of the logo, not the body underneath.
BADGE_SEGS :: 24
// Clear of the torso surface by enough to beat depth-buffer fighting, and no
// more -- any further out and it reads as a floating sign again.
BADGE_LIFT :: 0.0015

Badge :: struct {
	texture: rl.Texture2D,
	model:   rl.Model,
	normals: []rl.Vector3, // model space, kept for re-baking as he turns
	colours: []u8, // RGBA scratch uploaded to the GPU
	baked:   f32,
	present: bool,
}

// Torso radius at a given height, matching the tapering cone in figure.odin.
@(private = "file")
torso_radius :: proc(y: f32) -> f32 {
	t := clamp((y - PLINTH_H) / (TORSO_TOP - PLINTH_H), 0, 1)
	return TORSO_R_BASE + (TORSO_R_TOP - TORSO_R_BASE) * t
}

badge_load :: proc(path: string) -> Badge {
	name := fmt.ctprint(path)
	if !rl.FileExists(name) {
		return {}
	}

	badge := Badge {
		texture = rl.LoadTexture(name),
	}
	if badge.texture.id == 0 {
		fmt.eprintfln("%s could not be loaded as a texture", path)
		return {}
	}
	rl.SetTextureFilter(badge.texture, .BILINEAR)
	// clamp, not repeat: the panel's UVs stop at the artwork's edge and a
	// wrapping sampler would bleed the far side of the image across the seam
	rl.SetTextureWrap(badge.texture, .CLAMP)

	badge_build(&badge)
	badge.present = true
	return badge
}

// The curved panel. Height comes from the artwork's own aspect ratio against the
// arc length it is stretched over, so the logo is never squashed whatever shape
// of PNG is supplied.
@(private = "file")
badge_build :: proc(badge: ^Badge) {
	aspect := f32(badge.texture.width) / f32(badge.texture.height)
	arc_len := BADGE_ARC * torso_radius(BADGE_Y)
	half_h := arc_len / aspect / 2
	y0, y1 := BADGE_Y - half_h, BADGE_Y + half_h

	// tilt of the chest wall, used to lean the normals with the taper so the
	// panel is shaded as part of the cone rather than as a vertical wall
	lean: f32 = (TORSO_R_BASE - TORSO_R_TOP) / (TORSO_TOP - PLINTH_H)

	count := BADGE_SEGS * 6
	pos := make([]f32, count * 3)
	uv := make([]f32, count * 2)
	badge.normals = make([]rl.Vector3, count)
	badge.colours = make([]u8, count * 4)
	defer delete(pos)
	defer delete(uv)

	at :: proc(a, y, lean: f32) -> (p, n: rl.Vector3) {
		dir := rl.Vector3{math.sin(a), 0, math.cos(a)}
		n = rl.Vector3Normalize(dir + rl.Vector3{0, lean, 0})
		p = dir * (torso_radius(y) + BADGE_LIFT) + rl.Vector3{0, y, 0}
		return
	}

	v := 0
	emit :: proc(pos, uv: []f32, normals: []rl.Vector3, v: ^int, p, n: rl.Vector3, u, tv: f32) {
		pos[v^ * 3 + 0] = p.x
		pos[v^ * 3 + 1] = p.y
		pos[v^ * 3 + 2] = p.z
		normals[v^] = n
		uv[v^ * 2 + 0] = u
		uv[v^ * 2 + 1] = tv
		v^ += 1
	}

	for i in 0 ..< BADGE_SEGS {
		u0 := f32(i) / BADGE_SEGS
		u1 := f32(i + 1) / BADGE_SEGS
		// angle 0 is straight ahead (+z, the way he faces); u grows with +x,
		// which is the viewer's right when looking at his front, so the artwork
		// reads the right way round rather than mirrored
		a0 := (u0 - 0.5) * BADGE_ARC
		a1 := (u1 - 0.5) * BADGE_ARC

		p00, n0 := at(a0, y0, lean)
		p10, n1 := at(a1, y0, lean)
		p01, _ := at(a0, y1, lean)
		p11, _ := at(a1, y1, lean)

		// v = 0 is the top of the image, so the taller y takes 0
		emit(pos, uv, badge.normals, &v, p00, n0, u0, 1)
		emit(pos, uv, badge.normals, &v, p10, n1, u1, 1)
		emit(pos, uv, badge.normals, &v, p11, n1, u1, 0)
		emit(pos, uv, badge.normals, &v, p00, n0, u0, 1)
		emit(pos, uv, badge.normals, &v, p11, n1, u1, 0)
		emit(pos, uv, badge.normals, &v, p01, n0, u0, 0)
	}

	mesh: rl.Mesh
	mesh.vertexCount = i32(count)
	mesh.triangleCount = i32(count / 3)
	mesh.vertices = cast([^]f32)rl.MemAlloc(u32(count * 3 * size_of(f32)))
	mesh.texcoords = cast([^]f32)rl.MemAlloc(u32(count * 2 * size_of(f32)))
	mesh.normals = cast([^]f32)rl.MemAlloc(u32(count * 3 * size_of(f32)))
	mesh.colors = cast([^]u8)rl.MemAlloc(u32(count * 4))
	for value, i in pos do mesh.vertices[i] = value
	for value, i in uv do mesh.texcoords[i] = value
	for n, i in badge.normals {
		mesh.normals[i * 3 + 0] = n.x
		mesh.normals[i * 3 + 1] = n.y
		mesh.normals[i * 3 + 2] = n.z
	}
	badge_bake(badge, 0)
	for value, i in badge.colours do mesh.colors[i] = value

	rl.UploadMesh(&mesh, true) // dynamic, for the same reason the figure's is
	badge.model = rl.LoadModelFromMesh(mesh)
	badge.model.materials[0].maps[rl.MaterialMapIndex.ALBEDO].texture = badge.texture
}

// Same trick as the figure: the light is rotated into model space and baked into
// the vertex colours, which raylib's default shader multiplies with the texture.
// A white base means the shading only darkens the artwork, never tints it.
@(private = "file")
badge_bake :: proc(badge: ^Badge, facing: f32) {
	local := figure_light_local(facing)
	for n, i in badge.normals {
		col := figure_shade(NHS_WHITE, n, local)
		badge.colours[i * 4 + 0] = col.r
		badge.colours[i * 4 + 1] = col.g
		badge.colours[i * 4 + 2] = col.b
		badge.colours[i * 4 + 3] = col.a
	}
	badge.baked = facing
}

badge_unload :: proc(badge: Badge) {
	if badge.present {
		// drop the material's borrowed reference before unloading the model,
		// so the texture is freed once, here
		badge.model.materials[0].maps[rl.MaterialMapIndex.ALBEDO].texture = {}
		rl.UnloadModel(badge.model)
		rl.UnloadTexture(badge.texture)
		delete(badge.normals)
		delete(badge.colours)
	}
}

// `base` is the figure's feet and `facing` his heading, exactly as passed to
// figure_draw -- the panel is built in the same model space, so it rides along.
badge_draw :: proc(badge: ^Badge, base: rl.Vector3, facing, scale: f32) {
	if !badge.present {
		return
	}
	if abs(math.angle_diff(badge.baked, facing)) > REBAKE_RADIANS {
		badge_bake(badge, facing)
		rl.UpdateMeshBuffer(
			badge.model.meshes[0],
			3, // buffer 3 is the colour VBO
			raw_data(badge.colours),
			i32(len(badge.colours)),
			0,
		)
	}
	rl.DrawModelEx(badge.model, base, {0, 1, 0}, facing * 180 / math.PI, scale, rl.WHITE)
}
