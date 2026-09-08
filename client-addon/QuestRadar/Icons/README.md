# Icons/

`glow.blp` — a round texture with a soft (gradient) edge, used by
`Minimap.lua` to draw an objective's translucent "area" (tinted blue via
`Texture:SetVertexColor`).

Pulled as-is (a binary `.blp` file, no code) from
[Questie-335](https://github.com/divial28/Questie-335) (`Icons/glow.blp`), a
Questie fork explicitly aiming for compatibility with a genuine WotLK
3.3.5.12340 client — the same one this module targets. Questie is
distributed under the GPL-3.0 license; if you redistribute this module
publicly, check that this use fits your case (attribution kept here).

## Why an image rather than a solid color

An earlier version drew the area with a plain solid color
(`Texture:SetTexture(r,g,b,a)`, no file). Problem observed in-game: WoW
3.3.5 has no native circular clip for addon textures — a square large
enough always pokes out of the minimap's circle, whatever its size (that's
geometry, not a setting). A real already-round image with a soft edge
avoids this problem.
