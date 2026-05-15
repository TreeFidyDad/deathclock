addon.name      = 'deathclock'
addon.author    = 'Blake & Watney'
addon.version   = '0.3.27'
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
        bg_alpha = 1.0,
    },
    -- 5m 49s -- measured on HorizonXI for claim mobs.
    default_respawn         = 349,
    overrides               = T{},
    keep_dead_after_respawn = 30,
    track_respawns          = true,
    respawn_lines           = true,
    -- NMs auto-detected via the kill chat message ("Spiny Spipi falls to the
    -- ground" -- no "The " article = NM). `nms[name] = true` is the persistent
    -- flag; `nm_kills[name] = {count, first, last, last_zone}` is the counter.
    -- NMs are tracked here instead of the regular respawn table because their
    -- spawn model (lottery/window/force-pop) doesn't fit a fixed timer.
    nms                     = T{},
    nm_kills                = T{},
    -- Spawn-slot observation log. Server IDs are stable per spawn point in
    -- FFXI; the same slot can host an NM or its placeholder depending on
    -- the lottery outcome. By recording (server_id -> {names_observed}) we
    -- can later infer placeholder relationships: any non-Notorious name
    -- observed in the same slot as a known NM is a PH for it.
    -- Schema: slot_map[server_id_str] = {
    --   zone = zone_id, last_seen = unix_ts,
    --   names = { [mob_name] = { count = N, last = unix_ts } }
    -- }
    -- Server ID is stored as a decimal STRING key (Ashita settings can be
    -- inconsistent with huge int keys; strings round-trip cleanly).
    slot_map                = T{},
    -- When mobdb is installed, look up per-mob Notorious flag
    -- from its zone data files. Toggle off if it causes problems.
    use_mobdb               = true,
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
    -- Per-window font scale applied to each arc label. 1.0 = ImGui's
    -- default; 1.5-2.0 reads comfortably from a normal viewing distance.
    -- Stored as a float and clamped to [0.5, 3.0] in the slider.
    arc_label_scale            = 1.0,
    -- When true, only mobs that were claimed by the player or someone in
    -- the player's party/alliance at time of death are tracked. Skips
    -- random mobs that someone else killed nearby (the noisy default of a
    -- pure HPP-scan). Set false to go back to "track every mob that dies".
    only_my_kills              = true,
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
-- Previous frame's claimer server ID per entity index. We read claim_id
-- from the frame BEFORE death because the claim field commonly clears on
-- the same tick that HPP transitions to 0 -- reading at the death frame
-- often returns 0 (unclaimed) for a mob we actually killed. Carrying the
-- previous frame's value preserves credit.
local last_claim = T{}
local last_scan = 0
-- Session-only ignore set, keyed by lowercase name. Deliberately not
-- persisted: "I don't care about Svana Rarab right now" is almost always
-- zone-specific or session-specific. Wiping on /lua reload is the feature.
local ignored = {}

local function is_ignored(name)
    return name and ignored[name:lower()] ~= nil
end

-- Forward declarations -- promote_to_nm is defined later (it shares helpers
-- with record_nm_kill) but record_kill needs to reach it for mobdb-detected
-- NMs. Declaring `local` here without assignment lets the later `function ...`
-- (no `local`) assign to this slot rather than introduce a new one.
local promote_to_nm
local record_nm_kill

-- ============================================================
-- mobdb integration (optional)
-- ============================================================
-- If the `mobdb` addon is installed, deathclock reads its per-zone mob
-- database to look up the Notorious flag and auto-divert NM kills to the
-- NMs tab. More reliable than the chat-article heuristic and works for
-- the FIRST kill (no race with the entity scanner).
--
-- We deliberately do NOT use mobdb's `Respawn` field. mobdb data is
-- AirSkyBoat/Wings-derived and HorizonXI has tuned respawn timers; the
-- default_respawn here (349s) was measured on HXI and beats mobdb's value
-- for the trash mobs we care about. mobdb is consulted for Notorious only.
--
-- We READ mobdb's data files; we do not require the addon to be loaded.
-- If mobdb is not installed the lookups silently return nil.

local mobdb_zone_cache = {}    -- [zone_id] = data_table  or  false (known-missing)

local function mobdb_load_zone(zone_id)
    if not zone_id or zone_id == 0 then return nil end
    if mobdb_zone_cache[zone_id] ~= nil then
        return mobdb_zone_cache[zone_id] or nil
    end
    local path = string.format('%saddons/mobdb/data/%u.lua', AshitaCore:GetInstallPath(), zone_id)
    local f = io.open(path, 'r')
    if not f then
        mobdb_zone_cache[zone_id] = false
        return nil
    end
    f:close()
    local chunk, err = loadfile(path)
    if not chunk then
        mobdb_zone_cache[zone_id] = false
        return nil
    end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= 'table' or type(data.Names) ~= 'table' then
        mobdb_zone_cache[zone_id] = false
        return nil
    end
    mobdb_zone_cache[zone_id] = data
    return data
end

-- Look up a mob in the current zone's mobdb. Returns the record table or nil.
local function mobdb_lookup(name)
    if not config.use_mobdb then return nil end
    if not name or name == '' then return nil end
    local data = mobdb_load_zone(get_zone_id())
    if not data then return nil end
    return data.Names[name]
end

local function get_respawn_window(name)
    return config.overrides[name] or config.default_respawn
end

local function record_kill(name, server_id, x, y, z)
    if is_ignored(name) then return end
    -- Capture spawn-slot observation BEFORE any early returns. We want
    -- slot data for NMs too -- that's literally the point (knowing a slot
    -- hosted both Crawler and Spiny Spipi is what proves PH relationship).
    if server_id and server_id ~= 0 then
        local key = tostring(server_id)
        config.slot_map = config.slot_map or T{}
        local slot = config.slot_map[key]
        if not slot then
            slot = T{ zone = get_zone_id(), names = T{}, last_seen = 0 }
            config.slot_map[key] = slot
        end
        local n = slot.names[name] or T{ count = 0, last = 0 }
        n.count = (n.count or 0) + 1
        n.last  = now()
        slot.names[name] = n
        slot.last_seen   = now()
        slot.zone        = get_zone_id()
    end
    -- Already-known NM -> handled by the NM tab, not the respawn list.
    if config.nms[name] then return end
    -- New mobdb-detected NM -> promote on the spot. More reliable than the
    -- chat-article heuristic and works for the FIRST kill (no race with the
    -- entity scanner). Chat handler stays as a backstop for kills mobdb missed.
    local rec = mobdb_lookup(name)
    if rec and rec.Notorious then
        promote_to_nm(name)
        return
    end
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
        server_id  = server_id,
    })
    -- PH detection: if this slot has previously hosted a known NM (and the
    -- current kill is not that NM), call it out. Helps the player know
    -- when a lottery candidate just dropped.
    local ph_for = nil
    if server_id and server_id ~= 0 then
        local slot = config.slot_map and config.slot_map[tostring(server_id)]
        if slot and slot.names then
            local nm_names = {}
            for n, _ in pairs(slot.names) do
                if n ~= name and config.nms[n] then
                    table.insert(nm_names, n)
                end
            end
            if #nm_names > 0 then
                ph_for = table.concat(nm_names, ', ')
            end
        end
    end
    if ph_for then
        say(('%s killed -- respawn in %s  [PH for %s]'):format(name, fmt_eta(window), ph_for))
    else
        say(('%s killed -- respawn in %s'):format(name, fmt_eta(window)))
    end
