addon.name      = 'deathclock'
addon.author    = 'Blake & Watney'
addon.version   = '0.2.0'
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
-- loading at all — without drawArc, lines just don't render and every
-- other feature still works.
local _tl_root = string.format('%s\\vendor\\targetlines', addon.path)
package.path = string.format('%s\\?.lua;%s', _tl_root, package.path)
local drawArc
do
    local ok, mod = pcall(require, 'drawArc')
    if ok then drawArc = mod end
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
    -- 5m 49s — measured on HorizonXI for claim mobs.
    default_respawn         = 349,
    overrides               = T{},
    keep_dead_after_respawn = 30,
    track_respawns          = true,
    respawn_lines           = true,
    -- (legacy `respawn_lines_show_all` intentionally NOT in defaults — its
    -- presence in a loaded XML is the signal that the user predates v0.2.0
    -- and needs the arc_show_below_pct migration.)

    -- Color bands run high-%-remaining → low. Blue = just died, Red = about
    -- to pop. "ready" is its own band (eta <= 0) so green-means-go survives.
    -- ImGui RGB floats 0-1. Alpha is not user-editable: bars use 1.0, arcs
    -- use 0.75 to read over terrain without becoming a blinding overlay.
    colors = T{
        ready  = T{ 0.27, 1.00, 0.27 },
        blue   = T{ 0.35, 0.55, 1.00 },
        green  = T{ 0.40, 0.85, 0.55 },
        yellow = T{ 1.00, 0.93, 0.27 },
        orange = T{ 1.00, 0.60, 0.20 },
        red    = T{ 1.00, 0.33, 0.33 },
    },
    -- Thresholds are the LOWER bound (% of total respawn remaining) for each
    -- band. Going down: > blue → blue, > green → green, ..., otherwise red.
    -- Must stay monotonically decreasing; clamped on slider edit.
    thresholds = T{
        blue   = 75,
        green  = 50,
        yellow = 25,
        orange = 10,
    },
    -- In-world arcs render only when remaining % <= this. 100 = always,
    -- 0 = never (use the on/off toggle for that). Replaces the old binary
    -- "show all" toggle with a continuous knob.
    arc_show_below_pct = 100,
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
-- continuous `arc_show_below_pct`. False (the old default) meant "only
-- green and yellow arcs" — yellow was eta<=60s, ~17% remaining for a 349s
-- timer. Map false → 25 (a touch more permissive than the old yellow line
-- so users don't feel they lost arcs), true → 100 (always show).
-- Sentinel prevents re-applying this if the user later lowers the value to 0.
if not config._arc_pct_migrated then
    config._arc_pct_migrated = true
    if config.respawn_lines_show_all == false then
        config.arc_show_below_pct = 25
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

local function color_for(eta, total)
    if eta <= 0 then return config.colors.ready end
    local pct = (total and total > 0) and (eta / total * 100) or 100
    local th = config.thresholds
    if pct >= th.blue   then return config.colors.blue   end
    if pct >= th.green  then return config.colors.green  end
    if pct >= th.yellow then return config.colors.yellow end
    if pct >= th.orange then return config.colors.orange end
    return config.colors.red
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

-- Bars use ImGui PushStyleColor which wants {r,g,b,a}. Wrap the RGB triple
-- with a full-opacity alpha so we don't mutate the stored table.
local function bar_rgba(c)
    return { c[1], c[2], c[3], 1.0 }
end

local function draw_respawn_body()
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
    end

    -- Collapsed by default — most users never open it, but the knobs are
    -- here for the ones who care. Bands run blue (just died) → red (about
    -- to pop). "ready" is its own band so green-means-go survives.
    if imgui.CollapsingHeader('colors & thresholds') then
        local band_order = { 'ready', 'blue', 'green', 'yellow', 'orange', 'red' }
        for _, name in ipairs(band_order) do
            local c = config.colors[name]
            local tmp = { c[1], c[2], c[3] }
            imgui.PushID('col_' .. name)
            if imgui.ColorEdit3('##' .. name, tmp) then
                config.colors[name] = T{ tmp[1], tmp[2], tmp[3] }; save()
            end
            imgui.PopID()
            imgui.SameLine()
            imgui.Text(name)
        end

        imgui.Separator()
        imgui.TextDisabled('band kicks in at % remaining')

        -- Sliders define the LOWER bound for each band, in % of total
        -- respawn remaining. Must stay monotonically decreasing
        -- (blue > green > yellow > orange) or the bands lose meaning;
        -- clamp on edit rather than constrain min/max because clamping
        -- gives the user a clearer "you hit the floor" signal.
        local th = config.thresholds
        local function clamp_thresholds()
            if th.green  >= th.blue   then th.green  = th.blue   - 1 end
            if th.yellow >= th.green  then th.yellow = th.green  - 1 end
            if th.orange >= th.yellow then th.orange = th.yellow - 1 end
            if th.orange < 1 then th.orange = 1 end
            if th.yellow < 2 then th.yellow = 2 end
            if th.green  < 3 then th.green  = 3 end
            if th.blue   < 4 then th.blue   = 4 end
        end
        local function slider(label, key, lo, hi)
            local v = { th[key] }
            imgui.PushID('th_' .. key)
            if imgui.SliderInt(label, v, lo, hi, '%d%%') then
                th[key] = v[1]; clamp_thresholds(); save()
            end
            imgui.PopID()
        end
        slider('blue',   'blue',   1, 99)
        slider('green',  'green',  1, 99)
        slider('yellow', 'yellow', 1, 99)
        slider('orange', 'orange', 1, 99)

        if drawArc then
            imgui.Separator()
            local v = { config.arc_show_below_pct or 100 }
            if imgui.SliderInt('arcs visible below', v, 0, 100, '%d%%') then
                config.arc_show_below_pct = v[1]; save()
            end
            imgui.TextDisabled('100% = always, 25% = last quarter only')
        end

        if imgui.SmallButton('reset colors & thresholds') then
            config.colors = T{
                ready  = T{ 0.27, 1.00, 0.27 },
                blue   = T{ 0.35, 0.55, 1.00 },
                green  = T{ 0.40, 0.85, 0.55 },
                yellow = T{ 1.00, 0.93, 0.27 },
                orange = T{ 1.00, 0.60, 0.20 },
                red    = T{ 1.00, 0.33, 0.33 },
            }
            config.thresholds = T{ blue = 75, green = 50, yellow = 25, orange = 10 }
            config.arc_show_below_pct = 100
            save()
        end
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
    -- actual entity index — slot 0 of the entity table is unreliable).
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
-- window + d3d_present
----------------------------------------------------------------
local function draw_window()
    if not config.window.visible then return end
    imgui.SetNextWindowSize({ config.window.w, 0 }, ImGuiCond_FirstUseEver)
    imgui.SetNextWindowPos({ config.window.x, config.window.y }, ImGuiCond_FirstUseEver)
    if imgui.Begin('Deathclock', true) then
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
        local thr_pct = config.arc_show_below_pct or 100
        for _, k in ipairs(kills) do
            if k.zone == cur_zone and k.x and k.y and k.z then
                local eta = k.respawn_at - t
                local total = k.respawn_at - (k.killed_at or k.respawn_at)
                local pct = (total > 0) and math.max(0, eta / total * 100) or 0
                if eta <= 0 or pct <= thr_pct then
                    local color = rgb_to_argb(color_for(eta, total))
                    drawArc(px, py, pz, k.x, k.y, k.z, color, 1)
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
        -- the last quarter". Maps onto the new continuous arc_show_below_pct.
        if (config.arc_show_below_pct or 100) >= 100 then
            config.arc_show_below_pct = 25
        else
            config.arc_show_below_pct = 100
        end
        save()
        say(('arcs visible below: %d%%'):format(config.arc_show_below_pct))
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
    say(('deathclock v%s loaded — /dc help'):format(addon.version))
end)
