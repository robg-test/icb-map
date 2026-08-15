package ukmap

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// Typography, following the NHS digital service manual as closely as licensing
// allows. The manual specifies Frutiger W01 with an Arial fallback; neither is
// redistributable, so this ships Liberation Sans, which is metric-compatible
// with Arial and licensed under the SIL Open Font License.
//
// The type scale is the manual's: bold headings, regular body, and a line height
// of roughly 1.5.
FONT_REGULAR :: "assets/fonts/LiberationSans-Regular.ttf"
FONT_BOLD :: "assets/fonts/LiberationSans-Bold.ttf"

// Glyphs are rasterised at this size and scaled down when drawn, so text stays
// crisp at every size we use.
FONT_ATLAS :: 64

SIZE_HEADING :: f32(24)
SIZE_VALUE :: f32(22)
SIZE_BODY :: f32(16)
SIZE_CAPTION :: f32(14)
LINE_HEIGHT :: f32(1.45)

Fonts :: struct {
	regular: rl.Font,
	bold:    rl.Font,
	loaded:  bool,
}

// ASCII plus the handful of extras the content actually uses -- raylib's default
// glyph set stops at 126, which would drop the pound signs.
@(private = "file")
codepoints :: proc() -> []rune {
	extra := [?]rune{'£', '·', '–', '—', '…', '’', '°', '²', '³'}
	set := make([]rune, 95 + len(extra), context.temp_allocator)
	for i in 0 ..< 95 {
		set[i] = rune(32 + i)
	}
	for r, i in extra {
		set[95 + i] = r
	}
	return set
}

fonts_load :: proc() -> Fonts {
	set := codepoints()
	fonts := Fonts {
		regular = rl.LoadFontEx(FONT_REGULAR, FONT_ATLAS, raw_data(set), i32(len(set))),
		bold    = rl.LoadFontEx(FONT_BOLD, FONT_ATLAS, raw_data(set), i32(len(set))),
	}
	if fonts.regular.texture.id == 0 || fonts.bold.texture.id == 0 {
		fmt.eprintfln("could not load %s -- falling back to the built-in font", FONT_REGULAR)
		return {}
	}
	rl.SetTextureFilter(fonts.regular.texture, .BILINEAR)
	rl.SetTextureFilter(fonts.bold.texture, .BILINEAR)
	fonts.loaded = true
	return fonts
}

fonts_unload :: proc(fonts: Fonts) {
	if fonts.loaded {
		rl.UnloadFont(fonts.regular)
		rl.UnloadFont(fonts.bold)
	}
}

@(private = "file")
pick :: proc(fonts: Fonts, bold: bool) -> rl.Font {
	if !fonts.loaded {
		return rl.GetFontDefault()
	}
	return bold ? fonts.bold : fonts.regular
}

text_width :: proc(fonts: Fonts, str: string, size: f32, bold := false) -> f32 {
	return rl.MeasureTextEx(pick(fonts, bold), fmt.ctprint(str), size, size / 12).x
}

text_draw :: proc(
	fonts: Fonts,
	str: string,
	x, y: f32,
	size: f32,
	colour: rl.Color,
	bold := false,
) {
	rl.DrawTextEx(pick(fonts, bold), fmt.ctprint(str), {x, y}, size, size / 12, colour)
}

// Greedy word wrap. Words longer than the width are left to overhang rather than
// broken mid-word -- with region names that never happens in practice.
text_wrap :: proc(
	fonts: Fonts,
	str: string,
	size: f32,
	max_width: f32,
	bold := false,
) -> []string {
	words := strings.split(str, " ", context.temp_allocator)
	lines := make([dynamic]string, context.temp_allocator)
	if len(words) == 0 {
		return lines[:]
	}

	current := words[0]
	for word in words[1:] {
		candidate := strings.concatenate({current, " ", word}, context.temp_allocator)
		if text_width(fonts, candidate, size, bold) <= max_width {
			current = candidate
		} else {
			append(&lines, current)
			current = word
		}
	}
	append(&lines, current)
	return lines[:]
}

// Draws wrapped text and returns the y just past the last line.
text_draw_wrapped :: proc(
	fonts: Fonts,
	str: string,
	x, y: f32,
	size: f32,
	max_width: f32,
	colour: rl.Color,
	bold := false,
) -> f32 {
	cursor := y
	for line in text_wrap(fonts, str, size, max_width, bold) {
		text_draw(fonts, line, x, cursor, size, colour, bold)
		cursor += size * LINE_HEIGHT
	}
	return cursor
}
