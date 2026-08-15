#!/usr/bin/env python3
"""Turn the UK boundary GeoJSON into flat binaries for the Odin app.

  python3 tools/build_mesh.py       # -> assets/uk.mesh, assets/uk.land, assets/uk.sea

Each region becomes a bevelled extruded slab: a flat top face (triangulated
with earcut) plus sloped side walls running down to the shared footprint at
y = 0. The bevel is what draws the borders -- neighbouring regions touch at
the base, so there are no cracks to see through, but their top faces are
separated by a shaded slope.

Lighting is baked into the vertex colours, so the renderer only needs raylib's
default unlit shader.

Output format ("UKM4", little-endian):

    magic   char[4]  "UKM4"
    count   u32      vertex count (multiple of 3, non-indexed triangles)
    regions u32      number of regions in the mesh
    bounds  f32[4]   min_x, max_x, min_z, max_z  (world units)
    height  f32      slab height (world units)
    ranges  u32[2*regions]  first vertex and vertex count per region, in the
                     same order as the land grid's region indices, so one
                     region's colours can be rewritten without touching the rest
    pos     f32[3*count]
    normal  f32[3*count]
    colour  u8 [4*count]

Alongside it goes a land grid, so the app can answer "is this spot land, and
which region is it?" with an array lookup instead of a raycast against 100k
triangles. Format ("UKL2", little-endian):

    magic    char[4]  "UKL2"
    size     u32[2]   grid_w, grid_h  (cells, row-major, +x then +z)
    origin   f32[2]   world x/z of cell (0,0)'s corner
    cell     f32      world size of one cell
    surface  f32      world y of the walkable top face
    regions  u16      region count
    names    per region: u8 code length, code, u8 name length, name (utf-8).
                        The code is the join key for data/regions.tsv; the
                        country letter is just its first character.
    cells    u16[grid_w*grid_h]   0 = sea, otherwise region index + 1

And a bathymetry texture, coloured by distance from the coast, drawn as a single
quad at sea level. Format ("UKS1", little-endian):

    magic    char[4]  "UKS1"
    size     u32[2]   width, height
    origin   f32[2]   world x/z of texel (0,0)'s corner
    cell     f32      world size of one texel
    level    f32      world y of the water surface
    deep     u8[4]    RGBA of the plane drawn beyond the texture
    pixels   u8[4*w*h]  RGBA, rows running +z (north to south)
"""

import json
import math
import os
import struct
import sys
from array import array

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from earcut import earcut  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# England is split into its 36 Integrated Care Boards; the devolved nations are
# single blobs. Both files are ONS BGC (generalised, clipped to the coastline),
# so the England/Scotland and England/Wales borders line up between them.
SOURCES = [
    {
        "path": os.path.join(ROOT, "data", "icb.json"),
        "code": "ICB26CD",
        "name": "ICB26NM",
    },
    {
        "path": os.path.join(ROOT, "data", "countries.json"),
        "code": "CTRY24CD",
        "name": "CTRY24NM",
        "skip": ("E92000001",),  # England comes from the ICB file instead
    },
]
OUT = os.path.join(ROOT, "assets", "uk.mesh")
OUT_LAND = os.path.join(ROOT, "assets", "uk.land")
OUT_SEA = os.path.join(ROOT, "assets", "uk.sea")
SRC_INFO = os.path.join(ROOT, "data", "regions.tsv")  # hand-edited
OUT_INFO = os.path.join(ROOT, "assets", "regions.tsv")  # copy the app reads

# --- tunables ---------------------------------------------------------------

MAP_SIZE = 20.0  # longest horizontal extent, in world units
SLAB_HEIGHT = 0.26  # extrusion height
BEVEL = 0.028  # horizontal inset of the top face (world units)
SIMPLIFY_M = 200.0  # Douglas-Peucker tolerance, metres
MIN_AREA_KM2 = 1.0  # drop islands smaller than this
LAND_CELLS = 1024  # land grid resolution along the map's longest axis