end

-- NM kill recorder. Bumps the counter, marks the name as a known NM so
-- subsequent kills bypass the respawn list entirely. Also retroactively
-- removes any stale `kills` entry the entity-scanner queued for this
-- mob in the last 10 seconds: chat lags entity-scan by ~0.5-1s, so the
-- very first kill of a brand-new NM gets recorded as a respawn before
-- chat fires. This cleanup turns that race into self-correction.
function record_nm_kill(name)
    if not name or name == '' then return end
    if is_ignored(name) then return end

    local first_time = not config.nms[name]
    config.nms[name] = true

    local t_now = now()
    local rec = config.nm_kills[name] or T{ count = 0, first = t_now, last = 0, last_zone = 0 }
    rec.count     = (rec.count or 0) + 1
    rec.first     = rec.first or t_now
    rec.last      = t_now
    rec.last_zone = get_zone_id()
    config.nm_kills[name] = rec

    -- Sweep any respawn-table entry for this name from the last 10s.
    -- Entity-scan races chat-parse on the first-ever NM kill.
    local kept = T{}
    for _, k in ipairs(kills) do
        if not (k.name == name and (t_now - k.killed_at) <= 10) then
            table.insert(kept, k)
        end
    end
    kills = kept

    save()
    if first_time then
        say(('%s flagged as NM (kill #%d). Now tracked in nms tab.'):format(name, rec.count))
    else
        say(('%s (NM) killed -- now at %d kill%s'):format(name, rec.count, rec.count == 1 and '' or 's'))
    end
end

-- Set ToD for an existing NM. `when_spec` may be:
--   "now"          -> current time
--   "<N>"          -> N minutes ago (integer)
--   "HH:MM"        -> today at that local time; if that's in the future,
--                     interpret as yesterday at that time (last night).
-- Returns (ok, new_last_ts, msg).
local function set_nm_tod(name, when_spec)
    if not name or name == '' then return false, 0, 'empty name' end
    local rec = config.nm_kills[name]
    if not rec then return false, 0, ('no NM record for "%s"'):format(name) end
    when_spec = (when_spec or ''):gsub('^%s+',''):gsub('%s+$','')
    local new_ts
    if when_spec == '' or when_spec:lower() == 'now' then
        new_ts = now()
    else
        local hh, mm = when_spec:match('^(%d?%d):(%d%d)$')
        if hh then
            local t = os.date('*t')
            t.hour = tonumber(hh); t.min = tonumber(mm); t.sec = 0
            new_ts = os.time(t)
            if new_ts > now() then new_ts = new_ts - 86400 end -- assume yesterday
        else
            local n = tonumber(when_spec)
            if not n or n < 0 then
                return false, 0, ('bad time spec "%s" -- use now | <minutes> | HH:MM'):format(when_spec)
            end
            new_ts = now() - math.floor(n * 60)
        end
    end
    rec.last      = new_ts
    rec.last_zone = (rec.last_zone and rec.last_zone > 0) and rec.last_zone or get_zone_id()
    config.nm_kills[name] = rec
    save()
    return true, new_ts, nil
