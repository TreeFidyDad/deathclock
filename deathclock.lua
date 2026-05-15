addon.name      = 'deathclock'
addon.author    = 'Blake & Watney'
addon.version   = '0.3.20'
addon.desc      = 'FFXI respawn timers: tracks mob deaths, predicts pops, draws return-arcs to the kill spot.'
addon.commands  = { '/dc', '/rt' }

-- Extracted from huntpartner v0.7.93 so the respawn feature can be reloaded
-- independently of the rest of the hunt UI. Same death-detection (HPP-scan),
-- same urgency colors (red > yellow > green), same drawArc return-lines.

require('common')
local chat     = require('chat')
local settings = require('settings')
local imgui    = require('imgui')

-- Vendored targetlines drawArc machinery for in-world respawn return-lines.
-- See vendor/targetlines/NOTICE.md for source/attribution. Loaded under
-- pcall so a binding mismatch on d3d8/ffi can't keep deathclock from
-- loading at all -- without drawArc, lines just don't render and every
-- other feature still works.
local _tl_root = string.format('%s\\vendor\\targetlines', addon.path)
package.path = string.format('%s\\?.lua;%s', _tl_root, package.path)
local drawArc
do
    local ok, mod = pcall(require, 'drawArc')
    if ok then drawArc = mod end
end
-- Optional: world->screen helper + d3d8 device for arc labels. Same pcall
-- discipline -- if any of these fail to load, labels just don't render
-- and the arc itself keeps working.
local tl_helpers, d3d8dev, d3dC
do
    local ok, mod = pcall(require, 'tl_helpers')
    if ok then tl_helpers = mod end
    local ok2, d3d8 = pcall(require, 'd3d8')
    if ok2 then
        local okdev, dev = pcall(d3d8.get_device)
        if okdev then d3d8dev = dev end
    end
    local ok3, ffi = pcall(require, 'ffi')
    if ok3 then d3dC = ffi.C end
end

----------------------------------------------------------------
-- persisted config
----------------------------------------------------------------
local default_settings = T{
    window = T{
        visible = true,
        x = 100,
        y = 100,
        w = 340,
    },
    -- 5m 49s -- measured on HorizonXI for claim mobs.
    default_respawn         = 349,
    overrides               = T{},
    keep_dead_after_respawn = 30,
    track_respawns          = true,
    respawn_lines           = true,
    -- (legacy `respawn_lines_show_all` intentionally NOT in defaults -- its
    -- presence in a loaded XML is the signal that the user predates v0.2.0
    -- and needs the arc_show_below_pct migration.)

    -- Color bands keyed by % ELAPSED of the respawn window. Red = freshly
    -- killed (cooling corpse), bands cool through orange/yellow/green/blue
    -- as the timer matures, then purple at ready (eta <= 0) for "pop time."
    -- Thermometer-inverted-into-spectral, very FFXI-flavored.
    -- ImGui RGB floats 0-1. Alpha is not user-editable: bars use 1.0, arcs
    -- use 0.75 to read over terrain without becoming a blinding overlay.
    colors = T{
        red    = T{ 1.00, 0.33, 0.33 },
        orange = T{ 1.00, 0.60, 0.20 },
        yellow = T{ 1.00, 0.93, 0.27 },
        green  = T{ 0.40, 0.85, 0.55 },
        blue   = T{ 0.35, 0.55, 1.00 },
        purple = T{ 0.80, 0.40, 1.00 },
    },
    -- How many color bands are active. 1 = single color always. 2 = one
    -- timer color plus a distinct "ready" color (eta<=0). 3-6 = spectrum
    -- across the timer with the final slot reserved for ready. Each slot
    -- is independently recolorable, so any palette (monochrome, black/
    -- white/brown, autumn, whatever) is achievable.
    color_count = 6,
    -- Thresholds are the LOWER bound (% of total respawn ELAPSED) for each
    -- band beyond the first. Going up: >= purple → purple, >= blue → blue,
    -- ..., otherwise red. Must stay monotonically increasing; clamped on
    -- slider edit. Red is the floor (no slider). Purple's default of 100
    -- means "only at pop time (eta<=0)" -- the final band always kicks in
    -- at pop regardless of its threshold, but you can drag this lower for
    -- an early-warning color (e.g. 90 = ready color shows in the last 10%).
    thresholds = T{
        orange = 20,
        yellow = 40,
        green  = 60,
        blue   = 80,
        purple = 100,
    },
    -- In-world arcs render only when pct ELAPSED >= this. 0 = always,
    -- 100 = never (use the on/off toggle for that). A higher value hides
    -- arcs for fresh kills and reveals them as the timer matures.
    arc_show_above_elapsed_pct = 0,
    -- When true, arcs ignore the threshold above and render the moment a
    -- kill is logged. The slider stays in config but is disabled while this
    -- is on. Default true because "always on" is what most users want.
    arc_always_on              = true,
    -- Draw the mob name + eta as a floating text label at the death spot,
    -- following the arc to its endpoint. Off in the rare case the user
    -- doesn't have d3d8/tl_helpers available (graceful fallback).
    arc_labels                 = true,
}

local config = settings.load(default_settings)
-- One-time migration: old huntpartner defaults (300, 345) were less accurate
-- than measured HorizonXI claim-mob respawn. Anyone migrating from huntpartner
-- whose settings happened to carry the legacy value gets the correction
-- without re-running /dc default.
if config.default_respawn == 300 or config.default_respawn == 345 then
    config.default_respawn = 349
    settings.save()
end

-- v0.2.0 migration: legacy boolean `respawn_lines_show_all` becomes the
-- continuous `arc_show_above_elapsed_pct` (was briefly `arc_show_below_pct`
-- in v0.2.0). False (the old default) meant "only green and yellow arcs"
-- -- yellow was eta<=60s, roughly the last 20% of a 349s timer. Map false →
-- show only when elapsed >= 80 (last fifth), true → 0 (always show).
-- Sentinel prevents re-applying.
if not config._arc_pct_migrated then
    config._arc_pct_migrated = true
    if config.respawn_lines_show_all == false then
        config.arc_show_above_elapsed_pct = 80
        config.arc_always_on = false
    end
    settings.save()
