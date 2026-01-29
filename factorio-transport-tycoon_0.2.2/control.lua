-- control.lua

local util = require("util")

-- constants
local BUG_FORCE       = "bugs-trade"
local BOARD_NAME      = "sbt-contract-board"
local TRADEPOST_REQUEST_NAME  = "sbt-bug-tradepost"
local TRADEPOST_OFFER_NAME    = "sbt-bug-tradepost-offer"

-- board icon area inside selection_box
local BOARD_SEL_BOX = { left = -2.5, top = -3.3, right = 2.5, bottom = 1.0 }
local BOARD_MARGIN  = 0.35

-- sprite sizing
local ITEM_BASE_PX   = 64      -- typical item sprite is 64 px
local PX_PER_TILE    = 32
local MIN_GAP_TILES  = 0.075   -- spacing between icons in tiles
local OFFER_STOCK_CAP = 5000

-- forward declarations
local clear_board_icons
local draw_board_icons
local refresh_board_icons
local get_colony_offers

-------------------------------------------------
-- helpers
-------------------------------------------------

local function make_colony_name(kind, mode)
  if kind == "metal"      then return "Kolonia Metali" end
  if kind == "components" then return "Kolonia Komponentow" end
  if kind == "engines"    then return "Kolonia Silnikow" end
  return "Kolonia Handlowa"
end

local function get_colony_name(colony)
  local n = colony and colony.name or nil
  if type(n) == "string" then return n end
  return "Kolonia Handlowa"
end

-------------------------------------------------
-- storage init and migration
-------------------------------------------------

local function rebuild_entity_index()
  storage.entity_to_colony = {}
  for id, c in pairs(storage.colonies or {}) do
    if c.tradepost and c.tradepost.valid then
      storage.entity_to_colony[c.tradepost.unit_number] = id
    end
    if c.board and c.board.valid then
      storage.entity_to_colony[c.board.unit_number] = id
    end
  end
end

local function migrate_colonies()
  if not storage.colonies then return end

  for _, colony in pairs(storage.colonies) do
    if colony.entity and not colony.tradepost then
      if colony.entity.valid then colony.tradepost = colony.entity end
      colony.entity = nil
    end

    if colony.tradepost and colony.tradepost.valid then
      colony.pos = colony.pos or { x = colony.tradepost.position.x, y = colony.tradepost.position.y }
      colony.surface_index = colony.surface_index or colony.tradepost.surface.index
    end

    colony.enabled  = colony.enabled  or {}
    colony.partial  = colony.partial  or {}
    colony.rr_index = colony.rr_index or 1
    colony.icons_drawn = colony.icons_drawn or false
    colony.mode = "normal"
    if colony.tradepost and colony.tradepost.valid and colony.tradepost.name == TRADEPOST_OFFER_NAME then
      colony.trade_type = "offer"
    elseif colony.tradepost and colony.tradepost.valid and colony.tradepost.name == TRADEPOST_REQUEST_NAME then
      colony.trade_type = "request"
    elseif not colony.trade_type then
      colony.trade_type = (colony.id and (colony.id % 2 == 0)) and "offer" or "request"
    end

    if type(colony.name) ~= "string" then
      colony.name = make_colony_name(colony.kind or "generic", colony.mode or "normal")
    end
  end

  rebuild_entity_index()
end

-------------------------------------------------
-- item caches from runtime prototypes
-------------------------------------------------

local function build_item_caches()
  storage.trade_items = {}
  storage.intermediate_items = {}
  storage.science_items = {}

  if not prototypes or not prototypes.item then
    return
  end

  for name, proto in pairs(prototypes.item) do
    local in_group = false
    if proto.group and proto.group.valid and proto.group.name == "intermediate-products" then
      in_group = true
    elseif proto.subgroup and proto.subgroup.valid and proto.subgroup.group
      and proto.subgroup.group.valid and proto.subgroup.group.name == "intermediate-products" then
      in_group = true
    end

    if in_group then
      table.insert(storage.intermediate_items, name)
    end

    if string.find(name, "science%-pack") then
      table.insert(storage.science_items, name)
    end
  end

  if prototypes.item["space-science-pack"] then
    local found = false
    for _, n in ipairs(storage.science_items) do
      if n == "space-science-pack" then found = true break end
    end
    if not found then table.insert(storage.science_items, "space-science-pack") end
  end

  for _, name in ipairs(storage.intermediate_items) do
    table.insert(storage.trade_items, name)
  end
  for _, name in ipairs(storage.science_items) do
    table.insert(storage.trade_items, name)
  end
