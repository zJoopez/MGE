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
- Not in it: the offline builder, patched replays. Unknown until tried: whether set_obj_mass and set_obj_sides on dynamic objects are recorded in
  replays and change their physics; how cached replays look (objects misplaced, the drawn props follow).

## Still open (checked during Phases 1-2, in game)

- **R2:** do `set_obj_flag` / `set_obj_bounce` take effect on a static object, and can static objects use
  ids 1-48?
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
