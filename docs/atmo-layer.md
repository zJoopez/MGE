# Atmo layer (MGE's Atmo list)

How MGE keeps and edits atmo objects, and the game facts behind it. Built 2026-11-14 (was atmo-tab-plan.md;
its history is in git). User-facing description: README, "Atmo".

## Design

- **Data:** `ModData.parsed.atmo`, objects with `kind = "atmo"`. `utils/atmo.lua` reads and writes `.atmo`
  text keeping every line in order, the object's name, file lines (`shader`, `opt`...) and `player` sections;
  `size` is read as `sides` and written back as `size`, `rot` unchanged.
- **Storage:** inside the mod as `#@ ` lines (docs/atmo-play-plan.md, "Format"). Mods saved before that open
  with their `data/atmospheres/MGE - <mod>.atmo`. World > Export writes clean copies.
- **One edit path:** `utils/transforms.lua` works on lines only for atmo objects (`inWorld` false, no
  `set_obj_*`); rows, gizmo, camera framing and the pivot all use it. `ModData.getEditSelection()` gives the
  selected atmo objects while the Atmo list shows.
- **To atmo / To objects** (Advanced tab): joint-linked objects stay; To objects only as far as free ids go;
  one undo step. Objects entering the atmo get colors limited to 0–2.
- **Drawing:** on the Atmo list atmo objects in their own color, the mod's objects see-through (alpha set live
  to `AtmoLayer.seeThroughAlpha`, put back on leaving, quitting and after reloads). On Objects they're ghosts.
  The nearest `AtmoLayer.maxDraws` (Settings > Max draws) are drawn; Generate adds at most `MAX_GENERATE`.
- **The game's loaded atmo** is unloaded once when MGE starts (`Atmospheres.Unload`, only when `_ATMO` says
  one is loaded); `atmo.cfg` isn't touched.

## Game facts (this install)

- The atmo loader is `Atmospheres.ParseFile` (`system/atmospheres_manager.lua`). Per object: `shape` (box /
  cube, sphere, cylinder / capsule, `custom <model>`), `pos`, `rot`, `size` / `sides`, `color` (above 2:
  0–256), `parent`, `rotate` / `move`, `count` + `random*`, `no_depth 1`, `min_level` / `max_level` (0–2),
  `queue_player`, `drawfunc` / `framefunc` (functions in a sidecar `<name>.lua`). File lines: `shader`,
  `shaderopt`, `opt`. Unknown lines are skipped (so physics lines can ride along).
- **Rotation:** an atmo's `rot` turns like a mod object's: rotX(-x) rotY(-y) rotZ(-z), what `get_obj_rot`
  gives (measured in game). Atmos exported by MGE before 2026-11-14 negated it.
- Sizes: spheres and capsules as in mod files (x radius, y length; `drawCapsule` passes `size.y, size.x`).
- The game's 34 atmos: 2,733 objects, nearly all only `shape pos rot size color`.
- Atmos are client-side: each player loads their own; the mod never carries one to other players.
- `Atmospheres.LoadAtmo` can be called from a script (paths with `../` load from `data/`), but isn't cheaper:
  one `UIElement3D` per object, all drawn every frame with the same `draw_*_m` calls, plus toriui's work; it
  also replaces the player's atmo and can change options.
- How many shapes are drawn a frame depends on the graphics setting; ~10,000 ghosts drew on the lowest.
- Scripts can't delete files (`os.remove` didn't work in game) or create folders (sample assets ship the
  `assets/atmo` folder).