SEA_LEVEL = 0.09  # world y of the water surface (the slab runs 0 .. SLAB_HEIGHT)
SEA_PAD = 3.2  # world units of open water painted beyond the land bounds
SEA_CELLS = 512  # bathymetry texture resolution along its longest axis
SEA_SHALLOW = (38, 78, 104)
SEA_DEEP = (14, 28, 46)
SEA_FALLOFF_KM = 180.0  # distance from shore at which the ramp bottoms out
SEA_CONTOUR_KM = 25.0  # spacing of the depth contour bands

LIGHT = (-0.45, 0.80, 0.40)  # baked directional light
AMBIENT = 0.42  # floor brightness for faces pointing away

LAT0, LON0 = 54.5, -3.0  # projection origin, roughly the centre of the UK
EARTH_KM = 6371.0

COUNTRY_COLOUR = {
    "E": (86, 132, 96),  # England, if it ever gets drawn as one blob
    "S": (78, 112, 148),  # Scotland
    "W": (150, 106, 84),  # Wales
    "N": (138, 116, 156),  # Northern Ireland
}

# Cycled across the ICBs in file order. Kept within one green/teal family so
# England still reads as England, but adjacent boards separate clearly.
ICB_PALETTE = [
    (86, 132, 96),
    (72, 126, 112),
    (104, 140, 94),
    (84, 122, 126),
    (118, 142, 90),
    (94, 134, 116),
]


# --- geojson ----------------------------------------------------------------


def tidy_name(name):
    """'... Integrated Care Board' -> '... ICB', keeping the rest of the official name."""
    suffix = " Integrated Care Board"
    if name.endswith(suffix):
        name = name[: -len(suffix)] + " ICB"
    return name


def load_regions(source):
    """Yield (code, name, [exterior ring of (lon, lat), ...]) per feature."""
    doc = json.load(open(source["path"]))
    skip = set(source.get("skip", ()))

    for feature in doc["features"]:
        props = feature["properties"]
        code = props[source["code"]]
        if code in skip:
            continue
        geometry = feature["geometry"]
        polygons = (
            geometry["coordinates"]
            if geometry["type"] == "MultiPolygon"
            else [geometry["coordinates"]]
        )
        # ring 0 of each polygon is the exterior; interior rings (a handful of
        # enclaves and reservoirs) are filled rather than carved
        rings = [[(x, y) for x, y in poly[0]] for poly in polygons]
        yield code, tidy_name(props[source["name"]]), rings


# --- geometry ---------------------------------------------------------------


def project(lon, lat):
    """Equirectangular around the UK centre. Good enough over a 1000 km span."""
    x = math.radians(lon - LON0) * math.cos(math.radians(LAT0)) * EARTH_KM
    z = -math.radians(lat - LAT0) * EARTH_KM
    return x, z  # kilometres, north is -z


def spherical_area_km2(ring):
    """Area of a lon/lat ring on the sphere.

    Not measured off the projected map: the equirectangular projection stretches
    east-west by a fixed cos(54.5 deg), so areas come out several percent high in
    Scotland and low in Wales. This is the standard spherical-excess formula and
    is good to well under a percent at these sizes.
    """
    total = 0.0
    n = len(ring)
    for i in range(n):
        lon0, lat0 = ring[i]
        lon1, lat1 = ring[(i + 1) % n]
        total += math.radians(lon1 - lon0) * (
            2 + math.sin(math.radians(lat0)) + math.sin(math.radians(lat1))
        )
    return abs(total) * EARTH_KM * EARTH_KM / 2.0


def signed_area(ring):
    """Positive when counter-clockwise with north up (u = x, v = -z)."""
    total = 0.0
    n = len(ring)
    for i in range(n):
        x0, z0 = ring[i]
        x1, z1 = ring[(i + 1) % n]
        total += x0 * (-z1) - x1 * (-z0)
    return total / 2.0


