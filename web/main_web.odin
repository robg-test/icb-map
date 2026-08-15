// Entry points called from index.html. The browser drives the frame loop, so
// there is no `for` here -- a blocking loop would freeze the tab.
//
// emscripten_allocator.odin and emscripten_logger.odin are taken from
// karl-zylinski/odin-raylib-web (MIT).

package main_web

import "base:runtime"
import "core:c"
import "core:mem"
import ukmap ".."

@(private = "file")
web_context: runtime.Context

@export
main_start :: proc "c" () {
	context = runtime.default_context()

	// Odin's WASM allocator conflicts with how emscripten manages memory, so
	// route allocations through emscripten's malloc instead.
	context.allocator = emscripten_allocator()
	runtime.init_global_temporary_allocator(4 * mem.Megabyte)
	context.logger = create_emscripten_logger()

	web_context = context

	if !ukmap.init() {
		ukmap.web_stop()
	}
}

@export
main_update :: proc "c" () -> bool {
	context = web_context
	ukmap.update()
	return ukmap.should_run()
}

@export
main_end :: proc "c" () {
	context = web_context
	ukmap.shutdown()
}

@export
web_window_size_changed :: proc "c" (w: c.int, h: c.int) {
	context = web_context
	ukmap.parent_window_size_changed(int(w), int(h))
}
