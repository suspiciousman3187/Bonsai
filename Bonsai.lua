_addon.name     = 'Bonsai'
_addon.author   = 'Man In Black'
_addon.version  = '1.0'
_addon.commands = {'bonsai', 'bon'}

local packets = require('packets')

local MOG_GARDEN_ZONE     = 280
local POKE_DISTANCE       = 3.5
local STATE_TIMEOUT       = 30.0
local INTER_NPC_DELAY     = 1.5
local INTER_MESSAGE_DELAY = 1.0
local MAX_LOOP_INTERACTS  = 16

local NPC_PLAN_GARDEN = {
    { kind='garden', name_prefix='Mineral Vein',         opt=1, mode='multi'  },
    { kind='garden', name_prefix='Pond Dredger',         opt=0, mode='single' },
    { kind='garden', name_prefix='Arboreal Grove',       opt=0, mode='multi'  },
    { kind='garden', name_prefix='Coastal Fishing Net',  opt=0, mode='single' },
}

local MONSTER_INDEX_LO    = 0x8A
local MONSTER_INDEX_HI    = 0x8D
local PET_OPT             = 2560
local PET_DISTANCE_LIMIT  = 200.0

local FURROW_NAME_PREFIX          = 'Garden Furrow'
local FURROW_PLANT_OPT            = 16
local FURROW_HARVEST_OPT          = 18
local FURROW_HARVEST_WAIT_SECONDS = 61 * 60
local FURROW_FERT_WAIT_SECONDS    = 30 * 60
local FURROW_REST_SECONDS         = 10
local FURROW_REMINDER_SECONDS     = { 45*60, 30*60, 15*60, 5*60 }
local REVIVAL_ROOT_ITEM_ID        = 940
local MIRACLE_MULCH_ITEM_ID       = 8971
local FURROW_FERTILIZE_OPT        = 16
local USE_FERTILIZER              = false

local WARP_TO_REARING_GROUNDS = {
    kind='warp', mode='warp', name_prefix='Chacharoon',
    warp_x = 361.16, warp_y = -554.77, warp_z = -3.34, warp_u1 = 72,
    intermediate_opts = {1, 11},
    opt = 11,
}
local POST_WARP_DELAY       = 12.0
local POST_WARP_ARRIVE_DIST = 25.0

local STATE_IDLE          = 'IDLE'
local STATE_FIND_NEXT     = 'FIND_NEXT'
local STATE_MOVING        = 'MOVING'
local STATE_POKED         = 'POKED'
local STATE_SENDING       = 'SENDING'
local STATE_INTER_MESSAGE = 'INTER_MESSAGE'
local STATE_COOLDOWN      = 'COOLDOWN'
local STATE_PHASE_WAIT    = 'PHASE_WAIT'

local state                   = STATE_IDLE
local current_plan            = {}
local plan_index              = 1
local cycle_end_index         = 0
local current_npc             = nil
local state_time              = 0
local cooldown_until          = 0
local inter_message_until     = 0
local phase_chain             = {}
local pending_phase           = nil
local phase_wait_until        = 0
local warp_arrival_dest       = nil
local loop_template           = nil
local phase_reminders_pending = {}

local function chat(msg) windower.add_to_chat(207, '[Bonsai] ' .. msg) end
local function err(msg)  windower.add_to_chat(123, '[Bonsai] ' .. msg) end

local SETTINGS_FILE = (windower.addon_path or '') .. 'data/bonall_settings.lua'
local DEFAULT_BONALL_ORDER = { 'mine', 'dredger', 'grove', 'flotsam', 'net', 'pet' }
local NODE_KEY_SET = {
    mine=true, dredger=true, grove=true, net=true, flotsam=true, pet=true,
}
local NODE_LABEL = {
    mine    = 'Mineral Vein',
    dredger = 'Pond Dredger',
    grove   = 'Arboreal Grove',
    net     = 'Coastal Fishing Net',
    flotsam = 'Flotsam',
    pet     = 'Pet (warp + monsters)',
}

local function load_bonall_settings()
    local f = io.open(SETTINGS_FILE, 'r')
    if not f then return {} end
    local content = f:read('*a')
    f:close()
    if not content or content == '' then return {} end
    local loader = loadstring(content)
    if not loader then return {} end
    local ok, result = pcall(loader)
    if ok and type(result) == 'table' then return result end
    return {}