def simplify(ring, eps):
    """Douglas-Peucker on a closed ring, iterative so deep rings can't blow the stack."""
    if len(ring) < 4:
        return ring
    keep = [False] * len(ring)
    keep[0] = keep[-1] = True
    stack = [(0, len(ring) - 1)]
    eps2 = eps * eps
    while stack:
        lo, hi = stack.pop()
        if hi <= lo + 1:
            continue
        ax, az = ring[lo]
        bx, bz = ring[hi]
        dx, dz = bx - ax, bz - az
        seg2 = dx * dx + dz * dz
        worst = -1.0
        widx = -1
        for i in range(lo + 1, hi):
            px, pz = ring[i]
            if seg2 == 0.0:
                d2 = (px - ax) ** 2 + (pz - az) ** 2
            else:
                t = ((px - ax) * dx + (pz - az) * dz) / seg2
                t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
                d2 = (px - ax - t * dx) ** 2 + (pz - az - t * dz) ** 2
            if d2 > worst:
                worst, widx = d2, i
        if worst > eps2:
            keep[widx] = True
            stack.append((lo, widx))
            stack.append((widx, hi))
    return [p for p, k in zip(ring, keep) if k]


def dedupe(ring):
    out = []
    for p in ring:
        if not out or (abs(p[0] - out[-1][0]) > 1e-9 or abs(p[1] - out[-1][1]) > 1e-9):
            out.append(p)
    while len(out) > 1 and out[0] == out[-1]:
        out.pop()
    return out


def edge_normals(ring):
    """Outward horizontal normal of each edge i -> i+1, for a CCW ring."""
    n = len(ring)
    out = []
    for i in range(n):
        x0, z0 = ring[i]
        x1, z1 = ring[(i + 1) % n]
        dx, dz = x1 - x0, z1 - z0
        # left of travel is inside for a CCW ring, so outward is (-dz, dx)
        nx, nz = -dz, dx
        length = math.hypot(nx, nz)
        out.append((nx / length, nz / length) if length > 0 else (0.0, 0.0))
    return out


def inset_ring(ring, enormals, dist):
    """Move every vertex inward along its angle bisector."""
    n = len(ring)
    out = []
    for i in range(n):
        ax, az = enormals[i - 1]
        bx, bz = enormals[i]
        mx, mz = ax + bx, az + bz
        length = math.hypot(mx, mz)
        if length < 1e-6:  # 180 degree spike, no sane bisector
            out.append(ring[i])
            continue
        mx, mz = mx / length, mz / length
        # scale so the inset edges sit `dist` in from the originals
        cosang = max(0.35, mx * bx + mz * bz)  # clamped: sharp spikes would shoot off
        step = dist / cosang
        out.append((ring[i][0] - mx * step, ring[i][1] - mz * step))
    return out


def triangulate(ring):
    flat = []
    for x, z in ring:
        flat.extend((x, z))
    return earcut(flat)


def triangulated_area(ring, tris):
    total = 0.0
    for i in range(0, len(tris), 3):
        a, b, c = ring[tris[i]], ring[tris[i + 1]], ring[tris[i + 2]]
        total += abs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]))
    return total / 2.0


def bevel_top(ring, enormals):
    """Inset `ring` for the top face, backing off until the result is sane.

    A naive bisector inset folds over itself wherever the shape is narrower than
    twice the bevel -- small islands, thin peninsulas, river-mouth spits. A
    folded ring triangulates into overlapping garbage and leaves see-through
    holes in the slab, so each candidate is checked two ways: it has to keep most
    of the original area, and its triangulation has to cover it exactly. If no
    inset survives we drop the bevel for that ring and let the wall go vertical.
    """
    area = abs(signed_area(ring))
    perimeter = sum(
        math.dist(ring[i], ring[(i + 1) % len(ring)]) for i in range(len(ring))
    )
    # 2*area/perimeter approximates the inscribed radius; never eat more than a
    # quarter of it, whatever BEVEL says
    dist = min(BEVEL, 0.25 * 2.0 * area / perimeter) if perimeter > 0 else 0.0

    while dist > BEVEL / 32:
        top = inset_ring(ring, enormals, dist)
        top_area = signed_area(top)
        if top_area > 0.3 * area:
            tris = triangulate(top)
            if abs(triangulated_area(top, tris) - top_area) <= 0.01 * top_area:
                return top, tris, True
        dist /= 2.0

    return list(ring), triangulate(ring), False


# --- land grid --------------------------------------------------------------