end

-- v0.3.10 migration: introduced `arc_always_on` checkbox. Existing users
-- whose slider sat at 0 ("always on") get the checkbox flipped on so
-- behavior is unchanged. Anyone with a non-zero threshold keeps the
-- slider active. Sentinel keyed off the new field's absence in storage.
if config._arc_always_on_migrated == nil then
    config._arc_always_on_migrated = true
    config.arc_always_on = ((config.arc_show_above_elapsed_pct or 0) <= 0)
    settings.save()
end

-- v0.2.1 migration: flipped the color-band axis from %-remaining to
-- %-elapsed and replaced the "ready" band with "purple". Old v0.2.0 users
-- have `arc_show_below_pct` (inverse semantics) and a `ready` color but no
-- `purple`. Translate cleanly: new_above_elapsed = 100 - old_below_remaining;
-- carry the ready color over as purple if user customized it.
if not config._v021_axis_flip then
    config._v021_axis_flip = true
    if type(config.arc_show_below_pct) == 'number' then
        config.arc_show_above_elapsed_pct = math.max(0, math.min(100, 100 - config.arc_show_below_pct))
        config.arc_show_below_pct = nil
    end
    if config.colors and config.colors.ready and not (config.colors.purple and config.colors.purple[1]) then
        config.colors.purple = config.colors.ready
    end
    if config.colors then config.colors.ready = nil end
    -- v0.2.0 thresholds were %-remaining (blue=75, green=50, yellow=25,
    -- orange=10). Flip to %-elapsed equivalents: 100 - old.
    if config.thresholds then
        local th = config.thresholds
        -- Detect v0.2.0 shape by the presence of blue >= 50 (v0.2.1 default
        -- blue is 80; v0.2.0 default blue is 75 -- both > 50). If the user
        -- never opened the panel, the values match v0.2.0 defaults and
        -- need flipping; if they did customize, we still flip because the
        -- axis itself inverted.
        local looks_like_v020 = (th.blue or 0) > (th.green or 0)
            and (th.green or 0) > (th.yellow or 0)
            and (th.yellow or 0) > (th.orange or 0)
        if looks_like_v020 then
            config.thresholds = T{
                orange = 100 - (th.orange or 10),
                yellow = 100 - (th.yellow or 25),
                green  = 100 - (th.green  or 50),
                blue   = 100 - (th.blue   or 75),
            }
        end
    end
    settings.save()
end

-- First-load migration from huntpartner. If our overrides table is empty AND
-- huntpartner has a settings.xml we can read, lift over default_respawn,
-- overrides, keep_dead_after_respawn, track_respawns, respawn_lines,
-- respawn_lines_show_all. Best-effort: any failure leaves us on fresh
-- defaults. Tracked via a sentinel so we only attempt this once per install.
if not config._hp_migration_attempted then
    config._hp_migration_attempted = true
    pcall(function()
        local hp_path = string.format('%s\\..\\huntpartner\\settings\\settings.xml', addon.path)
        local f = io.open(hp_path, 'r')
        if not f then return end
        local xml = f:read('*a')
        f:close()
        if not xml or xml == '' then return end

        local n = tonumber(xml:match('<default_respawn[^>]*>(%d+)</default_respawn>'))
        if n and n > 0 then config.default_respawn = n end

        local k = tonumber(xml:match('<keep_dead_after_respawn[^>]*>(%d+)</keep_dead_after_respawn>'))
        if k and k > 0 then config.keep_dead_after_respawn = k end

        local tr = xml:match('<track_respawns[^>]*>([%a]+)</track_respawns>')
        if tr then config.track_respawns = (tr:lower() == 'true') end

        local rl = xml:match('<respawn_lines[^>]*>([%a]+)</respawn_lines>')
        if rl then config.respawn_lines = (rl:lower() == 'true') end

        local sa = xml:match('<respawn_lines_show_all[^>]*>([%a]+)</respawn_lines_show_all>')
        if sa then config.respawn_lines_show_all = (sa:lower() == 'true') end

        -- overrides: <overrides><Mob_Name>secs</Mob_Name>...</overrides>
        -- huntpartner's settings lib serializes table keys with spaces as
        -- underscores in tag names; lift them back. Best effort.
        local ov = xml:match('<overrides>(.-)</overrides>')
        if ov then
            for tag, val in ov:gmatch('<([%w_]+)[^>]*>(%d+)</%1>') do
                local name = tag:gsub('_', ' ')
                config.overrides[name] = tonumber(val)
            end
        end
    end)
    settings.save()
end

settings.register('settings', 'settings_update', function(s)
    if s ~= nil then config = s end
    settings.save()
end)

local function save() settings.save() end

----------------------------------------------------------------
-- shared helpers
----------------------------------------------------------------
local function now() return os.time() end
local function say(msg) print(chat.header('dc') .. chat.message(msg)) end

local function fmt_eta(secs)
    if secs <= 0 then return 'READY' end
    local m = math.floor(secs / 60)
    local s = secs % 60
    if m > 0 then return ('%dm%02ds'):format(m, s) end
    return ('%ds'):format(s)
end

local function get_zone_id()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0)
end
local function get_zone_name(zone_id)
    return AshitaCore:GetResourceManager():GetString('zones', zone_id) or ('zone_' .. tostring(zone_id))
end

----------------------------------------------------------------
-- RESPAWN TRACKER
----------------------------------------------------------------
local kills    = T{}
-- Last error caught from arc-label rendering. Printed once per unique error
-- by the label block; surfaces via `/dc diag` for cold inspection.
local last_label_err
local last_hpp = T{}
local last_scan = 0
-- Session-only ignore set, keyed by lowercase name. Deliberately not
-- persisted: "I don't care about Svana Rarab right now" is almost always
-- zone-specific or session-specific. Wiping on /lua reload is the feature.
local ignored = {}

local function is_ignored(name)
    return name and ignored[name:lower()] == true
end

local function get_respawn_window(name)
    return config.overrides[name] or config.default_respawn
end