end

local function init_storage()
  storage.players          = storage.players          or {}
  storage.colonies         = storage.colonies         or {}
  storage.next_colony_id   = storage.next_colony_id   or 1
  storage.board_render_objs = storage.board_render_objs or {}  -- [colony_id] -> {LuaRenderObject}
  migrate_colonies()
  build_item_caches()
end

-------------------------------------------------
-- forces
-------------------------------------------------

local function ensure_bug_force()
  if not game.forces[BUG_FORCE] then
    game.create_force(BUG_FORCE)
  end
  local bugs = game.forces[BUG_FORCE]
  local player_force = game.forces["player"]
  if player_force then
    bugs.set_cease_fire(player_force, true)
    player_force.set_cease_fire(bugs, true)
    bugs.set_friend(player_force, true)
    player_force.set_friend(bugs, true)
  end
end

-------------------------------------------------
-- settings
-------------------------------------------------

local function get_offer_generosity()
  local g = settings.global or {}
  local v = (g["ftt-offer-generosity"] and g["ftt-offer-generosity"].value) or 10
  if v < 1 then v = 1 end
  if v > 10 then v = 10 end
  return v
end

local function get_dynamic_spawn_config()
  local g = settings.global or {}
  local chance = (g["ftt-colony-spawn-chance"] and g["ftt-colony-spawn-chance"].value) or 0.02
  local tries  = (g["ftt-colony-spawn-tries"]  and g["ftt-colony-spawn-tries"].value)  or 2
  if chance < 0 then chance = 0 end
  if chance > 1 then chance = 1 end
  if tries  < 1 then tries  = 1 end
  if tries  > 10 then tries  = 10 end
  return chance, tries
end

-------------------------------------------------
-- start pack
-------------------------------------------------

local function give_start_pack(player)
  if not (player and player.valid) then return end
  storage.players[player.index] = storage.players[player.index] or {}
end

-------------------------------------------------
-- colony spawn and registry
-------------------------------------------------

local function register_colony(surface, pos, kind)
  if not (surface and surface.valid and pos) then return nil end

  local trade_type = (math.random() < 0.5) and "offer" or "request"
  local tradepost_name = (trade_type == "offer") and TRADEPOST_OFFER_NAME or TRADEPOST_REQUEST_NAME
  local tradepost = surface.create_entity{ name = tradepost_name, position = pos, force = BUG_FORCE }
  if not (tradepost and tradepost.valid) then return nil end

  local board_pos = { x = pos.x + 3, y = pos.y }
  local board = surface.create_entity{ name = BOARD_NAME, position = board_pos, force = BUG_FORCE }

  local id = storage.next_colony_id
  storage.next_colony_id = id + 1

  local colony = {
    id            = id,
    pos           = { x = tradepost.position.x, y = tradepost.position.y },
    board_pos     = board and { x = board.position.x, y = board.position.y } or nil,
    surface_index = surface.index,
    kind          = kind or "metal",
    name          = make_colony_name(kind, "normal"),
    mode          = "normal",
    trade_type    = trade_type,
    tradepost     = tradepost,
    board         = board,
    offers        = nil,
    enabled       = {},
    partial       = {},
    rr_index      = 1,
    icons_drawn   = false
  }

  storage.colonies[id] = colony
  storage.entity_to_colony = storage.entity_to_colony or {}
  storage.entity_to_colony[tradepost.unit_number] = id
  if board then storage.entity_to_colony[board.unit_number] = id end

--refresh_board_icons(colony)  

  return colony
end

local function get_spawn_center(surface)
  if game.forces["player"] and game.forces["player"].valid then
    local sp = game.forces["player"].get_spawn_position(surface)
    return { x = sp.x, y = sp.y }
  end
  return { x = 0, y = 0 }
end

