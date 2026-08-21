package ukmap

// Shared between the desktop and web entry points. The frame loop lives in the
// caller, not here: on desktop it is a plain `for`, on web the browser drives it
// one frame at a time, and a blocking loop would freeze the tab.

import "core:c"
import "core:fmt"
import rl "vendor:raylib"

MESH_PATH :: "assets/uk.mesh"
LAND_PATH :: "assets/uk.land"
SEA_PATH :: "assets/uk.sea"

BACKGROUND :: rl.Color{13, 16, 23, 255}

State :: struct {
	uk:       Uk_Map,
	land:     Land,
	sea:      Sea,
	badge:    Badge,
	focus:    Focus,
	panel:    Panel,
	figure:   Figure,
	fonts:    Fonts,
	cam:      Orbit_Camera,
	home:     Orbit_Camera,
	overview: rl.Vector3,
	walker:   Walker,
	running:  bool,
	loaded:   bool,
}

g: State

init :: proc() -> bool {
	rl.SetConfigFlags({.MSAA_4X_HINT, .WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(1280, 800, "UK 3D Map")
	rl.SetTargetFPS(60)

	ok: bool
	if g.uk, ok = uk_load(MESH_PATH); !ok {
		return false
	}
	if g.land, ok = land_load(LAND_PATH); !ok {
		return false
	}
	if g.sea, ok = sea_load(SEA_PATH); !ok {
		return false
	}
	g.badge = badge_load(BADGE_PATH) // optional, see badge.odin
	g.panel = panel_load(INFO_PATH)
	g.fonts = fonts_load()
	g.figure = figure_build()

	// Aim well south of centre. The default view is a low, close one, so the
	// near (southern) end of the map is thrown a long way down the screen and
	// the framing needs pulling back up.
	g.overview = uk_centre(g.uk) + rl.Vector3{0, 0, uk_radius(g.uk) * 0.30}
	g.cam = orbit_make(g.overview, uk_radius(g.uk))
	g.home = g.cam
	g.walker = walker_make(g.land)
	g.focus.region = -1
	g.running = true
	g.loaded = true
	return true
}

// The web loop calls update() before it checks should_run(), so a failed load
// has to be survivable here.
web_stop :: proc() {
	g.running = false
}

update :: proc() {
	if !g.loaded {
		return
	}
	dt := rl.GetFrameTime()

	if rl.IsKeyPressed(.R) {
		focus_leave(&g.focus, &g.cam, g.walker.pos)
		g.cam = g.home
		g.focus.settling = false
		g.walker = walker_make(g.land)
	}
	// Focus on the ICB he is standing in: everything else stops being drawn.
	if rl.IsKeyPressed(.SPACE) {
		if g.focus.on {
			focus_leave(&g.focus, &g.cam, g.walker.pos)
			g.walker.confined = false
		} else if g.walker.on_land {
			focus_enter(&g.focus, g.uk, g.land, &g.cam, g.walker.district)
			// only pen him in if the region actually came up
			g.walker.confined = g.focus.on
			g.walker.confine_to = g.walker.district
		}
	}
	if rl.IsKeyPressed(.P) do g.panel.open = !g.panel.open
	if rl.IsKeyPressed(.TAB) {
		g.cam.follow = !g.cam.follow
		if !g.cam.follow do g.cam.target = g.overview
	}

	walker_update(&g.walker, g.land, g.cam.yaw, dt)
	uk_set_highlight(&g.uk, g.walker.on_land ? g.walker.district : -1)
	if g.cam.follow {
		orbit_follow(&g.cam, g.walker.pos, dt)
	}
	focus_update(&g.focus, &g.cam, dt)
	orbit_update(&g.cam, dt)

	rl.BeginDrawing()
	rl.ClearBackground(BACKGROUND)

	cam := orbit_rl(g.cam)
	rl.BeginMode3D(cam)
	if g.focus.on {
		focus_draw(g.focus, g.land)
	} else {
		sea_draw(g.sea)
		rl.DrawModel(g.uk.model, {0, 0, 0}, 1, rl.WHITE)
	}
	walker_draw(g.walker, &g.figure, &g.badge)
	rl.EndMode3D()

	draw_hud(g.fonts)
	panel_draw(g.panel, g.fonts, g.land, g.walker)
	rl.EndDrawing()

	free_all(context.temp_allocator)
}

should_run :: proc() -> bool {
	when ODIN_OS != .JS {
		// never on web: this contains a 16 ms sleep there
		if rl.WindowShouldClose() {
			g.running = false
		}
	}
	return g.running
}

shutdown :: proc() {
	if g.loaded {
		uk_unload(g.uk)
		land_unload(g.land)
		sea_unload(g.sea)
		focus_unload(&g.focus)
		badge_unload(g.badge)
		panel_unload(g.panel)
		figure_unload(g.figure)
		fonts_unload(g.fonts)
	}
	rl.CloseWindow()
}

// Called from the browser when the canvas is resized.
parent_window_size_changed :: proc(w, h: int) {
	rl.SetWindowSize(c.int(w), c.int(h))
}

// Writes the frame just drawn. Not rl.TakeScreenshot: that one throws away any
// directory in the path.
screenshot :: proc(path: string) {
	frame := rl.LoadImageFromScreen()
	rl.ExportImage(frame, fmt.ctprint(path))
	rl.UnloadImage(frame)
}

draw_hud :: proc(fonts: Fonts) {
	// The only thing left on screen. The region name used to be centred up here
	// too, but the panel shows it, wraps it, and is open by default -- and a long
	// ICB name ran clean under the panel.
	text_draw(
		fonts,
		"WASD to move",
		24,
		f32(rl.GetScreenHeight()) - 40,
		SIZE_BODY,
		rl.Color{150, 160, 175, 255},
	)
}
