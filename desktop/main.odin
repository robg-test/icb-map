package main_desktop

import "core:os"
import ukmap ".."

main :: proc() {
	if !ukmap.init() {
		os.exit(1)
	}

	// `ukmap --shot out.png` renders one frame, saves it and exits (handy for
	// checking the mesh over ssh or in a build).
	shot := len(os.args) > 2 && os.args[1] == "--shot" ? os.args[2] : ""

	for ukmap.should_run() {
		ukmap.update()
		if shot != "" {
			ukmap.screenshot(shot)
			break
		}
	}

	ukmap.shutdown()
}
