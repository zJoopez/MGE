# Atmo Play

Plays **playable atmo mods**: maps far bigger than the 256 objects a mod can hold, made solid. A playable
mod carries its atmo (thousands of objects, only drawn) together with a pool of hidden objects; Atmo Play
moves that pool onto the atmo objects next to each player, every frame of a fight.

Atmo objects that aren't static are **props**: pushable crates and the like. A second, smaller pool of
dynamic objects carries the props near the players (and near the mod's own moving objects); a carried prop
shows the game's move predictions like any dynamic object.

## Use

1. Unzip into `data/script` (you get `data/script/atmoplay/`).
2. `/ls atmoplay/atmoplay.lua`. It runs until the game closes or `/atmoplay quit`; opening the menu or
   loading other scripts doesn't stop it.
3. `/lm` a playable mod: its atmo is drawn and the map is solid.
4. Loading a normal mod gives you your own atmo back.

Commands: `/atmoplay` (status), `/atmoplay show` (the pool objects in green), `/atmoplay reload` (read the
mod again), `/atmoplay log` (a debug log of every frame, slow), `/atmoplay hold` (the pool stops moving),
`/atmoplay quit`.

## Replays

The game records every move of the pools in the replay, so replays collide the way the fight did by
themselves, with seeking. Atmo Play only draws the atmo in them (and the props where they are): without it
a replay still plays right, the map just isn't drawn.

- Atmo Play moves nothing in replays. A replay of a fight that wasn't finished (R in the middle of a
  fight, or a replay saved then) plays the moves made so far; the frames after them, which nobody played,
  have no pools: tori fall through the map there.
- A mod with props turns the replay cache off while it's loaded (cached replays misplace the props); your
  setting comes back when another mod loads.

## Making playable mods

With MGE (Mod Group Editor): **World → Playable: On**, then Save. While it's On, fights in the editor are
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
