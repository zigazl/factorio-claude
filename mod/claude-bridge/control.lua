-- claude-bridge: RCON commands (/cb_*) that let an external agent read state and act through the player.
-- Every command takes an optional JSON object as its parameter and replies with JSON:
--   {"ok": true, ...}  or  {"ok": false, "error": "..."}
local common = require("common")
local actions = require("actions")

script.on_init(actions.init)
script.on_configuration_changed(actions.init)
script.on_event(defines.events.on_tick, actions.on_tick)
script.on_event(defines.events.on_script_path_request_finished, actions.on_path_finished)

local function reply(cmd, tbl)
  local json = helpers.table_to_json(tbl)
  if cmd.player_index then
    game.get_player(cmd.player_index).print(json)
  else
    rcon.print(json)
  end
end

local function register(name, help, fn)
  commands.add_command("cb_" .. name, "[claude-bridge] " .. help, function(cmd)
    local args = {}
    if cmd.parameter and cmd.parameter ~= "" then
      args = helpers.json_to_table(cmd.parameter)
      if type(args) ~= "table" then
        reply(cmd, { ok = false, error = "parameter must be a JSON object" })
        return
      end
    end
    local ok, result = pcall(fn, args)
    if ok then
      result = result or {}
      result.ok = true
      reply(cmd, result)
    else
      reply(cmd, { ok = false, error = (tostring(result):gsub("^__claude%-bridge__/[%w_]+%.lua:%d+: ", "")) })
    end
  end)
end

local function need(args, ...)
  for _, key in pairs({ ... }) do
    if args[key] == nil then error("missing argument '" .. key .. "'") end
  end
end

local function reachable_entity(player, args)
  need(args, "x", "y")
  local e = common.entity_at(player.surface, args.x, args.y, args.entity)
  if not e then error("no entity at " .. args.x .. "," .. args.y) end
  if not player.can_reach_entity(e) then error(e.name .. " is out of reach; walk closer first") end
  return e
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

