# Atmo Play (playable atmo maps)

Current design and the game facts it rests on. History: git log of this file (condensed 2026-11-26).

**Status:** works in game (fights, replays, two players). Built and offline-tested, not all checked in
game: props (part 6), drawn flight (part 7), Far props, the solver refactor. Single player and replays only
(online: not supported). Not deployed yet: no older playable mods to support (save again from MGE).

## Why

A mod holds 256 env objects; an atmo 5,000+ (a converted map). Atmo objects are only drawn. Atmo Play keeps
the mod's free ids as a hidden pool and moves it onto the atmo objects nearest each player, so only what a
tori can touch is solid.

## Format: a playable mod carries its atmo

```
(the mod's own lines: gamerules, players, joints)
env_obj <id>                  real objects: dynamic, joint-linked and model ones
env_obj <id>                  the static pool: hidden, every free static id
    #atmoplay pool            marker
#atmoplay v1 rule=1 radius=4  header (version, pool rule)
#@ shader <name>              the atmo, every line commented out
#@ env_obj 1 ...
```

- The game skips `#` lines; its atmo parser reads only `shader`, `opt`, `env_obj`. A 5k atmo as `#@ ` (1.6
  MB, 65k lines) loads with `/lm` in 39 ms, same as the pool alone (6.3 MB: 54 ms).
- One file to share; viewers need Atmo Play, else tori fall through (live and in replays).
- **Drawn mods:** MGE's Default save keeps the atmo inside too, header `#atmoplay v1 mode=draw`
  (`Format.isDrawOnly`): drawn, no pools. World > Export writes clean copies (`MGE - exp_<name>.atmo`,
  `modmaker/exp_<name>.tbm`). Mods saved before still open with their separate `.atmo`.
- **Stays real:** dynamic objects (own ids), joint-linked objects (fixed ids), static model objects. Other
  static objects move into the atmo; Playable marks them `mge_was_object <id>` (`AtmoLayer.FROM_KEY`) so
  Default can move them back.
- **Pool groups** (`Colliders.groupKey`): shape | friction | hardness | bounce | flag bits. Replays record
  neither flag nor bounce (EOBJ has neither), so nothing is set live: each pool object is written with its
  group's values. No friction setter exists. Typical maps have one group (dust2-5k: friction 10000, flag 8,
  bounce 0.1). `visible 0` statics collide but aren't drawn.

## 1. Making a playable mod (builder)

MGE's World > Atmo: Playable (`mge/utils/playable.lua`, Atmo Play's own modules); offline
`tools/atmoplay/build_playable.lua` + `builder.lua`. Steps: keep the real objects, move the other statics into
the atmo, fill every free static id (above `MAX_NONSTATIC_OBJECTS` 48) with pool objects, split by demand
(`Pool.plan`: the most objects of a group one player can have in reach), append header + `#@ ` atmo.
Converting is MGE's job; Atmo Play is player-side only.

## 2. Runtime

On `match_begin` (synchronous inside `/lm` and `open_replay`):
1. Read the loaded mod (`get_game_rules().mod` keeps the `/lm` folder; read through `Files`: plain `io.open`
   lacks `:lines()` and failed on `../`). No header: give the player's atmo back, stop. Same mod and text as
   last time: keep everything.
2. Pool objects (marker) and atmo lines (~60 ms for 5k).
3. Drawing: Atmo Play draws the plain shapes itself (`atmoplay/drawer.lua`); the game's atmo keeps only what
   it can't (models, `count`/random, `rotate`/`move`, `drawfunc`/`framefunc`, parents, header).
4. Colliders: positioned boxes, spheres, pills. Not random or animated objects (rolled again per load).
5. Fights only: pool moved from `draw2d` whenever the match frame changed, from match frame 1
   (`Driver.FIRST_FRAME`); only what differs is set (pose read from the object).

**Pool rule:** per group, colliders within `radius` of any player, nearest first, ties by index. Stable: an
object keeps its collider while it's still wanted (fewer `set_obj_*` and EOBJ lines). 2D grid: 0.15 ms a
frame on dust2 (5,501 colliders, 208 pool objects); grid build 9 ms, colliders ~120 ms per mod switch.

`unload` isn't an end: the game fires it when it loads its own scripts (menu, replay save). Atmo Play stops
only on Quit or a new `/ls`. Its window (`atmoplay/ui.lua`): Detail, Ghosts, Distant (Far props), Max draws, Quit; an
"AP" launcher while hidden; settings in `atmoplay.cfg`. Dev builds only (`atmoplay/debuglog.lua` present,
left out of the zips): `/atmoplay status|reload|time|log|...`.

## 3. Replays (measured)

**Replays move nothing**; the game replays the pool from its EOBJ lines.