end

local function save_bonall_settings(s)
    local f = io.open(SETTINGS_FILE, 'w')
    if not f then
        pcall(function() os.execute('mkdir "' .. (windower.addon_path or '') .. 'data" 2>nul') end)
        f = io.open(SETTINGS_FILE, 'w')
        if not f then return false end
    end
    f:write('-- Per-character //bon all node order. Managed by //bon add/remove.\n')
    f:write('return {\n')
    for char, list in pairs(s) do
        if type(list) == 'table' then
            local quoted = {}
            for _, k in ipairs(list) do quoted[#quoted+1] = string.format('%q', k) end
            f:write(string.format('  [%q] = { %s },\n', char, table.concat(quoted, ', ')))
        end
    end
    f:write('}\n')
    f:close()
    return true
end

local bonall_settings = load_bonall_settings()

local function get_bonall_order_for_current()
    local p = windower.ffxi.get_player()
    if not p or not p.name or p.name == '' then return nil, nil end
    local name = p.name
    if type(bonall_settings[name]) ~= 'table' then
        local copy = {}
        for _, k in ipairs(DEFAULT_BONALL_ORDER) do copy[#copy+1] = k end
        bonall_settings[name] = copy
    end
    return bonall_settings[name], name
end

local function index_of_key(list, key)
    for i, k in ipairs(list) do if k == key then return i end end
    return nil
end

local function build_node_entry(key)
    if key == 'mine'    then return NPC_PLAN_GARDEN[1] end
    if key == 'dredger' then return NPC_PLAN_GARDEN[2] end
    if key == 'grove'   then return NPC_PLAN_GARDEN[3] end
    if key == 'net'     then return NPC_PLAN_GARDEN[4] end
    if key == 'flotsam' then return { kind='garden', name_prefix='Flotsam', opt=1, mode='pet' } end
    return nil
end

local function format_order(order)
    if #order == 0 then return '(empty)' end
    local labels = {}
    for _, k in ipairs(order) do labels[#labels+1] = NODE_LABEL[k] or k end
    return table.concat(labels, ' -> ')
end

local function in_mog_garden()
    local info = windower.ffxi.get_info()
    return info and info.zone == MOG_GARDEN_ZONE
end

local function reset_all()
    if state == STATE_MOVING then windower.ffxi.run(false) end
    state                   = STATE_IDLE
    current_plan            = {}
    plan_index              = 1
    cycle_end_index         = 0
    current_npc             = nil
    state_time              = 0
    cooldown_until          = 0
    inter_message_until     = 0
    phase_chain             = {}
    pending_phase           = nil
    phase_wait_until        = 0
    warp_arrival_dest       = nil
    loop_template           = nil
    phase_reminders_pending = {}
end

local function is_ghost_monster_name(name)
    if not name or name == '' then return true end
    if name == 'Monster' then return true end
    if name:sub(1, 16) == 'Breeding Monster' then return true end
    return false
end

local function find_all_furrows()
    local out = {}
    local seen = {}
    for i = 1, 2048 do
        local m = windower.ffxi.get_mob_by_index(i)
        if m and m.name and m.valid_target and m.id and m.id ~= 0
           and m.name:sub(1, #FURROW_NAME_PREFIX) == FURROW_NAME_PREFIX
           and not seen[m.id] then
            seen[m.id] = true
            out[#out+1] = { name=m.name, index=m.index, id=m.id }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function build_furrow_plant_plan()
    local plan = {}
    for _, f in ipairs(find_all_furrows()) do
        plan[#plan+1] = {
            kind  = 'furrow',
            index = f.index,
            opt   = FURROW_PLANT_OPT,
            mode  = 'single',
            trade = { item_id = REVIVAL_ROOT_ITEM_ID, count = 1 },
        }
    end
    return plan
end

local function build_furrow_harvest_plan()
    local plan = {}
    for _, f in ipairs(find_all_furrows()) do
        plan[#plan+1] = {
            kind  = 'furrow',
            index = f.index,
            opt   = FURROW_HARVEST_OPT,
            mode  = 'pet',
        }
    end
    return plan
end

local function build_furrow_fertilize_plan()
    local plan = {}
    for _, f in ipairs(find_all_furrows()) do
        plan[#plan+1] = {
            kind  = 'furrow',
            index = f.index,
            opt   = FURROW_FERTILIZE_OPT,
            mode  = 'single',
            trade = { item_id = MIRACLE_MULCH_ITEM_ID, count = 1 },
        }
    end
    return plan
end

local function build_monster_plan()
    local plan = {}
    for idx = MONSTER_INDEX_LO, MONSTER_INDEX_HI do
        local m = windower.ffxi.get_mob_by_index(idx)
        if m and m.valid_target and m.id and m.id ~= 0 then
            if is_ghost_monster_name(m.name) then
                chat(string.format('Skipping ghost monster at idx 0x%02X (name=%s)', idx, tostring(m.name)))
            else
                plan[#plan+1] = {
                    kind  = 'monster',
                    index = idx,
                    opt   = PET_OPT,
                    mode  = 'pet',
                }
            end
        end
    end
    return plan
end

local function set_state(new_state)
    state      = new_state
    state_time = os.clock()
end

local function find_npc_by_prefix(prefix)
    local me = windower.ffxi.get_mob_by_target('me')
    if not me then return nil end
    local best, best_dist = nil, math.huge
    for i = 1, 2048 do
        local m = windower.ffxi.get_mob_by_index(i)
        if m and m.name and m.valid_target and m.name:sub(1, #prefix) == prefix then
            local dx, dy = m.x - me.x, m.y - me.y
            local d = math.sqrt(dx*dx + dy*dy)
            if d < best_dist then
                best, best_dist = m, d
            end
        end
    end
    return best
end

local function send_poke(npc)
    local p = packets.new('outgoing', 0x01A)
    p['Target']       = npc.id
    p['Target Index'] = npc.index
    p['Category']     = 0x00
    p['Param']        = 0
    packets.inject(p)
end

local function find_inventory_slot(item_id, min_count)
    local inv = windower.ffxi.get_items(0)
    if not inv then return nil end
    for slot = 1, #inv do
        local it = inv[slot]
        if it and it.id == item_id and (it.count or 0) >= (min_count or 1) then
            return slot
        end
    end
    return nil
end

local function send_trade(npc, item_id, count)
    local slot = find_inventory_slot(item_id, count)
    if not slot then
        return false, 'item_not_in_inventory'
    end
    local p = packets.new('outgoing', 0x036, {
        ['Target']          = npc.id,
        ['Target Index']    = npc.index,
        ['Number of Items'] = 1,
    })
    p['Item Index 1'] = slot
    p['Item Count 1'] = count
    packets.inject(p)
    return true
end

local function send_menu_response(npc, opt, automatic)
    local p = packets.new('outgoing', 0x05B)
    p['Target']            = npc.id
    p['Target Index']      = npc.index
    p['Zone']              = MOG_GARDEN_ZONE
    p['Menu ID']           = current_npc and current_npc.menu_id or 0
    p['Option Index']      = opt
    p['_unknown1']         = 0
    p['Automated Message'] = automatic
    p['_unknown2']         = 0
    packets.inject(p)
end

local function send_coord_packet(npc, x, y, z, u1)
    local p = packets.new('outgoing', 0x05C)
    p['Target ID']    = npc.id
    p['Target Index'] = npc.index
    p['Zone']         = MOG_GARDEN_ZONE
    p['Menu ID']      = current_npc and current_npc.menu_id or 0
    p['X']            = x
    p['Y']            = y
    p['Z']            = z
    p['_unknown1']    = u1
    p['Rotation']     = 0
    packets.inject(p)
end

local function extract_harvest_count(parsed)
    local mp = parsed['Menu Parameters']
    if not mp or #mp < 12 then return nil end
    local b0 = mp:byte(9)
    local b1 = mp:byte(10)
    local b2 = mp:byte(11)
    local b3 = mp:byte(12)
    return b0 + b1*0x100 + b2*0x10000 + b3*0x1000000
end

local function build_message_queue(count)
    local plan = current_npc.plan
    local queue = {}
    if plan.mode == 'single' then
        queue[#queue+1] = { type='menu', opt=plan.opt, auto=false }
    elseif plan.mode == 'pet' then
        queue[#queue+1] = { type='menu', opt=plan.opt, auto=true }
        queue[#queue+1] = { type='menu', opt=plan.opt, auto=false }
    elseif plan.mode == 'warp' then
        queue[#queue+1] = { type='coord', x=plan.warp_x, y=plan.warp_y, z=plan.warp_z, u1=plan.warp_u1 }
        for _, op in ipairs(plan.intermediate_opts or {}) do
            queue[#queue+1] = { type='menu', opt=op, auto=true }
        end
        queue[#queue+1] = { type='menu', opt=plan.opt, auto=false }
    else
        local n = count
        if not n or n <= 0 then
            n = 1
        elseif n > MAX_LOOP_INTERACTS then
            n = MAX_LOOP_INTERACTS
        end
        for _ = 1, n do
            queue[#queue+1] = { type='menu', opt=plan.opt, auto=true }
        end
        queue[#queue+1] = { type='menu', opt=plan.opt, auto=false }
    end
    current_npc.queue = queue
    current_npc.total = #queue
end

local function send_next_in_queue()
    if not current_npc or not current_npc.queue or #current_npc.queue == 0 then
        return false
    end
    local m = table.remove(current_npc.queue, 1)
    if m.type == 'coord' then
        send_coord_packet(current_npc, m.x, m.y, m.z, m.u1)
    else
        send_menu_response(current_npc, m.opt, m.auto)
    end
    return true
end

local function go_to_cooldown()
    cooldown_until = os.clock() + INTER_NPC_DELAY
    set_state(STATE_COOLDOWN)
end

windower.register_event('prerender', function()
    if state == STATE_IDLE then return end

    local now = os.clock()

    if state ~= STATE_FIND_NEXT and state ~= STATE_COOLDOWN
       and state ~= STATE_INTER_MESSAGE and state ~= STATE_PHASE_WAIT
       and state_time > 0 and now - state_time > STATE_TIMEOUT then
        err('Timeout in state ' .. state .. ', aborting cycle')
        reset_all()
        return
    end

    if state == STATE_FIND_NEXT then
        if plan_index > cycle_end_index then
            if #phase_chain == 0 and loop_template then
                chat('Loop iteration complete, restarting.')
                for _, p in ipairs(loop_template) do
                    phase_chain[#phase_chain+1] = p
                end
            end
            if #phase_chain == 0 then
                chat('All done.')
                reset_all()
                return
            end
            pending_phase    = table.remove(phase_chain, 1)
            phase_wait_until = os.clock() + (pending_phase.pre_delay or 0)
            phase_reminders_pending = {}
            if pending_phase.reminders then
                for _, r in ipairs(pending_phase.reminders) do
                    if (pending_phase.pre_delay or 0) > r then
                        phase_reminders_pending[#phase_reminders_pending+1] = r
                    end
                end
            end
            chat(string.format('Next phase: %s', pending_phase.label or '?'))
            set_state(STATE_PHASE_WAIT)
            return
        end
        local entry = current_plan[plan_index]
        local npc
        if entry.kind == 'monster' or entry.kind == 'furrow' then
            npc = windower.ffxi.get_mob_by_index(entry.index)
            if not npc or not npc.valid_target or not npc.id or npc.id == 0 then
                err(string.format('%s at index 0x%02X no longer present, skipping.',
                    entry.kind, entry.index))
                plan_index = plan_index + 1
                return
            end
        else
            npc = find_npc_by_prefix(entry.name_prefix)
            if not npc then
                err('NPC matching "' .. entry.name_prefix .. '" not found in zone, skipping.')
                plan_index = plan_index + 1
                return
            end
        end
        current_npc = {
            id    = npc.id,
            index = npc.index,
            name  = npc.name,
            plan  = entry,
        }
        chat(string.format('Walking to %s (step %d of %d)', npc.name, plan_index, cycle_end_index))
        set_state(STATE_MOVING)
        return
    end

    if state == STATE_MOVING then
        local me  = windower.ffxi.get_mob_by_target('me')
        local mob = windower.ffxi.get_mob_by_index(current_npc.index)
        if not me or not mob then
            err('Lost target while moving, aborting.')
            windower.ffxi.run(false)
            reset_all()
            return
        end
        local dx, dy = mob.x - me.x, mob.y - me.y
        local dist   = math.sqrt(dx*dx + dy*dy)
        if dist <= POKE_DISTANCE then
            windower.ffxi.run(false)
            if current_npc.plan and current_npc.plan.trade then
                local t = current_npc.plan.trade
                local ok, why = send_trade(current_npc, t.item_id, t.count or 1)
                if not ok then
                    err(string.format('Skipping %s: trade failed (%s, item %d).',
                        current_npc.name, tostring(why), t.item_id))
                    go_to_cooldown()
                    return
                end
            else
                send_poke(current_npc)
            end
            set_state(STATE_POKED)
            return
        end
        local angle = math.atan2(dy, dx) * -1
        windower.ffxi.run(angle)
        return
    end

    if state == STATE_INTER_MESSAGE then
        if now >= inter_message_until then
            send_next_in_queue()
            set_state(STATE_SENDING)
        end
        return
    end

    if state == STATE_COOLDOWN then
        if now >= cooldown_until then
            plan_index = plan_index + 1
            current_npc = nil
            set_state(STATE_FIND_NEXT)
        end
        return
    end

    if state == STATE_PHASE_WAIT then
        if #phase_reminders_pending > 0 then
            local remaining = phase_wait_until - now
            while #phase_reminders_pending > 0 and remaining <= phase_reminders_pending[1] do
                local threshold = table.remove(phase_reminders_pending, 1)
                local mins = math.floor(threshold / 60)
                chat(string.format('[%s] %d minute(s) remaining',
                    pending_phase and pending_phase.label or 'wait', mins))
            end
        end

        local arrived_by_position = false
        if warp_arrival_dest then
            local me = windower.ffxi.get_mob_by_target('me')
            if me and me.x and me.y then
                local dx = me.x - warp_arrival_dest.x
                local dy = me.y - warp_arrival_dest.y
                local d  = math.sqrt(dx*dx + dy*dy)
                if d <= POST_WARP_ARRIVE_DIST then
                    arrived_by_position = true
                end
            end
        end
        if not arrived_by_position and now < phase_wait_until then return end
        warp_arrival_dest = nil

        local phase = pending_phase
        pending_phase = nil

        if not phase.plan and not phase.build_plan then
            current_plan    = {}
            plan_index      = 1
            cycle_end_index = 0
            current_npc     = nil
            set_state(STATE_FIND_NEXT)
            return
        end

        local plan = phase.plan or phase.build_plan() or {}
        if #plan == 0 then
            err(string.format('Phase "%s": no targets, skipping.', phase.label or '?'))
            current_plan    = {}
            plan_index      = 1
            cycle_end_index = 0
            set_state(STATE_FIND_NEXT)
            return
        end
        chat(string.format('Phase "%s": %d entries', phase.label or '?', #plan))
        current_plan    = plan
        plan_index      = 1
        cycle_end_index = #plan
        current_npc     = nil
        set_state(STATE_FIND_NEXT)
        return
    end
end)

windower.register_event('incoming chunk', function(id, data)
    if state == STATE_IDLE then return end

    if id == 0x032 or id == 0x033 or id == 0x034 then
        if state ~= STATE_POKED then return end
        local p = packets.parse('incoming', data)
        if not p then return end
        local npc_id = p['NPC'] or p['NPC ID'] or p['Target ID'] or p['Target']
        if npc_id ~= current_npc.id then return end

        current_npc.menu_id = p['Menu ID'] or 0

        local plan  = current_npc.plan
        local count = nil
        if id == 0x034 and plan.mode == 'multi' then
            count = extract_harvest_count(p)
        end

        build_message_queue(count)
        if plan.mode == 'multi' then
            chat(string.format('Starting %s with %d harvest%s',
                current_npc.name, count or 0, (count or 0) == 1 and '' or 's'))
        else
            chat(string.format('Starting %s', current_npc.name))
        end

        if not send_next_in_queue() then
            err('Empty queue for ' .. current_npc.name)
            go_to_cooldown()
            return true
        end
        set_state(STATE_SENDING)
        return true
    end

    if id == 0x052 then
        if state ~= STATE_SENDING then return end
        local p = packets.parse('incoming', data)
        local rtype = p and p['Type'] or 0

        if rtype == 0x02 then
            err('Got Event Skip release on ' .. current_npc.name .. ', moving on.')
            go_to_cooldown()
            return
        end

        if not current_npc.queue or #current_npc.queue == 0 then
            chat(string.format('Done with %s (step %d of %d)',
                current_npc.name, plan_index, cycle_end_index))
            if current_npc.plan and current_npc.plan.mode == 'warp' then
                warp_arrival_dest = {
                    x = current_npc.plan.warp_x,
                    y = current_npc.plan.warp_y,
                    z = current_npc.plan.warp_z,
                }
            end
            go_to_cooldown()
            return
        end

        inter_message_until = os.clock() + INTER_MESSAGE_DELAY
        set_state(STATE_INTER_MESSAGE)
        return
    end
end)

windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or 'help'):lower()
    local args = {...}

    local function begin_run(plan, label, require_garden_zone, chain)
        if state ~= STATE_IDLE then
            err('Already running (state=' .. state .. '). Use //bon cancel first.')
            return
        end
        if require_garden_zone and not in_mog_garden() then
            err('This command is only usable within the Mog Garden.')
            return
        end
        if not plan or #plan == 0 then
            err('Nothing to do (empty plan).')
            return
        end
        current_plan    = plan
        plan_index      = 1
        cycle_end_index = #plan
        phase_chain     = chain or {}
        chat(label)
        set_state(STATE_FIND_NEXT)
    end

    local single_aliases = {
        mine    = 1, vein  = 1, mineral = 1,
        dredger = 2, pond  = 2,
        grove   = 3, tree  = 3,
        net     = 4, fish  = 4, fishing = 4,
    }

    if cmd == 'garden' or cmd == 'start' then
        begin_run(NPC_PLAN_GARDEN,
            'Starting garden cycle: Mineral Vein -> Pond Dredger -> Arboreal Grove -> Coastal Fishing Net',
            true)

    elseif cmd == 'pet' then
        local monsters = build_monster_plan()
        if #monsters == 0 then
            err(string.format('No breeding monsters found at indices 0x%02X-0x%02X in current zone.',
                MONSTER_INDEX_LO, MONSTER_INDEX_HI))
            return
        end
        local me = windower.ffxi.get_mob_by_target('me')
        if me and me.x and me.y then
            local closest = math.huge
            for _, entry in ipairs(monsters) do
                local m = windower.ffxi.get_mob_by_index(entry.index)
                if m and m.x and m.y then
                    local dx, dy = m.x - me.x, m.y - me.y
                    local d = math.sqrt(dx*dx + dy*dy)
                    if d < closest then closest = d end
                end
            end
            if closest > PET_DISTANCE_LIMIT then
                err(string.format('Closest monster is %.0f yalms away. //bon pet must be run from the rearing grounds. Use //bon all from Mog Garden instead.',
                    closest))
                return
            end
        end
        begin_run(monsters,
            string.format('Petting %d monster(s).', #monsters),
            false)

    elseif cmd == 'furrow' then
        local sub = (args[1] or ''):lower()
        if sub == 'stop' or sub == 'cancel' then
            if state == STATE_IDLE then
                chat('No furrow loop running.')
            else
                chat('Furrow loop stopped.')
                reset_all()
            end
        elseif sub == 'status' then
            if state == STATE_IDLE or loop_template == nil then
                chat('No furrow loop running.')
            elseif state == STATE_PHASE_WAIT and pending_phase
                   and pending_phase.label == 'Furrows growing' then
                local remaining = phase_wait_until - os.clock()
                if remaining > 0 then
                    local mins = math.ceil(remaining / 60)
                    chat(string.format('Furrows growing. About %d minute(s) until ready to harvest.', mins))
                else
                    chat('Furrows ready, harvesting shortly.')
                end
            else
                local first = current_plan[1]
                local phase_desc
                if first and first.trade then
                    phase_desc = 'planting'
                elseif first and first.mode == 'pet' then
                    phase_desc = 'harvesting'
                else
                    phase_desc = 'working on'
                end
                chat(string.format('Furrow loop active. Currently %s furrow %d of %d.',
                    phase_desc, plan_index, cycle_end_index))
            end
        elseif sub == 'start' then
            local mode_arg = args[2]
            local fert_arg = args[3] or args[2]
            local start_with_harvest
            if mode_arg == nil or mode_arg == '' or mode_arg == '1' then
                start_with_harvest = false
            elseif mode_arg == '2' then
                start_with_harvest = true
            elseif mode_arg == 'fert' or mode_arg == 'fertilize' then
                start_with_harvest = false
                USE_FERTILIZER = true
            else
                err('Usage: //bon furrow start [1|2] [fert]   (1 = plant first [default], 2 = harvest first, fert = use Miracle Mulch)')
                return
            end
            -- Check for fert as second arg
            if fert_arg == 'fert' or fert_arg == 'fertilize' then
                USE_FERTILIZER = true
            elseif mode_arg ~= 'fert' and mode_arg ~= 'fertilize' then
                USE_FERTILIZER = false
            end

            local initial = start_with_harvest
                and build_furrow_harvest_plan()
                or  build_furrow_plant_plan()
            if #initial == 0 then
                err('No Garden Furrows found in zone.')
                return
            end

            local inv = windower.ffxi.get_items(0) or {}
            local roots = 0
            for slot = 1, #inv do
                local it = inv[slot]
                if it and it.id == REVIVAL_ROOT_ITEM_ID then
                    roots = roots + (it.count or 0)
                end
            end
            if roots == 0 then
                err(string.format('No Revival Roots (item %d) in main inventory; need at least one to plant.',
                    REVIVAL_ROOT_ITEM_ID))
                return
            end
            chat(string.format('Inventory has %d Revival Root(s); %d furrow(s) found.',
                roots, #initial))

            local plant_phase   = { label='Plant furrows',      build_plan=build_furrow_plant_plan,      pre_delay=0 }
            local fert_phase    = { label='Fertilize furrows',  build_plan=build_furrow_fertilize_plan, pre_delay=5 }
            local wait_phase    = { label='Furrows growing',
                                    pre_delay = USE_FERTILIZER and FURROW_FERT_WAIT_SECONDS or FURROW_HARVEST_WAIT_SECONDS,
                                    reminders = FURROW_REMINDER_SECONDS }
            local harvest_phase = { label='Harvest furrows', build_plan=build_furrow_harvest_plan, pre_delay=0 }
            local rest_phase    = { label=string.format('%d second rest between cycles', FURROW_REST_SECONDS),
                                    pre_delay = FURROW_REST_SECONDS }

            local initial_chain
            local start_label
            if start_with_harvest then
                if USE_FERTILIZER then
                    initial_chain = { rest_phase, plant_phase, fert_phase, wait_phase, harvest_phase }
                    start_label   = string.format('Furrow loop start (harvest first): %d furrow(s), harvest -> rest -> plant -> fertilize -> wait -> repeat',
                                                  #initial)
                else
                    initial_chain = { rest_phase, plant_phase, wait_phase, harvest_phase }
                    start_label   = string.format('Furrow loop start (harvest first): %d furrow(s), harvest -> rest -> plant -> wait -> repeat',
                                                  #initial)
                end
            else
                if USE_FERTILIZER then
                    initial_chain = { fert_phase, wait_phase, harvest_phase }
                    start_label   = string.format('Furrow loop start: %d furrow(s), plant -> fertilize -> wait -> harvest -> repeat',
                                                  #initial)
                else
                    initial_chain = { wait_phase, harvest_phase }
                    start_label   = string.format('Furrow loop start: %d furrow(s), plant -> wait -> harvest -> repeat',
                                                  #initial)
                end
            end
            begin_run(initial, start_label, true, initial_chain)
            if USE_FERTILIZER then
                loop_template = { rest_phase, plant_phase, fert_phase, wait_phase, harvest_phase }
            else
                loop_template = { rest_phase, plant_phase, wait_phase, harvest_phase }
            end
        else
            chat('Usage: //bon furrow start [1|2] | stop | status')
        end

    elseif cmd == 'all' then
        local order, name = get_bonall_order_for_current()
        if not order then
            err('Not logged in yet.')
            return
        end
        if #order == 0 then
            err('//bon all order is empty. Use //bon add <node> first.')
            return
        end

        local initial_plan = {}
        local has_pet = false
        for _, key in ipairs(order) do
            if key == 'pet' then
                has_pet = true
            else
                local e = build_node_entry(key)
                if e then initial_plan[#initial_plan+1] = e end
            end
        end

        local chain = {}
        if has_pet then
            chain[#chain+1] = { plan      = { WARP_TO_REARING_GROUNDS },
                                label     = 'Warp to rearing grounds',
                                pre_delay = 1.5 }
            chain[#chain+1] = { build_plan = build_monster_plan,
                                label      = 'Pet monsters',
                                pre_delay  = POST_WARP_DELAY }
        end

        if #initial_plan == 0 then
            initial_plan = { WARP_TO_REARING_GROUNDS }
            chain = { { build_plan = build_monster_plan,
                        label      = 'Pet monsters',
                        pre_delay  = POST_WARP_DELAY } }
        end

        begin_run(initial_plan,
            'Starting //bon all: ' .. format_order(order),
            true, chain)

    elseif single_aliases[cmd] then
        local idx = single_aliases[cmd]
        local entry = NPC_PLAN_GARDEN[idx]
        begin_run({entry}, 'Single garden NPC: ' .. entry.name_prefix, true)

    elseif cmd == 'flotsam' then
        local entry = { kind='garden', name_prefix='Flotsam', opt=1, mode='pet' }
        begin_run({entry}, 'Single garden NPC: Flotsam', true)

    elseif cmd == 'add' or cmd == 'remove' then
        local target = (args[1] or ''):lower()
        if target == '' or not NODE_KEY_SET[target] then
            err('Usage: //bon ' .. cmd .. ' (mine|dredger|grove|net|flotsam|pet)')
            return
        end
        local order, name = get_bonall_order_for_current()
        if not order then
            err('Not logged in yet.')
            return
        end
        if cmd == 'add' then
            if index_of_key(order, target) then
                chat(target .. ' is already in the //bon all order.')
                return
            end
            order[#order+1] = target
            if save_bonall_settings(bonall_settings) then
                chat(string.format('Added %s. Order: %s', target, format_order(order)))
            else
                err('Order updated in memory but failed to save to disk.')
            end
        else
            local idx = index_of_key(order, target)
            if not idx then
                chat(target .. ' is not in the //bon all order.')
                return
            end
            table.remove(order, idx)
            if save_bonall_settings(bonall_settings) then
                chat(string.format('Removed %s. Order: %s', target, format_order(order)))
            else
                err('Order updated in memory but failed to save to disk.')
            end
        end

    elseif cmd == 'list' then
        local order, name = get_bonall_order_for_current()
        if not order then
            err('Not logged in yet.')
            return
        end
        chat('//bon all order: ' .. format_order(order))

    elseif cmd == 'cancel' or cmd == 'stop' then
        if state == STATE_IDLE then
            chat('Nothing to cancel.')
        else
            chat('Cancelled.')
            reset_all()
        end

    elseif cmd == 'fertilize' or cmd == 'fert' then
        USE_FERTILIZER = not USE_FERTILIZER
        chat('Fertilizer (Miracle Mulch): ' .. (USE_FERTILIZER and 'ON' or 'OFF'))

    else
        chat('Commands:')
        chat('  all                              Run your customized //bon all order (see //bon list)')
        chat('  garden                           Run all 4 garden nodes (Mog Garden)')
        chat('  pet                              Pet all monsters in current zone (idx 0x8A-0x8D)')
        chat('  furrow start [1|2] | stop | status   Loop plant <-> harvest. 1=plant first (default), 2=harvest first')
        chat('  fert                             Toggle Miracle Mulch fertilizing (default: OFF)')
        chat('  mine | dredger | grove | net     Run just one garden NPC')
        chat('  flotsam                          Interact with Flotsam')
        chat('  add | remove (mine|dredger|grove|net|flotsam|pet)   Customize //bon all order (per-character, saved)')
        chat('  list                             Show your //bon all order')
        chat('  cancel                           Abort current run')
        chat('  status                           Show current state')
    end
end)

windower.register_event('zone change', function(new_zone)
    if state == STATE_IDLE then return end
    local needs_garden = false
    for _, entry in ipairs(current_plan) do
        if entry.kind == 'garden' or entry.kind == 'warp' then needs_garden = true break end
    end
    if needs_garden and new_zone ~= MOG_GARDEN_ZONE then
        err('Left Mog Garden unexpectedly, aborting cycle.')
        reset_all()
    end
end)