local function record_kill(name, x, y, z)
    if is_ignored(name) then return end
    local t = now()
    local window = get_respawn_window(name)
    table.insert(kills, {
        name       = name,
        killed_at  = t,
        respawn_at = t + window,
        zone       = get_zone_id(),
        x          = x,
        y          = y,
        z          = z,
    })
    say(('%s killed -- respawn in %s'):format(name, fmt_eta(window)))
end

local function scan_for_deaths()
    local entities = AshitaCore:GetMemoryManager():GetEntity()
    for i = 0, 2303 do
        local name  = entities:GetName(i)
        local flags = entities:GetSpawnFlags(i)
        local hpp   = entities:GetHPPercent(i)
        local is_mob = (flags == 16)

        if name and name ~= '' and is_mob then
            local prev = last_hpp[i]
            if prev and prev > 0 and hpp == 0 then
                -- Grab coords while the entity is still in memory. Ashita's
                -- binding uses X (east-west) and Y (north-south) for the
                -- ground plane; Z is altitude. Capture all three for safety
                -- but only X and Y are used for distance/compass. Wrapped
                -- in pcall because death detection should never crash on a
                -- missing position field.
                local x, y, z
                pcall(function()
                    x = entities:GetLocalPositionX(i)
                    y = entities:GetLocalPositionY(i)
                    z = entities:GetLocalPositionZ(i)
                end)
                record_kill(name, x, y, z)
            end
            last_hpp[i] = hpp
        else
            last_hpp[i] = nil
        end
    end
end

local function prune_kills()
    local t = now()
    local cutoff = config.keep_dead_after_respawn
    local kept = T{}
    for _, k in ipairs(kills) do
        if (t - k.respawn_at) <= cutoff then
            table.insert(kept, k)
        end
    end
    kills = kept
end

local function build_respawn_rows()
    local counts = {}
    for _, k in ipairs(kills) do
        counts[k.name] = (counts[k.name] or 0) + 1
    end
    local seen = {}
    local rows = {}
    for _, k in ipairs(kills) do
        seen[k.name] = (seen[k.name] or 0) + 1
        local label = k.name
        if counts[k.name] > 1 then
            label = ('%s #%d'):format(k.name, seen[k.name])
        end
        table.insert(rows, {
            label = label, name = k.name, respawn_at = k.respawn_at, zone = k.zone,
            x = k.x, y = k.y, z = k.z,
        })
    end
    table.sort(rows, function(a, b) return a.respawn_at < b.respawn_at end)
    return rows
end

-- Color band ordering, fresh kill -> ready. Used by color_for() and the
-- config UI. THRESHOLD_ORDER[i] is the lower-bound %-elapsed threshold
-- for the (i+1)-th band. The final band's threshold defaults to 100
-- (only at pop), but the eta<=0 short-circuit in color_for() ensures the
-- last band ALWAYS lights up at pop time, regardless of slider value.
local BAND_ORDER       = { 'red', 'orange', 'yellow', 'green', 'blue', 'purple' }
local THRESHOLD_ORDER  = { 'orange', 'yellow', 'green', 'blue', 'purple' }

-- Resolve the configured color_count into the actual list of band names
-- to use. count=1 -> {red} (single color, no ready distinction).
-- count>=2 -> first (count-1) timer bands + purple as the ready slot.
local function active_bands()
    local n = math.max(1, math.min(6, config.color_count or 6))
    if n == 1 then return { BAND_ORDER[1] } end
    local b = {}
    for i = 1, n - 1 do b[i] = BAND_ORDER[i] end
    b[n] = 'purple'
    return b
end

-- Evenly distribute the *intermediate* thresholds across [0,100] when
-- color_count changes (so going 6 -> 3 yields a 50/50 split instead of a
-- stale 20%). The final band's threshold ('purple', the ready slot) is
-- preserved across count changes -- users tune it deliberately for
-- early-warning timing, and we don't want to clobber that on a recount.
local function redistribute_thresholds(n)
    if n < 3 then return end
    local timer_bands = n - 1
    local th = config.thresholds
    for i = 1, n - 2 do
        th[THRESHOLD_ORDER[i]] = math.floor(100 * i / timer_bands + 0.5)
    end
end

-- Pick the band for a kill based on elapsed fraction of its respawn window.
-- count=1 short-circuits to the single slot. Otherwise eta<=0 forces the
-- last band (pop-time guarantee), then thresholds cascade top-down. The
-- last band's threshold can also fire pre-pop for early-warning colors.
local function color_for(eta, total)
    local bands = active_bands()
    local n = #bands
    if n == 1 then return config.colors[bands[1]] end
    if eta <= 0 then return config.colors[bands[n]] end
    local pct_elapsed
    if total and total > 0 then
        pct_elapsed = math.max(0, math.min(100, (total - eta) / total * 100))
    else
        pct_elapsed = 0
    end
    local th = config.thresholds
    for i = n, 2, -1 do
        local key = THRESHOLD_ORDER[i - 1]
        local floor_pct = th[key] or (key == 'purple' and 100 or 0)
        if pct_elapsed >= floor_pct then return config.colors[bands[i]] end
    end
    return config.colors[bands[1]]
end

-- ImGui RGB floats → drawArc ARGB uint32. Alpha hardcoded to 0xC0 (~75%):
-- matches the original arc alpha and reads over terrain without dominating.
local function rgb_to_argb(c, alpha)
    local a = alpha or 0xC0
    local r = math.floor((c[1] or 0) * 255 + 0.5)
    local g = math.floor((c[2] or 0) * 255 + 0.5)
    local b = math.floor((c[3] or 0) * 255 + 0.5)
    return a * 0x1000000 + r * 0x10000 + g * 0x100 + b
end

-- ImGui draw-list packs as IM_COL32 (ABGR little-endian): a<<24|b<<16|g<<8|r.
-- Different byte order from D3D ARGB; can't reuse rgb_to_argb. Default alpha
-- is full opacity so labels stay legible against terrain.
local function rgb_to_imu32(c, alpha)
    local a = alpha or 0xFF
    local r = math.floor((c[1] or 0) * 255 + 0.5)
    local g = math.floor((c[2] or 0) * 255 + 0.5)
    local b = math.floor((c[3] or 0) * 255 + 0.5)
    return a * 0x1000000 + b * 0x10000 + g * 0x100 + r