end


-- Manual promotion: flag as NM and sweep every kills-tab entry for this name
-- regardless of age. Used by the GUI "NM" button and `/dc nm add <name>`.
function promote_to_nm(name)
    if not name or name == '' then return 0, false end
    local t_now = now()
    local rec = config.nm_kills[name] or T{ count = 0, first = t_now, last = 0, last_zone = 0 }
    local was_new = not config.nms[name]
    config.nms[name] = true
    rec.count     = (rec.count or 0) + 1
    rec.first     = rec.first or t_now
    rec.last      = t_now
    rec.last_zone = get_zone_id()
    config.nm_kills[name] = rec
    local removed = 0
    local kept = T{}
    for _, k in ipairs(kills) do
        if k.name == name then
            removed = removed + 1
        else
            table.insert(kept, k)
        end
    end
    kills = kept
    save()
    return removed, was_new
end

-- Match a kill message and return the bare mob name. NM kill messages in
-- FFXI omit the "The " article (e.g. "Spiny Spipi falls to the ground.")
-- while trash kill messages keep it ("The Spipi falls..."). This is the
-- canonical server-side NM signal that survives translation between message
-- variants. Returns nil if the line isn't a kill message OR the name has
-- a "The "/"the " prefix (= regular mob).
local function parse_nm_kill_message(text)
    if not text or text == '' then return nil end
    -- Strip Ashita's leading color/control bytes (typically 0x1E/0x1F prefix
    -- with optional trailing bytes). Don't try to clean inline codes -- the
    -- mob name itself can't contain control bytes, so a leading trim is
    -- enough for "<name> falls to the ground".
    local s = text:gsub('^[%z\1-\31]+', '')
    -- "<Mob> falls to the ground." is the universal death notification in
    -- FFXI -- fires once per kill regardless of who landed the killing
    -- blow. NM names omit the "The " article ("Spiny Spipi falls...") while
    -- trash keeps it ("The Spipi falls...") -- canonical NM signal.
    local name = s:match('^(.-) falls to the ground')
    if not name or name == '' then return nil end
    name = name:gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then return nil end
    -- Reject articled names (trash mobs).
    if name:sub(1, 4):lower() == 'the ' then return nil end
    return name
end

-- Last claim_id we successfully matched against a party/alliance member.
-- Surfaced via /dc diag so when the filter eats a kill that should have
-- counted, we can compare the seen claim_id to what GetMemberServerId
-- returned (most common drift: 16- vs 32-bit comparison).
local last_seen_claim = 0
local last_seen_player_sid = 0
local last_filter_skip = nil