def rasterise(regions, min_x, min_z, cell, gw, gh):
    """Scan-convert the district footprints into a grid of district indices.

    Standard even-odd scanline fill, except the crossings are bucketed by row
    up front: walking every edge for every row would be O(edges x rows) and the
    big Scottish districts have thousands of edges each.
    """
    grid = array("H", bytes(2 * gw * gh))

    for index, (_, _, rings) in enumerate(regions):
        value = index + 1
        rows = {}
        for ring in rings:
            n = len(ring)
            for i in range(n):
                x0, z0 = ring[i]
                x1, z1 = ring[(i + 1) % n]
                if z0 == z1:
                    continue
                # a row is crossed when its centre lies in [min(z), max(z))
                lo_z, hi_z = (z0, z1) if z0 < z1 else (z1, z0)
                j_lo = math.ceil((lo_z - min_z) / cell - 0.5)
                j_hi = math.ceil((hi_z - min_z) / cell - 0.5) - 1
                if j_hi < 0 or j_lo > gh - 1:
                    continue
                j_lo = max(j_lo, 0)
                j_hi = min(j_hi, gh - 1)
                inv = (x1 - x0) / (z1 - z0)
                for j in range(j_lo, j_hi + 1):
                    zc = min_z + (j + 0.5) * cell
                    rows.setdefault(j, []).append(x0 + (zc - z0) * inv)

        for j, crossings in rows.items():
            crossings.sort()
            base = j * gw
            for k in range(0, len(crossings) - 1, 2):
                i_lo = math.ceil((crossings[k] - min_x) / cell - 0.5)
                i_hi = math.ceil((crossings[k + 1] - min_x) / cell - 0.5) - 1
                if i_hi < 0 or i_lo > gw - 1 or i_hi < i_lo:
                    continue
                i_lo = max(i_lo, 0)
                i_hi = min(i_hi, gw - 1)
                grid[base + i_lo : base + i_hi + 1] = array(
                    "H", [value] * (i_hi - i_lo + 1)
                )

    return grid


def write_land(regions, min_x, max_x, min_z, max_z, surface_y):
    cell = max(max_x - min_x, max_z - min_z) / LAND_CELLS
    gw = int(math.ceil((max_x - min_x) / cell))
    gh = int(math.ceil((max_z - min_z) / cell))
    grid = rasterise(regions, min_x, min_z, cell, gw, gh)

    with open(OUT_LAND, "wb") as f:
        f.write(b"UKL2")
        f.write(struct.pack("<II", gw, gh))
        f.write(struct.pack("<4f", min_x, min_z, cell, surface_y))
        f.write(struct.pack("<H", len(regions)))
        for code, name, _ in regions:
            code_raw = code.encode("utf-8")[:255]
            name_raw = name.encode("utf-8")[:255]
            f.write(struct.pack("<B", len(code_raw)))
            f.write(code_raw)
            f.write(struct.pack("<B", len(name_raw)))
            f.write(name_raw)
        f.write(grid.tobytes())

    land_cells = sum(1 for v in grid if v)
    return gw, gh, land_cells


# --- bathymetry -------------------------------------------------------------


def distance_to_land(grid, gw, gh):
    """Chamfer distance transform: cells -> distance to the nearest land, in cells.

    Two passes (down-right, then up-left) with 3-4 style weights. Close enough to
    Euclidean for a colour ramp, and it does not need a queue.
    """
    ORTHO, DIAG = 1.0, 1.41421356
    far = float(gw + gh)
    dist = array("f", [0.0 if v else far for v in grid])

    for j in range(gh):
        base = j * gw
        for i in range(gw):
            k = base + i
            d = dist[k]
            if d == 0.0:
                continue
            if i > 0 and dist[k - 1] + ORTHO < d:
                d = dist[k - 1] + ORTHO
            if j > 0:
                up = k - gw
                if dist[up] + ORTHO < d:
                    d = dist[up] + ORTHO
                if i > 0 and dist[up - 1] + DIAG < d:
                    d = dist[up - 1] + DIAG
                if i < gw - 1 and dist[up + 1] + DIAG < d:
                    d = dist[up + 1] + DIAG
            dist[k] = d

    for j in range(gh - 1, -1, -1):
        base = j * gw
        for i in range(gw - 1, -1, -1):
            k = base + i
            d = dist[k]
            if d == 0.0:
                continue
            if i < gw - 1 and dist[k + 1] + ORTHO < d:
                d = dist[k + 1] + ORTHO
            if j < gh - 1:
                down = k + gw
                if dist[down] + ORTHO < d:
                    d = dist[down] + ORTHO
                if i > 0 and dist[down - 1] + DIAG < d:
                    d = dist[down - 1] + DIAG
                if i < gw - 1 and dist[down + 1] + DIAG < d:
                    d = dist[down + 1] + DIAG
            dist[k] = d

    return dist


