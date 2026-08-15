package ukmap

import "core:c"
import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// core:os does not exist on js_wasm32, so assets go through raylib's own file
// API instead. On the web build that reads out of the emscripten filesystem the
// `--preload-file assets` bundle was mounted into; on desktop it is a plain
// fread. Free the result with rl.UnloadFileData.
read_file :: proc(path: string) -> (data: []byte, ok: bool) {
	size: c.int
	raw := rl.LoadFileData(strings.clone_to_cstring(path, context.temp_allocator), &size)
	if raw == nil || size <= 0 {
		fmt.eprintfln("cannot read %s -- run `make mesh` to generate it", path)
		return nil, false
	}
	return raw[:size], true
}
