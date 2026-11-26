# Atmo Play

Plays **playable atmo mods**: maps far bigger than the 256 objects a mod can hold, made solid. A playable
mod carries its atmo (thousands of objects, only drawn) together with a pool of hidden objects; Atmo Play
moves that pool onto the atmo objects next to each player, every frame of a fight.

Atmo objects that aren't static are **props**: pushable crates and the like. A second, smaller pool of
dynamic objects carries the props near the players (and near the mod's own moving objects); a carried prop
shows the game's move predictions like any dynamic object.

Mods made with MGE keep their atmo inside the mod file even when it isn't playable (**drawn mods**): Atmo
Play draws those too, without making anything solid.

## Use

1. Unzip into `data/script` (you get `data/script/atmoplay/`).
2. `/ls atmoplay/atmoplay.lua`. It runs until the game closes or you quit it in its window; opening the menu
   or loading other scripts doesn't stop it.
3. `/lm` a playable mod: its atmo is drawn and the map is solid. A drawn mod: its atmo is drawn.
4. Loading a normal mod gives you your own atmo back.

Atmo Play's window has everything you set (drag it by its bar). Its cross hides it behind a small AP button,
which opens it again:

- **Detail**: how props move while no pool object carries them, for your computer. Low flies them as
  spheres (the least work), Medium (default) with their real shapes, High with real shapes that also hit each
  other (the most work). Used from the next fight.
- **Ghosts**: the flying props' move predictions while a turn waits (like the game's ghosts). Off saves their
  work on maps with many thrust props.
- **Distant**: what moving props do far from every player. Move (default): they keep moving. Pause: they
  wait where they are until someone comes near: less work on big maps. Neither starts a prop: ones the
  map's maker didn't set Active stay still until something reaches them.
  Used from the next fight; replays pause the same props at the same frames.
- **Max draws**: at most 5000 / 1000 (default) / 500 atmo shapes a frame, the nearest. Lower keeps big
  maps' fps steady; low graphics settings can show more.
- **Quit Atmo Play**: stops it and gives you your own atmo back.

Your choices (and whether the window is open) are kept in `atmoplay.cfg`. Atmo Play stays quiet in the chat:
it only speaks up when something goes wrong or you need to load the mod again.

## Replays

The game records every move of the pools in the replay, so replays collide the way the fight did by
themselves, with seeking. Atmo Play only draws the atmo in them (and the props where they are): without it
a replay still plays right, the map just isn't drawn.

- Atmo Play moves nothing in replays. A replay of a fight that wasn't finished (R in the middle of a
  fight, or a replay saved then) plays the moves made so far; the frames after them, which nobody played,
  have no pools: tori fall through the map there.
- A mod with props turns the replay cache off while it's loaded (cached replays misplace the props); your
  setting comes back when another mod loads, or when Atmo Play next starts if the game closed first.

## Making playable mods

With MGE (Mod Group Editor): **World → Atmo: Playable**, then Save. While it's Playable, fights in the editor are
solid the same way. While MGE is open, Atmo Play leaves playable mods to it. A playable mod made with an
older MGE version must be saved again.

What an atmo object needs to play, set on MGE's Atmo list (Core and Advanced tabs):
- **Static** (Flags): solid and still. Static off makes it a prop.
- **Friction, Hardness, Bounce, Weapon / Nogrip**: each combination gets pool objects of its own, written
  with those values (the game can't change them on a pool object in a way replays keep). Maps where most
  objects share their values (the usual case) lose nothing; many different values split the pool.
- **Mass** (props): a prop's weight, written on its pool objects the same way.
- **Visible: Hidden**: solid but not drawn (invisible walls).

## Limits

- A viewer needs the playable mod file; it isn't on the game's server.
- Single player and replays only: online play isn't supported.
- Solid are boxes, spheres and capsules. Custom models, random (`count`, `rpos`, `rsize`), animated and
  parented atmo objects are only drawn.
- Props: at most 48 dynamic objects in a mod (the game's limit for dynamic objects with move predictions),
  shared with the mod's own. When more props are wanted than there are objects, the ones nearest a player
  come first; others wait or are stopped where they are. Very light props (much lighter than a tori's body
  parts) make the physics jumpy.
