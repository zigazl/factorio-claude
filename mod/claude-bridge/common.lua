-- Shared helpers for claude-bridge.
local common = {}

-- Returns the controlling LuaPlayer. Without connected players (headless testing) it falls back
-- to the character spawned by /cb_debug_spawn, which supports the same LuaControl API.
function common.get_player()
  for _, p in pairs(game.connected_players) do
    if p.character and p.character.valid then return p end
  end
  if game.connected_players[1] then return game.connected_players[1] end
  if storage.debug_character and storage.debug_character.valid then return storage.debug_character end
  return nil
end

-- Returns controller (player or debug character), character, or raises an error the caller can surface.
function common.require_character()
  local player = common.get_player()
  if not player then error("no player connected") end
  if player.object_name == "LuaEntity" then return player, player end
  local character = player.character
  if not (character and character.valid) then error("player has no character (dead or in map view?)") end
  return player, character
end

function common.round(n, places)
  local m = 10 ^ (places or 1)
  return math.floor(n * m + 0.5) / m
end

function common.pos(p)
  return { x = common.round(p.x or p[1]), y = common.round(p.y or p[2]) }
end

function common.dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

-- {name=count} map from an inventory, ignoring quality.
function common.contents(inv)
  local out = {}
  if not (inv and inv.valid) then return out end
  for _, item in pairs(inv.get_contents()) do
    out[item.name] = (out[item.name] or 0) + item.count
  end
  return out
end

local status_names
function common.status_name(status)
  if status == nil then return nil end
  if not status_names then
    status_names = {}
    for name, value in pairs(defines.entity_status) do status_names[value] = name end
  end
  return status_names[status]
end

local direction_names
function common.direction_name(dir)
  if dir == nil then return nil end
  if not direction_names then
    direction_names = {}
    for name, value in pairs(defines.direction) do direction_names[value] = name end
  end
  return direction_names[dir]
end

function common.parse_direction(d)
  if d == nil then return defines.direction.north end
  if type(d) == "number" then return d end
  local v = defines.direction[d]
  if v == nil then error("unknown direction '" .. tostring(d) .. "' (use north/east/south/west)") end
  return v
end

-- Safe property read: some properties raise on entity types that don't support them.
function common.try(fn)
  local ok, v = pcall(fn)
  if ok then return v end
  return nil
end

-- Find the (non-resource) entity at a position, preferring player-force buildings.
function common.entity_at(surface, x, y, name)
  local found = surface.find_entities_filtered { position = { x, y }, radius = 0.7, name = name }
  local best, best_score
  for _, e in pairs(found) do
    local score = 0
    if e.type == "resource" then score = 3
    elseif e.type == "character" then score = 4
    elseif e.force.name == "neutral" then score = 1 end
    score = score + common.dist(e.position, { x = x, y = y }) / 10
    if not best or score < best_score then best, best_score = e, score end
  end
  return best
end

function common.describe_entity(e, detailed)
  local d = {
    name = e.name,
    type = e.type,
    position = common.pos(e.position),
  }
  if e.supports_direction then d.direction = common.direction_name(e.direction) end
  d.status = common.try(function() return common.status_name(e.status) end)
  local recipe = common.try(function() return e.get_recipe() end)
  if recipe then d.recipe = recipe.name end
  if e.type == "resource" then d.amount = e.amount end
  if detailed then
    d.inventories = {}
    for _, idx in pairs({ defines.inventory.fuel, defines.inventory.chest,
      defines.inventory.furnace_source, defines.inventory.furnace_result,
      defines.inventory.assembling_machine_input, defines.inventory.assembling_machine_output,
      defines.inventory.lab_input, defines.inventory.turret_ammo }) do
      local inv = common.try(function() return e.get_inventory(idx) end)
      if inv and inv.valid then
        local key = inv.name or tostring(idx)
        if not d.inventories[key] then d.inventories[key] = common.contents(inv) end
      end
    end
    d.crafting_progress = common.try(function() return common.round(e.crafting_progress, 2) end)
    d.mining_progress = common.try(function() return common.round(e.mining_progress, 2) end)
    d.energy = common.try(function() return e.energy end)
    d.health = e.health
    if e.type == "transport-belt" or e.type == "underground-belt" or e.type == "splitter" then
      d.belt = {}
      for i = 1, e.get_max_transport_line_index() do
        d.belt[i] = common.contents(e.get_transport_line(i))
      end
    end
  end
  return d
end

function common.say(msg)
  game.print("[color=0.8,0.6,1][Claude][/color] " .. msg)
end

return common