| Moved in | Recorded under | Replay, script off |
|---|---|---|
| `match_begin` | FRAME 0 | exact |
| `draw2d` (between steps) | the step it affects | exact, cache 0 and 2 |
| `enter_frame` (inside a step) | the next frame | one step late, drifts |

- Moving objects during a replay crashed the game when it reached its last frame. RPH moves dynamic objects
  in replays fine, so the rule is "don't drive replays", not "never touch objects".
- A cached replay is simulated inside `open_replay` (~620 ms for 500 frames) with no `enter_frame`; playback
  comes from the cache. Cache 1 uses a cache only if one exists. Uncached, `rewind_replay_to_frame` does
  nothing and `rewind_replay()` fires only `leave_game`; cached, `enter_frame` reports frames one higher.
- R mid-fight fires `leave_game` only; an opened replay fires `match_begin` first. At the end of the recorded
  frames the game puts script-moved objects at 0,0,0; back in a fight every pool object is set again.
- A replay stores body state once per turn and simulates between. Ordinary dynamic objects drift in some
  fights even without a script (0.46 from frame 133 in a probe); per-frame FRAME/body/EOBJ lines make even
  teleporting fights exact (file 12x longer) — not used.
- Replays carry no object color: carried props are painted while watching (`keepDressed`, every draw call).
- Saved replays get nothing extra: the game doesn't say which file is open, and a file's last FRAME isn't
  where the fight ended.
- A match frame is ~0.006 s.

## 4. Code layout

One source in MGE's repo; modules register on the namespace their loader gives (`ATMOPLAY_LOADING`:
`ATMOPLAY`, `MGE.AtmoPlay`, tests).

| File | Contents |
|---|---|
| `atmoplay.lua` | entry, reload-safe `ATMOPLAY`, one hook set |
| `atmoplay/format.lua` | header, pool markers, `#@ ` lines (`read`, `split`) |
| `atmoplay/colliders.lua`, `mat3.lua` | atmo lines → shapes, props, group keys |
| `atmoplay/pool.lua` | pool rule (grid), `Pool.plan` |
| `atmoplay/driver.lua` | moves one static pool in fights |
| `atmoplay/dynamics.lua` | props (part 6) |
| `atmoplay/flight.lua` | drawn flight (part 7) |
| `atmoplay/drawer.lua` | own atmo drawing |
| `atmoplay/runtime.lua`, `ui.lua` | hooks, window |
| `mge/utils/playable.lua` | MGE: Playable / Default, writing, its own fights |
| `tools/atmoplay/` | offline builder |
| `tests/test_atmoplay_*`, `test_playable.lua` | offline tests |

`tools/package.ps1`: mge.zip carries the modules too; atmoplay.zip = entry, `$AtmoPlayModules`, README from
`docs/atmoplay-readme.md`, LICENSE.

## 5. In MGE

- World > Atmo: **Playable / Default**. Playable moves statics into the atmo, the working copy carries the
  pool and MGE runs the driver after each reload; Default moves the marked ones back. One undo step.
- Opening a playable mod reads its atmo into the Atmo list and leaves the pool out of Objects.
- Atmo list edits use the objects' Core / Advanced panels on atmo lines (Mass, Visible, Friction, Bounce,
  Hardness, Flags); on a playable mod they reload the working copy (`Rows.afterAtmoEdit`).
- F1 draws the atmo as in game. Atmo Play leaves playable mods to MGE while MGE runs.

## 6. Props (dynamic atmo objects)

An atmo object whose flag lacks the static bit. MGE writes a **dynamic pool** on free ids 1-48 (above 48 the
game shows no predictions and replays misbehave), grouped by shape, friction, mass (`#atmoplay dynamic`), each
object at its group's most common size/mass/bounce (`Playable.propLooks`), parked side by side on a hidden
static platform **above** the map (`Dynamics.PARK_Z = 50000`: below z 0 a dynamic body is inside the ground
and gets launched). Header `dradius=` (default 2).

- **Wanted:** a player's center within `dradius`, the mod's dynamic objects (their bounding sphere), a moving
  carried prop touching it (chain; "moving" = speed + spin x radius > MOVING). Tiers: player > dynamic objects
  > chain; within a tier by distance minus what the closing speed covers in `LOOKAHEAD` (0.1 s).
- **Release** only untouched and at rest (except thrust props and evictions: they fly on drawn). A full pool
  evicts the least wanted lower-tier prop (`EVICT_MARGIN` 0.5 within a tier).
- The static pool also follows every dynamic object of the mod (`Driver.dynamicIds`).
- **Replays:** nothing moved; the script watches pool objects in `enter_frame` and `pre_draw` (every frame,
  before drawing): leaving the platform = took the nearest free prop of its group; back = left it there.
  `MATCH_FAR` (4) takes the nearest free prop when none is within the usual slack (papers over drifted
  flights; drop it if it ever takes the wrong one). Events and snapshots (every 50 frames, thinned past 200)
  rebuild props on rewinds.