end

-- Bars use ImGui PushStyleColor which wants {r,g,b,a}. Wrap the RGB triple
-- with a full-opacity alpha so we don't mutate the stored table.
local function bar_rgba(c)
    return { c[1], c[2], c[3], 1.0 }
end

----------------------------------------------------------------
-- config tab: tracking + arcs toggles, default respawn editor,
-- per-mob overrides, colors & thresholds, arc visibility.
----------------------------------------------------------------
local function draw_config_tab()
    -- Default respawn: input + mm:ss readout + inline reset on one line.
    local dr = { config.default_respawn or 349 }
    imgui.PushItemWidth(90)
    if imgui.InputInt('default respawn (s)', dr, 1, 30) then
        if dr[1] < 1 then dr[1] = 1 end
        if dr[1] > 86400 then dr[1] = 86400 end
        config.default_respawn = dr[1]
        save()
    end
    imgui.PopItemWidth()
    imgui.SameLine()
    imgui.TextDisabled('(' .. fmt_eta(config.default_respawn or 349) .. ')')
    imgui.SameLine()
    if imgui.SmallButton('reset 5m49s') then
        config.default_respawn = 349
        save()
    end

    imgui.Separator()

    -- Tracking + arcs checkboxes share a row to save vertical space.
    local tr = { config.track_respawns }
    if imgui.Checkbox('tracking', tr) then
        config.track_respawns = tr[1]; save()
    end
    if drawArc then
        imgui.SameLine()
        local rl = { config.respawn_lines }
        if imgui.Checkbox('return arcs', rl) then
            config.respawn_lines = rl[1]; save()
        end
        if tl_helpers and d3d8dev and d3dC then
            imgui.SameLine()
            local al = { config.arc_labels }
            if imgui.Checkbox('labels', al) then
                config.arc_labels = al[1]; save()
            end
        end
        -- "always" toggle bypasses the threshold below. When checked, the
        -- slider/secs row is replaced by a short status line so the config
        -- tab stays compact.
        local ao = { config.arc_always_on }
        if imgui.Checkbox('always show arcs', ao) then
            config.arc_always_on = ao[1]; save()
        end
        if config.arc_always_on then
            imgui.SameLine()
            imgui.TextDisabled('(threshold disabled)')
        else
            -- Arc visibility threshold. Slider + paired seconds InputInt
            -- (against default respawn) so users can reason in either unit.
            local total = math.max(1, config.default_respawn or 349)
            local pct   = math.max(0, math.min(100, config.arc_show_above_elapsed_pct or 0))
            local v = { pct }
            imgui.PushItemWidth(110)
            if imgui.SliderInt('##arc_pct', v, 0, 100, 'arc: %d%% elapsed') then
                config.arc_show_above_elapsed_pct = v[1]; save()
            end
            imgui.PopItemWidth()
            imgui.SameLine()
            local remaining = math.floor(total * (1 - pct / 100) + 0.5)
            local rv = { remaining }
            imgui.PushItemWidth(55)
            if imgui.InputInt('##arc_secs', rv, 0, 0) then
                if rv[1] < 0 then rv[1] = 0 end
                if rv[1] > total then rv[1] = total end
                config.arc_show_above_elapsed_pct = math.floor((1 - rv[1] / total) * 100 + 0.5)
                save()
            end
            imgui.PopItemWidth()
            imgui.SameLine()
            if pct >= 100 then
                imgui.TextDisabled('s  (only at pop)')
            elseif pct <= 0 then
                imgui.TextDisabled('s  (always on)')
            else
                imgui.TextDisabled(('s  (%s left)'):format(fmt_eta(remaining)))
            end
        end
    end

    -- Keep-pop-visible: how long to keep popped rows in the list.
    do
        local kd = math.max(0, config.keep_dead_after_respawn or 30)
        local kv = { kd }
        imgui.PushItemWidth(60)
        -- step=0 step_fast=0 hides the +/- buttons; with them on at width 55
        -- the buttons ate the digit field and the number was clipped.
        if imgui.InputInt('keep pop visible (s)', kv, 0, 0) then
            if kv[1] < 0 then kv[1] = 0 end
            config.keep_dead_after_respawn = kv[1]; save()
        end
        imgui.PopItemWidth()
        imgui.SameLine()
        if kd <= 0 then
            imgui.TextDisabled('(drops at pop)')
        else
            imgui.TextDisabled(('(%s)'):format(fmt_eta(kd)))
        end
    end

    imgui.Separator()

    -- Per-mob overrides. List sorted alphabetically; each row has a delete
    -- button + inline-editable seconds + mm:ss preview. Use /dc add to
    -- create new entries (cmd line handles quoted names cleanly).
    if imgui.CollapsingHeader('per-mob overrides') then
        local names = {}
        for n, _ in pairs(config.overrides or {}) do table.insert(names, n) end
        table.sort(names)
        if #names == 0 then
            imgui.TextDisabled('none. add via:  /dc add "Mob Name" <secs>')
        else
            for _, name in ipairs(names) do
                imgui.PushID('ov_' .. name)
                if imgui.SmallButton('x') then
                    config.overrides[name] = nil
                    save()
                    imgui.PopID()
                else
                    imgui.SameLine()
                    local v = { config.overrides[name] or 0 }
                    imgui.PushItemWidth(80)
                    if imgui.InputInt('##secs', v, 0, 0) then
                        if v[1] < 1 then v[1] = 1 end
                        config.overrides[name] = v[1]
                        save()
                    end
                    imgui.PopItemWidth()
                    imgui.SameLine()
                    imgui.Text(('%-22s %s'):format(name, fmt_eta(config.overrides[name] or 0)))
                    imgui.PopID()
                end
            end
            imgui.TextDisabled('add more via:  /dc add "Mob Name" <secs>')
        end
    end

    -- Colors & thresholds. Bands run by % ELAPSED of the respawn window:
    -- red = fresh kill (cooling corpse) cools through orange/yellow/green/
    -- blue as time matures, then purple at ready. Click any swatch to repaint.
    if imgui.CollapsingHeader('colors & thresholds') then
        local nn = { math.max(1, math.min(6, config.color_count or 6)) }
        imgui.PushItemWidth(110)
        if imgui.SliderInt('color count', nn, 1, 6) then
            config.color_count = nn[1]
            redistribute_thresholds(nn[1])
            save()
        end
        imgui.PopItemWidth()
        imgui.Separator()

        local bands = active_bands()
        local n = #bands
        local th = config.thresholds
        local total_secs = math.max(1, config.default_respawn or 349)

        -- Seed any nil threshold values so sliders don't read garbage on
        -- first display (older configs predate the purple threshold).
        if n >= 2 then
            for i = 1, n - 1 do
                local k = THRESHOLD_ORDER[i]
                if th[k] == nil then
                    th[k] = (k == 'purple') and 100 or 0
                end
            end
        end

        -- Clamp pass: enforce strict monotonic increase from the bottom
        -- up, then ceiling-cap from the top down so high-end sliders
        -- can't pin everything against 100 and force lower ones into
        -- invalid territory. The final slider (ready band) gets 100 as
        -- its ceiling so "only at pop" stays reachable.
        local function clamp_thresholds()
            local keys = {}
            for i = 1, n - 1 do keys[i] = THRESHOLD_ORDER[i] end
            for i = 2, #keys do
                local prev_k, k = keys[i-1], keys[i]
                if th[k] <= th[prev_k] then th[k] = th[prev_k] + 1 end
            end
            local last_idx = #keys
            if last_idx >= 1 and th[keys[last_idx]] > 100 then th[keys[last_idx]] = 100 end
            local ceiling = 99
            for i = last_idx - 1, 1, -1 do
                local k = keys[i]
                if th[k] > ceiling then th[k] = ceiling end
                ceiling = ceiling - 1
            end
        end

        -- One row per band: swatch + slider + seconds InputInt + role tag.
        -- We drop the color-name label (red/orange/...) since those names
        -- become a lie the moment the user recolors a swatch. Role tags
        -- ('Fresh Kill', 'Ready') and the visible mm:ss are the durable
        -- semantics. First band is the implicit 0% floor (no controls).
        for i, name in ipairs(bands) do
            local c = config.colors[name]
            if c then
                local tmp = { c[1], c[2], c[3] }
                imgui.PushID('band_' .. name)
                -- ImGuiColorEditFlags_NoInputs (1<<5 = 32): hide R/G/B
                -- numeric fields, leaving just the clickable swatch. The
                -- full picker (HSV/hex/wheel) still opens on click.
                if imgui.ColorEdit3('##swatch', tmp, 32) then
                    config.colors[name] = T{ tmp[1], tmp[2], tmp[3] }; save()
                end
                imgui.SameLine()

                if n == 1 then
                    imgui.Text('always')
                elseif i == 1 then
                    imgui.Text('Fresh Kill')
                else
                    local key = THRESHOLD_ORDER[i - 1]
                    local hi  = (i == n) and 100 or 99
                    local v = { th[key] }
                    imgui.PushItemWidth(90)
                    if imgui.SliderInt('##sl_' .. key, v, 1, hi, '%d%%') then
                        th[key] = v[1]; clamp_thresholds(); save()
                    end
                    imgui.PopItemWidth()
                    imgui.SameLine()
                    local cur_pct   = th[key] or 0
                    local remaining = math.floor(total_secs * (1 - cur_pct / 100) + 0.5)
                    local rv = { remaining }
                    imgui.PushItemWidth(50)
                    if imgui.InputInt('##secs_' .. key, rv, 0, 0) then
                        if rv[1] < 0 then rv[1] = 0 end
                        if rv[1] > total_secs then rv[1] = total_secs end
                        local new_pct = math.floor((1 - rv[1] / total_secs) * 100 + 0.5)
                        if new_pct < 1   then new_pct = 1   end
                        if new_pct > hi  then new_pct = hi  end
                        th[key] = new_pct; clamp_thresholds(); save()
                    end
                    imgui.PopItemWidth()
                    imgui.SameLine()
                    local final_pct = th[key] or 0
                    local final_rem = math.floor(total_secs * (1 - final_pct / 100) + 0.5)
                    if i == n and final_pct >= 100 then
                        imgui.TextDisabled('s  Ready (only at pop)')
                    elseif i == n then
                        imgui.TextDisabled(('s  Ready (%s left)'):format(fmt_eta(final_rem)))
                    else
                        imgui.TextDisabled(('s  (%s left)'):format(fmt_eta(final_rem)))
                    end
                end
                imgui.PopID()
            end
        end

        if imgui.SmallButton('reset colors & thresholds') then
            config.colors = T{
                red    = T{ 1.00, 0.33, 0.33 },
                orange = T{ 1.00, 0.60, 0.20 },
                yellow = T{ 1.00, 0.93, 0.27 },
                green  = T{ 0.40, 0.85, 0.55 },
                blue   = T{ 0.35, 0.55, 1.00 },
                purple = T{ 0.80, 0.40, 1.00 },
            }
            config.thresholds = T{ orange = 20, yellow = 40, green = 60, blue = 80, purple = 100 }
            config.color_count = 6
            config.arc_show_above_elapsed_pct = 0
            save()
        end
    end