def write_sea(regions, min_x, max_x, min_z, max_z, scale):
    """Bake a bathymetry texture: colour by distance from the coast.

    Reuses the same scan conversion as the land grid, on a padded, coarser grid.
    Baking it means the renderer just draws a textured quad -- no custom shader,
    so it behaves the same on desktop GL and WebGL.
    """
    x0, x1 = min_x - SEA_PAD, max_x + SEA_PAD
    z0, z1 = min_z - SEA_PAD, max_z + SEA_PAD
    cell = max(x1 - x0, z1 - z0) / SEA_CELLS
    gw = int(math.ceil((x1 - x0) / cell))
    gh = int(math.ceil((z1 - z0) / cell))

    grid = rasterise(regions, x0, z0, cell, gw, gh)
    dist = distance_to_land(grid, gw, gh)

    km_per_cell = cell / scale  # `scale` is world units per km
    pixels = bytearray(gw * gh * 4)
    for k in range(gw * gh):
        km = dist[k] * km_per_cell
        t = min(1.0, km / SEA_FALLOFF_KM) ** 0.6
        shade = 1.0
        # a darker line every SEA_CONTOUR_KM, which is what makes it read as a
        # chart rather than a flat gradient
        if km > 0 and (km % SEA_CONTOUR_KM) < km_per_cell:
            shade = 0.86
        o = k * 4
        for c in range(3):
            v = SEA_SHALLOW[c] + (SEA_DEEP[c] - SEA_SHALLOW[c]) * t
            pixels[o + c] = max(0, min(255, int(v * shade)))
        pixels[o + 3] = 255

    with open(OUT_SEA, "wb") as f:
        f.write(b"UKS1")
        f.write(struct.pack("<II", gw, gh))
        f.write(struct.pack("<4f", x0, z0, cell, SEA_LEVEL))
        f.write(bytes(SEA_DEEP) + b"\xff")  # colour of the plane beyond the texture
        f.write(pixels)

    return gw, gh


# --- region info ------------------------------------------------------------

# Columns after `name` become rows in the side panel, labelled by this header.
# Add or remove a column here (or in data/regions.tsv) and the panel follows --
# nothing in the Odin code names these fields.
INFO_FIELDS = [
    "Registered patients",
    "GP practices",
    "Area",
    "Patients per km²",
]

NHS_MAP_ZIP = os.path.join(ROOT, "data", "nhs", "gp-reg-pat-prac-map.zip")
NHS_REGIONS_ZIP = os.path.join(
    ROOT, "data", "nhs", "gp-reg-pat-prac-sing-age-regions.zip"
)


def load_nhs_stats():
    """Registered patients and GP practice counts per ICB, keyed by ONS code.

    Both come from NHS England's monthly "Patients Registered at a GP Practice"
    release, which carries the same E54... codes as the ONS boundaries, so the
    join is exact rather than by name.

    England only: ICBs do not exist elsewhere, and Scotland, Wales and Northern
    Ireland run separate health systems whose figures are not comparable.
    """
    import csv
    import io
    import zipfile

    patients, practices, extract = {}, {}, None

    with zipfile.ZipFile(NHS_REGIONS_ZIP) as z:
        with z.open(z.namelist()[0]) as f:
            for row in csv.DictReader(io.TextIOWrapper(f, "utf-8")):
                if (
                    row["ORG_TYPE"].strip() == "ICB"
                    and row["SEX"] == "ALL"
                    and row["AGE"] == "ALL"
                ):
                    patients[row["ONS_CODE"].strip()] = int(row["NUMBER_OF_PATIENTS"])
                    extract = extract or row["EXTRACT_DATE"].strip()

    with zipfile.ZipFile(NHS_MAP_ZIP) as z:
        with z.open(z.namelist()[0]) as f:
            for row in csv.DictReader(io.TextIOWrapper(f, "utf-8")):
                code = row["ONS_ICB_CODE"].strip()
                if code:
                    practices[code] = practices.get(code, 0) + 1

    return patients, practices, extract


