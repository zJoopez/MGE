# Atmo Play plan (playable atmo maps)

Status (2026-11-20): **Atmo Play works in game (fights and replays, two players). Phase 3 built and tested
offline, not yet in game: MGE converts (Atmo list → Advanced → Playable) and tests playable mods with the same code; one
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
   `docs/atmoplay-readme.md`). Left: in-game checks of Phase 3 (Convert, Save, reopen, Test), maybe a small
   status window. No converter in the runtime (part 5).