end

----------------------------------------------------------------
-- kills tab: live respawn list. The tracking toggle stays here too
-- so it's one click away from the data it controls.
----------------------------------------------------------------
local function draw_kills_tab()
    local tr = { config.track_respawns }
    if imgui.Checkbox('tracking', tr) then
        config.track_respawns = tr[1]; save()
    end

    if not config.track_respawns then
        imgui.TextDisabled('clocked out')
        return
    end

    local rows = build_respawn_rows()
    if #rows == 0 then
        imgui.TextDisabled('no kills yet')
        return
    end
    local t = now()
    local cur_zone = get_zone_id()

    -- Player position via party-member-0 target index (the local player's
    -- actual entity index -- slot 0 of the entity table is unreliable).
    -- FFXI/Ashita convention: +X = east, -X = west, +Y = north, -Y = south.
    local px, py
    pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty()
        local entities = AshitaCore:GetMemoryManager():GetEntity()
        local pidx = party:GetMemberTargetIndex(0)
        if pidx and pidx > 0 then
            px = entities:GetLocalPositionX(pidx)
            py = entities:GetLocalPositionY(pidx)
        end
    end)

    -- 8-way compass. Absolute bearings (N is map-north), not facing-relative;
    -- the in-game /compass already gives the reference frame. Plain text
    -- labels because the default imgui font doesn't reliably render arrow glyphs.
    local COMPASS_ARROWS = { 'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW' }
    local function compass_dir(dx, dy)
        local angle = math.atan2(dx, dy)
        if angle < 0 then angle = angle + 2 * math.pi end
        local bucket = math.floor((angle / (math.pi / 4)) + 0.5) % 8
        return COMPASS_ARROWS[bucket + 1]
    end

    -- Urgent banner: same-zone rows in the yellow tier (eta <= 60) get their
    -- direction+distance promoted above the row list. The in-game /compass
    -- gets blocked by the attack menu mid-fight; this banner stays visible.
    -- Capped at 3 so a synchronized respawn wave doesn't fill the window.
    local urgent = {}
    if px and py then
        for _, r in ipairs(rows) do
            local eta = r.respawn_at - t
            if eta <= 60 and r.zone == cur_zone and r.x and r.y then
                local dx = r.x - px
                local dy = r.y - py
                local dist = math.sqrt(dx*dx + dy*dy)
                table.insert(urgent, {
                    label = r.label,
                    eta   = eta,
                    dist  = dist,
                    dir   = compass_dir(dx, dy),
                    ready = eta <= 0,
                })
            end
        end
        table.sort(urgent, function(a, b) return a.eta < b.eta end)
        while #urgent > 3 do table.remove(urgent) end
    end

    if #urgent > 0 then
        for _, u in ipairs(urgent) do
            local color = u.ready and { 0.4, 1.0, 0.4, 1.0 } or { 1.0, 1.0, 0.4, 1.0 }
            local text
            if u.dist >= 5 then
                text = ('-> %s %.0fy  %s'):format(u.dir, u.dist, u.label)
            else
                text = ('* HERE  %s'):format(u.label)
            end
            imgui.TextColored(color, text)
        end
        imgui.Separator()
    end

    for i, r in ipairs(rows) do
        local eta = r.respawn_at - t
        local total = r.respawn_at - (r.respawn_at - get_respawn_window(r.label:gsub(' #%d+$', '')))
        local elapsed = total - eta
        local frac = (total > 0) and math.max(0, math.min(1, elapsed / total)) or 1
        local c = bar_rgba(color_for(eta, total))

        -- Per-row ignore button. Adds the mob to the session ignore set AND
        -- drops every existing entry for it. PushID keeps the button unique
        -- when names repeat across the list.
        imgui.PushID(i)
        if imgui.SmallButton('x') then
            ignored[r.name:lower()] = true
            local kept = T{}
            for _, k in ipairs(kills) do
                if k.name:lower() ~= r.name:lower() then table.insert(kept, k) end
            end
            kills = kept
            say(('ignoring %s this session'):format(r.name))
        end
        imgui.PopID()
        imgui.SameLine()

        imgui.PushStyleColor(ImGuiCol_PlotHistogram, c)
        imgui.ProgressBar(frac, { -1, 14 }, '')
        imgui.PopStyleColor()
        imgui.SameLine(8 + 24)
        -- Near-black text on the colored bar. White vanishes against the
        -- yellow tier and washes out on green; near-black holds contrast
        -- across all three urgency colors.
        local TEXT_DARK = { 0.05, 0.05, 0.05, 1.0 }
        imgui.TextColored(TEXT_DARK, ('%-22s  %s'):format(r.label, fmt_eta(eta)))
        if r.zone ~= cur_zone then
            imgui.SameLine()
            imgui.TextColored(TEXT_DARK, ' (' .. get_zone_name(r.zone) .. ')')
        elseif r.x and r.y and px and py then
            -- Same-zone kill with captured coord: how far from where it
            -- dropped and which way to run. Below 5y, just say HERE so
            -- "on the corpse" reads cleanly without a misleading 2y readout.
            local dx = r.x - px
            local dy = r.y - py
            local dist = math.sqrt(dx*dx + dy*dy)
            local suffix
            if dist >= 5 then
                suffix = (' %.0fy %s'):format(dist, compass_dir(dx, dy))
            else
                suffix = ' HERE'
            end
            imgui.SameLine()
            imgui.TextColored(TEXT_DARK, suffix)
        end
    end
