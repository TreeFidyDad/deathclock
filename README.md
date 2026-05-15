# deathclock

FFXI respawn timer + 3D return-arc HUD for HorizonXI, extracted from huntpartner v0.7.93 so respawn can be reloaded independently.

## What it does

- **Tracks mob deaths** via HPP-scan (no packet hooks, no chat scrape — watches the entity table for HP 0→prev>0 transitions on mob entities).
- **Predicts respawn** using a configurable default window (349s — measured for HorizonXI claim mobs) and per-name overrides.
- **Color-tiered ETA bars** — red while waiting, yellow at ≤60s, green when ready.
- **Urgent banner** for same-zone yellow-tier rows: compass direction + yalms to where it dropped, so you can sprint the run-back even when the attack menu blocks `/compass`.
- **3D return-arcs** drawn from your character to the death spot, colored by a 5-band palette (vendored from `targetlines`).
- **Session-only ignore set** to mute noise mobs (`/dc ignore Svana Rarab`) without persisting the choice across reloads.

## Commands

```
/dc                          toggle window
/dc show | hide
/dc list                     print pending kills + ETAs
/dc clear [Name]             clear all, or just this mob
/dc add "Mob Name" <secs>    per-mob respawn override
/dc default <secs>           change global default
/dc ignore [Name]            mute this mob for the session
/dc unignore [Name]          unmute
/dc lines                    toggle 3D return-arcs
/dc all                      toggle arc-visibility threshold between 100% and 25%
/dc test                     drop a TestMob entry to verify rendering
/rt <subcmd>                 alias for /dc <subcmd>
```

## First-load migration

If you previously ran the respawn feature inside `huntpartner` and have an `addons/huntpartner/settings/settings.xml` on disk, deathclock will lift over `default_respawn`, `keep_dead_after_respawn`, `track_respawns`, `respawn_lines`, `respawn_lines_show_all`, and per-mob `overrides` on first load. Best-effort; sets a one-shot sentinel so it doesn't retry.

## Why a separate addon

huntpartner reloads frequently during development. A single Lua error in any of its features unloads the entire addon — taking respawn tracking down with it. Deathclock isolates the respawn surface so an unrelated huntpartner reload doesn't wipe your in-flight kill timers.

## Provenance

- Extracted from [huntpartner](../huntpartner/) v0.7.93.
- `vendor/targetlines/` (the `drawArc` machinery) is vendored from the targetlines addon — see `vendor/targetlines/NOTICE.md` for attribution.
