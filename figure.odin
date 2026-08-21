package ukmap

import "core:math"
import rl "vendor:raylib"

// The walker's body, built once as a mesh with lighting baked into the vertex
// colours -- the same trick the map uses, and for the same reason: raylib's
// default shader is unlit, and a real light would need one GLSL variant for
// desktop GL 3.3 and another for the WebGL build.
//
// The whole figure is in here, nose and arms included, and the model is rotated
// to face his direction of travel. Baked lighting would normally spin round with
// a rotated model, so instead the light is rotated *into model space* by the
// opposite angle and the colours are re-baked whenever he turns. That costs one
// small buffer upload per turn and keeps the highlight sitting still in the
// world, which is what the eye expects.
//
// Model space faces +z, arms along x; `facing` of 0 means north.

// matched to LIGHT in tools/build_mesh.py so he is lit like the ground
FIGURE_LIGHT :: rl.Vector3{-0.45, 0.80, 0.40}
// Lifted above the map's 0.42: he is a small white-and-blue piece rather than a
// broad surface, and at the map's ambient the white parts read as grey.
FIGURE_AMBIENT :: 0.62

SIDES :: 20 // segments around a limb
HEAD_ROWS :: 10
REBAKE_RADIANS :: 0.01 // don't re-upload for turns smaller than this

Figure :: struct {
	model:   rl.Model,
	normals: []rl.Vector3, // model space, kept for re-baking
	bases:   []rl.Color, // unlit colour per vertex
	colours: []u8, // RGBA scratch uploaded to the GPU
	baked:   f32, // facing the current colours were baked for
	loaded:  bool,
}

@(private = "file")
Builder :: struct {
	pos:   [dynamic]f32,
	nrm:   [dynamic]rl.Vector3,
	bases: [dynamic]rl.Color,
}

// Shared with badge.odin so the logo panel is lit exactly like the body it sits on.
figure_shade :: proc(base: rl.Color, normal, light: rl.Vector3) -> rl.Color {
	k := FIGURE_AMBIENT + (1 - FIGURE_AMBIENT) * max(0, rl.Vector3DotProduct(normal, light))
	return {
		u8(clamp(f32(base.r) * k, 0, 255)),
		u8(clamp(f32(base.g) * k, 0, 255)),
		u8(clamp(f32(base.b) * k, 0, 255)),
		base.a,
	}
}

@(private = "file")
push :: proc(b: ^Builder, p, n: rl.Vector3, base: rl.Color) {
	append(&b.pos, p.x, p.y, p.z)
	append(&b.nrm, rl.Vector3Normalize(n))
	append(&b.bases, base)
}

// Emitted in reverse. The builders below walk their rings anticlockwise about
// +Y, which puts the resulting triangles clockwise as seen from outside the
// surface -- back-facing under raylib's GL_CCW default, so they get culled and
// you see straight through the model to its far inside wall. Flipping here fixes
// every builder at once.
@(private = "file")
tri :: proc(b: ^Builder, p0, p1, p2: rl.Vector3, n0, n1, n2: rl.Vector3, base: rl.Color) {
	push(b, p0, n0, base)
	push(b, p2, n2, base)
	push(b, p1, n1, base)
}