end

----------------------------------------------------------------
-- top-level: tab bar
----------------------------------------------------------------
local function draw_respawn_body()
    if imgui.BeginTabBar('dc_tabs') then
        if imgui.BeginTabItem('kills') then
            draw_kills_tab()
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('config') then
            draw_config_tab()
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end
end

----------------------------------------------------------------
-- window + d3d_present
----------------------------------------------------------------
local function draw_window()
    if not config.window.visible then return end
    imgui.SetNextWindowSize({ config.window.w, 0 }, ImGuiCond_FirstUseEver)
    imgui.SetNextWindowPos({ config.window.x, config.window.y }, ImGuiCond_FirstUseEver)
    -- ImGuiWindowFlags_AlwaysAutoResize (1<<6 = 64): the window shrink-
    -- wraps its current content every frame. Switching tabs (kills vs
    -- config) or collapsing/expanding the colors panel resizes the
    -- window to match, so the empty kills tab is no longer huge.
    if imgui.Begin('Deathclock', true, 64) then
        draw_respawn_body()
        local px, py = imgui.GetWindowPos()
        if px ~= config.window.x or py ~= config.window.y then
            config.window.x = px; config.window.y = py; save()
        end
    end
    imgui.End()
end

ashita.events.register('d3d_present', 'dc_present_cb', function()
    local t = os.clock()
    if t - last_scan >= 0.5 then
        last_scan = t
        if config.track_respawns then
            scan_for_deaths()
            prune_kills()
        end
    end
    draw_window()
end)