def region_info(code, area_km2, patients, practices):
    """One row of panel fields. "--" wherever the figure genuinely does not exist."""
    people = patients.get(code)
    return [
        "{:,}".format(people) if people else "--",
        "{:,}".format(practices[code]) if code in practices else "--",
        "{:,.0f} km²".format(area_km2),
        "{:,.0f}".format(people / area_km2) if people and area_km2 else "--",
    ]


def write_region_info(regions, areas):
    """Write data/regions.tsv if absent, then copy it to assets/ for the app.

    Kept in data/ rather than assets/ precisely so that hand-edited content is
    never clobbered by a rebuild -- this only ever creates the file, never
    overwrites it.
    """
    created = False
    if not os.path.exists(SRC_INFO):
        patients, practices, extract = load_nhs_stats()
        lines = [
            "# Registered patients and GP practices: NHS England, "
            "Patients Registered at a GP Practice, %s. Area from ONS boundaries."
            % extract,
            "\t".join(["code", "name"] + INFO_FIELDS),
        ]
        for code, name, _ in regions:
            lines.append(
                "\t".join(
                    [code, name] + region_info(code, areas[code], patients, practices)
                )
            )
        with open(SRC_INFO, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        created = True

    with open(SRC_INFO, "rb") as src, open(OUT_INFO, "wb") as dst:
        dst.write(src.read())
    return created


# --- shading ----------------------------------------------------------------

LIGHT_LEN = math.sqrt(sum(c * c for c in LIGHT))
LIGHT_N = tuple(c / LIGHT_LEN for c in LIGHT)


def shade(base, normal, jitter):
    lambert = sum(a * b for a, b in zip(normal, LIGHT_N))
    k = (AMBIENT + (1.0 - AMBIENT) * max(0.0, lambert)) * jitter
    return tuple(min(255, max(0, int(c * k))) for c in base)


def region_hash(key):
    h = 2166136261
    for ch in key:
        h = ((h ^ ord(ch)) * 16777619) & 0xFFFFFFFF
    return h


def region_jitter(key):
    return 0.94 + (region_hash(key) % 1000) / 1000.0 * 0.12


# --- mesh building ----------------------------------------------------------


class MeshBuilder:
    def __init__(self):
        self.pos = []
        self.nrm = []
        self.col = []

    def tri(self, a, b, c, normal, colour):
        # keep the winding consistent with the normal so backface culling works
        ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
        vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
        cx = uy * vz - uz * vy
        cy = uz * vx - ux * vz
        cz = ux * vy - uy * vx
        if cx * normal[0] + cy * normal[1] + cz * normal[2] < 0.0:
            b, c = c, b
        for p in (a, b, c):
            self.pos.extend(p)
            self.nrm.extend(normal)
            self.col.extend(colour)
            self.col.append(255)

    def count(self):
        return len(self.pos) // 3


def build():
    regions = []  # (code, name, [ring in km, ...])
    areas = {}  # code -> km^2, measured on the sphere before projection
    for source in SOURCES:
        for code, name, raw_rings in load_regions(source):
            rings = []
            for raw in raw_rings:
                ring = dedupe([project(lon, lat) for lon, lat in raw])
                if len(ring) < 3:
                    continue
                if abs(signed_area(ring)) < MIN_AREA_KM2:
                    continue
                ring = dedupe(simplify(ring, SIMPLIFY_M / 1000.0))
                if len(ring) < 3:
                    continue
                if signed_area(ring) < 0:  # force CCW with north up
                    ring.reverse()
                rings.append(ring)
                areas[code] = areas.get(code, 0.0) + spherical_area_km2(raw)
            if rings:
                regions.append((code, name, rings))

    # centre and scale to world units
    xs = [p[0] for _, _, rs in regions for r in rs for p in r]
    zs = [p[1] for _, _, rs in regions for r in rs for p in r]
    cx, cz = (min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2
    scale = MAP_SIZE / max(max(xs) - min(xs), max(zs) - min(zs))
    regions = [
        (code, name, [[((x - cx) * scale, (z - cz) * scale) for x, z in r] for r in rs])
        for code, name, rs in regions
    ]
    min_x = (min(xs) - cx) * scale
    max_x = (max(xs) - cx) * scale
    min_z = (min(zs) - cz) * scale
    max_z = (max(zs) - cz) * scale

    mb = MeshBuilder()
    h = SLAB_HEIGHT
    unbevelled = 0
    icb_index = 0
    ranges = []  # (first vertex, vertex count) per region, for highlighting
    for code, _, rings in regions:
        region_start = mb.count()
        if code[0] == "E":
            base = ICB_PALETTE[icb_index % len(ICB_PALETTE)]
            icb_index += 1
        else:
            base = COUNTRY_COLOUR[code[0]]
        jitter = region_jitter(code)
        top_colour = shade(base, (0.0, 1.0, 0.0), jitter)

        for ring in rings:
            enorm = edge_normals(ring)
            top, tris, bevelled = bevel_top(ring, enorm)
            if not bevelled:
                unbevelled += 1

            # top face
            for i in range(0, len(tris), 3):
                a, b, c = tris[i], tris[i + 1], tris[i + 2]
                mb.tri(
                    (top[a][0], h, top[a][1]),
                    (top[b][0], h, top[b][1]),
                    (top[c][0], h, top[c][1]),
                    (0.0, 1.0, 0.0),
                    top_colour,
                )

            # bevelled walls: base ring at y=0 up to the inset ring at y=h
            n = len(ring)
            for i in range(n):
                j = (i + 1) % n
                nx, nz = enorm[i]
                # tilt the normal up by however far this edge actually stepped in
                inset = max(0.0, (ring[i][0] - top[i][0]) * nx + (ring[i][1] - top[i][1]) * nz)
                ny = inset / h
                length = math.sqrt(nx * nx + ny * ny + nz * nz)
                normal = (nx / length, ny / length, nz / length)
                colour = shade(base, normal, jitter)
                p0 = (ring[i][0], 0.0, ring[i][1])
                p1 = (ring[j][0], 0.0, ring[j][1])
                q0 = (top[i][0], h, top[i][1])
                q1 = (top[j][0], h, top[j][1])
                mb.tri(p0, p1, q1, normal, colour)
                mb.tri(p0, q1, q0, normal, colour)

        ranges.append((region_start, mb.count() - region_start))

    count = mb.count()

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(b"UKM4")
        f.write(struct.pack("<II", count, len(regions)))
        f.write(struct.pack("<5f", min_x, max_x, min_z, max_z, h))
        for start, length in ranges:
            f.write(struct.pack("<II", start, length))
        f.write(struct.pack("<%df" % len(mb.pos), *mb.pos))
        f.write(struct.pack("<%df" % len(mb.nrm), *mb.nrm))
        f.write(bytes(mb.col))

    gw, gh, land_cells = write_land(regions, min_x, max_x, min_z, max_z, h)
    sw, sh = write_sea(regions, min_x, max_x, min_z, max_z, scale)
    info_created = write_region_info(regions, areas)

    print(
        "%s: %d regions, %d triangles, %.1f MB (%d rings too thin to bevel)"
        % (
            os.path.relpath(OUT, ROOT),
            len(regions),
            count // 3,
            os.path.getsize(OUT) / 1e6,
            unbevelled,
        )
    )
    print(
        "%s: %dx%d cells, %d land, %.1f MB"
        % (
            os.path.relpath(OUT_LAND, ROOT),
            gw,
            gh,
            land_cells,
            os.path.getsize(OUT_LAND) / 1e6,
        )
    )
    print(
        "%s: %dx%d texels, %.1f MB"
        % (os.path.relpath(OUT_SEA, ROOT), sw, sh, os.path.getsize(OUT_SEA) / 1e6)
    )
    print(
        "%s: %s (%d fields)"
        % (
            os.path.relpath(SRC_INFO, ROOT),
            "created from NHS England + ONS figures" if info_created else "kept, copied to assets",
            len(INFO_FIELDS),
        )
    )


if __name__ == "__main__":
    build()
