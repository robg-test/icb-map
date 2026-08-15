package ukmap

import "core:fmt"
import rl "vendor:raylib"

// An optional logo worn on the walker's chest, drawn as a camera-facing
// billboard so it stays legible whichever way he is pointing.
//
// This deliberately loads artwork from disk rather than drawing anything itself.
// The NHS logo is a UK trade mark owned by the Secretary of State for Health and
// Social Care, and the NHS identity guidelines are explicit that only the
// original artwork files should be used and that you should not attempt to
// recreate it. So: drop the official PNG in as assets/logo.png and it gets worn;
// leave it out and he goes without. Nothing here fabricates a facsimile.
//
// Whoever supplies the artwork is responsible for being licensed to use it.
BADGE_PATH :: "assets/logo.png"

// height in world units; the width follows the artwork's aspect ratio
BADGE_HEIGHT :: 0.1

Badge :: struct {
	texture: rl.Texture2D,
	present: bool,
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
	badge.present = true
	return badge
}

badge_unload :: proc(badge: Badge) {
	if badge.present {
		rl.UnloadTexture(badge.texture)
	}
}

badge_draw :: proc(badge: Badge, cam: rl.Camera3D, chest: rl.Vector3) {
	if !badge.present {
		return
	}
	// float it just clear of the torso towards the camera, or the billboard
	// half-buries itself in the cylinder
	towards := rl.Vector3Normalize(cam.position - chest)
	rl.DrawBillboard(cam, badge.texture, chest + towards * 0.075, BADGE_HEIGHT, rl.WHITE)
}
