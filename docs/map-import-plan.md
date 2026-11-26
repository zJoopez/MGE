# Map import (brush maps → Toribash boxes)

Design and measured facts of World list → **Convert map**. History: git log of this file (condensed
2026-11-26). Users convert files they have; no converted maps are shipped.

**Status:** in game only (the command-line tool went 2026-11-15). Built: `.vmf` (Hammer) and Source `.bsp`
v19-21 readers, box fitting, terrain slabs, merge / simplify / hidden boxes, sky clips, roof caps, clip
colors, the placement view, the atmo budget. Dropped after in-game tests: props (static props, `.vpk` model
sizes: git `de2ce06`), the ledge-shell join, red clips, the `.obj` visuals (Phase 2). Not done: Quake `.map`.

## Code (`mge/mapconv/`, pure Lua, loaded on the first Convert map click: `MGE.loadMapConv`)

| File | Contents |
|---|---|
| `vmf.lua` | KeyValues parser → MapFile (brushes with sides, entities); `nonSolidEntity` |
| `bsp.lua` | `.bsp` → the same MapFile: planes per side, role from contents flags, brush entities placed by their `origin` / `angles` (`placeModel`), displacements |
| `brush.lua` | sides → geometry (corners, faces, volume, bounds) |
| `boxfit.lua` | geometry → box or slab; terrain patches → slabs (`BoxFit.terrain`) |
| `merge.lua` | exact merge, `Merge.flat` (simplify), `Merge.hidden` |
| `skyclips.lua` | sky-clip rules |
| `convert.lua` | filtering, roles, pieces → select → objects, budget, report |
| `ui/map_overlay.lua`, `ui/map_place.lua` | settings overlay, placement view |

Stages: `MapConv.pieces` (slow, cached per map + options in `overlayState.cache`) → `MapConv.select` (region,
merge, size, budget; reruns on every gizmo release) → `toWorld` / `objects`.

## Rules

- **Dropped:** tool textures (trigger, skybox, hint, skip, areaportal, occluder, fog...), `trigger_*`, buy
  zones, bomb targets, areaportals, `func_illusionary`; brushes whose every side is an undrawn tool texture
  ("invisible": sealing slabs, backs of terrain walls; option `invisible`); brushes of an entity that starts
  disabled or a never-solid func_brush (CS:GO Retakes walls). `.bsp` brushes follow the same texture rule.
- **Roof caps:** an invisible brush is kept when flat, open (sky over half a 6×6 sample) and supported (a solid
  under it reaches its bottom); it takes its walls' color. dust2 keeps 67, inferno 52.
- **Clips** on by default (players walk on them), always solid in the color of the geometry they overlap most
  (within 8 units; none: grey).
- **Sky clips** left out (`skyClips` false): wide (both sides ≥ 256), flat, and either sky within 256 above
  over half its top, or floating (nothing solid 72 under on half a 6×6 sample) and open. dust2 11, office 8.
- **Box fit:** exact boxes from 3 opposite face pairs; wedges/ramps → a slab under the slope
  (`slabThickness` 8); other shapes → smallest-volume box. Terrain: a flat patch one slab, a bumpy one splits
  in 4 (`terrainTolerance` 8).
- **Simplify** (`Merge.flat`, on): slabs (thinnest ≤ 32, others ≥ 2×) and beams join edge to edge only (no
  doorway bridged), within `simplifyTolerance` 12, fill `simplifyFill` 0.75, normals |n·n| ≥ 0.95.
- **Hidden:** a box inside one other box is dropped (lossless); `dropCovered` (Covered toggle, off) drops ones
  95% inside several.
- **Budget order** (`MapConv.priority`): bigger first, a walkable top (within ~45° of up) counts 3×. Budget
  defaults to every free id; **Atmo** budget sends the smaller rest to the atmo (purple in the preview).
- **Transform:** Source and Toribash are both Z-up: `p' = (p - anchor) * scale`, lowest kept box at z = lift
  (≥ 0). Scale default 0.035 (a tori's head ~2.5 = 72 Source units).

## Placement view

Opened by the overlay's Place. Draws the map where Convert puts it (orange kept, red over budget, purple atmo,
grey context within 0.5 of the region, cyan region box), at most `MapPlace.maxDraws` shapes. Bar: Region | Map,
Move | Rotate | Scale, Settings | Convert, then Simplify | Covered. Region gizmo moves / scales the region; Map
gizmo moves the anchor, turns the yaw, scales. Per-map placement kept in `overlayState.placements`. MGE's
window is hidden meanwhile (Alt+Q/W/E still work).

## Measured

- dust2 (CS:GO Legacy, 325 MB, 9.1 MB read): 2,471 brushes, 8,324 terrain grids; 88% of floors are terrain
  only; whole map ~7,500 boxes, so always by region. B site 1000×1000 at defaults: ~135 boxes before hidden.
- 27 CS:GO maps convert as whole maps without errors (0.7–12 s; cache is the heaviest). Newer maps (agency,
  boyard, chalice) are mostly props: expect holes.
- 26 of 27 maps have brush entities placed by origin / angles (de_train's cars).
- Test maps live in `mge/assets/maps/` (gitignored).

## Tests

`lua5.1 tests/run.lua mapconv` (and `bsp`): hand-written VMFs through the whole conversion;
`tests/test_bsp.lua` reads `tf2_test2.bsp` when present. `tools/mapconv_baseline.lua check` compares
conversions against a stored baseline.

## Open (in game)

- The angle convention of turned brush entities against a known placement.
- Convert's pause on big maps (~1.3 s offline for dust2): a coroutine if it feels bad.
- Ramps / slabs feel; frame rate with the grey context.
