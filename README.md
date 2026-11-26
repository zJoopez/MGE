# MGE: Mod Group Editor

A Toribash script for editing mods. The game's own editor changes one object at a time. MGE selects
many objects, players or joints and moves, rotates, scales or edits them together, with a gizmo in
the world and undo / redo.

Built for Toribash 5.76. Work in progress.

## Install

1. Download `mge.zip` and unzip it into Toribash's `data/script` folder. You get
   `data/script/mge/mge.lua` and `data/script/mge/mge/...`.
2. In game, load a mod, then type `/ls mge/mge.lua` in chat.

F1 hides or shows the window. Running `/ls mge/mge.lua` again shows the running window instead of
starting a second one.

## What it does

The window has five lists, each with its own tabs.

| List | Tabs |
|---|---|
| **Objects** | **Core**: position, rotation, scale, color, mass, shape, visibility. **Advanced**: friction, bounce, hardness, flags, model, reindexing ids, To atmo. **Thrust**: frames, direction, axes. **Generate**: rows, rings and grids of new objects, each piece turned with Rot or the Rotate gizmo. |
| **Atmo** | **Core**: as on Objects, with To objects. **Advanced**: friction, bounce, hardness, flags (as on Objects, for Atmo Play), depth, graphics levels, kept lines. **Generate**: as on Objects. |
| **Joints** | **Link**: the two objects a joint connects, picked in the list or, with Pick from world on, in the world. **Properties**: position, axis, range, strength, velocity, type. |
| **Players** | **Player**: start position, rotation, scale and part averages of the selected players, model reset. **Parts**: position, rotation, sides and shape of the selected body parts. **Advanced**: density, friction, bounce, hardness, flag. **Joints**: position, radius, strength, velocity, axis, range of the selected joints. |
| **World** | The mod's name (where Save writes), its message, the atmo's shader, map import, Export (Atmo, Mod), Atmo: Playable / Default (a playable atmo mod, or the atmo only drawn), Reset all (loads the classic mod). |

- Number fields apply what you type when you leave them (click elsewhere) or press Enter, then show the
  new value as their placeholder. Esc while typing drops it. The Generate tab's fields keep their text:
  Enter there generates.
- Click objects in the world to select them. Shift + click adds to the selection.
- The gizmo (Move, Rotate, Scale) works on everything selected. Hold Ctrl while dragging to snap
  (Ctrl + Shift: the fine step). The steps are in Settings > Snapping.
- **In place** (the toggle left of the gizmo tools): Rotate and Scale, with the gizmo or the Rot / Scale rows, turn
  and size each object around itself and leave the positions. Off: the selection turns and scales as one group
  around its center. Objects and atmo objects; it stays as you left it (config.cfg).