// A cone/cylinder between two arbitrary points, so limbs can point any way.
@(private = "file")
bar :: proc(b: ^Builder, from, to: rl.Vector3, r0, r1: f32, base: rl.Color) {
	axis := to - from
	length := rl.Vector3Length(axis)
	if length < 1e-6 {
		return
	}
	dir := axis / length

	// any vector not parallel to the axis will do for the first basis vector
	seed := abs(dir.y) > 0.9 ? rl.Vector3{1, 0, 0} : rl.Vector3{0, 1, 0}
	u := rl.Vector3Normalize(rl.Vector3CrossProduct(seed, dir))
	v := rl.Vector3CrossProduct(dir, u)

	for i in 0 ..< SIDES {
		a0 := f32(i) / SIDES * 2 * math.PI
		a1 := f32(i + 1) / SIDES * 2 * math.PI
		d0 := u * math.cos(a0) + v * math.sin(a0)
		d1 := u * math.cos(a1) + v * math.sin(a1)

		// tilt the normal by the taper, so cones are not lit like cylinders
		n0 := rl.Vector3Normalize(d0 * length + dir * (r0 - r1))
		n1 := rl.Vector3Normalize(d1 * length + dir * (r0 - r1))

		p00 := from + d0 * r0
		p10 := from + d1 * r0
		p01 := to + d0 * r1
		p11 := to + d1 * r1

		tri(b, p00, p01, p11, n0, n0, n1, base)
		tri(b, p00, p11, p10, n0, n1, n1, base)
	}
}

@(private = "file")
disc :: proc(b: ^Builder, centre: rl.Vector3, r: f32, normal: rl.Vector3, base: rl.Color) {
	n := rl.Vector3Normalize(normal)
	seed := abs(n.y) > 0.9 ? rl.Vector3{1, 0, 0} : rl.Vector3{0, 1, 0}
	u := rl.Vector3Normalize(rl.Vector3CrossProduct(seed, n))
	v := rl.Vector3CrossProduct(n, u)
	for i in 0 ..< SIDES {
		a0 := f32(i) / SIDES * 2 * math.PI
		a1 := f32(i + 1) / SIDES * 2 * math.PI
		p0 := centre + (u * math.cos(a0) + v * math.sin(a0)) * r
		p1 := centre + (u * math.cos(a1) + v * math.sin(a1)) * r
		tri(b, centre, p0, p1, n, n, n, base)
	}
}

@(private = "file")
sphere :: proc(b: ^Builder, centre: rl.Vector3, r: f32, rows: int, base: rl.Color) {
	at :: proc(theta, phi: f32) -> rl.Vector3 {
		return {math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi)}
	}
	for j in 0 ..< rows {
		t0 := f32(j) / f32(rows) * math.PI
		t1 := f32(j + 1) / f32(rows) * math.PI
		for i in 0 ..< SIDES {
			a0 := f32(i) / SIDES * 2 * math.PI
			a1 := f32(i + 1) / SIDES * 2 * math.PI
			n00, n01 := at(t0, a0), at(t0, a1)
			n10, n11 := at(t1, a0), at(t1, a1)
			tri(b, centre + n00 * r, centre + n10 * r, centre + n11 * r, n00, n10, n11, base)
			tri(b, centre + n00 * r, centre + n11 * r, centre + n01 * r, n00, n11, n01, base)
		}
	}
}