-- True when claim_id (low 16 bits of GetClaimStatus) belongs to me or to
-- anyone in my party/alliance. Loops 0..17 to cover all 3 alliance parties
-- (18 slots total, matching hpui's pattern). Both sides masked to 16 bits
-- because claim_id is the low 16 of the claimer's 32-bit server ID --
-- comparing without the mask never matches for entities whose high bits
-- are non-zero. Wrapped because the Ashita API can throw on torn reads
-- around zoning.
local function claim_is_mine(claim_id)
    if not claim_id or claim_id == 0 then return false end
    local target = bit.band(claim_id, 0xFFFF)
    local ok, result = pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty()
        for i = 0, 17 do
            if party:GetMemberIsActive(i) == 1 then
                local sid = party:GetMemberServerId(i)
                if sid and bit.band(sid, 0xFFFF) == target then
                    if i == 0 then last_seen_player_sid = sid end
                    return true
                end
            end
        end
        return false
    end)
    return ok and result or false
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
            -- Sample claim each frame regardless of HP transition so we
            -- always have a "previous frame" value ready when death lands.
            local cur_claim
            pcall(function()
                local cs = entities:GetClaimStatus(i)
                if cs then cur_claim = bit.band(cs, 0xFFFF) end
            end)
            if prev and prev > 0 and hpp == 0 then
                -- Credit check: prefer prev-frame claim (often cleared on
                -- the death frame itself). Fall back to current claim if
                -- prev wasn't sampled yet (first-seen-dying edge case).
                local credit_claim = last_claim[i] or cur_claim or 0
                last_seen_claim = credit_claim
                local mine = claim_is_mine(credit_claim)
                if (not config.only_my_kills) or mine then
                    local x, y, z, sid
                    pcall(function()
                        x = entities:GetLocalPositionX(i)
                        y = entities:GetLocalPositionY(i)
                        z = entities:GetLocalPositionZ(i)
                        sid = entities:GetServerId(i)
                    end)
                    record_kill(name, sid, x, y, z)
                else
                    last_filter_skip = ('%s claim=0x%x'):format(name, credit_claim)
                end
            end
            last_hpp[i] = hpp
            last_claim[i] = cur_claim
        else
            last_hpp[i] = nil
            last_claim[i] = nil
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
            x = k.x, y = k.y, z = k.z, server_id = k.server_id,
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

    -- Window background opacity. 1.0 = fully opaque (original behavior),
    -- 0.0 = transparent background (text still draws). Useful for keeping
    -- the kill list visible without obscuring the world behind it.
    local ba = { config.window.bg_alpha or 1.0 }
    imgui.PushItemWidth(120)
    if imgui.SliderFloat('bg opacity', ba, 0.0, 1.0, '%.2f') then
        config.window.bg_alpha = ba[1]
        save()
    end
    imgui.PopItemWidth()

    -- mobdb integration toggle. Off = chat-article heuristic only.
    -- On (default) = consult mobdb for Notorious flag and auto-divert
    -- NM kills to the NMs tab on the first kill (no scanner race).
    -- NOTE: we do NOT use mobdb's Respawn -- the default 349s is measured
    -- on HorizonXI and beats mobdb's retail-era values.
    local um = { config.use_mobdb }
    if imgui.Checkbox('use mobdb (Notorious)', um) then
        config.use_mobdb = um[1]
        if not config.use_mobdb then mobdb_zone_cache = {} end
        save()
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Reads addons/mobdb/data/<zone>.lua at runtime.\nNo-op if mobdb is not installed.')
    end

    imgui.Separator()

    -- Tracking + arcs checkboxes share a row to save vertical space.
    local tr = { config.track_respawns }
    if imgui.Checkbox('tracking', tr) then
        config.track_respawns = tr[1]; save()
    end
    imgui.SameLine()
    local omk = { config.only_my_kills }
    if imgui.Checkbox('only my kills', omk) then
        config.only_my_kills = omk[1]; save()
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Only track mobs claimed by you or your party/alliance at\ntime of death. Skips random mobs killed by others nearby.')
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
            if config.arc_labels then
                imgui.SameLine()
                local sc = { config.arc_label_scale or 1.0 }
                imgui.PushItemWidth(110)
                if imgui.SliderFloat('##label_scale', sc, 0.5, 3.0, 'label x%.2f') then
                    if sc[1] < 0.5 then sc[1] = 0.5 end
                    if sc[1] > 3.0 then sc[1] = 3.0 end
                    config.arc_label_scale = sc[1]; save()
                end
                imgui.PopItemWidth()
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

    -- Diagnostics: live mirror of `/dc diag`, collapsed by default so it
    -- stays out of the way until something misbehaves. Same field set as
    -- the chat dump so debugging notes from chat-paste days still apply.
    imgui.Separator()
    if imgui.CollapsingHeader('diagnostics') then
        local function tf(b) return b and 'on' or 'off' end
        imgui.TextDisabled(('addon v%s'):format(addon.version))
        imgui.Text(('bindings: drawArc=%s tl_helpers=%s d3d8dev=%s d3dC=%s'):format(
            tf(drawArc ~= nil), tf(tl_helpers ~= nil), tf(d3d8dev ~= nil), tf(d3dC ~= nil)))
        imgui.Text(('flags: labels=%s arcs=%s track=%s only_my_kills=%s'):format(
            tf(config.arc_labels), tf(config.respawn_lines),
            tf(config.track_respawns), tf(config.only_my_kills)))

        local cur_zone = get_zone_id()
        local n_total, n_zone = 0, 0
        for _, k in ipairs(kills) do
            n_total = n_total + 1
            if k.zone == cur_zone and k.x and k.y and k.z then n_zone = n_zone + 1 end
        end
        imgui.Text(('kills: %d total, %d in this zone w/ positions'):format(n_total, n_zone))

        local my_sid = 0
        pcall(function()
            my_sid = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0) or 0
        end)
        imgui.Text(('my server id: 0x%x  (low16 = 0x%x)'):format(my_sid, bit.band(my_sid, 0xFFFF)))
        imgui.Text(('last claim seen at death: 0x%x'):format(last_seen_claim or 0))
        imgui.Text(('last filter skip: %s'):format(tostring(last_filter_skip)))
        imgui.Text(('last label err: %s'):format(tostring(last_label_err)))
    end
end