-- Yellow-tier return-arcs: when a kill enters its last 60s before respawn
-- (or is already ready), draw a 3D arc from player to death spot so the
-- run-back vector is visible in-world without relying on /compass (which
-- the attack menu blocks during a fight). pcall'd because any error in
-- d3d_present unloads the whole addon, and an in-world cosmetic feature
-- is never worth taking everything else down.
ashita.events.register('d3d_present', 'dc_return_arcs_cb', function()
    if not drawArc then return end
    if not config.track_respawns then return end
    if not config.respawn_lines then return end
    pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty()
        local entities = AshitaCore:GetMemoryManager():GetEntity()
        local pidx = party:GetMemberTargetIndex(0)
        if not pidx or pidx <= 0 then return end
        local px = entities:GetLocalPositionX(pidx)
        local py = entities:GetLocalPositionY(pidx)
        local pz = entities:GetLocalPositionZ(pidx)
        if not (px and py and pz) then return end

        local cur_zone = get_zone_id()
        local t = now()
        local thr_pct = config.arc_show_above_elapsed_pct or 0
        for _, k in ipairs(kills) do
            if k.zone == cur_zone and k.x and k.y and k.z then
                local eta = k.respawn_at - t
                local total = k.respawn_at - (k.killed_at or k.respawn_at)
                local pct_elapsed
                if total > 0 then
                    pct_elapsed = math.max(0, math.min(100, (total - eta) / total * 100))
                else
                    pct_elapsed = 100
                end
                local rgb       = color_for(eta, total)
                local show_arc  = eta <= 0
                                  or config.arc_always_on
                                  or pct_elapsed >= thr_pct
                if show_arc then
                    drawArc(px, py, pz, k.x, k.y, k.z, rgb_to_argb(rgb), 1)
                end
                -- Labels are independent of the arc threshold: the mob
                -- name + eta floats over every active death spot the moment
                -- the kill is logged, even when the arc itself is still
                -- hidden by the threshold. Gated only by the `labels`
                -- checkbox and successful d3d8/tl_helpers/ffi loads.
                --
                -- Rendered as a tiny transparent overlay window rather than
                -- a draw-list AddText call: Ashita's imgui binding doesn't
                -- expose GetBackgroundDrawList, so the draw-list approach
                -- silently no-ops. The overlay window pattern works on every
                -- ImGui binding and inherits the addon's font for free.
                if config.arc_labels and tl_helpers and d3d8dev and d3dC then
                    local ok, err = pcall(function()
                        local _, view = d3d8dev:GetTransform(d3dC.D3DTS_VIEW)
                        local _, proj = d3d8dev:GetTransform(d3dC.D3DTS_PROJECTION)
                        -- Replicate drawArc's apex math so the label sits on
                        -- the *visible* peak of the bezier, not on the
                        -- ground midpoint. drawArc builds an initial P1 at
                        -- the linear midpoint, then rotates (P1 - P0) by
                        -- pi/16 around the unit player->target axis. That
                        -- rotation is what lifts the curve off the ground;
                        -- without it the label projects underground.
                        --
                        -- Axes are swapped to D3D convention (x, alt, depth)
                        -- in the same way drawArc.lua does at line 60-61.
                        local zoom = (2.8 - proj._11) * 0.47619047619
                        local P0x, P0y, P0z = px,  pz,  py
                        local P2x, P2y, P2z = k.x, k.z, k.y
                        local P1x = (P0x + P2x) / 2
                        local P1y = (P0y + P2y) / 2 - 2 - 2 * zoom
                        local P1z = (P0z + P2z) / 2

                        -- Rodrigues rotation of v=(P1-P0) around the unit
                        -- axis k=normalize(P2-P0) by pi/16 (matches the
                        -- `flip=true` branch in tl_helpers.rotateVector16).
                        local vx, vy, vz = P1x - P0x, P1y - P0y, P1z - P0z
                        local ax, ay, az = P2x - P0x, P2y - P0y, P2z - P0z
                        local alen = math.sqrt(ax*ax + ay*ay + az*az)
                        if alen > 1e-6 then
                            ax, ay, az = ax / alen, ay / alen, az / alen
                        end
                        local ang = math.pi / 16
                        local s, c = math.sin(ang), math.cos(ang)
                        local kv  = ax*vx + ay*vy + az*vz
                        local kvc = kv * (1 - c)
                        local rx = vx * c + (ay*vz - az*vy) * s + ax * kvc
                        local ry = vy * c + (az*vx - ax*vz) * s + ay * kvc
                        local rz = vz * c + (ax*vy - ay*vx) * s + az * kvc
                        P1x, P1y, P1z = rx + P0x, ry + P0y, rz + P0z

                        -- Bezier(0.5) = 0.25*P0 + 0.5*P1 + 0.25*P2.
                        local mx = 0.25 * P0x + 0.5 * P1x + 0.25 * P2x
                        local my = 0.25 * P0y + 0.5 * P1y + 0.25 * P2y
                        local mz = 0.25 * P0z + 0.5 * P1z + 0.25 * P2z

                        local sx, sy, sz = tl_helpers.worldToScreen(mx, my, mz, view, proj)
                        if sx and sz and sz > 0 and sz < 1 then
                            local label = (eta <= 0)
                                and ('%s  READY'):format(k.name)
                                or  ('%s  %s'):format(k.name, fmt_eta(math.floor(eta)))
                            local FLAGS = 13263
                            local wid   = ('##dclbl_%d_%s'):format(k.killed_at or 0, k.name or '')
                            imgui.SetNextWindowPos({ sx + 6, sy - 8 })
                            if imgui.Begin(wid, true, FLAGS) then
                                imgui.TextColored({ rgb[1], rgb[2], rgb[3], 1.0 }, label)
                            end
                            imgui.End()
                        end
                    end)
                    if not ok and err ~= last_label_err then
                        last_label_err = err
                        print(chat.header('dc'):append(chat.error('label err: ' .. tostring(err))))
                    end
                end
            end
        end
    end)
end)

