# Atmo Play plan (playable atmo maps)

Status (2026-11-20): **Atmo Play works in game (fights and replays, two players). Phase 3 built, tested
offline and checked in game by the user (2026-11-20): MGE converts (Atmo list → Advanced → Playable) and tests playable mods with the same code; one
source in MGE's repo, two releases (mge.zip, atmoplay.zip).** History: a proof of concept inside MGE came
first; then a repo of its own (`atmoplayDev/`, deleted after the merge); then (user's choice "C") everything moved into MGE's repo
(`atmoplay.lua`, `atmoplay/`, this file, `tools/atmoplay/`, `tests/test_atmoplay_*`), with Atmo Play built
from it as a small separate release. The first version of this plan made pool copies of any mod for the
loaded atmo; it was replaced by "the mod carries its atmo", which is simpler and fits the main case (big
converted maps).

## Why

A mod holds at most 256 env objects, but an atmo can hold 5,000 or more (a converted map, see
map-import-plan.md). Atmo objects are only drawn, so a big map can be seen but not stood on. Atmo Play
keeps a pool of the mod's env objects hidden and, every frame, moves them onto the atmo objects nearest
to each player. Only what a tori can touch needs to be solid, so the free object ids of a mod make a
5k-object map playable.

## The idea: a playable mod carries its own atmo

A playable mod is one `.tbm` file with three parts:

```
(the mod's own lines: gamerules, players, joints)
env_obj <id>                  real objects: only dynamic, joint-linked and model ones (see below)

env_obj <id>                  the pool: hidden, static objects on every free id
    #atmoplay pool            (marker, so the runtime finds them)
    shape box
    flag <static>
    visible 0
    pos <parked far below>
    ...

#atmoplay v1 rule=1 radius=4  header: format version and the pool rule's parameters (see "Replays")
#@ shader <name>              the atmo, every line commented out
#@ env_obj 1
#@ shape box
#@ pos ...
#@ sides ...
...
```

- **The game ignores the atmo part.** Its mod loader skips `#` lines, and its atmo parser
  (`Atmospheres.ParseFile`) only reads lines that start with `shader`, `opt` or `env_obj`. Measured: a
  5k-object atmo as `#@ ` lines (1.6 MB, 65k lines) loads with `/lm` in 39 ms, the same as the pool alone,
  and none of the lines becomes an object (4x that, 6.3 MB: 54 ms).
- **Loading the mod is enough.** Atmo Play sees the header on `match_begin`, draws the atmo and drives
  the pool. Nothing to pick, nothing to turn on.
- **Replays work** while Atmo Play runs and the replay is uncached (see "Replays"). The replay stores the
  mod name, the mod holds the atmo, the pool and the rule.
- **One file to share.** The atmo travels inside the mod. It isn't on the game's server, so a viewer
  needs the mod file and Atmo Play to watch a replay; without Atmo Play the tori fall through the map,
  live and in replays. The README and the mod's first comment line say so.

### Which objects stay real

The mod's **static** objects become atmo objects too. They are then drawn and collided like the rest
of the atmo, and their ids join the pool. Only objects the pool can't stand in for stay real env objects:

- **Dynamic objects** (no static flag). The engine simulates them, so they keep their own id. They cost
  Atmo Play nothing per frame, only their ids.
- **Joint-linked objects**, also static ones: a joint needs a real object at a fixed id.
- **Static custom-model objects**, until it is known how a model's collision relates to its `shape` line.

Dynamic *atmo* objects (a pool object knocked away has to stay where it went) are out of scope: that
would mean tracking every moved object's state and keeping ids for it, a different system.

### Physics properties

An atmo object keeps the lines the game's atmo parser ignores (`flag`, `bounce`, `friction`, `mass`), so a
converted object keeps its physics. When the pool takes an object:
- **`flag` and `bounce`** are set with `set_obj_flag` / `set_obj_bounce`, the static bit kept on
  (check in game, R2).
- **`friction` has no setter.** Pool objects are split by (shape, friction) instead, like the shape split.
  Most maps have one friction value (all 5,293 objects of `MGE - dust2-5k.atmo` use 10000, flag 8,
  bounce 0.1), so the split costs nothing there.
- **Invisible statics** (`visible 0`: walls, clips) collide but aren't written to the drawn atmo.

## Parts

### 1. Making a playable mod (the builder)

Input: a base mod (or the built-in classic, which has no file) and an atmo. Output: the playable mod.

1. Copy the base mod's lines. Keep its dynamic, joint-linked and model objects as env objects, and move
   its other static objects into the atmo part.
2. Find the free ids: the ids the base mod doesn't use after step 1. (MGE finds them from the loaded
   world, `get_obj_pos(i) == nil`; the builder works from the file, so it can run offline.) Static
   objects take ids above `MAX_NONSTATIC_OBJECTS` (48). Fill **every** free static id with a pool object
   (and free low ids too, if static objects work there, R2). More pool objects, more solid objects near
   the players.
3. Split the pool by shape and friction, in proportion to the collidable atmo objects (the PoC's
   `proxiesToCreate`), at least one of each kind that occurs.
4. Append the header and the atmo, each atmo line with `#@ ` in front.

Two places use it:
- **MGE**: "Save playable" writes the map being edited as a playable mod.
- **Atmo Play**: "Make playable mod" takes the loaded mod and an atmo from `data/atmospheres/` (default:
  the loaded one) and writes `data/mod/atmoplay/<mod> + <atmo>.tbm`, then loads it.

The builder is plain text work, so it is shared by copying one file into both projects.

### 2. Playing it (the runtime, standalone)

On `match_begin` (inside the `/lm` or `open_replay` call; both are synchronous):

1. Read the loaded mod's file (`get_game_rules().mod` keeps the `/lm` folder; read through the game's
   `Files` class, plain `io.open` handles lack `:lines()` and failed on `../` paths). No `#atmoplay`
   header: unload what Atmo Play loaded, give the player their own atmo back, stop.
   Same playable mod as last time (path and file size): keep the drawn atmo and the colliders, go to 5.
2. Find the pool objects (marker) and read the atmo lines (strip `#@ `), about 60 ms for 5k objects.
3. **Drawing:** write the drawn atmo lines to one cache file, `data/atmospheres/Atmo Play.atmo`, and
   load it with `Atmospheres.LoadAtmo` (about 300 ms for 5k objects, so only on a mod switch). Remember
   the player's own atmo (wrap `LoadAtmo`, or `atmo.cfg`) and load it again when a non-playable mod
   loads.
4. **Colliders:** the positioned boxes, spheres and cylinders of the atmo. Skip custom models, random
   objects (`count`, `rpos`, `rsize`: rolled again on every load, so a replay would differ) and animated
   ones (`move`, `rotate`, `drawfunc`, `framefunc`). They are still drawn.
5. **In fights only:** place the pool in `match_begin`, then move it onto the colliders nearest to the
   players (all players) from `draw2d` whenever the match frame changed. Replays move nothing (part 3).

**Pool rule.** Per (shape, friction) group: the colliders within `radius` of any player's center,
nearest first, ties by index. **Stable assignment:** a pool object keeps its collider while that
collider is still wanted; only freed objects take new ones. This keeps `set_obj_*` calls and the
replay's `EOBJ` lines (one per object change per frame) down; the PoC re-sorted every frame and moved
several objects per frame for nothing. The rule must give the same result for the same state, which it
does: it reads only the body positions at `enter_frame` and its own previous assignment.

A small status window (toggled with a command) shows "N pool objects, M solid atmo objects, K drawn
only", and warnings (cached replay, option changed). Loading the script once and loading playable mods
is the whole UX.

### 3. Replays (settled 2026-11-20)

**The game replays the pool by itself; Atmo Play moves nothing in replays.** Every env object change is
recorded as an `EOBJ` line (the user saw the same with RPH: objects moved in a fight show up in its replay
and the saved file). What matters is *when* the fight moves the pool:

