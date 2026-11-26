# Body parts (plan)

Edit the selected players' body parts like objects: select parts (list or world), Core / Advanced rows,
gizmo, undo. Players today only edit the whole body (Pos, Rot, Scale, part averages: `utils/players.lua`,
`ui/editor_player.lua`). Not started; probes first.

## What the mod file holds (seen in shipped mods, not measured)

- A `player N` section has `body <name>` and `joint <name>` blocks; shared blocks outside a section apply to
  every player (`FileHandler.getSharedPlayerLines`, e.g. fatkido.tbm). Missing lines: the game's defaults
  (`data/mod/modmaker.tbm`, player 0; players.lua already keeps density / strength / friction / bounce ones).
- Body keys used in `data/mod` (count of blocks): pos, density, sides, point_hit, flag, rot, shape, force,
  hardness, alt_sides, dm_threshold, friction, bounce, material, trig_*. Joint keys: pos, radius, strength,
  velocity, axis, range.
- Positions are in a player frame: a4_drift_track_one.tbm gives player 0 and 1 the same head pos, so the game
  places player 1 (mirror / turn) and applies engageplayerpos / rot.
- Live: `get_body_info` (pos, rot, sides, shape), `set_body_pos / sides / rotation_m` (players.lua previews
  drags with them). No live read of density, friction, flags.

## Probes (one question each, in game)

`tools/body_probe.lua` (dev only): `/ls mgeDev/tools/body_probe.lua`, then `/lm mge_tests/body_<name>.tbm` for
each mod below. A few frames after each load it appends the file's body / joint lines next to the live ones to
`data/script/body_probe.log`, with a rigid fit (FIT: live = R * file + t, worst miss; a mirrored-x try) and,
for `rot` lines, the miss of each Euler reading against the groin's turn. `/bprobe` dumps again (after a turn),
`/bprobe quit` stops. The mods are the classic body from `modmaker.tbm` with one change each:

1. **Frame:** `body_frame` (classic) and `body_engage` (engageplayerpos `0,0,0,3,2,0`, engageplayerrot
   `0,0,0,0,0,90`): how a world edit maps back to the file (offset, turn, mirror?).
   **Measured (2026-11-26):** rigid, no mirror (every part and joint fits with miss 0; mirrored-x misses 0.26).
   Player 0 unturned, player 1 turned 180° about z (classic) or by its engageplayerrot. Offsets: classic p0
   (0, -0.45, -0.06), p1 (2, 0.25, -0.06); with engage p0 (0, -0.95, -0.06), p1 (4.85, 0.9, -0.06). So MGE
   fits R, t per player after each reload (3 parts, as the probe) instead of deriving them from the gamerules.
2. **Rot line:** `body_rot` (r_foot `0 0 30`, l_foot `30 0 0`, chest `0 30 0`, breast `10 20 30`): the order
   and sign; env_obj's is "xyz -" (rotX(-x) rotY(-y) rotZ(-z)).
   **Measured:** "xyz -", like env_obj, in the player frame (miss 0 on all four). The feet turn about their
   center, but breast and chest also move: breast exactly as turned about the point 0.15 below its center
   (the chest joint, 1 0.9 2.05), chest as about a point 0.1 below (lumbar height). Pivot rule unknown: a
   follow-up probe if the Rot row's preview must match; MGE reads the pose after the reload anyway.
   **Needed after all:** a gizmo turn of a whole leg came apart after the reload (MGE writes centers already
   turned; the game turns some parts again about its own point). Probe 2b: `body_rot_x` / `_y` / `_z` (every
   body 30 degrees about one axis); the probe's PIVOT lines name the point each part turns about (center, a
   face end or a joint; frame from the joints, which stay put). Then MGE writes c = P + M^T (D - P).
   **Measured (2b):** each body turns about one joint, miss 0 on all three axes: head neck, breast chest,
   chest lumbar, stomach abs, pecs their pecs joint, biceps shoulder, triceps elbow, hand wrist, butt glute,
   thigh hip, leg **ankle**; groin and feet their own center (`BodyParts.PIVOTS`). MGE edits where parts are
   placed (`BodyParts.placed`) and writes pos lines to land there (`setPlaced`); bodies turning about a moved
   joint keep their place. All other joints stay at their pos line, except the knees (no body's pivot): they
   moved as if turned about the thigh's placed center, j' = c' + M (j - c'), M the **thigh's** rot
   (`body_rot_knee`: r_thigh turned alone moved r_knee, l_leg turned alone left l_knee). MGE edits knees by
   where they land (`jointPlaced` / `setJointPlaced`); a knee keeps its place when its thigh turns or moves.
