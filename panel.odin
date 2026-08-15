package ukmap

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// Side panel describing whichever region the walker is standing in.
//
// The content is data, not code: assets/regions.tsv has a header row, then one
// row per region keyed by its ONS code. Every column after `name` becomes a row
// in the panel, labelled by its header. Add a column to the file and it shows up
// here -- nothing below names a specific field.
//
// Edit data/regions.tsv (the copy in assets/ is overwritten on each build).
INFO_PATH :: "assets/regions.tsv"

PANEL_W :: f32(340)
PANEL_PAD :: f32(22)
PANEL_MARGIN :: f32(20)

PANEL_BG :: rl.Color{18, 26, 36, 232}
PANEL_EDGE :: rl.Color{40, 56, 74, 255}
PANEL_LABEL :: rl.Color{132, 150, 170, 255}
PANEL_VALUE :: rl.Color{233, 240, 247, 255}
PANEL_MUTED :: rl.Color{96, 112, 130, 255}

Region_Info :: struct {
	fields: []string, // parallel to Panel.headers
}

Panel :: struct {
	headers: []string, // field labels, i.e. the columns after code and name
	rows:    map[string]Region_Info, // keyed by region code
	note:    string, // provenance line, from a leading # comment in the file
	raw:     []byte, // backs every string above
	open:    bool,
	loaded:  bool,
}

panel_load :: proc(path: string) -> Panel {
	panel := Panel {
		open = true,
	}

	data, ok := read_file(path)
	if !ok {
		return panel // the map still works, the panel just says so
	}
	panel.raw = data

	lines := strings.split_lines(string(data), context.temp_allocator)
	if len(lines) == 0 {
		return panel
	}

	// leading # lines are comments; the first is shown as the panel's footnote,
	// so the data file states its own provenance rather than the code claiming it
	body := lines
	for len(body) > 0 && strings.has_prefix(body[0], "#") {
		if panel.note == "" {
			panel.note = strings.trim_space(body[0][1:])
		}
		body = body[1:]
	}
	if len(body) == 0 {
		return panel
	}

	header := strings.split(body[0], "\t", context.temp_allocator)
	if len(header) < 3 {
		fmt.eprintfln("%s: expected columns code, name, then one per field", path)
		return panel
	}
	// header[0] is `code`, header[1] is `name`; the rest are the panel's rows
	panel.headers = make([]string, len(header) - 2)
	for i in 0 ..< len(panel.headers) {
		panel.headers[i] = header[i + 2]
	}

	panel.rows = make(map[string]Region_Info)
	for line in body[1:] {
		if len(strings.trim_space(line)) == 0 {
			continue
		}
		cells := strings.split(line, "\t", context.temp_allocator)
		if len(cells) < 2 {
			continue
		}
		fields := make([]string, len(panel.headers))
		for i in 0 ..< len(fields) {
			fields[i] = i + 2 < len(cells) ? cells[i + 2] : "--"
		}
		panel.rows[cells[0]] = Region_Info{fields = fields}
	}

	panel.loaded = true
	return panel
}

panel_unload :: proc(panel: Panel) {
	for _, info in panel.rows {
		delete(info.fields)
	}
	rows := panel.rows
	delete(rows)
	delete(panel.headers)
	if panel.raw != nil {
		rl.UnloadFileData(raw_data(panel.raw))
	}
}

// Laid out in two passes: measure the wrapped content to get the height, then
// draw the box and the content into it. Everything wraps, so a long ICB name or
// a long value grows the panel instead of running off the edge.
panel_draw :: proc(panel: Panel, fonts: Fonts, land: Land, walker: Walker) {
	if !panel.open {
		return
	}

	inner := f32(PANEL_W - 2 * PANEL_PAD)
	x := f32(rl.GetScreenWidth()) - PANEL_W - PANEL_MARGIN
	y := f32(PANEL_MARGIN)

	line :: proc(size: f32) -> f32 {
		return size * LINE_HEIGHT
	}

	if !walker.on_land {
		height := PANEL_PAD * 2 + line(SIZE_HEADING) + line(SIZE_BODY)
		panel_box(x, y, height)
		cursor := y + PANEL_PAD
		text_draw(fonts, "No region", x + PANEL_PAD, cursor, SIZE_HEADING, PANEL_MUTED, true)
		cursor += line(SIZE_HEADING)
		text_draw(fonts, "He is at sea.", x + PANEL_PAD, cursor, SIZE_BODY, PANEL_MUTED)
		return
	}

	name := land.names[walker.district]
	code := land.codes[walker.district]
	subtitle := fmt.tprintf("%s  ·  %s", code, land_country(land, walker.district))
	info, found := panel.rows[code]

	// --- measure ---
	height := f32(PANEL_PAD)
	height += f32(len(text_wrap(fonts, name, SIZE_HEADING, inner, true))) * line(SIZE_HEADING)
	height += line(SIZE_CAPTION) + 14 // subtitle and the rule under it
	if found {
		for label, i in panel.headers {
			height += line(SIZE_BODY)
			height +=
				f32(len(text_wrap(fonts, info.fields[i], SIZE_VALUE, inner))) *
				line(SIZE_VALUE)
			height += 10 // gap between fields
		}
		if panel.note != "" {
			height +=
				6 +
				f32(len(text_wrap(fonts, panel.note, SIZE_CAPTION, inner))) *
					line(SIZE_CAPTION)
		}
	} else {
		height += line(SIZE_BODY) * 2
	}
	height += PANEL_PAD

	// --- draw ---
	panel_box(x, y, height)
	left := x + PANEL_PAD
	cursor := y + PANEL_PAD

	cursor = text_draw_wrapped(
		fonts,
		name,
		left,
		cursor,
		SIZE_HEADING,
		inner,
		PANEL_VALUE,
		true,
	)
	text_draw(fonts, subtitle, left, cursor, SIZE_CAPTION, PANEL_MUTED)
	cursor += line(SIZE_CAPTION) + 6
	rl.DrawLineV({left, cursor}, {left + inner, cursor}, PANEL_EDGE)
	cursor += 8

	if !found {
		message :=
			panel.loaded \
			? fmt.tprintf("No row for %s in regions.tsv", code) \
			: "regions.tsv not loaded"
		text_draw_wrapped(fonts, message, left, cursor, SIZE_BODY, inner, PANEL_MUTED)
		return
	}

	for label, i in panel.headers {
		text_draw(fonts, label, left, cursor, SIZE_BODY, PANEL_LABEL)
		cursor += line(SIZE_BODY)
		cursor = text_draw_wrapped(
			fonts,
			info.fields[i],
			left,
			cursor,
			SIZE_VALUE,
			inner,
			PANEL_VALUE,
			true,
		)
		cursor += 10
	}

	if panel.note != "" {
		text_draw_wrapped(fonts, panel.note, left, cursor + 6, SIZE_CAPTION, inner, PANEL_MUTED)
	}
}

@(private = "file")
panel_box :: proc(x, y, height: f32) {
	rl.DrawRectangleV({x, y}, {PANEL_W, height}, PANEL_BG)
	rl.DrawRectangleLinesEx({x, y, PANEL_W, height}, 1, PANEL_EDGE)
	rl.DrawRectangleV({x, y}, {4, height}, NHS_BLUE) // NHS blue spine
}