----------------------------------------------------------------
-- kills tab: live respawn list. The tracking toggle stays here too
-- so it's one click away from the data it controls.
----------------------------------------------------------------
-- PH lookup helper for the kills tab. Given a kill's server_id, return the
-- list of NM names this slot has previously hosted (excluding the kill's
-- own name -- we don't flag NM kills as PHs for themselves). Empty list
-- means "no PH evidence", so callers can just check `#result > 0`.
local function ph_nms_for_slot(server_id, name)
    local out = {}
    if not server_id or server_id == 0 then return out end
    local slot = config.slot_map and config.slot_map[tostring(server_id)]
    if not slot or not slot.names then return out end
    for n, _ in pairs(slot.names) do
        if n ~= name and config.nms[n] then
            table.insert(out, n)
        end
    end
    return out
end

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

    -- Session ignore list. Factored out so we can render it whether or not
    -- there are tracked kills -- otherwise ignoring your only mob hides the
    -- unignore UI behind the 'no kills yet' early return.
    local function draw_ignored_list()
        local ignored_display = {}
        for _, disp in pairs(ignored) do table.insert(ignored_display, disp) end
        if #ignored_display == 0 then return end
        table.sort(ignored_display, function(a, b) return a:lower() < b:lower() end)
        imgui.Separator()
        imgui.TextDisabled(('ignored this session (%d):'):format(#ignored_display))
        for i, disp in ipairs(ignored_display) do
            imgui.PushID('ign_list_' .. i)
            if imgui.SmallButton('unignore') then
                ignored[disp:lower()] = nil
            end
            imgui.PopID()
            imgui.SameLine()
            imgui.Text(disp)
        end
    end

    if #rows == 0 then
        imgui.TextDisabled('no kills yet')
        draw_ignored_list()
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

    for i, r in ipairs(rows) do
        local eta = r.respawn_at - t
        local total = r.respawn_at - (r.respawn_at - get_respawn_window(r.label:gsub(' #%d+$', '')))
        local elapsed = total - eta
        local frac = (total > 0) and math.max(0, math.min(1, elapsed / total)) or 1
        local c = bar_rgba(color_for(eta, total))

        -- Per-row controls:
        --   'x'   = delete just this one entry. No session ignore. If the
        --           same mob dies again it tracks normally. This is the
        --           common "I accidentally tracked a PH I didn't want to
        --           clutter the list" action.
        --   'ign' = the heavy-handed version: add the mob to the session
        --           ignore set AND drop every existing entry for it.
        --           Future kills of that name are skipped until /reload or
        --           /dc unignore.
        -- PushID keeps the buttons unique when names repeat across the list.
        imgui.PushID(i)
        if imgui.SmallButton('x') then
            local kept = T{}
            for _, k in ipairs(kills) do
                if not (k.name == r.name and k.respawn_at == r.respawn_at) then
                    table.insert(kept, k)
                end
            end
            kills = kept
        end
        imgui.SameLine()
        if imgui.SmallButton('NM') then
            local removed, was_new = promote_to_nm(r.name)
            local rec = config.nm_kills[r.name]
            if was_new then
                say(('%s flagged as NM (count=%d)'):format(r.name, rec.count))
            else
                say(('%s NM count bumped to %d'):format(r.name, rec.count))
            end
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Flag as NM and move to NMs tab')
        end
        imgui.SameLine()
        if imgui.SmallButton('ign') then
            ignored[r.name:lower()] = r.name
            local kept = T{}
            for _, k in ipairs(kills) do
                if k.name:lower() ~= r.name:lower() then table.insert(kept, k) end
            end
            kills = kept
            say(('ignoring %s this session'):format(r.name))
        end
        imgui.PopID()
        imgui.SameLine()

        -- Capture the bar's left edge so the text overlay aligns with it
        -- regardless of how many buttons precede the bar. The old fixed
        -- SameLine(8 + 24) broke when 'ign' was added.
        local bar_x = imgui.GetCursorPosX()
        imgui.PushStyleColor(ImGuiCol_PlotHistogram, c)
        imgui.ProgressBar(frac, { -1, 14 }, '')
        imgui.PopStyleColor()
        imgui.SameLine(bar_x)
        -- Near-black text on the colored bar. White vanishes against the
        -- yellow tier and washes out on green; near-black holds contrast
        -- across all three urgency colors.
        local TEXT_DARK = { 0.05, 0.05, 0.05, 1.0 }
        local ph_nms = ph_nms_for_slot(r.server_id, r.name)
        local display_label = r.label
        if #ph_nms > 0 then
            display_label = '[PH] ' .. r.label
        end
        imgui.TextColored(TEXT_DARK, ('%-22s  %s'):format(display_label, fmt_eta(eta)))
        if #ph_nms > 0 and imgui.IsItemHovered() then
            imgui.SetTooltip(('Placeholder for: %s'):format(table.concat(ph_nms, ', ')))
        end
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

    draw_ignored_list()
end

----------------------------------------------------------------
-- nms tab: persistent per-NM kill counter. Sorted by most recently
-- killed first. Each row: name, count, "Xm ago" since last, zone.
-- Right-click a row for a context menu (reset count / forget NM).
----------------------------------------------------------------
local function fmt_tod(t)
    if not t or t == 0 then return '' end
    local today = os.date('*t')
    local d = os.date('*t', t)
    if d.year == today.year and d.yday == today.yday then
        return os.date('%H:%M', t)
    end
    return os.date('%m/%d %H:%M', t)
end

local function fmt_since(secs)
    if secs < 60 then return ('%ds ago'):format(secs) end
    if secs < 3600 then return ('%dm ago'):format(math.floor(secs / 60)) end
    if secs < 86400 then
        return ('%dh%dm ago'):format(math.floor(secs / 3600), math.floor((secs % 3600) / 60))
    end
    return ('%dd ago'):format(math.floor(secs / 86400))
end

-- Module-scoped buffer for the "Add NM" text input. Lives outside
-- draw_nms_tab so the typed-but-not-submitted text persists across frames.
local nm_add_buf = { '' }
-- Per-NM string buffers for the ToD-edit popup (keyed by name).
-- Stores an "HH:MM" string. Lazily seeded on popup open.
local nm_tod_buf = {}

local function draw_nms_tab()
    -- Add-by-name row at the top: text input + Add button. Submits on
    -- Enter (EnterReturnsTrue=32) or button click.
    imgui.PushItemWidth(180)
    local submitted = imgui.InputText('##nm_add_name', nm_add_buf, 64, 32)
    imgui.PopItemWidth()
    imgui.SameLine()
    local clicked = imgui.Button('Add NM')
    if submitted or clicked then
        local target = (nm_add_buf[1] or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if target ~= '' then
            local removed, was_new = promote_to_nm(target)
            local rec = config.nm_kills[target]
            if was_new then
                say(('%s flagged as NM (count=%d, %d stale kill entr%s swept)'):format(
                    target, rec.count, removed, removed == 1 and 'y' or 'ies'))
            else
                say(('%s NM count bumped to %d'):format(target, rec.count))
            end
            nm_add_buf[1] = ''
        end
    end
    imgui.SameLine()
    imgui.TextDisabled('(or click NM on a kills-tab row)')
    imgui.Separator()

    -- Snapshot to a sortable array. Pairs() order isn't stable across
    -- save/reload, so we always re-sort on draw.
    local rows = {}
    for name, rec in pairs(config.nm_kills) do
        table.insert(rows, {
            name      = name,
            count     = rec.count or 0,
            first     = rec.first or 0,
            last      = rec.last or 0,
            last_zone = rec.last_zone or 0,
        })
    end
    if #rows == 0 then
        imgui.TextDisabled('No NMs tracked yet.')
        imgui.TextDisabled('Auto-detected from kill messages, or add manually above.')
        return
    end
    table.sort(rows, function(a, b) return a.last > b.last end)

    local t_now = now()
    for i, r in ipairs(rows) do
        local since = t_now - r.last
        local zname = (r.last_zone > 0) and get_zone_name(r.last_zone) or ''
        local tod = fmt_tod(r.last)

        -- Per-row controls. PushID lets us reuse short button labels per row.
        imgui.PushID(i)
        if imgui.SmallButton('reset') then
            config.nm_kills[r.name] = nil
            save()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip('Reset kill counter') end
        imgui.SameLine()
        if imgui.SmallButton('forget') then
            config.nms[r.name] = nil
            config.nm_kills[r.name] = nil
            save()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip('Un-flag as NM (future kills go back to respawn list)') end
        imgui.SameLine()
        if imgui.SmallButton('ToD') then
            -- Seed input with the row's current ToD as HH:MM (24hr local).
            nm_tod_buf[r.name] = nm_tod_buf[r.name] or { '' }
            nm_tod_buf[r.name][1] = os.date('%H:%M', r.last)
            imgui.OpenPopup('##tod_edit_' .. r.name)
        end
        if imgui.IsItemHovered() then imgui.SetTooltip('Edit ToD (word-of-mouth)') end
        imgui.SameLine()

        if imgui.BeginPopup('##tod_edit_' .. r.name) then
            imgui.Text(('Set ToD for %s'):format(r.name))
            imgui.TextDisabled('24hr local time. If the time is in the future, it')
            imgui.TextDisabled('is interpreted as yesterday at that time.')
            imgui.Separator()
            local buf = nm_tod_buf[r.name]
            imgui.PushItemWidth(80)
            local submitted = imgui.InputText('HH:MM', buf, 8, 32) -- 32 = EnterReturnsTrue
            imgui.PopItemWidth()
            if submitted or imgui.Button('Apply') then
                local ok, _, err = set_nm_tod(r.name, buf[1])
                if not ok and err then say(err) end
                imgui.CloseCurrentPopup()
            end
            imgui.SameLine()
            if imgui.Button('Just now') then
                set_nm_tod(r.name, 'now')
                imgui.CloseCurrentPopup()
            end
            imgui.SameLine()
            if imgui.Button('Cancel') then
                imgui.CloseCurrentPopup()
            end
            imgui.EndPopup()
        end

        -- Main row text: "Spiny Spipi  x3   ToD 14:32 · 12m ago · East Sarutabaruta"
        imgui.Text(('%s  x%d'):format(r.name, r.count))
        imgui.SameLine()
        local rhs
        if zname ~= '' then
            rhs = ('ToD %s  ·  %s  ·  %s'):format(tod, fmt_since(since), zname)
        else
            rhs = ('ToD %s  ·  %s'):format(tod, fmt_since(since))
        end
        imgui.TextDisabled(rhs)

        -- Right-click context menu kept as an alternative interaction surface.
        if imgui.BeginPopupContextItem('##nmctx_' .. r.name) then
            if imgui.MenuItem('reset count') then
                config.nm_kills[r.name] = nil
                save()
            end
            if imgui.MenuItem('forget (un-flag as NM)') then
                config.nms[r.name] = nil
                config.nm_kills[r.name] = nil
                save()
            end
            imgui.EndPopup()
        end
        imgui.PopID()
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
        if imgui.BeginTabItem('nms') then
            draw_nms_tab()
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
    imgui.SetNextWindowBgAlpha(config.window.bg_alpha or 1.0)
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

-- NM kill auto-detector. Hooks the chat stream and watches for the
-- universal "<Mob> falls to the ground." line. Names without "The " are
-- NMs (server-side naming convention). Wrapped in pcall because text_in
-- runs on every chat line: a regex error here would unload the addon.
ashita.events.register('text_in', 'dc_nm_text_cb', function(e)
    if not config.track_respawns then return end
    pcall(function()
        local name = parse_nm_kill_message(e.message)
        if name then record_nm_kill(name) end
    end)
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
                                local scl = config.arc_label_scale or 1.0
                                if scl ~= 1.0 then imgui.SetWindowFontScale(scl) end
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
        for _, disp in pairs(ignored) do any = true; say('  ' .. disp) end
        if not any then say('no ignored mobs this session') end
        return
    end
    ignored[name:lower()] = name
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
    say('/dc lines | mine | all | test')
    say('/dc nm [list|reset <name>|forget <name>] -- NM counter')
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
    elseif sub == 'mobdb' then
        config.use_mobdb = not config.use_mobdb
        if not config.use_mobdb then mobdb_zone_cache = {} end
        save()
        say(('mobdb integration: %s'):format(config.use_mobdb and 'on' or 'off'))
    elseif sub == 'nm' then
        local action = args[prefix_word_count + 2]
        action = action and action:lower() or 'list'
        if action == 'list' then
            local n = 0
            for _ in pairs(config.nm_kills) do n = n + 1 end
            if n == 0 then
                say('no NMs tracked yet')
            else
                say(('tracked NMs (%d):'):format(n))
                for name, rec in pairs(config.nm_kills) do
                    local since = now() - (rec.last or 0)
                    say(('  %s  x%d  (%s)'):format(name, rec.count or 0, fmt_since(since)))
                end
            end
        elseif action == 'reset' then
            -- /dc nm reset <name>  or  /dc nm reset all
            local rest_start = 0
            for i = 1, prefix_word_count + 2 do
                rest_start = rest_start + #args[i] + 1
            end
            local target = raw:sub(rest_start + 1):gsub('^%s+', ''):gsub('%s+$', '')
            if target == '' or target:lower() == 'all' then
                config.nm_kills = T{}; save(); say('all NM counts reset')
            else
                if config.nm_kills[target] then
                    config.nm_kills[target] = nil; save()
                    say(('reset NM count for %s'):format(target))
                else
                    say(('no NM record for "%s" -- check spelling, names are case-sensitive'):format(target))
                end
            end
        elseif action == 'add' then
            -- /dc nm add <name>  -- promote an existing kill-list entry (or unseen mob)
            -- to the NMs tab. Sweeps the kills list regardless of age and seeds count=1.
            local rest_start = 0
            for i = 1, prefix_word_count + 2 do
                rest_start = rest_start + #args[i] + 1
            end
            local target = raw:sub(rest_start + 1):gsub('^%s+', ''):gsub('%s+$', '')
            if target == '' then
                say('usage: /dc nm add <name>')
            else
                local removed, was_new = promote_to_nm(target)
                local rec = config.nm_kills[target]
                if was_new then
                    say(('%s flagged as NM (count=%d, %d stale kill entr%s swept)'):format(
                        target, rec.count, removed, removed == 1 and 'y' or 'ies'))
                else
                    say(('%s NM count bumped to %d (%d stale kill entr%s swept)'):format(
                        target, rec.count, removed, removed == 1 and 'y' or 'ies'))
                end
            end
        elseif action == 'tod' then
            -- /dc nm tod <name> <when>
            -- <when> is the LAST whitespace-delimited token: now | <minutes> | HH:MM
            local rest_start = 0
            for i = 1, prefix_word_count + 2 do
                rest_start = rest_start + #args[i] + 1
            end
            local rest = raw:sub(rest_start + 1):gsub('^%s+', ''):gsub('%s+$', '')
            local name_part, when_part = rest:match('^(.-)%s+(%S+)$')
            if not name_part or name_part == '' then
                say('usage: /dc nm tod <name> now | <minutes> | HH:MM')
            else
                local ok, new_ts, err = set_nm_tod(name_part, when_part)
                if not ok then
                    say(err)
                else
                    say(('%s ToD set to %s (%dm ago)'):format(
                        name_part, fmt_tod(new_ts), math.floor((now() - new_ts) / 60)))
                end
            end
        elseif action == 'forget' then
            local rest_start = 0
            for i = 1, prefix_word_count + 2 do
                rest_start = rest_start + #args[i] + 1
            end
            local target = raw:sub(rest_start + 1):gsub('^%s+', ''):gsub('%s+$', '')
            if target == '' then
                say('usage: /dc nm forget <name>')
            else
                config.nms[target] = nil
                config.nm_kills[target] = nil
                save()
                say(('un-flagged %s as NM'):format(target))
            end
        else
            say('/dc nm list | add <name> | tod <name> now|<min>|HH:MM | reset [name|all] | forget <name>')
        end
    elseif sub == 'test' then
        record_kill('TestMob', nil)
    elseif sub == 'slots' then
        -- Inspect the spawn-slot observation log. Foundation for the
        -- placeholder-learning feature: any slot showing both an NM and a
        -- non-NM has identified that non-NM as the PH.
        local action = args[2 + prefix_word_count]
        if action == 'clear' then
            config.slot_map = T{}
            save()
            say('slot_map cleared')
        elseif action == 'tag' then
            -- Manual seed: /dc slots tag <server_id> <NM name>
            -- For bootstrapping known PH relationships without waiting for
            -- the next NM pop. server_id accepts decimal or 0xHEX.
            local sid_raw = args[3 + prefix_word_count]
            if not sid_raw then
                say('usage: /dc slots tag <server_id> <NM name>')
                say('  ex:  /dc slots tag 0x01074130 Spiny Spipi')
            else
                local sid_num
                if sid_raw:sub(1, 2) == '0x' or sid_raw:sub(1, 2) == '0X' then
                    sid_num = tonumber(sid_raw:sub(3), 16)
                else
                    sid_num = tonumber(sid_raw)
                end
                local name_start = 0
                for i = 1, prefix_word_count + 3 do
                    name_start = name_start + #args[i] + 1
                end
                local nm_name = raw:sub(name_start + 1):gsub('^%s+', ''):gsub('%s+$', '')
                if not sid_num or sid_num == 0 then
                    say('invalid server_id (expected decimal or 0xHEX)')
                elseif nm_name == '' then
                    say('usage: /dc slots tag <server_id> <NM name>')
                else
                    local key = tostring(sid_num)
                    config.slot_map = config.slot_map or T{}
                    local slot = config.slot_map[key]
                    if not slot then
                        slot = T{ zone = get_zone_id(), names = T{}, last_seen = now() }
                        config.slot_map[key] = slot
                    end
                    slot.names[nm_name] = slot.names[nm_name] or T{ count = 0, last = now() }
                    -- Bump count to 1 if zero so the slot reads as "seen".
                    if (slot.names[nm_name].count or 0) == 0 then
                        slot.names[nm_name].count = 1
                    end
                    -- Ensure the name is also flagged as an NM so the PH
                    -- callout in record_kill recognizes it.
                    config.nms[nm_name] = true
                    save()
                    say(('tagged 0x%08x as host of NM "%s"'):format(sid_num, nm_name))
                end
            end
        else
            local count = 0
            local with_nms = 0
            for sid, slot in pairs(config.slot_map or {}) do
                count = count + 1
                local names = {}
                local has_nm = false
                for n, _ in pairs(slot.names or {}) do
                    table.insert(names, n)
                    if config.nms[n] then has_nm = true end
                end
                if has_nm and #names > 1 then
                    with_nms = with_nms + 1
                    say(('  0x%08x [%s]: %s'):format(tonumber(sid), slot.zone or 0, table.concat(names, ', ')))
                end
            end
            say(('slot_map: %d slots tracked, %d with PH evidence'):format(count, with_nms))
            if action ~= 'verbose' then
                say('  (use /dc slots verbose | tag <id> <NM> | clear)')
            elseif count > 0 and with_nms == 0 then
                say('  no slot has been seen as both NM and non-NM yet -- kill some PHs first')
            end
            if action == 'verbose' then
                for sid, slot in pairs(config.slot_map or {}) do
                    local parts = {}
                    for n, rec in pairs(slot.names or {}) do
                        table.insert(parts, ('%s x%d'):format(n, rec.count or 1))
                    end
                    say(('  0x%08x [%s]: %s'):format(tonumber(sid), slot.zone or 0, table.concat(parts, ', ')))
                end
            end
        end
    elseif sub == 'target' then
        -- Inspect the player's current main target: name, server_id, and
        -- any PH/NM evidence recorded for that slot. Useful for deciding
        -- whether to engage *before* committing to the pull.
        local idx
        pcall(function()
            idx = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0)
        end)
        if not idx or idx == 0 then
            say('no target')
        else
            local ents = AshitaCore:GetMemoryManager():GetEntity()
            local name, sid
            pcall(function()
                name = ents:GetName(idx)
                sid  = ents:GetServerId(idx)
            end)
            if not name or name == '' then
                say(('target idx=%d (no name -- entity gone?)'):format(idx))
            else
                say(('target: %s  id=0x%08x  index=%d'):format(name, sid or 0, idx))
                if sid and sid ~= 0 then
                    local slot = config.slot_map and config.slot_map[tostring(sid)]
                    if slot and slot.names then
                        local nm_names, ph_names = {}, {}
                        for n, rec in pairs(slot.names) do
                            if config.nms[n] then
                                table.insert(nm_names, ('%s x%d'):format(n, rec.count or 1))
                            elseif n ~= name then
                                table.insert(ph_names, ('%s x%d'):format(n, rec.count or 1))
                            end
                        end
                        if #nm_names > 0 then
                            say(('  NM here: %s'):format(table.concat(nm_names, ', ')))
                            if not config.nms[name] then
                                say(('  -> "%s" is a PH for this slot'):format(name))
                            end
                        end
                        if #ph_names > 0 then
                            say(('  also seen: %s'):format(table.concat(ph_names, ', ')))
                        end
                        if #nm_names == 0 and #ph_names == 0 then
                            say('  no slot history yet')
                        end
                    else
                        say('  slot has no recorded history (kill it to start)')
                    end
                end
            end
        end
    elseif sub == 'lines' then
        config.respawn_lines = not config.respawn_lines
        save()
        say(('return arcs: %s'):format(config.respawn_lines and 'on' or 'off'))
    elseif sub == 'mine' then
        config.only_my_kills = not config.only_my_kills
        save()
        say(('only my kills: %s'):format(config.only_my_kills and 'on' or 'off'))
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
        -- Claim-filter diagnostics: shows whether GetClaimStatus and
        -- GetMemberServerId are giving comparable values. If a kill should
        -- have counted but didn't, compare last_seen_claim against your
        -- own server ID's low 16 bits.
        local my_sid = 0
        pcall(function()
            my_sid = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0) or 0
        end)
        say(('only_my_kills=%s my_sid=0x%x (low16=0x%x)'):format(
            tostring(config.only_my_kills), my_sid, bit.band(my_sid, 0xFFFF)))
        say(('last claim seen at death: 0x%x  last skip: %s'):format(
            last_seen_claim, tostring(last_filter_skip)))
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