3. **Shape / sides:** which sides number is radius / length per shape. `body_shape` (five changes at once)
   crashed the game on load; split into `body_shape_a` (breast cylinder, r_thigh sphere, l_thigh box),
   `body_shape_b` (l_leg `capsule`), `body_shape_c` (head box).
   **Measured:** a and b load. Live sides = the file's: sphere x = radius; cylinder (shape 2, a capsule) x =
   radius, y = length, z ignored (classic l_thigh's `0.12 0.30 0.20` reads 0.12 0.30 0); box x y z. `capsule`
   reads as cylinder. **c (head as a box) crashes the game**: the head stays a sphere (no shipped mod changes
   it). Other keys (flag, force, point_hit, dm_threshold, alt_sides, material) stay as written until needed.
4. **Joints follow?** `body_joints` (both biceps up 0.3; the left shoulder and elbow joints moved with it, the
   right ones not): does a joint stay at its file pos (right arm torn) or follow the body?
   **Measured:** at frame 0 every joint sits at its file pos (miss 0), the right ones too: joints don't follow
   their bodies, so MGE writes joint pos lines. In game both arms started with the biceps up (the user saw no
   difference between the arm whose joints moved and the one whose didn't).

## Design

- **Where:** the **Players** list (merged after building it as its own Parts list: the map's player switch
  covers the players' selection). Tabs **Player** (whole players, as the old Players list), **Parts**,
  **Advanced**, **Joints**; the active tab decides what clicks, keys, box select and the gizmo act on
  (`Main.partsShown`). Player tab buttons: select all, new, duplicate, import, export, delete; part tabs: select
  all, Mirror.
- **Tori map** (the list's selector): a 2D back view of the player, every part a clickable shape, as RPH's
  mini tori (back view: the tori's left on screen left, nearly every part shows). For parts hard to click on
  some models (small, hidden, inside a model). Always the classic tori's proportions (modmaker.tbm), whatever
  the mod's layout: the user's call after trying it, a custom layout (a car body) overlaps too much to click.
  Drawn with `draw_quad` / `draw_disk`, no image atlas (RPH's is third-party). Hover shows the part's name; selected ones lit; where parts still
  overlap the nearer one wins (the other: pick in the world). A player switch above it picks whose parts show.
- **Selection:** `{ player, part }` keys. Click on the map or in the world (`WorldSelect`'s `hitBody` already
  hits parts); Shift adds, Ctrl + A all of the shown player. Highlight: the selected parts' boxes (`Highlight`
  draws players already). Selection back / forward as Objects (`SelectionHistory` layer "parts").
- **Mirror** toggle (on by default): an edit also changes the l_ / r_ twin, x mirrored in the player frame.
  No "all players" toggle: players can have separate models. Editing several players means selecting their
  parts (map: Shift on another player's parts). A mod with shared blocks: an edit writes the player's own
  section (the others keep the shared ones).
- **Core:** Pos, Rot (player frame, like the file), Sides (Scale), Shape (box / sphere / cylinder, written as
  `cylinder`; not offered for the head: a non-sphere head crashes the game). **Advanced:** Density, Friction,
  Bounce, Hardness, Flag, the rest of probe 3's working keys. Empty rows show the default as placeholder.
  Reuse `EditorRows` inputs and the wheel steps.
- **Gizmo:** Move / Rotate / Scale on the selected parts; preview live with `set_body_*`, commit on release.
- **Write path:** edit the parsed section (players.lua's `parseSection` / `setProp` / `sectionLines`, moved
  into a shared `utils/body_parts.lua`), `FileHandler.setPlayerLines`, one `History.commit`, `MGE.apply`
  (reload) — as `Players.multiplyParts` does. Missing blocks are created; untouched lines stay as written.
- **Joints:** they stay at their file pos (probe 4), so MGE moves joint pos lines itself: a joint moves (and
  turns, scales) with the parts when both of its bodies are selected (`get_joint_bodies`), else it stays.
  Stragglers are fixed by editing joints on the same list (radius, strength, range, axis, pos: a later step).

## Steps

1. Probes 1-4; results here and in memory. Done.
2. `utils/body_parts.lua`: section parse / write (from players.lua), defaults from modmaker.tbm, frame mapping,
   mirror twin. Tests in `tests/test_body_parts.lua` (parse, write, mirror, shared blocks). Done: also the
   frame fit (`fitFrame` / `measureFrame`), rot lines and `transform` (Mirror, the joint rule); players.lua
   uses its section code. Joint links: `get_joint_bodies` where the game has it (5.78+), else `LINKS`.
3. Parts list: tori map, world click, highlight, Core rows (Pos / Rot / Sides / Shape) with undo. Written
   (`ui/part_list.lua`, `ui/editor_parts.lua`), not yet checked in game. World clicks on the Parts list pick
   parts only (a miss changes nothing); Mirror is on the list's action bar; no gizmo until step 4.
4. Gizmo with live preview. Written (`utils/part_target.lua`), not yet checked in game: Move / Rotate preview
   with `set_body_*` (twins mirrored in the world), Scale through the highlight, in place along each part's
   axes; the release writes each player's frame (fitted at frame 0, else it refuses with a message).
5. Advanced rows; README section. Written, not yet checked in game: Density, Friction, Bounce, Hardness, Flag
   (a plain number: body flags look like env_obj's, hands 1 and 24 = 8 + 16 in mods, but not measured). Force,
   point_hit and the rest stay as written.
6. Joints on the Parts list: written, not yet checked in game. Map draws them on top (hit first), world clicks
   pick the nearer of a body and a joint, a Joints tab (Pos, Radius, Strength, Velocity, Axis, Range; classic
   values from modmaker.tbm). Mirror: a twin joint gets the same lines, only pos mirrored (classic twins share
   axis and range). Gizmo: selected joints move with Move / Rotate, previewed by the highlight (set_joint_pos
   exists but what it does to the bodies isn't measured); joints alone: Move only.
7. Box select and selection back / forward on Parts: written, not yet checked in game. Shift + drag: the parts
   and joints the box's rays reach first (`WorldSelect.pickPartsBox`, its own small ray pass: a few dozen
   shapes); Ctrl + Shift: every center inside. Selection history: a "parts" layer of Main.selectedParts keys.
8. Later: extra bodies (5.78+: indices after the classic 21).
