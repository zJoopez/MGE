# Atmo Play

Plays **playable atmo mods**: maps far bigger than the 256 objects a mod can hold, made solid. A playable
mod carries its atmo (thousands of objects, only drawn) together with a pool of hidden objects; Atmo Play
moves that pool onto the atmo objects next to each player, every frame of a fight.

## Use

1. Unzip into `data/script` (you get `data/script/atmoplay/`).
2. `/ls atmoplay/atmoplay.lua`. It runs until the game closes or `/atmoplay quit`; opening the menu or
   loading other scripts doesn't stop it.
3. `/lm` a playable mod: its atmo is drawn and the map is solid.
4. Loading a normal mod gives you your own atmo back.

Commands: `/atmoplay` (status), `/atmoplay show` (the pool objects in green), `/atmoplay reload` (read the
mod again), `/atmoplay quit`.

## Replays

The game records every move of the pool in the replay, so replays collide the way the fight did by
themselves, cached or not, with seeking. Atmo Play only draws the atmo in them: without it a replay
still plays right, the map just isn't drawn.

## Making playable mods

With MGE (Mod Group Editor): **Atmo list → Advanced → Playable: On**, then Save. While it's On, fights in the editor are
solid the same way. While MGE is open, Atmo Play leaves playable mods to it.

## Limits

- A viewer needs the playable mod file; it isn't on the game's server.
- Single player only: in multiplayer the server decides the physics.
- Solid are boxes, spheres and capsules. Custom models, random (`count`, `rpos`, `rsize`), animated and
  parented atmo objects are only drawn.