figure_build :: proc() -> Figure {
	b: Builder
	defer {
		delete(b.pos)
		delete(b.nrm)
		delete(b.bases)
	}

	// plinth, so he reads as a piece standing on the board rather than in it
	bar(&b, {0, 0, 0}, {0, PLINTH_H, 0}, PLINTH_R, PLINTH_R, NHS_WHITE)
	disc(&b, {0, PLINTH_H, 0}, PLINTH_R, {0, 1, 0}, NHS_WHITE)
	// torso, tapering in towards the shoulders
	bar(&b, {0, PLINTH_H, 0}, {0, TORSO_TOP, 0}, TORSO_R_BASE, TORSO_R_TOP, NHS_BLUE)
	disc(&b, {0, TORSO_TOP, 0}, TORSO_R_TOP, {0, 1, 0}, NHS_BLUE)
	// arms, spanning across the direction of travel, rounded off at the ends
	shoulder := rl.Vector3{0, SHOULDER_Y, 0}
	bar(&b, shoulder - {ARM_SPAN, 0, 0}, shoulder + {ARM_SPAN, 0, 0}, 0.023, 0.023, NHS_BLUE)
	sphere(&b, shoulder - {ARM_SPAN, 0, 0}, 0.023, 6, NHS_BLUE)
	sphere(&b, shoulder + {ARM_SPAN, 0, 0}, 0.023, 6, NHS_BLUE)
	// head
	sphere(&b, {0, HEAD_Y, 0}, HEAD_R, HEAD_ROWS, NHS_WHITE)
	// Nose: a stubby snout, not a beak. It starts inside the head so no seam
	// shows, and only protrudes about half a head radius -- longer than this and
	// it reads as a bird from side-on. Blunt tip rather than a point, for the
	// same reason.
	bar(&b, {0, HEAD_Y, 0.02}, {0, HEAD_Y - 0.006, 0.082}, 0.03, 0.013, NHS_WHITE)

	count := len(b.pos) / 3
	fig := Figure {
		normals = make([]rl.Vector3, count),
		bases   = make([]rl.Color, count),
		colours = make([]u8, count * 4),
	}
	copy(fig.normals, b.nrm[:])
	copy(fig.bases, b.bases[:])

	mesh: rl.Mesh
	mesh.vertexCount = i32(count)
	mesh.triangleCount = i32(count / 3)
	mesh.vertices = cast([^]f32)rl.MemAlloc(u32(len(b.pos) * size_of(f32)))
	mesh.colors = cast([^]u8)rl.MemAlloc(u32(count * 4))
	mesh.normals = cast([^]f32)rl.MemAlloc(u32(count * 3 * size_of(f32)))
	for v, i in b.pos do mesh.vertices[i] = v
	for n, i in fig.normals {
		mesh.normals[i * 3 + 0] = n.x
		mesh.normals[i * 3 + 1] = n.y
		mesh.normals[i * 3 + 2] = n.z
	}
	figure_bake(&fig, 0)
	for v, i in fig.colours do mesh.colors[i] = v

	rl.UploadMesh(&mesh, true) // dynamic: the colours are re-uploaded as he turns
	fig.model = rl.LoadModelFromMesh(mesh)
	fig.loaded = true
	return fig
}

// The world light expressed in the model space of a figure rotated by `facing`:
// the inverse of the model's rotation about Y, applied to the light.
figure_light_local :: proc(facing: f32) -> rl.Vector3 {
	c, s := math.cos(facing), math.sin(facing)
	light := rl.Vector3Normalize(FIGURE_LIGHT)
	return {light.x * c - light.z * s, light.y, light.x * s + light.z * c}
}

// Re-shade for a given facing by rotating the light into model space.
@(private = "file")
figure_bake :: proc(fig: ^Figure, facing: f32) {
	local := figure_light_local(facing)

	for i in 0 ..< len(fig.normals) {
		col := figure_shade(fig.bases[i], fig.normals[i], local)
		fig.colours[i * 4 + 0] = col.r
		fig.colours[i * 4 + 1] = col.g
		fig.colours[i * 4 + 2] = col.b
		fig.colours[i * 4 + 3] = col.a
	}
	fig.baked = facing
}

figure_draw :: proc(fig: ^Figure, position: rl.Vector3, facing, scale: f32) {
	if !fig.loaded {
		return
	}
	if abs(math.angle_diff(fig.baked, facing)) > REBAKE_RADIANS {
		figure_bake(fig, facing)
		// buffer 3 is the colour VBO
		rl.UpdateMeshBuffer(
			fig.model.meshes[0],
			3,
			raw_data(fig.colours),
			i32(len(fig.colours)),
			0,
		)
	}
	rl.DrawModelEx(
		fig.model,
		position,
		{0, 1, 0},
		facing * 180 / math.PI,
		scale,
		rl.WHITE,
	)
}

figure_unload :: proc(fig: Figure) {
	if fig.loaded {
		rl.UnloadModel(fig.model)
	}
	delete(fig.normals)
	delete(fig.bases)
	delete(fig.colours)
}