register("state", "Player position, inventory, crafting queue and research.", function()
  local player, character = common.require_character()
  local force = player.force
  local queue = {}
  for _, q in pairs(player.crafting_queue or {}) do
    queue[#queue + 1] = { recipe = q.recipe, count = q.count }
  end
  local research = force.current_research
  local busy = storage.queue and storage.queue[1] and storage.actions[storage.queue[1]]
  return {
    tick = game.tick,
    player = player.object_name == "LuaPlayer" and player.name or "debug-character",
    position = common.pos(character.position),
    health = character.health,
    reach_distance = character.reach_distance,
    build_distance = character.build_distance,
    resource_reach_distance = character.resource_reach_distance,
    inventory = common.contents(player.get_main_inventory()),
    cursor = player.cursor_stack and player.cursor_stack.valid_for_read and player.cursor_stack.name or nil,
    crafting_queue = queue,
    research = research and { name = research.name, progress = common.round(force.research_progress, 2) } or nil,
    current_action = busy and actions.public(busy) or nil,
    queued_actions = storage.queue and math.max(0, #storage.queue - 1) or 0,
  }
end)

-- Groups resource tiles into patches using an 8x8 grid + union-find over neighbouring cells.
local function resource_patches(resources)
  local CELL = 8
  local cells, parent = {}, {}
  local function key(name, cx, cy) return name .. ":" .. cx .. ":" .. cy end
  local function find(k)
    while parent[k] ~= k do
      parent[k] = parent[parent[k]]
      k = parent[k]
    end
    return k
  end
  for _, r in pairs(resources) do
    local cx, cy = math.floor(r.position.x / CELL), math.floor(r.position.y / CELL)
    local k = key(r.name, cx, cy)
    local c = cells[k]
    if not c then
      c = { name = r.name, cx = cx, cy = cy, tiles = 0, amount = 0, sx = 0, sy = 0,
        minx = math.huge, miny = math.huge, maxx = -math.huge, maxy = -math.huge }
      cells[k] = c
      parent[k] = k
    end
    c.tiles = c.tiles + 1
    c.amount = c.amount + r.amount
    c.sx, c.sy = c.sx + r.position.x, c.sy + r.position.y
    c.minx, c.miny = math.min(c.minx, r.position.x), math.min(c.miny, r.position.y)
    c.maxx, c.maxy = math.max(c.maxx, r.position.x), math.max(c.maxy, r.position.y)
  end
  for k, c in pairs(cells) do
    for dx = -1, 1 do
      for dy = -1, 1 do
        local nk = key(c.name, c.cx + dx, c.cy + dy)
        if cells[nk] then parent[find(nk)] = find(k) end
      end
    end
  end
  local patches = {}
  for k, c in pairs(cells) do
    local root = find(k)
    local p = patches[root]
    if not p then
      p = { name = c.name, tiles = 0, amount = 0, sx = 0, sy = 0,
        minx = math.huge, miny = math.huge, maxx = -math.huge, maxy = -math.huge }
      patches[root] = p
    end
    p.tiles, p.amount = p.tiles + c.tiles, p.amount + c.amount
    p.sx, p.sy = p.sx + c.sx, p.sy + c.sy
    p.minx, p.miny = math.min(p.minx, c.minx), math.min(p.miny, c.miny)
    p.maxx, p.maxy = math.max(p.maxx, c.maxx), math.max(p.maxy, c.maxy)
  end
  local out = {}
  for _, p in pairs(patches) do
    out[#out + 1] = {
      name = p.name,
      tiles = p.tiles,
      amount = p.amount,
      center = common.pos({ x = p.sx / p.tiles, y = p.sy / p.tiles }),
      bounds = { left_top = { x = math.floor(p.minx), y = math.floor(p.miny) },
        right_bottom = { x = math.floor(p.maxx), y = math.floor(p.maxy) } },
    }
  end
  table.sort(out, function(a, b) return a.amount > b.amount end)
  return out
end

register("scan", "Entities, resource patches, trees and rocks around the player. {radius?, x?, y?, limit?}", function(args)
  local player, character = common.require_character()
  local center = { x = args.x or character.position.x, y = args.y or character.position.y }
  local radius = math.min(args.radius or 30, 200)
  local limit = args.limit or 150
  local surface = character.surface
  local area = { { center.x - radius, center.y - radius }, { center.x + radius, center.y + radius } }

  local resources = surface.find_entities_filtered { area = area, type = "resource" }
  local trees = surface.find_entities_filtered { area = area, type = "tree" }
  local rocks = {}
  for _, e in pairs(surface.find_entities_filtered { area = area, type = "simple-entity" }) do
    if e.name:find("rock") then rocks[#rocks + 1] = common.pos(e.position) end
  end

  local entities, counts, truncated = {}, {}, false
  local skip = { resource = true, tree = true, ["simple-entity"] = true, character = true,
    corpse = true, ["character-corpse"] = true, ["item-entity"] = true, fish = true }
  local found = surface.find_entities_filtered { area = area }
  table.sort(found, function(a, b)
    return common.dist(a.position, center) < common.dist(b.position, center)
  end)
  for _, e in pairs(found) do
    if not skip[e.type] then
      counts[e.name] = (counts[e.name] or 0) + 1
      if #entities < limit then
        local d = common.describe_entity(e)
        if e.force.name ~= player.force.name then d.force = e.force.name end
        entities[#entities + 1] = d
      else
        truncated = true
      end
    end
  end

  local nearest_trees = {}
  if #trees > 0 then
    table.sort(trees, function(a, b)
      return common.dist(a.position, character.position) < common.dist(b.position, character.position)
    end)
    for i = 1, math.min(5, #trees) do nearest_trees[i] = common.pos(trees[i].position) end
  end

  return {
    center = common.pos(center),
    radius = radius,
    resource_patches = resource_patches(resources),
    trees = { count = #trees, nearest = nearest_trees },
    rocks = rocks,
    entity_counts = counts,
    entities = entities,
    truncated = truncated,
  }
end)

register("map", "ASCII map of an area. {x?, y?, width?, height?} (max 80x80)", function(args)
  local _, character = common.require_character()
  local w = math.min(args.width or 40, 80)
  local h = math.min(args.height or 30, 80)
  local cx = math.floor(args.x or character.position.x)
  local cy = math.floor(args.y or character.position.y)
  local x0, y0 = cx - math.floor(w / 2), cy - math.floor(h / 2)
  local surface = character.surface

  local grid = {}
  for row = 1, h do
    grid[row] = {}
    for col = 1, w do
      local tile = surface.get_tile(x0 + col - 1, y0 + row - 1)
      local ch = "."
      if not tile.valid or tile.name == "out-of-map" then ch = " "
      elseif tile.name:find("water") then ch = "~" end
      grid[row][col] = ch
    end
  end

  local legend = { ["~"] = "water", ["."] = "ground", ["@"] = "you", T = "tree", R = "rock" }
  local resource_chars = { ["iron-ore"] = "i", ["copper-ore"] = "c", coal = "k", stone = "s",
    ["uranium-ore"] = "u", ["crude-oil"] = "o" }
  local symbols, next_symbol = {}, 1
  local pool = "ABDEFGHJKLMNPQSUVWXYZ0123456789#$%&*+=?"
  local function put(x, y, ch)
    local col, row = math.floor(x) - x0 + 1, math.floor(y) - y0 + 1
    if row >= 1 and row <= h and col >= 1 and col <= w then grid[row][col] = ch end
  end

  local area = { { x0, y0 }, { x0 + w, y0 + h } }
  for _, e in pairs(surface.find_entities_filtered { area = area }) do
    local ch
    if e.type == "resource" then
      ch = resource_chars[e.name] or "r"
      legend[ch] = e.name
      put(e.position.x, e.position.y, ch)
    elseif e.type == "tree" then
      put(e.position.x, e.position.y, "T")
    elseif e.type == "simple-entity" and e.name:find("rock") then
      put(e.position.x, e.position.y, "R")
    elseif e.type ~= "character" and e.type ~= "corpse" and e.type ~= "item-entity" then
      ch = symbols[e.name]
      if not ch then
        ch = pool:sub(next_symbol, next_symbol)
        if ch == "" then ch = "?" end
        next_symbol = next_symbol + 1
        symbols[e.name] = ch
        legend[ch] = e.name
      end
      local box = e.bounding_box
      for x = math.floor(box.left_top.x + 0.01), math.ceil(box.right_bottom.x - 0.01) - 1 do
        for y = math.floor(box.left_top.y + 0.01), math.ceil(box.right_bottom.y - 0.01) - 1 do
          put(x, y, ch)
        end
      end
    end
  end
  put(character.position.x, character.position.y, "@")

  local lines = {}
  for row = 1, h do lines[row] = table.concat(grid[row]) end
  return {
    left_top = { x = x0, y = y0 },
    note = "row 1 is y=" .. y0 .. ", column 1 is x=" .. x0 .. "; each char is one tile",
    rows = lines,
    legend = legend,
  }
end)

register("find", "Nearest entity/resource. {name? | type?, radius?, count?}", function(args)
  local player, character = common.require_character()
  if not args.name and not args.type then error("give 'name' (e.g. iron-ore) or 'type' (e.g. tree)") end
  local filter = { position = character.position, radius = math.min(args.radius or 200, 500) }
  filter.name = args.name
  filter.type = args.type
  local found = character.surface.find_entities_filtered(filter)
  table.sort(found, function(a, b)
    return common.dist(a.position, character.position) < common.dist(b.position, character.position)
  end)
  local out = {}
  for i = 1, math.min(args.count or 1, #found) do
    local d = common.describe_entity(found[i])
    d.distance = common.round(common.dist(found[i].position, character.position))
    out[#out + 1] = d
  end
  return { results = out, total_found = #found }
end)

register("inspect", "Details of the entity at a position. {x, y, entity?}", function(args)
  local player = common.require_character()
  need(args, "x", "y")
  local e = common.entity_at(player.surface, args.x, args.y, args.entity)
  if not e then error("no entity at " .. args.x .. "," .. args.y) end
  local d = common.describe_entity(e, true)
  d.reachable = player.can_reach_entity(e)
  return { entity = d }
end)

local function recipe_info(player, r)
  local ingredients, products = {}, {}
  for _, i in pairs(r.ingredients) do ingredients[#ingredients + 1] = { name = i.name, amount = i.amount } end
  for _, p in pairs(r.products) do products[#products + 1] = { name = p.name, amount = p.amount } end
  return {
    name = r.name,
    enabled = r.enabled,
    category = r.category,
    energy = r.energy,
    ingredients = ingredients,
    products = products,
    hand_craftable_now = player.get_craftable_count(r.name),
  }
end

register("recipe", "Recipes producing an item. {name}", function(args)
  local player = common.require_character()
  need(args, "name")
  local out = {}
  local recipes = player.force.recipes
  if recipes[args.name] then out[#out + 1] = recipe_info(player, recipes[args.name]) end
  for name, r in pairs(recipes) do
    if name ~= args.name then
      for _, p in pairs(r.products) do
        if p.name == args.name then
          out[#out + 1] = recipe_info(player, r)
          break
        end
      end
    end
    if #out >= 5 then break end
  end
  if #out == 0 then error("no recipe produces '" .. args.name .. "'") end
  return { recipes = out }
end)

register("research_options", "Technologies that can be researched now.", function()
  local player = common.require_character()
  local out = {}
  for name, t in pairs(player.force.technologies) do
    if t.enabled and not t.researched then
      local ready = true
      for _, pre in pairs(t.prerequisites) do
        if not pre.researched then ready = false break end
      end
      if ready then
        local trigger = t.prototype.research_trigger
        if trigger then
          -- 2.0 trigger techs unlock by doing something (e.g. craft an item), not with science packs.
          out[#out + 1] = { name = name, unit_count = 0, trigger = trigger }
        else
          local units = {}
          for _, ing in pairs(t.research_unit_ingredients) do units[#units + 1] = ing.name end
          out[#out + 1] = { name = name, unit_count = t.research_unit_count, packs = units }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.unit_count < b.unit_count end)
  return { technologies = out }
end)

---------------------------------------------------------------------------
-- Instant actions
---------------------------------------------------------------------------

register("craft", "Queue hand-crafting. {recipe, count?}", function(args)
  local player = common.require_character()
  need(args, "recipe")
  local count = args.count or 1
  local craftable = player.get_craftable_count(args.recipe)
  if craftable < 1 then error("cannot hand-craft " .. args.recipe .. " now (missing ingredients or not a hand recipe)") end
  local started = player.begin_crafting { recipe = args.recipe, count = math.min(count, craftable) }
  return { queued = started, requested = count }
end)

register("place", "Place an entity from inventory. {name, x, y, direction?}", function(args)
  local player, character = common.require_character()
  need(args, "name", "x", "y")
  local item = prototypes.item[args.name]
  if not item then error("unknown item '" .. args.name .. "'") end
  local result = item.place_result
  if not result then error(args.name .. " is not placeable") end
  local inv = player.get_main_inventory()
  if inv.get_item_count(args.name) < 1 then error("no " .. args.name .. " in inventory") end
  local direction = common.parse_direction(args.direction)
  local position = { x = args.x, y = args.y }
  local d = common.dist(character.position, position)
  if d > character.build_distance then
    error("too far to build (" .. common.round(d) .. " > " .. character.build_distance .. "); walk closer")
  end
  if not character.surface.can_place_entity { name = result.name, position = position, direction = direction,
      force = player.force, build_check_type = defines.build_check_type.manual } then
    error("cannot place " .. result.name .. " at " .. args.x .. "," .. args.y .. " (blocked or invalid terrain)")
  end
  local entity = character.surface.create_entity {
    name = result.name,
    position = position,
    direction = direction,
    force = player.force,
    player = player.object_name == "LuaPlayer" and player or nil,
    type = args.underground_type, -- "input"/"output" for underground belts
    raise_built = true,
  }
  if not entity then error("placement failed") end
  inv.remove({ name = args.name, count = 1 })
  return { entity = common.describe_entity(entity) }
end)

register("pickup", "Mine a building back into inventory. {x, y, entity?}", function(args)
  local player = common.require_character()
  local e = reachable_entity(player, args)
  if e.type == "resource" then error("use the mine action for resources") end
  local name = e.name
  if not player.mine_entity(e, false) then error("could not pick up " .. name .. " (inventory full?)") end
  return { picked_up = name }
end)

register("insert", "Move items from inventory into an entity. {x, y, item, count?, entity?}", function(args)
  local player = common.require_character()
  need(args, "item")
  local e = reachable_entity(player, args)
  local inv = player.get_main_inventory()
  local have = inv.get_item_count(args.item)
  if have < 1 then error("no " .. args.item .. " in inventory") end
  local count = math.min(args.count or have, have)
  local inserted = e.insert { name = args.item, count = count }
  if inserted > 0 then inv.remove { name = args.item, count = inserted } end
  if inserted == 0 then error(e.name .. " does not accept " .. args.item .. " (or is full)") end
  return { inserted = inserted, entity = e.name }
end)

register("take", "Move items from an entity into inventory. {x, y, item?, count?, entity?}", function(args)
  local player = common.require_character()
  local e = reachable_entity(player, args)
  local taken = {}
  for i = 1, e.get_max_inventory_index() do
    local src = common.try(function() return e.get_inventory(i) end)
    if src and src.valid then
      for _, stack in pairs(src.get_contents()) do
        if not args.item or stack.name == args.item then
          local want = stack.count
          if args.count then want = math.min(want, args.count - (taken[stack.name] or 0)) end
          if want > 0 then
            local moved = player.insert { name = stack.name, count = want, quality = stack.quality }
            if moved > 0 then
              src.remove { name = stack.name, count = moved, quality = stack.quality }
              taken[stack.name] = (taken[stack.name] or 0) + moved
            end
          end
        end
      end
    end
  end
  return { taken = taken, entity = e.name }
end)

register("set_recipe", "Set an assembler's recipe. {x, y, recipe, entity?}", function(args)
  local player = common.require_character()
  need(args, "recipe")
  local e = reachable_entity(player, args)
  local returned = e.set_recipe(args.recipe)
  for _, stack in pairs(returned or {}) do player.insert(stack) end
  return { entity = common.describe_entity(e) }
end)

register("rotate", "Rotate an entity. {x, y, reverse?, entity?}", function(args)
  local player = common.require_character()
  local e = reachable_entity(player, args)
  if not e.rotate { reverse = args.reverse or false, by_player = player } then error("cannot rotate " .. e.name) end
  return { entity = common.describe_entity(e) }
end)

register("research", "Add a technology to the research queue. {name}", function(args)
  local player = common.require_character()
  need(args, "name")
  local tech = player.force.technologies[args.name]
  if not tech then error("unknown technology '" .. args.name .. "'") end
  if tech.researched then error(args.name .. " is already researched") end
  if not player.force.add_research(tech) then error("could not queue " .. args.name .. " (prerequisites missing?)") end
  return { research = args.name }
end)

register("debug_spawn", "Testing only: spawn a character when no player is connected. {x?, y?}", function(args)
  if #game.connected_players > 0 then error("a player is connected; debug_spawn is only for headless tests") end
  if storage.debug_character and storage.debug_character.valid then storage.debug_character.destroy() end
  local surface = game.surfaces[1]
  local pos = surface.find_non_colliding_position("character", { args.x or 0, args.y or 0 }, 20, 0.5)
  storage.debug_character = surface.create_entity { name = "character", position = pos, force = "player" }
  return { position = common.pos(storage.debug_character.position) }
end)

register("say", "Print a message in game chat. {message}", function(args)
  need(args, "message")
  common.say(args.message)
end)

---------------------------------------------------------------------------
-- Queued actions
---------------------------------------------------------------------------

register("walk_to", "Walk to a position using the pathfinder (async). {x, y, radius?}", function(args)
  common.require_character()
  need(args, "x", "y")
  return { action = actions.public(actions.enqueue("walk_to", { x = args.x, y = args.y, radius = args.radius })) }
end)

register("mine", "Mine resources/trees/rocks, walking as needed (async). {name, count?, x?, y?}", function(args)
  common.require_character()
  need(args, "name")
  return { action = actions.public(actions.enqueue("mine", {
    name = args.name, count = args.count or 1, x = args.x, y = args.y,
  })) }
end)

register("action_status", "Status of an action. {id}", function(args)
  need(args, "id")
  local a = storage.actions[args.id]
  if not a then error("unknown action id " .. tostring(args.id)) end
  return { action = actions.public(a) }
end)

register("cancel", "Cancel the running action and clear the queue.", function()
  return { cancelled = actions.cancel_all() }
end)
