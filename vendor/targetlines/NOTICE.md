# Vendored: Jyouya/targetlines drawArc machinery

This directory contains a vendored copy of the 3D arc-rendering code from
the `targetlines` Ashita addon by Jyouya. It powers the optional in-world
"return-to-kill-spot" arcs drawn by huntpartner when a respawn enters the
yellow tier.

## Files

- `drawArc.lua` — bezier-curve arc renderer in 3D world-space. Calls into
  D3D8 directly via the d3d8 binding and a packed FFI vertex format.
  Patched two paths from the upstream: (1) `require('helpers')` →
  `require('tl_helpers')` to avoid collision with HXUI's `helpers.lua`,
  and (2) asset paths now resolve to `vendor/targetlines/assets/...` so
  textures load from this folder instead of the addon root.
- `tl_helpers.lua` — matrix math, world-to-screen projection, bone
  position read, texture loader, vector rotation. Renamed from upstream
  `helpers.lua` to avoid the namespace collision noted above. Otherwise
  byte-identical to upstream.
- `Bezier3D_2.lua` — cubic bezier helper used by drawArc to interpolate
  the arc curve. Byte-identical to upstream.
- `assets/beam.png` — the line texture sampled by drawArc.
- `assets/orb.png` — the endpoint orb texture (only drawn when the `orb`
  arg to drawArc is truthy; huntpartner currently does not enable it).

## Source

Vendored from the `targetlines` Ashita addon by **Jyouya**, version 1.2,
as shipped in the HorizonXI Ashita addon bundle. No explicit LICENSE
file accompanied the upstream copy. The repository owner (TreeFidyDad)
has made the call to vendor under standard Ashita-community sharing
norms, with prominent attribution here. If Jyouya prefers different
terms, contact will be made and this vendor folder updated or removed.

## Why vendored

`require`-ing across Ashita addon boundaries is fragile — the Lua
package.path for each loaded addon is scoped to that addon's folder,
and a player who doesn't have `targetlines` loaded would get a hard
crash on the cross-addon require. Vendoring is the boring path: huntpartner
ships everything it needs to render arcs and doesn't depend on another
addon being present.
