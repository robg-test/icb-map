# UK 3D map (Odin + raylib)
.PHONY: build run test web serve mesh data clean

ASSETS := assets/uk.mesh assets/uk.land assets/uk.sea assets/regions.tsv
PORT ?= 8000

# Fast iteration: debug compile + run
run: $(ASSETS)
	odin run desktop -out:ukmap-dbg

# Optimised release binary
build: $(ASSETS)
	odin build desktop -o:speed -out:ukmap

test: $(ASSETS)
	odin test . -out:ukmap-test

# WebAssembly build -> build/web (needs emscripten; see build_web.sh)
web: $(ASSETS)
	./build_web.sh

# Reclaims the port from a previous `make serve` first -- rebuilding and then
# failing on "address already in use" is just annoying. Only ever kills our own
# http.server; anything else on the port is left alone and reported.
serve: web
	@pid=$$(ss -ltnpH "sport = :$(PORT)" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1); \
	if [ -n "$$pid" ]; then \
		if tr '\0' ' ' < /proc/$$pid/cmdline 2>/dev/null | grep -q http.server; then \
			echo "replacing stale server on :$(PORT) (pid $$pid)"; \
			kill $$pid; \
			while kill -0 $$pid 2>/dev/null; do sleep 0.1; done; \
		else \
			echo "port $(PORT) is held by pid $$pid, which is not ours -- try: make serve PORT=8001"; \
			exit 1; \
		fi; \
	fi
	python3 -m http.server -d build/web $(PORT)

# Regenerate the mesh and land grid from the boundary data
mesh: $(ASSETS)

assets/uk.mesh: tools/build_mesh.py tools/earcut.py data/icb.json data/countries.json
	python3 tools/build_mesh.py

# written by the same run as the mesh
assets/uk.land assets/uk.sea: assets/uk.mesh

# The region info is hand-edited in data/ and only copied into assets/, so an
# edit costs a copy rather than a full rebuild. Created with placeholder values
# by the first mesh build if it does not exist yet.
assets/regions.tsv: data/regions.tsv
	cp $< $@

data/regions.tsv: assets/uk.mesh

# Re-download the source boundaries (already committed under data/)
data:
	./tools/fetch_data.sh

clean:
	rm -rf ukmap ukmap-dbg ukmap-test $(ASSETS) build