local function create_start_colonies()
  if next(storage.colonies) then return end

  local surface = game.surfaces[1]
  if not surface then return end

  ensure_bug_force()

  local center = get_spawn_center(surface)
  local radius_normal = 220

  local normals = 10
  for i = 0, normals - 1 do
    local angle = (2 * math.pi / normals) * i
    local target = { center.x + math.cos(angle) * radius_normal, center.y + math.sin(angle) * radius_normal }
    local pos = surface.find_non_colliding_position(TRADEPOST_REQUEST_NAME, target, 24, 1)
    if pos then
      local kinds = { "metal", "components", "engines" }
      local kind = kinds[(i % #kinds) + 1]
      local c = register_colony(surface, pos, kind)
      if c then c.offers = nil end
    end
  end
end

-------------------------------------------------
-- lifecycle
-------------------------------------------------

script.on_init(function()
  init_storage()
  ensure_bug_force()
  create_start_colonies()
end)

script.on_configuration_changed(function(_)
  init_storage()
  ensure_bug_force()
  create_start_colonies()

  for _, c in pairs(storage.colonies or {}) do
    clear_board_icons(c)
    c.offers   = nil
    c.partial  = {}
    c.rr_index = 1
  end

  for _, p in pairs(game.players) do
    give_start_pack(p)
  end
end)

script.on_event(defines.events.on_player_created, function(e)
  init_storage()
  ensure_bug_force()
  create_start_colonies()
  local player = game.get_player(e.player_index)
  give_start_pack(player)
end)

-------------------------------------------------
-- dynamic spawn
-------------------------------------------------

script.on_event(defines.events.on_chunk_generated, function(e)
  local surface = e.surface
  if not (surface and surface.valid) then return end
  if surface.name ~= "nauvis" then return end

  ensure_bug_force()

  local chance, tries = get_dynamic_spawn_config()

  for _ = 1, tries do
    if math.random() < chance then
      local center = { x = (e.position.x + 0.5) * 32, y = (e.position.y + 0.5) * 32 }
      local pos = surface.find_non_colliding_position(TRADEPOST_REQUEST_NAME, center, 16, 1)
      if pos then
        local kinds = { "metal", "components", "engines" }
        local kind = kinds[math.random(1, #kinds)]
        local c = register_colony(surface, pos, kind)
        if c then c.offers = nil end
        break
      end
    end
  end
end)

-------------------------------------------------
-- item pools
-------------------------------------------------

local function get_item_pool_for_colony(colony)
  return storage.trade_items or {}
end

-------------------------------------------------
-- offer generation for normal colonies
-------------------------------------------------

local function build_random_offers_for_normal_colony(colony)
  local offers = {}
  local pool = get_item_pool_for_colony(colony)
  if not pool or #pool == 0 then return offers end

  local count_offers = (colony.trade_type == "request") and 4 or math.random(5, 20)
  local used = {}

  local function pick_unique_item()
    if #pool == 0 then return nil end
    for _ = 1, #pool do
      local idx = math.random(1, #pool)
      local name = pool[idx]
      if name and not used[name] then
        used[name] = true
        return name
      end
    end
    return nil
  end

  local generosity = get_offer_generosity()

  for _ = 1, count_offers do
    local item = pick_unique_item()
    if not item then break end

    local proto = prototypes.item[item]
    local stack = (proto and proto.stack_size) or 100

    local base_amount = math.max(1, math.floor(stack * (0.4 + math.random() * 1.6)))
    base_amount = math.min(base_amount, 400)

    local cost_count = math.max(1, math.floor(base_amount / (generosity * 1.1)))

    table.insert(
      offers,
      {
        give = { name = item, count = base_amount },
        cost = (colony.trade_type == "request")
          and { { name = item, count = base_amount } }
          or {},
        pay = (colony.trade_type == "request")
          and { credits = cost_count }
          or nil
      }
    )
  end

  return offers
end

-------------------------------------------------
-- get offers
-------------------------------------------------

get_colony_offers = function(colony)
  if colony.offers then return colony.offers end

  colony.offers = build_random_offers_for_normal_colony(colony)
  return colony.offers
end

-------------------------------------------------
-- board icon rendering
-------------------------------------------------

clear_board_icons = function(colony)
  if not colony then return end
  if not storage.board_render_objs then return end
  local bag = storage.board_render_objs[colony.id]
  if not bag then return end

  for _, obj in pairs(bag) do
    if obj and obj.valid then
      pcall(function() obj.destroy() end)
    end
  end

  storage.board_render_objs[colony.id] = {}
  colony.icons_drawn = false
end

draw_board_icons = function(colony)
  if not colony or not colony.board or not colony.board.valid then return end
  local board = colony.board
  local surf  = board.surface
  local bpos  = board.position
  if not (surf and surf.valid) then return end

  storage.board_render_objs = storage.board_render_objs or {}
  storage.board_render_objs[colony.id] = storage.board_render_objs[colony.id] or {}
  local store = storage.board_render_objs[colony.id]

  local inner_left   = BOARD_SEL_BOX.left   + BOARD_MARGIN
  local inner_top    = BOARD_SEL_BOX.top    + BOARD_MARGIN
  local inner_right  = BOARD_SEL_BOX.right  - BOARD_MARGIN
  local inner_bottom = BOARD_SEL_BOX.bottom - BOARD_MARGIN
  local inner_w      = inner_right - inner_left
  local inner_h      = inner_bottom - inner_top

  local function add_sprite(sprite, offx_rel, offy_rel, scale)
    local obj = rendering.draw_sprite{
      sprite  = sprite,
      surface = surf,
      target  = { x = bpos.x + offx_rel, y = bpos.y + offy_rel },
      x_scale = scale,
      y_scale = scale
    }
    if obj then
      table.insert(store, obj)
    end
  end

  local function add_text(text, offx_rel, offy_rel)
    local obj = rendering.draw_text{
      text = text,
      surface = surf,
      target = { x = bpos.x + offx_rel, y = bpos.y + offy_rel },
      color = { 1, 1, 1, 1 },
      scale = 1.0,
      alignment = "left"
    }
    if obj then
      table.insert(store, obj)
    end
  end

  local icons = {}
  local offers = get_colony_offers(colony)
  if offers and #offers > 0 then
    local seen = {}
    for _, off in ipairs(offers) do
      local itm = nil
      if colony.trade_type == "request" then
        itm = off.cost and off.cost[1] and off.cost[1].name
      else
        itm = off.give and off.give.name
      end
      if itm and not seen[itm] then
        seen[itm] = true
        table.insert(icons, "item/" .. itm)
      end
      if #icons >= 24 then break end
    end
  end

  local n = #icons
  if n == 0 then return end

  local rows = (colony.trade_type == "request") and n or 4
  local cols = (colony.trade_type == "request") and 1 or math.max(1, math.ceil(n / rows))

  local gap_x = MIN_GAP_TILES
  local gap_y = MIN_GAP_TILES
  local base_tiles = ITEM_BASE_PX / PX_PER_TILE

  local cell_w = (inner_w - (cols - 1) * gap_x) / cols
  local cell_h = (inner_h - (rows - 1) * gap_y) / rows
  if cell_w <= 0 or cell_h <= 0 then return end

  local s = math.min(cell_w / base_tiles, cell_h / base_tiles)
  s = math.max(0.30, math.min(s, 0.80))

  local start_x_rel = inner_left + cell_w * 0.5
  local start_y_rel = inner_top  + cell_h * 0.5

  for i = 0, n - 1 do
    local r = i % rows
    local c = math.floor(i / rows)
    local x_rel = start_x_rel + c * (cell_w + gap_x)
    local y_rel = start_y_rel + r * (cell_h + gap_y)
    add_sprite(icons[i + 1], x_rel, y_rel, s)
    if colony.trade_type == "request" then
      local offer = offers[i + 1]
      local want = offer and offer.cost and offer.cost[1]
      local pay = offer and offer.pay
      if want and pay and pay.credits then
        local label = tostring(want.count) .. "x " .. want.name .. " -> " .. tostring(pay.credits) .. " credits"
        add_text(label, x_rel + (cell_w * 0.6), y_rel)
      end
    end
  end
end

refresh_board_icons = function(colony)
  if not colony then return end
  clear_board_icons(colony)
  draw_board_icons(colony)
end

local function ensure_board_icons(colony)
  if not colony or colony.icons_drawn then return end
  refresh_board_icons(colony)
  colony.icons_drawn = true
end

-------------------------------------------------
-- cleanup
-------------------------------------------------

local function on_entity_removed(ent)
  if not storage.entity_to_colony then return end
  if not ent then return end
  local id = ent.valid and storage.entity_to_colony[ent.unit_number] or nil
  if not id then return end
  local col = storage.colonies and storage.colonies[id]
  if not col then
    storage.entity_to_colony[ent.unit_number] = nil
    return
  end
  if col.board == ent or col.tradepost == ent then
    clear_board_icons(col)
  end
  storage.entity_to_colony[ent.unit_number] = nil
end

script.on_event(defines.events.on_entity_died, function(e) on_entity_removed(e.entity) end)
script.on_event(defines.events.on_pre_player_mined_item, function(e) on_entity_removed(e.entity) end)
script.on_event(defines.events.on_robot_mined_entity, function(e) on_entity_removed(e.entity) end)

-------------------------------------------------
-- fair trade loop round robin
-------------------------------------------------

local function add_blackmarket_credits(amount)
  if not amount or amount <= 0 then return end
  if not (remote and remote.interfaces and remote.interfaces.market) then return end
  if not remote.interfaces.market.get_credits then return end
  if not remote.interfaces.market.credits then return end

  local player_force = game.forces["player"]
  if not (player_force and player_force.valid) then return end

  local ok, current = pcall(remote.call, "market", "get_credits", player_force.name)
  if not ok or type(current) ~= "number" then return end

  local applied = pcall(remote.call, "market", "credits", current + amount)
  return applied
end

local function get_offer_stock_target(item_name, base_amount)
  if not prototypes or not prototypes.item then
    local fallback = math.max(base_amount or 0, 100)
    return math.min(fallback, OFFER_STOCK_CAP)
  end
  local proto = prototypes.item[item_name]
  local stack = (proto and proto.stack_size) or 100
  local target = math.max(base_amount or 0, stack * 5)
  return math.min(target, OFFER_STOCK_CAP)
end

local function stock_offer_inventory(colony)
  local ent = colony.tradepost
  if not (ent and ent.valid) then return end

  local inv = ent.get_inventory(defines.inventory.chest)
  if not (inv and inv.valid) then return end

  local offers = get_colony_offers(colony)
  if not offers or #offers == 0 then return end

  colony.enabled = colony.enabled or {}
  for idx, off in ipairs(offers) do
    if colony.enabled[idx] ~= false and off.give and off.give.name then
      local desired = get_offer_stock_target(off.give.name, off.give.count)
      local current = inv.get_item_count(off.give.name)
      if current < desired then
        inv.insert({ name = off.give.name, count = desired - current })
      end
    end
  end
end

local function process_requesting_colony(colony)
  local ent = colony.tradepost
  if not (ent and ent.valid) then return end

  local inv = ent.get_inventory(defines.inventory.chest)
  if not (inv and inv.valid) then return end

  local offers = get_colony_offers(colony)
  if not offers or #offers == 0 then return end

  colony.enabled = colony.enabled or {}
  for idx, off in ipairs(offers) do
    if colony.enabled[idx] == false then
      goto continue
    end
    local want = off.cost and off.cost[1]
    local pay = off.pay
    if want and pay and pay.credits then
      local available = inv.get_item_count(want.name)
      if available >= want.count then
        local batches = math.floor(available / want.count)
        for _ = 1, batches do
          if add_blackmarket_credits(pay.credits) then
            inv.remove({ name = want.name, count = want.count })
          else
            break
          end
        end
      end
    end
    ::continue::
  end
end

local function process_colony_trade_round_robin(colony)
  ensure_board_icons(colony)
  if colony.trade_type == "offer" then
    stock_offer_inventory(colony)
    return
  end
  if colony.trade_type == "request" then
    process_requesting_colony(colony)
    return
  end
  local ent = colony.tradepost
  if not (ent and ent.valid) then return end

  local inv = ent.get_inventory(defines.inventory.chest)
  if not (inv and inv.valid) then return end

  local offers = get_colony_offers(colony)
  if not offers or #offers == 0 then return end

  colony.enabled = colony.enabled or {}
  colony.partial = colony.partial or {}
  colony.rr_index = colony.rr_index or 1

  local idxs = {}
  for i = 1, #offers do
    if colony.enabled[i] ~= false then
      table.insert(idxs, i)
    end
  end
  if #idxs == 0 then return end

  local start = colony.rr_index
  if start < 1 or start > #idxs then start = 1 end

  for step = 1, #idxs do
    local idx = idxs[((start - 1 + step - 1) % #idxs) + 1]
    local off = offers[idx]
    if off and off.give and off.cost and #off.cost > 0 then
      if #off.cost == 1 then
        local cost = off.cost[1]
        local cur_name = cost.name
        if inv.get_item_count(cur_name) > 0 then
          inv.remove({ name = cur_name, count = 1 })
          local partial = colony.partial[idx] or 0
          partial = partial + 1
          if partial >= cost.count then
            if inv.can_insert({ name = off.give.name, count = off.give.count }) then
              inv.insert({ name = off.give.name, count = off.give.count })
              partial = partial - cost.count
            else
              inv.insert({ name = cur_name, count = 1 })
              partial = partial - 1
            end
          end
          colony.partial[idx] = math.max(0, partial)
        end
      else
        local can_pay = true
        for _, c in ipairs(off.cost) do
          if inv.get_item_count(c.name) < c.count then can_pay = false break end
        end
        if can_pay and inv.can_insert({ name = off.give.name, count = off.give.count }) then
          for _, c in ipairs(off.cost) do
            inv.remove({ name = c.name, count = c.count })
          end
          inv.insert({ name = off.give.name, count = off.give.count })
        end
      end
    end
  end

  colony.rr_index = ((start) % #idxs) + 1
end

script.on_nth_tick(60, function()
  for _, colony in pairs(storage.colonies or {}) do
    process_colony_trade_round_robin(colony)
  end
end)

-------------------------------------------------
-- lookup helpers
-------------------------------------------------

local function is_same_pos(a, b, radius_sq)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return (dx * dx + dy * dy) <= (radius_sq or 1)
end

local function find_colony_by_board(ent)
  if not (ent and ent.valid) then return nil end
  local pos = ent.position
  for _, colony in pairs(storage.colonies or {}) do
    if colony.board and colony.board.valid and colony.board == ent then return colony end
    if colony.board_pos and is_same_pos(colony.board_pos, pos, 9) then return colony end
  end
  return nil
end

local function find_or_create_colony_by_board(ent)
  local colony = find_colony_by_board(ent)
  if colony then return colony end

  local surface = ent.surface
  if not (surface and surface.valid) then return nil end

  local near_list = surface.find_entities_filtered{
    name = { TRADEPOST_REQUEST_NAME, TRADEPOST_OFFER_NAME },
    position = ent.position,
    radius = 5
  }
  local near = near_list and near_list[1]
  if not (near and near.valid) then return nil end

  local id = storage.next_colony_id or 1
  storage.next_colony_id = id + 1

  local trade_type = (near.name == TRADEPOST_OFFER_NAME) and "offer" or "request"

  colony = {
    id            = id,
    pos           = { x = near.position.x, y = near.position.y },
    board_pos     = { x = ent.position.x, y = ent.position.y },
    surface_index = surface.index,
    kind          = "generic",
    name          = make_colony_name("generic", "normal"),
    mode          = "normal",
    trade_type    = trade_type,
    tradepost     = near,
    board         = ent,
    offers        = nil,
    enabled       = {},
    partial       = {},
    rr_index      = 1,
    icons_drawn   = false
  }

  storage.colonies[id] = colony
  storage.entity_to_colony = storage.entity_to_colony or {}
  storage.entity_to_colony[near.unit_number] = id
  storage.entity_to_colony[ent.unit_number] = id

  return colony
end

-------------------------------------------------
-- GUI
-------------------------------------------------

local function close_trade_gui(player)
  local root = player.gui.screen.sbt_trade_root
  if root and root.valid then root.destroy() end
end

local function format_item_line_text(count, name)
  return tostring(count) .. "x " .. (name or "?")
end

local function format_credit_line_text(count)
  return tostring(count) .. " credits"
end

local function open_trade_gui(player, colony)
  if not (player and player.valid and colony) then return end

  close_trade_gui(player)

  local offers = get_colony_offers(colony)
  local enabled = colony.enabled or {}
  colony.enabled = enabled

  local cname = get_colony_name(colony)

  local root = player.gui.screen.add{
    type = "frame",
    name = "sbt_trade_root",
    direction = "vertical",
    caption = "Handel - " .. cname
  }
  root.auto_center = true

  local header = root.add{ type = "flow", direction = "horizontal" }
  header.add{ type = "label", caption = "Kolonia: " .. cname }

  if colony.trade_type == "request" then
    header.add{ type = "label", caption = "Kontrakt: dostarcz towar za gotowke" }
  else
    header.add{ type = "label", caption = "Oferta: towary dostepne w tradepoście" }
  end

  local close_btn = header.add{ type = "button", name = "sbt_trade_close", caption = "X" }
  close_btn.style.minimal_width = 24

  local controls = root.add{
    type = "flow",
    name = "sbt_trade_controls",
    direction = "horizontal"
  }
  controls.add{
    type = "checkbox",
    name = "sbt_trade_uncheck_all_" .. colony.id,
    state = false,
    caption = "Odznacz wszystkie"
  }

  local list = root.add{ type = "table", name = "sbt_trade_table", column_count = 3, draw_horizontal_lines = true }
  list.add{ type = "label", caption = "" }
  if colony.trade_type == "request" then
    list.add{ type = "label", caption = "Dostarcz" }
    list.add{ type = "label", caption = "Zaplata" }
  else
    list.add{ type = "label", caption = "Otrzymasz" }
    list.add{ type = "label", caption = "Koszt" }
  end

  for i, offer in ipairs(offers) do
    if enabled[i] == nil then enabled[i] = true end
    local cb_name = "sbt_offer_toggle_" .. colony.id .. "_" .. i
    list.add{ type = "checkbox", name = cb_name, state = enabled[i], caption = "" }

    if colony.trade_type == "request" then
      local want = offer.cost and offer.cost[1]
      local pay = offer.pay
      list.add{ type = "label", caption = format_item_line_text(want.count, want.name) }
      list.add{ type = "label", caption = format_credit_line_text(pay.credits or 0) }
    else
      local give = offer.give
      list.add{ type = "label", caption = format_item_line_text(give.count, give.name) }

      local cost_parts = {}
      for idx, c in ipairs(offer.cost) do
        if idx > 1 then table.insert(cost_parts, " + ") end
        table.insert(cost_parts, format_item_line_text(c.count, c.name))
      end
      if #cost_parts == 0 then
        table.insert(cost_parts, "Darmowe")
      end
      list.add{ type = "label", caption = table.concat(cost_parts) }
    end
  end

  player.opened = root
end

script.on_event(defines.events.on_gui_opened, function(e)
  local player = game.get_player(e.player_index)
  if not player then return end

  local element = e.element
  if element and element.valid and element.name == "sbt_trade_root" then
    return
  end

  local ent = e.entity
  if not (ent and ent.valid and ent.name == BOARD_NAME) then
    close_trade_gui(player)
    return
  end

  local colony = find_or_create_colony_by_board(ent)
  if not colony then return end

  player.opened = nil

  refresh_board_icons(colony)
  open_trade_gui(player, colony)
end)

script.on_event(defines.events.on_gui_closed, function(e)
  local player = game.get_player(e.player_index)
  if not player then return end

  local element = e.element
  if not (element and element.valid and element.name == "sbt_trade_root") then return end
  close_trade_gui(player)
end)

script.on_event(defines.events.on_gui_checked_state_changed, function(e)
  local element = e.element
  if not (element and element.valid) then return end
  local player = game.get_player(e.player_index)
  if not player then return end

  local colony_id_all = string.match(element.name, "^sbt_trade_uncheck_all_(%d+)$")
  if colony_id_all then
    local cid = tonumber(colony_id_all)
    local colony = storage.colonies and storage.colonies[cid]
    if not colony then return end

    local offers = get_colony_offers(colony) or {}
    colony.enabled = colony.enabled or {}
    for i = 1, #offers do
      colony.enabled[i] = false
    end

    local root = player.gui.screen.sbt_trade_root
    if root and root.valid then
      local list = root.sbt_trade_table
      if list and list.valid then
        for _, child in pairs(list.children) do
          if child.type == "checkbox" and string.match(child.name, "^sbt_offer_toggle_") then
            child.state = false
          end
        end
      end
    end

    element.state = false
    return
  end

  local colony_id, offer_index = string.match(element.name, "^sbt_offer_toggle_(%d+)_(%d+)$")
  if not (colony_id and offer_index) then return end
  colony_id = tonumber(colony_id)
  offer_index = tonumber(offer_index)
  local colony = storage.colonies and storage.colonies[colony_id]
  if not colony then return end
  colony.enabled = colony.enabled or {}
  colony.enabled[offer_index] = element.state
end)

script.on_event(defines.events.on_gui_click, function(e)
  local element = e.element
  if not (element and element.valid) then return end
  local player = game.get_player(e.player_index)
  if not player then return end
  if element.name == "sbt_trade_close" then
    close_trade_gui(player)
    return
  end
end)