- **Export** saves the selected objects (or a player's model) as an asset. **Import** adds one in
  front of the camera. Assets live in `mge/mge/assets/obj` and `mge/mge/assets/player`, and a few
  examples come with the download.
- **Settings** (UI size, camera follow, snapping steps, max atmo objects) and the color picker's saved colors
  are kept in `mge/mge/config.cfg`, so they stay between game sessions and over updates.
- **Save** writes the mod to `data/mod/modmaker/<name>.tbm`, the name on **World → Core → Name** (the loaded mod's, `mge` for the classic mod; click it to change it). Saving over a file that isn't this mod's asks first. While you edit, MGE reloads a working copy
  (`modmaker/mge-work.tbm`) so changes show in the game straight away.

### Players and their body parts (parts: experimental)

The **Players** list shows a map of the default tori seen from behind (its left on the left; joints only on
the Joints tab), whatever shape the mod gives the body, and the player buttons P0, P1... Its tab decides what
everything acts on:

- **Player tab:** whole players. P0, P1... select them (Shift adds), as do world clicks and Shift + drag; the
  list's buttons add, duplicate, import, export and delete players. A click on the map opens the part's tab.
- **Parts, Advanced and Joints tabs:** single body parts and joints of the players' models.

On the part tabs:

- **Selecting:** click a part or joint on the map, Shift + click adds. P0, P1... pick whose parts the map shows; a
  selection can span players. Clicks in the world pick parts and joints too, Shift + drag adds the ones in the
  box (Ctrl + Shift: hidden ones too). Ctrl + A selects all of the shown player's parts (on the Joints tab: its
  joints). Ctrl + Shift + Z / Y bring back an earlier selection, as on Objects.
- **Mirror** (on the list's bar, on by default): an edit also changes the left / right twin, mirrored. A twin
  joint gets the same axis, range and numbers (as the default body has them), only its position mirrored.
- **Editing:** the rows and the gizmo (Move, Rotate, Scale) work on the selection, one undo step each. Values are
  in the player's layout, as the mod file writes them. A joint moves only when both parts it links are
  selected; the others stay where they are. Scale works in place along each part's axes. Joints alone: Move only
  (the preview shows where they go).
- The gizmo needs the bodies where the mod puts them: back to the fight's start (frame 0) after playing.
- The head stays a sphere: another shape crashes the game.

### Map import (experimental)

World list → **Convert map** turns a Hammer `.vmf` or a compiled Source `.bsp` (CS:S, CS:GO, TF2,
HL2, Garry's Mod) into static boxes. Put maps in `mge/mge/assets/maps`. You pick the part of the map
to convert and where it goes in the world, then Convert adds the boxes. A mod holds 256 objects, so
pick a region (one bombsite, not a whole map).

### Atmo: scenery beyond 256 objects (experimental)

A mod holds 256 objects. Scenery beyond that goes in the mod's **atmo**: objects the game draws without
collisions. Players load an atmo themselves (main menu → Shaders & Atmos → Atmos); it doesn't come with
the mod.

- **The Atmo list** (next to Objects) shows the atmo objects as A1, A2… with the same grid and bottom bar:
  - **New** adds a box in front of the camera, **Duplicate** and **Delete** work on the selected ones.
  - **Import** reads an `.atmo` from `assets/atmo` or `data/atmospheres` (the game's atmos and your own)
    and adds its objects where the file has them. **Export** writes the selected ones to `assets/atmo`.
  - On this list the atmo objects are drawn in their own color and the mod's objects turn see-through.
- **Editing:** the **Core** and **Advanced** tabs are the objects' tabs, on the selected atmo objects. The
  gizmo, clicks and Shift + drag work the same. Advanced's last row has **To objects**.
  Mass, Visible, Friction, Bounce, Hardness and Flags only act in a playable atmo mod (Atmo Play, below): the
  game's own atmo ignores those lines. Static off makes a prop, pushable in Atmo Play. Model and Ids aren't on
  the Atmo list; Collision and Motion (props) are. Lines MGE doesn't edit (depth, graphics levels, animation)
  are kept as written. The **Generate** tab works as on Objects, and its pieces
  go to the atmo (no joints field there: atmos have none).
- **To atmo** (Objects → Advanced) moves the selected objects into the atmo and frees their ids. **To
  objects** moves atmo objects back while there are free ids. Objects joined by a joint stay.
- **Saving:** Save keeps the atmo **inside the mod**, as `#@` comment lines the game skips (one file to
  share), and opening the mod reads it back. **Atmo Play** draws it when the mod is loaded (a playable mod: also
  solid). For players without Atmo Play, **World → Export**: **Atmo** writes
  `data/atmospheres/MGE - exp_<name>.atmo` (loaded in the game's Shaders & Atmos > Atmos), **Mod** writes
  `modmaker/exp_<name>.tbm`, the mod without its atmo. Both ask the name first (default: the mod's), so wip and
  final copies don't change the mod's own name. The `exp_` prefix keeps exports apart from your mods: a mod's name
  never starts with it (loading `exp_foo.tbm` and saving writes `foo.tbm`), so an export replaces only an earlier
  export of the same name, without asking. Mods saved before atmos went inside them still open with their
  `MGE - <mod>.atmo`.
- **The game's own atmo** is unloaded when MGE starts, so the saved copy loaded in game doesn't show on
  top of the one you're editing. Your default atmo setting isn't changed.
- **Players tab:** atmo objects remain visible as translucent ghosts, like on the Objects tab.
- **Drawing:** the game draws only so many shapes per frame, and how many depends on its graphics settings.
  MGE draws the atmo objects on screen, nearest first: in color on the Atmo list, as faint ghosts on the
  Objects list. **Settings → Max draws** (default 1000) caps how many a frame; lower keeps big maps' fps
  steady. On the Atmo list the selected atmo objects show in
  the highlight color (no extra shape each), so every selected one shows however many there are.
- **Convert map** has two budgets: **Budget** is how many boxes become objects (up to the free ids),
  **Atmo** is how many more go to the atmo (the smaller boxes). Budget 0 puts every box in the atmo and
  leaves the object ids free. The placement view draws those boxes in purple.

### Playable atmo (experimental)

Atmo objects are only drawn: tori fall through them. A **playable atmo mod** makes them solid in game with
the **Atmo Play** script, which the players need: it moves hidden objects onto the atmo objects near
each player, in fights, and the game records those moves, so replays need nothing extra.

- **World → Atmo: Playable / Default** (for the whole mod, whatever is selected). Playable makes the mod playable, one undo step:
  - its static objects move into the atmo (like To atmo; dynamic, joint-linked and model objects stay objects),
  - fights in the editor are solid: MGE moves the pool with the same code Atmo Play uses (hide the window
    with F1 to play: the atmo stays drawn, as it looks in game),
  - **Save** writes one file into `modmaker/` like any mod: the mod, the atmo inside it (as `#@` comment lines
    the game skips) and a pool of hidden static objects on every free id. No separate `.atmo` file.

  Default makes it an ordinary mod again (the atmo only drawn, still saved inside the mod). The objects Playable
  moved into the atmo become objects again, on their old ids when those are free, as many as there are free ids;
  MGE says how many stay in the atmo when ids run out (To objects moves them later). The atmo's own objects stay.
  Playable remembers the objects it moved with a `mge_was_object` line, saved with the atmo (the game skips it).
  Switching to Playable again moves static objects added since.
- Opening a playable mod reads its atmo back into the Atmo list and the Atmo row shows Playable; the pool isn't shown
  (it's made again from the free ids on every save and reload).
- Solid are boxes, spheres and capsules with a position. Custom models and objects with `count`, random
  (`rpos`, `rsize`), animated (`move`, `rotate`, draw functions) or parented lines are only drawn.
- **Atmo Play** comes with MGE (`atmoplay.lua` and `atmoplay/` in MGE's folder: `/ls mge/atmoplay.lua`) and
  as its own small release for players (`atmoplay.zip`). While MGE is open, Atmo Play leaves playable mods
  to MGE.
- **Hiding the window (F1)** now always draws the atmo as it looks in game (its own colors, no selection).

## Keyboard shortcuts

| Keys | Action |
|---|---|
| F1 | Hide / show the window |
| Alt + Q / W / E | Move / Rotate / Scale tool (press again to turn it off) |
| Shift + Z / Shift + Y | Undo / redo (50 steps; the selection stays as it is) |
| Ctrl + Shift + Z / Y | Selection back / forward (Objects, Atmo, and the Players list's part tabs, 50 steps): brings back a selection a misclick replaced |
| Ctrl + S | Save |
| Ctrl + A | Select / deselect all (objects, atmo objects, players, or on the part tabs the shown player's parts or joints) |
| Ctrl + N / Ctrl + D | New / duplicate (an object, atmo object, player or joint, on the shown list) |
| Delete | Delete the selection on the shown list (asks first) |
| Shift + drag | Box select: adds what the box shows (the front ones) |
| Ctrl + Shift + drag | Box select through: adds everything inside the box, hidden ones too (fast on big atmos) |
| Mouse wheel over a number field | +0.5 up, -0.5 down (Shift: 0.05; Rot fields: 15 degrees, Shift: 1; whole-number fields like Frames or Amount: 1), from the typed number or the current value, applied right away. Steps in Settings > Snapping, shared with the gizmo's Ctrl snap. One undo step until the mouse leaves the field. On the Generate tab it only changes the field |
| Esc | Close the open popup, prompt or overlay |

Ctrl + Z / Y are taken by the game, so undo and redo use Shift.

## Limits

These come from the game:

- 256 objects in a mod. Only ids 1-48 can move, ids above 48 are static.
- 24 joints, and a joint can only link objects with ids 1-48. Linking a higher one reindexes it down.
- Objects never get a zero-sized side, since that breaks the physics.

## Development

- The code is Lua 5.1 (the game's version). Each module registers itself on the global `MGE` table,
  see `mge/main.lua`.
- Tests: `lua5.1 mge/tests/run.lua` checks file parsing, the matrix math and the map converter,
  without the game. Everything else is checked in game.
- Release zip: `powershell -ExecutionPolicy Bypass -File mge/tools/package.ps1` runs the tests and
  writes `data/script/mge.zip`.
- The map importer's design notes and status are in `docs/map-import-plan.md`.

## License

MIT, see [LICENSE](LICENSE).