| Moved in | Recorded under | Replay with the script off |
|---|---|---|
| `match_begin` | `FRAME 0` | exact |
| `draw2d` (between physics steps) | the step it affects | **exact, cache 0 and cache 2** |
| `enter_frame` (inside a step) | the next frame | one step late: drifts (saturated pool: from frame 90, max 0.11) |

Measured with `tools/atmoplay_native_probe.lua` and `tools/atmoplay_timing_probe.lua`: 500-frame automated
fights among 31 colliders, saved and replayed, every body part of both players compared per frame. A
fight with no pool replays exact cached and uncached (0.0002), so the cache is exact too. `draw2d` ran at
least once per match frame in those fights (at most 1 frame between two calls).

Decisions:
- (2026-11-21: placed from match frame 1 instead, and R replays drive their unrecorded tail: "Replay
  probe" below.)
- **Fights:** place the pool in `match_begin` (recorded under `FRAME 0`), then move it from `draw2d`
  whenever the match frame has changed. Never in `enter_frame`.
- **Replays:** move nothing, only draw the atmo. They replay exactly, cached or not, so seeking works, the
  `replaycache` option is left alone (no conflict with Replay Focus), and a viewer without Atmo Play still
  collides right (only the drawn atmo is missing).
- **Back in a fight** after a replay (replay view left, a replay edited and played on) or when the frame
  went back: every pool object is set again, which is recorded like any move.
- The pool rule no longer has to stay fixed for old replays to work (they don't run it); `rule=` in the
  header stays as information.

**Earlier findings that led here** (the first replay probe, the script driving the pool in replays). That
design (driving in replays, forcing `replaycache` 0) is dropped: moving objects during a replay crashed the
game when the replay reached its last frame (twice), while a replay played to its end with the script off
didn't crash. Measured then:

| Replay | Result |
|---|---|
| uncached (cache 0), script drives the pool in `enter_frame` | exact, every run, also after `rewind_replay()` |
| uncached, script off, pool placed in `enter_frame` 0 and reassigned all the time (the PoC's rule) | 3.3 off from frame 1 |
| cached, any driving | 3.3 off from frame 1 |

What the game does:
- A replay stores body positions once per turn and simulates the frames in between, with the `EOBJ`
  lines applied at the frame they're recorded under.
- **A cached replay is simulated inside the `open_replay` call** (about 620 ms for 500 frames, against
  30-46 ms uncached) with `leave_game` x2 and `match_begin` but no `enter_frame`, so no script can move
  the pool while it's built. Playback then comes from the cache; moving the pool, even from the fight's
  exact per-frame schedule, changes nothing. **Playable-mod replays must be uncached.**
- Cache 1 uses a cache only if one exists (built by watching the replay once or by a cache 2 open).
  `/lr` and the replay menu follow the `replaycache` option.
- Uncached, `rewind_replay_to_frame` does nothing (no hooks); `rewind_replay()` goes back to frame 0 and
  fires only `leave_game`. Cached, `rewind_replay_to_frame` works (instant, one `enter_frame`) and
  `enter_frame` reports frames one higher (1-500).

### 4. Code layout

One source, in MGE's repo (2026-11-20). Atmo Play's modules register on the namespace their loader gives
(the global `ATMOPLAY_LOADING` while one loads): Atmo Play's own `ATMOPLAY`, MGE's `MGE.AtmoPlay`, the
tests' `ATMOPLAY`. So MGE and a running Atmo Play each have their own copy.

| File | Contents | In |
|---|---|---|
| `atmoplay.lua` | Atmo Play's entry. Reload-safe global `ATMOPLAY`, one hook set. | both zips |
| `atmoplay/format.lua` | The playable-mod format: header, pool markers, `#@ ` lines; `read` (runtime), `split` (MGE). | both |
| `atmoplay/colliders.lua` + `mat3.lua` | Atmo lines to collision shapes: what's solid. | both |
| `atmoplay/pool.lua` | The pool rule (rule 1, 2D grid) and `Pool.plan` (the pool split by demand). | both |
| `atmoplay/driver.lua` | Moves one pool in the world: `match_begin` placement, `draw2d` steps, nothing in replays. | both |
| `atmoplay/runtime.lua` | Atmo Play's hooks: playable mod detection, drawing the atmo, commands, debug log. | both |
| `mge/utils/playable.lua` | MGE: Convert / Ordinary, the playable text through MGE's writer, Test (the driver). | mge.zip |
| `tools/atmoplay/` | `builder.lua` + `build_playable.lua` (offline builder), the in-game probes. | dev only |
| `tests/test_atmoplay_*`, `tests/test_playable.lua` | Offline tests, in MGE's suite. | dev only |

`tools/package.ps1` builds both zips (Atmo Play: entry, the six modules, README from
`docs/atmoplay-readme.md`, LICENSE). mge.zip carries the modules too (MGE needs them), so `/ls
mge/atmoplay.lua` works for MGE users.

### 5. What changes in MGE

**Decided 2026-11-20 (user):** converting is MGE's job. Players don't convert anything: they get finished
playable mods from map makers, and map makers use MGE. So the runtime's own "Make playable mod" (Phase 4)
is dropped; Atmo Play stays a player-side script (draw + pool in fights).

- **Done:** the PoC is removed from `mgeDev` (backup of its diff and files in the session scratchpad
  only). Kept: the atmo drawn as ghosts on the Players tab (`highlight.lua`, one line, README line).
- **World tab: "To playable atmo".** Converts the active mod and its atmo into a playable mod:
  - the mod's static objects the pool can stand in for move into the atmo layer (MGE's Atmo list), which
    frees their ids, then the pool fills every free static id: the builder's rules (part 1), done on
    MGE's own data instead of text so the result shows in the editor and can be undone;
  - writes the playable mod (base lines, kept objects, pool, header, `#@ ` atmo) through `builder.lua`'s
    format, next to MGE's normal save; the editor keeps working on the source (its atmo still in
    `MGE - <mod>.atmo`, atmo-tab-plan.md), the playable mod is an export.
  - Decided (user): the playable mod is a regular mod in `modmaker/`, and MGE holds the making logic
    itself, reusing its own code (no copies of Atmo Play's modules).
- **Built 2026-11-20** (`mgeDev`, uncommitted, offline-tested, not yet in game): `mge/utils/playable.lua`
  (split / text / pool plan / Convert / Ordinary), `FileHandler.parseLines` + `readLines`,
  `ModData.reloadObjects` (a playable mod is split before parsing, its pool ids freed, the flag kept over
  working-copy reloads), `Atmo.load(modPath, embedded)` + `Atmo.markSaved`, `writeMod` (playable text,
  no .atmo file), the flag in undo (`copyParsed`), over a script restart (`MGE_ATMO.playable`) and in
  "unsaved changes"; World tab Playable row (Convert / Ordinary). `tests/test_playable.lua` (63 checks)
  includes Atmo Play's `format.lua` and `colliders.lua` reading MGE's output (same header, pool, atmo,
  solid count). MGE README: "Playable atmo" section.
- **Opening a playable mod in MGE:** read its `#@ ` atmo into the Atmo list and leave the pool objects out
  of the Objects list, so editing and converting again doesn't duplicate the pool.

### 6. Dynamic atmo objects (exploring, 2026-11-20)

Pushable atmo objects (crates, props) through a pool of dynamic objects. Budget: dynamic objects must be on
ids 1-48 (above that the game shows no predictions and they misbehave in replays: user), minus the mod's
own dynamic and joint-linked objects: about 40 live at once. Calculation is cheap (the static grid plus
reading ~40 objects' state per frame). The hard parts: a released object's state (only released at rest,
pose saved), chain reactions (moving objects must pull in pool objects around them too), moving the drawn
atmo copy, saturation (a missing dynamic object behaves visibly wrong).

`tools/atmoplay/atmoplay_dynamic_probe.lua`: 16 crates around tori, a dynamic pool on ids 1-6, parked on a
far static platform; moves from `draw2d`; a crate is released only at rest. First run:

| Fight | Bodies, cache 0 | Bodies, cache 2 | Pool objects |
|---|---|---|---|
| pool6 (25 activations, 19 releases, 7 crates pushed) | from frame 56, max 1.12 | from frame 1, max 60.6 | exact |
| pool3 (13 activations, 13 releases) | from frame 126, max 0.03 | from frame 1, max 29.4 | exact |

- **These numbers (and the second run's) aren't valid:** the probe stored each position with
  `out[#out + 1], out[#out + 1], out[#out + 1] = x, y, z`, which takes every index before assigning: only z
  was kept, and the body / pool-object split counted everything as body ("pool objects exact" was never
  compared). Fixed in the third version. The static-pool probes (replay, native, timing) store values one
  at a time and are unaffected.
- What still holds from watching the runs (user): dismemberment was on (a cut-off limb relaxes the joints;
  a cut-off hand holding a crate isn't a gripping hand of the body), and in one fight a player grabbed
  the other. The third version: the probe's mods set no dismemberment, no fracture, flags 0; a crate isn't
  released while any body part is near it; one-frame jumps over 1 unit are logged; a baseline fight with 6
  ordinary dynamic crates and no script moves comes first.

Third run (valid; replay frame compared with the same fight frame, no one-frame jumps logged):

| Fight | Bodies, cache 0 | Objects, cache 0 | Bodies, cache 2 | Objects, cache 2 |
|---|---|---|---|---|
| baseline: 6 ordinary crates, no script | exact (0.0001) | exact | 0.08 from frame 1 | 0.004 |
| pool6 (8 activations, 3 releases) | 1.23 from frame 128 | 0.0016 from frame 448 | 1.23 | 37 from frame 1 |
| pool3 (3 activations at the start, 0 releases) | 0.35 from frame 128 | 0.0016 from frame 257 | 0.36 | 0.002 |

- The replay files: the game writes an `EOBJ` line for **every dynamic object every turn**, script or not
  (the baseline has them too): position, rotation quaternion, sides, linear and angular velocity, the same
  snapshot body parts get (POS / QAT / LINVEL / ANGVEL). So a teleported pool crate's full transform and
  velocity are recorded, like a static's position. For statics that line is the whole state, hence exact
  replays; for dynamics something outside it differs (guess: the physics engine's sleep / contact state
  after a teleport, unverified).
- Even pool3, which only placed its crates in `match_begin` (FRAME 0), drifts from frame 128.
- Verdict so far: dynamic pool objects work in fights but replays drift (0.35-1.2 against exact). Next
  probes, if pursued: the same crates written into the mod (nothing teleported); a teleported crate woken
  with a tiny velocity or force.

Fourth run (crate starts rounded to 4 decimals; replay frame = fight frame):

| Fight | Bodies, cache 0 | Bodies, cache 2 | Objects (both) | Fight against pool3's |
|---|---|---|---|---|
| plain (baseline) | exact | exact | exact | - |
| pool3 (3 placed in match_begin) | 0.46 from frame 133 | 0.46 from 133 | 0.0009 | - |
| placed3 (the same 3 crates in the mod, no script) | 0.46 from 133 | 0.46 from 133 | 0.0009 | identical |
| wake3 (pool3 + force 0 0 -0.001 after placing) | 0.46 from 133 | 0.46 from 133 | 0.0009 | identical |

- **Teleporting isn't the cause.** placed3 is an ordinary mod with no script, and it drifts exactly like
  pool3. Its fight is identical to pool3's, so placing objects in `match_begin` equals writing them into
  the mod.
- The force did nothing (wake3's fight is identical to pool3's): too small, or not applied. Moot now.
- What differs from the exact baseline is the mod: placed3 has a static platform on id 49 with 3 dynamic
  objects resting on it far away, and its crates sit elsewhere. One of those makes the game's own
  replays drift. Next probe: the baseline plus each difference alone.
- Hint from `clone_parser_v1.0.1.lua` (a third-party replay merger in the workspace root): its recorder
  writes a `FRAME` line every frame with each player's POS, QAT, LINVEL and ANGVEL (WriteBoutActions), and
  merged replays of separately recorded fights play back right, so the game applies those lines as state.
  The game itself writes them only once per turn (every 10 frames here). Untested for us: whether a replay
  with per-frame body and EOBJ lines replays exactly whatever makes the physics differ. The clone parser
  also turns the replay cache off while recording, so `enter_frame` fires (matches our cache finding).

Fifth run (each fight changes one thing from the baseline; replay frame = fight frame):

| Fight | Replay | Bodies | Objects |
|---|---|---|---|
| plain, plat49 (+ empty static platform id 49), plat7 (platform id 7), parked (+ 3 dynamic objects resting on it) | cache 0 | exact | exact |
| placed3 | cache 0 | 0.46 from frame 133 | 0.0009 |
| placed3 | cache 2 | 0.46 from frame 1 | 0.0018 |
| placed3 patched (FRAME, body and EOBJ lines on every frame) | cache 0 | **exact** | **exact** |
| placed3 patched | cache 2 | 0.057 from frame 1 | 0.0036 |
| placedOnly (placed3's 3 crates alone, ids 1-3) | cache 0 | 0.46 from frame 133 (identical to placed3) | 0.0009 |

- **The platform, its id and parked objects change nothing.** placedOnly drifts exactly like placed3: the
  cause is the crates' positions near tori, i.e. the fight itself. The game's own replays of ordinary
  dynamic objects drift in some fights; the baseline happened to replay exactly. So a dynamic pool that
  places its objects at the start drifts no more than the same mod without a script (pool3 = placed3).
- **The game doesn't apply its own per-turn lines** (or not enough to resync): the drift starts at 0.0009
  and grows across turns (36 turns start drifted, 1 exact).
- **Per-frame lines are applied: the patched replay is exact uncached.** Cached it's 0.057 instead of 0.46
  (the cache is built differently; its drift starts at frame 1 even for the game's own replay here).
- The patched file is 12 times longer (615 lines -> 7365 for 500 frames). The probe found the recorded
  state at `enter_frame` matches the FRAME line of the same match frame (offset 0), plain quaternion order
  (ODE's row-major matrix, w x y z), for bodies and objects.
- Sixth run, the pool with moves during the fight, patched:

  | Fight | Own replay, cache 0 | Own replay, cache 2 | Patched, cache 0 | Patched, cache 2 |
  |---|---|---|---|---|
  | plain (baseline) | exact | - | - | - |
  | pool6 (8 activations, 3 releases) | bodies 0.048 from 133, objects 0.0002 | same | **exact** | **exact** |
  | pool3 (3 activations at the start) | bodies 0.46 from 133 | same | **exact** | **exact** |

  Per-frame lines make even a fight with teleports replay exactly, cached or not. The cache is
  inconsistent between runs (the fifth run's cache 2 drifted from frame 1, this run's matched cache 0;
  the third run's pool6 cached objects were off by 37), but the patched replays were exact here both ways.
  The fights' crates sit around uke: the rings are built around tori, but the nearest crates to either
  player are the ones on uke's side, and only tori moves (setTurnJoints), so uke stands still among them.
- Untested: a patched replay
  saved by a script rather than the game (a player saves from the menu, so Atmo Play would need its own
  save command or to rewrite the game's file after saving).

Seventh run (no patching; three fights each, both players moving; most body drift / at the last frame):

| Fight | Cache 0 | Cache 2 bodies | Cache 2 objects |
|---|---|---|---|
| all16 (16 ordinary dynamic crates, no script) | 0.0148, 0.0308, 0.0013 / 0 | ~0.1 | < 0.01 |
| pool6 | identical to all16 | ~0.1 | **78-88** |
| pool3 | identical to all16 | ~0.1 | **33-57** |

- Uncached, the pool replays exactly as a normal mod with the same crates does (same drift, back to 0 by
  the last frame). Cached, the bodies are as good as a normal mod's, but the teleported pool objects are
  misplaced (33-88 units): a cached replay shows crates in the wrong places.

**Proof of concept (2026-11-20), for the user to try:** `atmoplay/dynamics.lua`.
- A prop is an atmo object whose flag line lacks the static bit (colliders.lua returns props apart, with
  their mass). In MGE: make objects dynamic, then To atmo; Save writes a dynamic pool on the free ids
  1-48 (`#atmoplay dynamic` blocks, Pool.plan by shape and friction) and a hidden static parking platform
  far below (`#atmoplay park`, the first free static id). Header `dradius=` (default 2).
- Fights: the probe's rule (props within reach of a player's center, nearest first; release only at rest
  with no body part near; freed objects reusable from the next frame) plus chain reactions (props touching
  a moving carried prop are wanted) and props that fell 50 below the lowest prop's start are released.
  The static pool also covers carried props (Driver's `moreCenters`).
- Drawn copies: the game's atmo items are local to its manager; dynamics.lua finds the props' items
  among `Atmospheres.EntityHolder`'s children by position and moves them (rotation from the object's
  matrix through `Utils3D.MatrixTBToMatrix`, checked offline to equal the atmo's own Euler rotation).
- Replays: nothing moved; the script watches the pool objects (leaving the platform = took the nearest free
  prop of its group; back on it = left its prop where last seen). Events by frame rebuild the props on a
  rewind and when a fight resumes from a replay.
- First try (user): the mod's own dynamic objects fell through the atmo floor (the static pool only
  covered the players), and the props didn't move in MGE's test fight (they only ran in Atmo Play). Now
  the static pool also follows every dynamic object of the mod (`Driver.dynamicIds`, `driver.follow`),
  and MGE runs the props in its own fights too, drawing them where they are (`Playable.movedGhost`).
- Cached replays (user: props didn't move in a saved replay): the cache misplaces the pool objects, so
  the props weren't followed. While a mod with props is loaded, Atmo Play (and MGE) turn `replaycache`
  off and set it back after; a replay that opened cached (its mod loaded inside open_replay) says to open
  it again. With the cache off, props replay right without patching.
- Speed (offline, plain Lua 5.1, 5,000 props, a 40-object pool): the first version scanned every prop
  each frame, 1.6 ms a step and 23 ms with pushed props (the chain check). Now props are listed by x / y
  cell (as the static pool's grid): 0.1 ms a step, ~1 ms with 40 pushed props; replay watching 0.3-0.4 ms.
  The tests check the grid gives the same takes and releases as the full scan (`noGrid`), in a fight and
  in its replay. Drawn copies: only carried and just-released props are looked at, and a still carried
  prop keeps its pose tables, so it isn't redrawn. `/atmoplay status` shows the props' ms per frame.
- A prop is still until something wants it (a player's center within `dradius`, or a pushed prop
  touching it): one placed in mid-air hangs there until a player comes near.
- Priority over a full pool (2026-11-21, user's idea): the mod's own dynamic objects want props as players do
  (`follow`, their bounding sphere from get_obj_sides), and a prop near a player or one of those that has no
  object left FREEZES the least wanted carried prop of its group, even a moving one (released where it is,
  speed lost; it can hang in the air until wanted again). Only when that prop is farther by more than
  `EVICT_MARGIN` (0.5) and no body part touches it; chain-wanted props don't freeze anything. In game
  (user, modmaker/test2.tbm: a thrust cube through a line of 360 props, pool ids 3-48): holds up with one
  cube; a second cube trailing it runs out of objects.
- Lookahead ranking (2026-11-21): props are ranked by the gap less what the closing speed covers in
  `LOOKAHEAD` (0.1 s, at most `MAX_LEAD` 3 either way); players' velocity is their body parts' mean, the
  mod's objects' size comes from get_obj_shape. Ahead of a fast cube first, the debris it leaves behind last
  (frozen first when the pool is full). Chain props rank by the pushed prop's heading too. Offline tests
  only; LOOKAHEAD assumes velocities per second (not measured).
- Tiers (2026-11-21, user): props near a player rank before props near the mod's dynamic objects, and those
  before chain ones; distance only within a tier. A full pool lets a waiting player prop freeze any carried
  prop of a lower tier however near (EVICT_MARGIN applies within a tier). Offline tests only.
- Move predictions (2026-11-21, user, in game): "visible 0" objects get no ghost; MGE now writes the dynamic
  pool `visible 1` with color alpha `POOL_ALPHA`, and ghosts show. The object and the drawn copy at one pose
  flickered (worst in replays, the copy a frame behind), so a carried prop's copy is hidden and its object
  painted the prop's color (set_obj_color, fights and replays); MGE skips drawing carried props. Copies
  with textures or models would show as plain colored objects while carried.
- Atmo objects edited like objects (2026-11-21, user): the Atmo list uses the objects' Core and Advanced
  panels (Mass, Visible, Friction, Bounce, Hardness, Flags on the atmo lines; the game's atmo parser skips
  lines it doesn't know, atmospheres_manager.lua), Depth / Graphics / Kept below Flags, no Model, Ids or
  Thrust (no setters; atmo models are `shape custom`, not solid). Playable moved to the World tab. On a
  playable mod those lines reload the working copy so the pools follow (Rows.afterAtmoEdit).
  Hardness is a pool group like friction (`Colliders.groupKey`: "shape|friction|hardness", hardness 0 or
  none keeps the old key, so mods written before still match). Props get their flag (weapon, nogrip) with
  their color (dress). Kept lines (count, randompos, rotate, move, parent...) could get a tab of their own
  later.
- Crash (2026-11-21, user): MGE, open modmaker/owo (playable, props on all 48 dynamic ids), R before any
  move: the game crashed. dress then set the flag while watching the replay too; as in section 3, changing
  objects in a replay crashes when it reaches its last frame. Flags are now set in fights only (and only
  when not 0, the pool objects' written flag); replays only paint (EOBJ lines carry no color, so replays
  must paint, and painting while watching was used in replays before without a crash). Not yet retested.
- Open: R mid-fight replays the fight, then the game simulates the frames after it with nothing driving the
  pools (players fall through). Driving there is what crashed before (section 3).
- Still crashes without moves after the flag fix (user). RPH (user): moving dynamic objects and pressing R
  without a move doesn't crash it, and it registers dynamic moves mid-replay well; but in that no-moves
  replay the moved objects were teleported to 0,0,0. Guess: owo's taken props (dynamic, prop-sized) all land
  at the origin with the static pool objects there too, and the physics blows up.

#### Decision (2026-11-21, user): the tail is dropped, replays move nothing again (R ones included)
The tail drove frames nobody played: there's nothing right to match there, saved replays can't have it (the
game doesn't say which file is open, and a file doesn't say where its fight ended), an edit in it didn't give
a correct replay, and it cost a series of crash fixes and a clump of stopped crates. Everything found on the
way stays: nothing moves before frame 1, the props park above the map, only what differs is set (sizes read,
flag and bounce cached until match_begin, parked props on their spot left alone), props painted (not
flagged) while watching, and going back to a fight from a replay puts back the objects the game left at
0,0,0 (the props' reseat) while the static pool is set again as before. The probe switches went with it;
`/atmoplay log` stays. The notes below are the history of the tail.

#### Replay probe (2026-11-21): both now the default, Atmo Play and MGE
- Probed with Atmo Play's `/atmoplay wait` and `/atmoplay tail` (user, owo): both worked, no crash, and the
  user asked for them as the default. The switches are gone; `/atmoplay log` keeps the trace (every
  `set_obj_*` call, the globals wrapped while it's on, originals in `ATMOPLAY_TRACED`; per frame how many pool
  objects sit at 0,0,0 and every dynamic one off its platform).
- **Nothing moves before match frame 1** (`Driver.FIRST_FRAME`, also the props' `fromFrame`): R before the
  first move replays nothing moved, so nothing lands at 0,0,0. Frame 0 -> 1 is one physics step without the
  pools.
- **R mid-fight: the replay's frames after the fight's are driven** like a fight (`Driver.trackTail`, shared
  with dynamics.lua). R fires `leave_game` only (the probe's log), an opened replay fires `match_begin`
  first: a replay drawn right after a fight drives frames after that fight's last one; `match_begin` clears
  it (also an opened replay while an R replay plays). The user's run: R at frame 50, the replay to 2101 and
  looped, no crash. Saved replays of unfinished fights still have no tail driven (their end isn't known).
- **No tail before the first turn** (user, same day: R without moves, the replay crashed when it looped).
  The 16:53 probe log (wait off, R without moves) shows why such a replay is unsafe: no script call between
  replay frames 5 and 6, yet all 48 parked dynamic pool objects jumped by the same offset and flew on
  (z 1.9 million by frame 389). The game has no recorded state for script-changed dynamic objects in a
  replay without a turn. A tail is driven only when the fight frame is above 0 (a turn recorded: every
  dynamic object has EOBJ lines then). R before the first move: nothing is moved at all.
- Editing an R replay in its tail crashed (user, log on; RPH edits replays fine). The log: in the recorded
  frames of the R replay the parked dynamic pool jumped erratically with no script call (frame 6 again);
  at the end of the recorded frames the game put all 255 pool objects at 0,0,0; the tail set the static
  pool again but left the 48 dynamic ones stacked at the origin; the edit (back to a fight) then crashed.
  Changes (user: try them, but keep the features):
  - The props are set again (`reseat`) when an R tail starts and when a replay goes back to a fight, as the
    driver already did for the static pool.
  - Gentler prop updates: size, mass and bounce are set only when they differ (`fitObject`); a released
    object parks at its own file size and spot. MGE writes each dynamic pool object at its group's most
    common prop size, mass and bounce (`Playable.propLooks`), parked side by side on a platform sized to
    fit (`Dynamics.parkLayout`): a uniform map's props never resize anything. Older mods resize as before.
  - Probe `/atmoplay tailprops`: an R tail drives the static pool only (props watched), to tell the two
    apart if editing still crashes.
  - Open: the parked props' jumps in the recorded frames are the game's own; if they keep causing trouble,
    parking them without a platform (free fall far below) is the next idea.
- **Found (owotail.rpl, user's saved replay; the user's hint: the game limits placing below ground):** the
  props' parking was 50000 BELOW the ground, and for a dynamic body everything below z = 0 is inside the
  ground. The fight's own EOBJ lines: frame 0 parked and still; frame 1 every parked prop at z -44999 with
  vz 833317 (= the depth 49999 x 16.67: the engine pushing it out); set back still at frames 3 and 4 (edits),
  launched again with the same numbers. They flew up through the map near frame 10, in fights and replays:
  the "jumps" and very likely a share of the crashes. The static pool (parked at -100000) doesn't move.
  - The props now park ABOVE the map (`Dynamics.PARK_Z = 50000`, the platform up there); "parked" is near the
    object's own spot (`PARKED`). (A first version also moved older files' underground spots up and seated
    every parked prop on each fight's first frame; removed the same day: Atmo Play isn't deployed yet, so
    there are no older playable mods to support. Mods made before this must be saved again from MGE.)
  - test2 crash (user's repro: one turn, R, the replay loops, then R or the next loop: the 2nd restart after
    a tail crashes). Probes: no tail (`notail`): no crash over 8 playbacks; any tail crashed, also the
    minimal one (`tailprops`: one props reseat + test2's 2 static strips) and with everything parked on
    leave. The tail re-set flag, bounce and size of the static pool on every reset although replays record
    neither flag nor bounce (and nothing else changes them). Now only what differs is set (RPH-like):
    sizes read from the object, flag and bounce cached (dropped only at match_begin, when the mod's
    objects load again), parked props already on their spot left alone. Not yet tested in game.
  - No crash since (user). Then a clump of crates under the trailing cube from the tail start, R replays only
    (not the saved replay, which has no tail): at the tail's first frame the re-seat compared each carried
    object with its prop's pose, but that pose is a frame old there (the frame is stepped, not watched), so
    all 30 pushed crates were put back a frame and stopped (frame 50 y 13.18, object at 13.37, put at 13.185).
    Now the object is the truth: its prop's pose is read from it, and only an object at 0,0,0 (the game's
    end-of-recording move) is put back. Not yet retested in game.
  - Saved (opened) replays get no tail: the game doesn't tell a script which file is open (no getter;
    wrapping open_replay would miss /lr), and a file's last FRAME isn't where the fight ended (test2.rpl:
    0, 1, 2, 42 of a 50-frame fight). A wrong guess drives the pools over recorded frames (what crashed).
  - The tail after an edit (user: "sometimes didn't activate"): the log had no missed tail; each replay
    without one was left before it passed the fight's last frame (330 -> watched to 232, 623 -> edited at
    442, 598 -> watched to 399). 17 restarts (R in a replay) with no crash and no objects at 0,0,0.
- Not in it: the offline builder, patched replays. Unknown until tried: whether set_obj_mass and set_obj_sides on dynamic objects are recorded in
  replays and change their physics; how cached replays look (objects misplaced, the drawn props follow).

### 7. Thrust props and drawn flight (planned, 2026-11-22)
The idea (user): atmo props may have thrust. A drawn prop flies (its copy moves); one that comes near enough
to be wanted takes a pool object with its drawn velocity and keeps its thrust (the script pushes it). With a
small flight sim for drawn props, a full pool can also let a prop go on flying drawn instead of freezing it.
The sim is simple on purpose: gravity, thrust, sphere against the static atmo and the ground, bounce and
friction from the measured curves below; no spin, no prop against prop. It starts only from states replays
also have (frame 0, a release's pose and velocity), so a fight and its replay draw the same flight.

#### Probe (2026-11-22, tools/atmoplay/probe_thrust.lua + data/mod/mge_tests/atmoplay_probe.tbm, test.rpl)
- **Step:** dt = 0.006 s exactly, semi-implicit Euler: `v += a*dt`, then `pos += v*dt` (obj 1: vz -0.05892
  a frame = 9.82 x 0.006). No air drag.
- **Thrust `<frames> x y z`** is a force for one step: `dv = F / mass * dt` on push frames (0.1, mass 1:
  0.0006; mass 2: 0.0003). Gravity just adds. `thrust 5` pushes on the steps into frames 1, 6, 11 ...
- **set_obj_force** is the same force, for one step (applied once: dv 0.0006 once, nothing after). Called in
  draw2d at frame f it shows from f + 1; pushing when `f % N == 0` gives exactly `thrust N`'s pushes (frames
  6, 11 ...; the game's first push, into frame 1, can't be matched: nothing moves before frame 1).
- **Object axes** (`thrust 1 0.1 0 0 1`, rot 0 0 90): pushed along -y. Which way the rotation matrix maps it
  still has to be checked against get_obj_rot when it's coded.
- **Replays:** the replay (cache 0) matched the fight exactly (0.00000) for every object: script forces and
  set_obj_linear_vel are recorded. (draw2d skipped frame 501 once: step by frame difference, not per draw.)
- **Bounce** (box dropped at 11.08 onto a block): the rebound is proportional to the impact speed,
  e = 0.096 x (bounce - 0.48): bounce 0 -> 0.04, 1 -> 0.05, 5 -> 0.43, 10 -> 0.91, 20 -> 1.87 (gains energy),
  50 -> 4.75. Bounce 10 on the falling box acts as bounce 10 on the block.
- **Friction** (box given vx 5 on a platform): friction 0, 10, 100, 1000, 10000 on the platform, and 0 on the
  box, all identical: it grips (dv 0.77 in 5 frames, ~26 m/s^2) and tips over, stopped by frame ~150.
  -10000 is frictionless (vx 5 kept). Between -10000 and 0 not measured.
- Friction probe 2 (`atmoplay_probe_friction.tbm`, flat 1 x 1 x 0.2 boxes that slide instead of tipping):
  platform friction 0, -1, -10, -100, -1000, -5000, -9999, -10000; box friction -100, -1000; box 10000 on
  platform -10000 and the reverse (which side wins). Results (2026-11-22):
  - -10000 on either side: frictionless (10000 against -10000 too: the LOWER value wins, as a min).
  - -9999: a steady 0.012 a frame (2.0 m/s^2 for mass 1): a friction force of ~2 N, i.e. friction looks like
    ODE's per-contact force limit `mu = friction + 10000` (1 N) on ~2 contacts, not a coefficient. So a
    heavier prop would slide farther (not measured).
  - 0, -1, -10, -100, -1000, -5000 (platform or box): identical grip; after landing the speed falls by a
    factor ~0.89 a frame (0.94 for a few frames) to 0: the solver's grip, not the friction limit.
  - Sim model: tangential speed loses `min(2 * (min(fa, fb) + 10000) / mass * dt, 0.11 * v)` a frame on contact
    (default friction: grip). Between -9999 and -5000 not measured.
  - The ground is always at z = 0 (user). Sphere proxies are fine to start with; a closer shape later.

#### Build plan
1. **Flight** (dynamics.lua, pure Lua, offline tests first). A prop gets `flight = { pos, vel, frame }` while
   drawn and moving; `Dynamics.fly(s, prop, toFrame)` steps it 0.006 s at a time, by frame difference (draw2d
   can skip a frame), as the game does: `v += (g + push) * dt`, then `pos += v * dt`; g from the gamerules.
   - Push: a thrust prop's `F / mass` on the steps into frames 1, 1 + N, 1 + 2N ... (world axes, or the
     prop's own: the sign from the probe's obj 8 checked against its rotation).
   - Hits: the prop as a sphere (radius: its smallest half side, so flat props sit low; open) against the
     static atmo colliders near it (a cell grid like the pool's) and the ground (z = 0, to be checked). New
     `Colliders.closest(c, p)` gives the normal. Normal speed reflected with `e = 0.096 x (bounce - 0.48)`
     (clamped at 0; the larger of the two bounces, unverified), tangential speed kept when either side is
     frictionless, else slowed at ~26 m/s^2 (probe 1); refined by probe 2.
   - Rest: on contact and below REST_SPEED for a few frames, the flight ends: an ordinary still prop.
   - No spin, no prop against prop (a flying prop passes through still ones), no players (a prop near one
     is real by then).
2. **Where flights start** (all states replays have too, so fights and replays fly the same):
   - a thrust prop: at frame 0 from the atmo pose, speed 0;
   - a release while moving: from the object's last pose and velocity. Fights: read in step; replays:
     observe also keeps the last seen velocity (EOBJ has it).
   - Releases: a carried prop nobody wants is let go when it's untouched, at rest OR not (it flies on drawn);
     a full pool's eviction lets the prop fly on instead of freezing it.
3. **Takes**: a flying prop is put at its flown pose WITH its velocity (placeAt gets a velocity). Ranking
   counts its own velocity in the closing speed (a prop flying at a player is wanted sooner).
4. **Carried thrust**: the script pushes the object with set_obj_force when `frame % N == 0` (draw2d, fights
   only; recorded in replays).
5. **Rewinds**: rebuild replays the events; each flight is simulated from its start event to the frame
   (snapshots every ~100 frames if that's slow). Replays match takes by the flown pose (MATCH 0.5).
6. **Drawing**: flying props are dirty every frame (their copies move); `/atmoplay` status counts flying props.
7. **Format / MGE**: props keep their `thrust` lines on the atmo lines (the game's atmo loader skips them);
   Colliders reads them into the prop; MGE's Thrust tab opens for props (it's off for atmo objects now).
8. **Tests** (tests/test_atmoplay_dynamics.lua): free flight equals the probe's numbers (obj 1 z 148.21472 at
   frame 100, obj 2 x 0.64908 at frame 600), thrust N and mass, bounce e, rest, a fight's flights equal its
   replay's (observe), a rewind's rebuild equals flying forward, evicted props fly on.
9. In game (user): thrust props in a playable mod, fights and replays (cache 0), R mid-fight, rewinds.

**Built 2026-11-22 (steps 1-8, offline tests only; step 9 pending):** atmoplay/flight.lua (loaded after
pool.lua: atmoplay.lua, mge/main.lua, tests/run.lua, package.ps1); dynamics.lua flies `s.flying`; the runtime
and MGE pass the static colliders (`statics`); gravity from `get_game_rules().gravity` at match_begin.
- One change from step 2: a carried prop nobody wants is still kept until it rests, except a thrust prop
  (it never rests) and a full pool's eviction; those fly on drawn. Kept that way so a kicked crate stays real
  as long as the pool has room.
- tests/test_atmoplay_flight.lua matches the probe's numbers (free fall, thrust 1 / 5 / mass 2, object axes);
  test_atmoplay_dynamics.lua: a thrust prop flies from frame 0, is taken moving and pushed, is let go moving,
  and its replay and a rewind fly every frame the same as the fight (fake world, exact).
- MGE: the Atmo list has the Thrust tab (its lines only, Rows.afterAtmoEdit). `/atmoplay` counts flying props.
- **Spin (2026-11-22, user saw rotations freeze):** a prop let go spinning kept its last rotation (flights had
  no spin) and a take zeroed the object's angular velocity. Now flights carry the angular velocity
  (get_obj_angular_vel, read as ODE's: world axes, rad/s; unverified in game: a copy that turns the other way
  at the let-go means the sign is wrong): the drawn copy turns, a thrust on its own axes turns with it, a
  gripping contact slows it by GRIP a frame, rest needs it below REST_SPIN. A take sets it on the object with
  set_obj_angular_vel (no torque setter for objects; RPH does the same). Releases, replays (seen.ang) and
  rewinds (events' ang) keep it. The sphere doesn't roll from it.
- **Shapes and prop hits (2026-11-22, user):** flight.lua is a small rigid-body step now. A box touches by its 8
  corners, a sphere by its center, a pill by its end spheres, each pair both ways (a static's corner holds a
  wide prop); box against box (props and static boxes) by separating axes, as flush faces of equal boxes
  have their corners on edges. Impulses (8 rounds: normal, bounce over BOUNCE_MIN, friction as a cone of MU = 2
  capped by `(friction + 10000) x 0.5` N per contact) turn props: a sliding cube tips and tumbles to rest in
  ~180 frames (the game's tipped and stopped by ~150), a dropped turned box settles on a face, a ball rolls.
  - **Flight levels** (2026-11-22, user: a player's setting, by their computer, not the mod's): `simple`
    (a sphere of the smallest half side, hits don't turn it, spin slows on grip: the old model), `shapes`
    (default, real shapes), `full` (real shapes that hit each other and wake the still props they run into).
    Atmo Play: `/atmoplay flight <level>`, kept in atmoplay.cfg next to atmoplay.lua (gitignored). MGE:
    Settings > Prop flight (config.cfg `propFlight` 1-3). A change applies from the next match_begin
    (Dynamics.setLevel), so a fight and its rewinds keep one level. Replays watched at another level than
    the fight draw props differently (takes are matched by the flown pose). A header option (`collide=1`,
    World tab) came first and was dropped the same day.
    Speed (30 / 100 flying props, 5,000 static boxes): simple 0.15 / 0.48 ms a frame, shapes 0.68 / 2.1,
    full 0.80 / 2.7.
  - All flights step together a frame at a time (Flight.step, atmo order), after the carried objects are read
    (step and observe in the same order). A flying prop near a carried one is wanted (chain tier): drawn
    flights don't meet carried props, the game does once it's real.
  - Rebuilds step the timeline again from the nearest snapshot (every SNAPSHOT_EVERY = 50 frames: the moved
    free props' poses and flights) with the events in between, as flights touch each other.
  - Speed (plain Lua 5.1, 5,000 static boxes): ~0.04 ms per flying prop a frame, collide ~25% more (30 flying:
    ~0.8 ms a frame); a rewind steps at most 49 frames again.
  - Tests: free flight still equals the probe; landing height, tipping onto a face, a post's corner holding a
    plate, rolling, head-on hits (and passing with collide off), waking, and fights equal to their replays
    and rewinds (across snapshots, with takes, releases, spin and wakes).
  - Not in it: edge against edge between a sphere / pill and a box is approximate; thin walls can be passed
    by fast props (no sweep); flying props never hit carried ones or players (they become real near them).

## Still open (checked during Phases 1-2, in game)

- **R2:** do `set_obj_flag` / `set_obj_bounce` take effect on a static object, and can static objects use
  ids 1-48? **Bounce answered (2026-11-21, `tools/atmoplay/atmoplay_bounce_probe.lua`, user's run):** no.
  Bouncy tiles (bounce 10) with the pool's bounce set live: the very same fight as with default tiles (max
  0.0000); written in the mod: differed by 13.3 units from frame 14. Every replay matched its fight.
  The user's own test then saw `set_obj_bounce` change both static and dynamic objects live, so the
  probe's "no effect" isn't the rule. What holds either way: replays don't record bounce or flag (EOBJ has
  neither), so a value set live isn't there when a replay is watched. The static pool is now grouped by
  bounce and by flag bits too (`Colliders.groupKey`: shape|friction|hardness|bounce|flag bits, written on
  each pool object), and the driver sets neither live. Typical maps have one bounce (dust2-5k: all 0.1),
  so no extra split there. A prop's mass is in the dynamic pool's key too (2026-11-21, user: fix it), so
  props of another weight get pool objects written with it and nothing is set live any more; a static
  object's mass doesn't count (it doesn't move).
- **Online play: not supported** (user, 2026-11-21). Atmo Play is for single player and replays.
- **Drawn mods (2026-11-21, user):** MGE's Default (not playable) Save keeps the atmo inside the mod too, behind
  `#atmoplay v1 mode=draw` (`Format.isDrawOnly`, `Atmo.bundledText`): one file to share, Atmo Play draws it (no
  pools). The game skips the lines, so without Atmo Play the map just isn't drawn. World > Export writes the
  clean copies for players without Atmo Play: Atmo (`data/atmospheres/MGE - exp_<name>.atmo`) and Mod
  (`modmaker/exp_<name>.tbm`, without its atmo), both named in a prompt (2026-11-22: the `exp_` prefix keeps exports from replacing mods, so they overwrite earlier exports without asking; the mod's own file is refused). Save atmo left the Atmo list's Core row; the save-time `.atmo` logic
  (`saveFor`, `saveAction`) went. Mods saved before still open with their separate `.atmo`.
- **Debug tools trimmed (2026-11-22, user):** `/atmoplay show`, `hold` and the status timings are gone (unused). `/atmoplay log` moved to `atmoplay/debuglog.lua`, dev only: neither zip ships it (`$DevOnly` in tools/package.ps1), atmoplay.lua loads it when the file is there and runtime.lua calls it through `NS.DebugLog`. Releases: `/atmoplay` (status), `reload`, `quit`.
- **Default undoes Playable's move (2026-11-22, user):** Playable writes `mge_was_object <id>`
  (`AtmoLayer.FROM_KEY`) on the objects it moves into the atmo; it's saved with the atmo, so it survives
  reopening, and the game's atmo loader skips it. Default moves the marked ones back
  (`AtmoLayer.returnObjects`, shared with To objects): their old id when it's free, other free ids next, as
  many as there are; the rest stay in the atmo, marked, and MGE says how many. One undo step with the
  switch. To objects drops the mark. A duplicate of a marked object carries the mark too.
- **Frame time measured:** a match frame is ~0.006 s (test2.rpl: the cube moved 0.1798 between two
  recorded frames at a recorded 29.98 per second), so `LOOKAHEAD = 0.1` s is ~17 frames ahead as meant.
- **Cleanup (2026-11-21):** the probe scripts (native, timing, replay, size, dynamic, replay patch, bounce)
  were removed from `tools/atmoplay` with their logs, mods and replays; git history keeps the scripts, and
  this doc keeps what they measured. The builder and `build_playable.lua` stay. The driver now places a
  static pool object only where it isn't already (position, rotation and size read from the object).
- **R5, cost:** offline on the dust2 mod (5,501 colliders, 208 pool objects, 2 players walking through the
  middle), the pool step takes **0.15 ms per frame** with the grid (1.33 ms looking at every collider),
  building the grid 9 ms, reading the colliders ~120 ms (once per mod switch). In game: `/atmoplay`.
- Does a big pool (200 objects) replay exactly? The probes used 11 and 31; the user's first runs on dust2
  (two players) looked right.
- Fast play: `draw2d` ran once per match frame in the probes. If the game ever steps several frames
  between two draws, the pool updates less often (replays stay exact: they replay what was recorded).
- Answered by the redesign (part 3): cached replays, seeking and the replay cache option need nothing
  from Atmo Play any more.

## Phases

0. **In-game checks.** Done (2026-11-20). Probes: `tools/atmoplay_size_probe.lua`,
   `tools/atmoplay_replay_probe.lua`.
1. **Format, builder and pool rule.** Done 2026-11-20: `atmoplay/format.lua`, `colliders.lua`,
   `pool.lua` (rule 1), `builder.lua`, `mat3.lua`; `tests/` (125 checks, `lua5.1 tests/run.lua`);
   `tools/build_playable.lua` (offline builder). Notes:
   - The cylinder is a capsule (rounded ends), as in the PoC; its length runs along local z.
   - A base mod object without a flag line counts as dynamic (flag 0) and stays real.
   - The builder needs `format.lua`, `colliders.lua`, `pool.lua` (defaults) and `mat3.lua`, so MGE gets
     those copied, not just one file.
   - The 5,293-object dust2 atmo on classic: 1.6 MB, 65,807 lines, all 208 free static ids pooled (one
     group, `box|10000`). Offline (Lua 5.1, this PC): read 19 ms, colliders 131 ms (once per mod switch;
     a rot-line cache like MGE's `frameByRot` would cut it), **pool step 1.3 ms per frame** on average,
     3 ms worst, 325 pool moves in 500 frames of two players walking through the middle.
2. **Runtime.** Colliders, the pool driven in live play and replays, drawing through the cache atmo,
   restoring the player's atmo and `replaycache`. In game: the 5k map, a saved replay, R2, R5.
   Written 2026-11-20: `atmoplay.lua` (entry, then `/ls atmoplayDev/atmoplay.lua`, now `/ls mgeDev/atmoplay.lua`), `atmoplay/runtime.lua`;
   `/atmoplay [status | show | reload | quit]`. Offline: `tests/test_runtime.lua` runs it against a fake
   game (157 checks in all). Changes on the way:
   - **Pool split by demand, not by count.** On the dust2 map the base mod's 208 objects have no friction
     line, so they are their own group; split by count it got 1 pool object for 208 boxes (the map's big
     ones). The builder now samples the map for the most objects of each group one player can have in
     reach (`box|10000`: 125, `box|`: 45) and splits by that: 153 and 55.
   - **Flag and bounce are set again after every reset.** The game puts objects back to their file
     values when a fight or replay starts; remembering what was set skipped calls in the replay that
     the fight made (the runtime test caught it). Colliders without a bounce/flag line give the pool
     object its own value (read at load), not the previous collider's.
   - An unknown in game: do hidden (`visible 0`) static objects collide? The pool stays hidden;
     `/atmoplay show` makes it visible, for the comparison if tori fall through.
   - The test mod: `data/mod/atmoplay_dust2.tbm`, built from `mge-modmaker.tbm` (spawns on the map) and
     `MGE - dust2-5k.atmo`: 5,501 atmo objects, 208 pool objects.
   - Don't run MGE at the same time: it unloads the game's atmo and draws its own.
   - **First in-game run: a crash** when the game switched from the fight to its replay, once the replay
     reached the last frame played. No Lua error (stderr.txt empty), so the game itself crashed. The probe's
     first run crashed the same way at a replay's end ("1 frame remaining") while it moved static objects;
     the later probe runs left each replay before its last frame. Suspect: object calls at the replay's end.
     Debug tools added: `/atmoplay log` (every hook and frame's planned calls to
     `data/script/atmoplay_debug.log`, written before the calls run) and `/atmoplay hold` (no calls).
     **The log (fight left with 'r' at frame 150):** `leave_game` at 150, the replay placed all 208 pool
     objects at its frame 0, then 0 calls from frame 7 on; the log ends after replay frame 148 with no
     further hook. So no object call ran at the crash. The game stays in replay mode at a replay's end (it
     doesn't switch back to the fight by itself, user 2026-11-20): it crashes as the replay reaches its
     last recorded frame, apparently over static objects a script moved / resized / turned. A replay
     restart (`rewind_replay()`) with such objects worked in the probe; only the end crashes.
     Next tools: `/atmoplay calls pos|sides|rot|flag|all` (which calls a placed pool object gets) to find
     the call that breaks it, and `/atmoplay endfix` (the pool back to its file state 3 frames before the
     replay reaches the frame the fight was left at) as a possible fix.
   - **Rethink (user, 2026-11-20): let the game replay the pool.** With RPH, objects moved during a fight
     show up in its replay and in the saved file (EOBJ lines). The first replay probe's "EOBJ lines only"
     replays went wrong from frame 1, but the file explains why: a change made in `enter_frame` of frame f
     is written under `FRAME f+1` (one frame late in the replay), and that probe placed its pool in
     `enter_frame` 0 and reassigned it all the time (the PoC's rule). Changes made in `match_begin` are
     written under `FRAME 0`. If the pool is placed in `match_begin` and the stable rule moves objects
     while players are still ~4 units away, a one-frame delay shouldn't matter. Then the runtime wouldn't
     touch objects in replays at all: no driving, perhaps no end-of-replay crash, cached replays and
     seeking could work, and viewers without Atmo Play would still collide right. Being checked with
     `tools/atmoplay_native_probe.lua` (generous and saturated pool, script off in replays, cache 0 and 2,
     and one replay played to its end).
     **Result (2026-11-20, Atmo Play's pool rule, placed in match_begin):**

     | Fight | Replay, script off, cache 0 | cache 2 | script driving, cache 0 |
     |---|---|---|---|
     | generous (31 for 31: no moves after the start) | **exact** | max 0.10 from frame 1 | exact |
     | saturated (11 for 31: 33 moves after the start) | max 0.11 from frame 90 | max 0.12 from frame 1 | exact |

     The saturated replay with the script off, played to its very end: **no crash** (it looped). So
     placing in `match_begin` makes the game's own replay exact; moves made in `enter_frame` replay one
     step late (small drift); the end-of-replay crash points at the script moving objects in replays.
     Next: `tools/atmoplay_timing_probe.lua` moves the saturated pool from `draw2d` (between steps) to
     see whether those moves are written under the step they affect (then exact), and replays a fight
     without any pool, cached, as the cache's own baseline.
   - **Timing probe result: `draw2d` moves replay exactly**, cached too (part 3). The runtime was rewritten
     to that design the same day: pool placed in `match_begin` and moved from `draw2d` in fights, nothing
     moved in replays, `replaycache` left alone. Dropped with it: `/atmoplay calls` and `/atmoplay endfix`
     (the end-of-replay crash came from moving objects in replays), the cached-replay warnings.
     `/atmoplay log`, `hold` and `show` stay. 164 offline checks.
   - **"unload" isn't an end** (user, 2026-11-20): Atmo Play stopped when the replay was saved with 'f' and
     when a replay was loaded from the menu. The game fires `unload` when it loads its own scripts too
     (opening the menu; `system/replay_save.lua` opens it when it isn't loaded), and hooks stay; the
     game's chat scripts only rebuild their UI on it. Atmo Play quit on it; now it keeps running and only
     `/atmoplay quit` or a new `/ls` stops it.
3. **MGE.** World tab "To playable atmo" and opening a playable mod (part 5). The PoC is removed
   (2026-11-20). Built 2026-11-20 and, with "C", reworked onto Atmo Play's modules:
   - `playable.lua` keeps only MGE's part; the format (`Format.split`), what's solid (`Colliders.build` on
     `Atmo.text`) and the pool split (`Pool.plan`, moved out of the builder) are Atmo Play's code.
   - **One switch** (user, 2026-11-20: Convert / Test / Ordinary was too much, and Test showed no atmo with
     the window hidden): World → Playable **Off / On**. On moves the static objects into the atmo, marks
     the mod playable, and the editor plays it: the working copy always carries the pool (and the header,
     so the reload frees its ids) and MGE runs `driver.lua` after each reload, on the pool the reloaded
     file has (`Playable.split` adds `poolObjects` from `Format.read`). Colliders are cached by the atmo's
     text, so reloads with an unchanged atmo don't build them again. Off: ordinary again, one undo step.
     Atmo Play leaves playable mods to MGE while MGE is open.
   - **F1 (window hidden) draws the atmo** as it looks in game (own colors, no selection highlight), for
     every mod; the map placement view (which also hides the window) keeps drawing only itself.
   - Release comment stripping no longer leaves gaps (`tools/strip_comments.lua`: comment lines removed,
     blank lines one in a row); line numbers move, so `tools/same_bytecode.lua` compares `luac -s` output
     ignoring the functions' source lines.
4. **Release.** Packaging done (`tools/package.ps1`: mge.zip and atmoplay.zip; README
   `docs/atmoplay-readme.md`). Phase 3 checked in game (user, 2026-11-20: "seems to work"). Left: maybe a
   small status window; committing. No converter in the runtime (part 5).

## Future ideas (out of scope for now)

### Jointed atmo assemblies (user, 2026-11-22)

Atmo objects joined by joints (doors, hanging lamps, chains), played the way props are: a pool of whole
**assemblies** (the real objects and their `env_obj_joint`s) parked above the map, and the one nearest a player
placed onto that copy of the assembly: every part at its pose, at rest. Its drawn copy hides while it's
carried, as a prop's does.

- **First step, a probe:** do joints survive the move? Joint anchors are stored relative to the bodies they
  join, so setting every part's pose together (relative poses kept) should leave the joints intact. Test with
  a 2-3 part assembly: move it, then check its parts stay together and its joints still act as before.
- **Costs:** every part takes one of the 48 dynamic ids (shared with props and the mod's own dynamic objects:
  a 4-part assembly x 3 pooled copies is 12); assemblies share a pool only when identical (parts, sizes, joints:
  one group per design); a moved assembly holds state (joint angles, motion), so it can only be given back at
  rest, which motorized joints may never reach; MGE needs a new atmo kind (atmo has no joints today:
  authoring, drawing, the Atmo list, saving); every prop concern (drawn copies, replays, freezing) times parts.