- Flags set in fights only, and only when not 0. A prop without a mass line flies with its pool object's
  `get_obj_mass`; Atmo list New writes mass 0.1.
- **Collision** row: `prop_collide <player> <dynamic> <atmo>` (no line: all on; old `prop_real 0` /
  `prop_hits 0` still read). Player / Dynamic: what a prop becomes real for (both off: never real, no pool
  object). Atmo: drawn flights hit other props. Props overlapping where the map places them never push each
  other (`Flight.overlap`).
- **Motion:** `prop_motion 1` Active flies from frame 0 (falls, settles); `0` waits until reached; no line:
  active with a pushing thrust (`Colliders.startsActive`). Old `prop_motion 1 1` reads as Active.
- **Far props** (player option: Atmo Play window / `farprops`, MGE Settings, config `propPauseFar`): Pause
  stops flights farther than `FLY_RANGE` 30 from every player and the mod's dynamic objects (sampled in
  `enter_frame`, so replays pause the same). Never starts an Active-off prop.

## 7. Drawn flight (measured physics)

Measured in game (probes, 2026-11-22/24):
- Step dt = 0.006 s, semi-implicit Euler (`v += a*dt; pos += v*dt`), no drag; gravity from gamerules.
- `thrust <N> x y z` = a one-step force on steps into frames 1, 1+N, ...; `set_obj_force` the same for one
  step, shows from f + 1 when called in draw2d at f. Script forces and `set_obj_linear_vel` are recorded.
- Bounce: rebound e = 0.096 x (bounce - 0.48); 10 → 0.91, 20 → 1.87 (gains energy).
- Friction: -10000 on either side is frictionless (the lower value wins); -9999 ≈ a 2 N limit
  (`mu = friction + 10000` per contact); 0 ... -5000 and up: the same grip (speed x ~0.89 a frame). The
  ground is always z = 0.
- Pills: ODE's capsule inertia (dMassSetCapsule); with it a drawn cylinder matched a real one (89.3 / 89.6
  travelled). Spheres match exactly; tumbling boxes part after ~150 frames (chaos, not a bias).

The sim (`atmoplay/flight.lua`): rigid bodies, box by corners + separating axes, sphere, pill end spheres;
impulse solver (8 rounds, stops per island below `SETTLE` 1e-7 N s), friction cone MU 2 capped by
`(friction + 10000) x 0.5` N per contact; rest by speed/spin or calm drift (`REST_DRIFT` 0.01,
`REST_TURN` 0.03). Detail levels (player's): Low = sphere, no turning hits; Medium = real shapes; High =
shapes that hit each other and wake still props. All flights step together, a frame at a time, in atmo
order, so a fight equals its replay and rewinds.

**Ghosts:** each flying prop drawn faint where its flight is at the game ghost's frame
(`get_ghost_frame`), only in fights with ghosts on, after the frame has held `GHOST_STILL`. `MAX_GHOSTS` 100
nearest on screen, predicted `PREDICT_MS` 2 a drawn frame, a new prediction swapped in once complete; drawn
last, shrunk `GHOST_SHRINK` so the prop shows through.

**Drawing:** both drawers (Atmo Play's and MGE's `drawAtmo`) cull to the screen and draw the nearest
**Max draws** (default 1000; 500 safe on every setting; past ~5k fps drops) by 256 distance buckets, early
stop by cells, colors set only on change. MGE's Atmo list draws selected ones first.

**Costs (offline, Lua 5.1):** 360-box pile 0.28 / 2.5 / 4.3 ms a frame (Low / Medium / High); 1.7k thrust
boxes sliding 8.9 / 55 / 57; 2.6k rolling spheres ~11-13; 100 thrust props over 5k statics 0.4 / 1.4 / 1.4.
Lua runs on the game's main thread: no threads, no GPU.

## Open (not checked in game)

- Props, Far props, the solver refactor, ghosts frame counting, `get_obj_angular_vel` sign.
- Stacks under gravity -30 sink into themselves (8 rounds don't hold them; -9.82 holds).
- Fast props pass thin walls (no sweep); drawn props never meet carried ones or players (they turn real).
- A flight range per prop (whose option) undecided.
- End-of-match freeze seen with 768 props (~1.3 s, game's own work, not our calls or a GC); not explained.

## Future: jointed atmo assemblies

Doors, lamps, chains as pooled assemblies (parts + joints) placed at rest. First a probe: do joints survive
moving every part together? Costs: every part a dynamic id, one pool per identical design, given back only at
rest, a new atmo kind in MGE.