----------------------------------------------------------------
-- commands
-- /dc                          toggle window
-- /dc show | hide
-- /dc list | clear [Name] | add "Name" <secs> | default <secs>
-- /dc ignore [Name] | unignore [Name]
-- /dc lines | all
-- /dc test
-- /rt <subcmd>                 same as /dc <subcmd>
----------------------------------------------------------------
local function cmd_list()
    local rows = build_respawn_rows()
    if #rows == 0 then say('no kills logged yet'); return end
    local t = now()
    for _, r in ipairs(rows) do
        local eta = r.respawn_at - t
        local marker = (eta <= 0) and '[READY]'
                    or (eta <= 60) and '[soon] '
                    or '[wait] '
        say(('%s %-30s %s'):format(marker, r.label, fmt_eta(eta)))
    end
end

local function cmd_clear(name)
    if not name or name == '' then
        kills = T{}
        say('cleared all kills')
    else
        local kept = T{}
        for _, k in ipairs(kills) do
            if k.name:lower() ~= name:lower() then table.insert(kept, k) end
        end
        kills = kept
        say(('cleared kills for %s'):format(name))
    end
end

local function cmd_add(rest)
    local name, secs = rest:match('^"([^"]+)"%s+(%d+)$')
    if not name then say('usage: add "Mob Name" <seconds>'); return end
    config.overrides[name] = tonumber(secs)
    save()
    say(('override: %s = %ds'):format(name, secs))
end

local function cmd_default(arg)
    local secs = tonumber(arg)
    if not secs then say('usage: default <seconds>'); return end
    config.default_respawn = secs
    save()
    say(('default respawn = %ds'):format(secs))
end

local function cmd_ignore(name)
    if not name or name == '' then
        local any = false
        for n, _ in pairs(ignored) do any = true; say('  ' .. n) end
        if not any then say('no ignored mobs this session') end
        return
    end
    ignored[name:lower()] = true
    local kept = T{}
    for _, k in ipairs(kills) do
        if k.name:lower() ~= name:lower() then table.insert(kept, k) end
    end
    kills = kept
    say(('ignoring %s this session'):format(name))
end

local function cmd_unignore(name)
    if not name or name == '' then
        ignored = {}
        say('cleared session ignore list')
    else
        ignored[name:lower()] = nil
        say(('no longer ignoring %s'):format(name))
    end
end

local function help()
    say('/dc                        toggle window')
    say('/dc show | hide')
    say('/dc list | clear [Name] | add "Name" <s> | default <s>')
    say('/dc ignore [Name] | unignore [Name]')
    say('/dc lines | all | test')
    say('alias: /rt <subcmd>')
end

local function handle(args, raw, prefix_word_count)
    local sub = args[prefix_word_count + 1]
    sub = sub and sub:lower() or nil
    if not sub then
        config.window.visible = not config.window.visible
        save()
        say('window ' .. (config.window.visible and 'shown' or 'hidden'))
        return
    end
    if sub == 'show' then
        config.window.visible = true; save(); say('window shown')
    elseif sub == 'hide' then
        config.window.visible = false; save(); say('window hidden')
    elseif sub == 'list' then
        cmd_list()
    elseif sub == 'clear' then
        cmd_clear(args[prefix_word_count + 2])
    elseif sub == 'add' then
        local strip = 0
        for i = 1, prefix_word_count + 1 do
            strip = strip + #args[i] + 1
        end
        cmd_add(raw:sub(strip + 1))
    elseif sub == 'default' then
        cmd_default(args[prefix_word_count + 2])
    elseif sub == 'ignore' then
        local strip = 0
        for i = 1, prefix_word_count + 1 do
            strip = strip + #args[i] + 1
        end
        cmd_ignore(raw:sub(strip + 1))
    elseif sub == 'unignore' then
        local strip = 0
        for i = 1, prefix_word_count + 1 do
            strip = strip + #args[i] + 1
        end
        cmd_unignore(raw:sub(strip + 1))
    elseif sub == 'test' then
        record_kill('TestMob')
    elseif sub == 'lines' then
        config.respawn_lines = not config.respawn_lines
        save()
        say(('return arcs: %s'):format(config.respawn_lines and 'on' or 'off'))
    elseif sub == 'all' then
        -- Legacy /dc all → toggle between "show every arc" and "show only
        -- the last quarter". Maps onto the new continuous threshold.
        if (config.arc_show_above_elapsed_pct or 0) <= 0 then
            config.arc_show_above_elapsed_pct = 75
        else
            config.arc_show_above_elapsed_pct = 0
        end
        save()
        say(('arcs visible above: %d%% elapsed'):format(config.arc_show_above_elapsed_pct))
    elseif sub == 'diag' then
        say(('drawArc=%s tl_helpers=%s d3d8dev=%s d3dC=%s'):format(
            tostring(drawArc ~= nil), tostring(tl_helpers ~= nil),
            tostring(d3d8dev ~= nil), tostring(d3dC ~= nil)))
        say(('arc_labels=%s respawn_lines=%s track=%s'):format(
            tostring(config.arc_labels), tostring(config.respawn_lines),
            tostring(config.track_respawns)))
        local cur_zone = get_zone_id()
        local n_total, n_zone = 0, 0
        for _, k in ipairs(kills) do
            n_total = n_total + 1
            if k.zone == cur_zone and k.x and k.y and k.z then n_zone = n_zone + 1 end
        end
        say(('kills: %d total, %d in this zone with positions'):format(n_total, n_zone))
        say(('last label err: %s'):format(tostring(last_label_err)))
    elseif sub == 'help' then
        help()
    else
        help()
    end
end

ashita.events.register('command', 'dc_command_cb', function(e)
    local args = e.command:args()
    if #args == 0 then return end
    local cmd = args[1]:lower()
    if cmd == '/dc' then
        e.blocked = true
        handle(args, e.command, 1)
    elseif cmd == '/rt' then
        e.blocked = true
        handle(args, e.command, 1)
    end
end)

ashita.events.register('load', 'dc_load_cb', function()
    say(('deathclock v%s loaded -- /dc help'):format(addon.version))
end)
