-- Long-running character actions (walking, mining), driven from on_tick.
-- Actions run one at a time in FIFO order; each has an id the caller can poll.
local common = require("common")

local actions = {}

local STUCK_TICKS = 90
local MAX_REPATHS = 3
local MAX_ACTION_TICKS = 60 * 60 * 10 -- 10 minutes of game time
local SEARCH_RADIUS = 150

function actions.init()
  storage.actions = storage.actions or {}       -- id -> action
  storage.queue = storage.queue or {}           -- list of ids, head is running
  storage.next_action_id = storage.next_action_id or 1
  storage.path_requests = storage.path_requests or {} -- request id -> action id
end

local function finish(action, status, message)
  action.status = status
  action.message = message
  action.finished_tick = game.tick
  local player = common.get_player()
  if player and player.valid then
    player.walking_state = { walking = false, direction = defines.direction.north }
    player.mining_state = { mining = false }
  end
  if status == "failed" then
    common.say(action.kind .. " #" .. action.id .. " failed: " .. tostring(message))
  end
  -- Drop old finished actions so storage doesn't grow forever.
  for id, a in pairs(storage.actions) do
    if a.finished_tick and game.tick - a.finished_tick > 60 * 60 * 30 then storage.actions[id] = nil end
  end
end

function actions.enqueue(kind, params)
  local id = storage.next_action_id
  storage.next_action_id = id + 1
  local action = { id = id, kind = kind, params = params, status = "queued", created_tick = game.tick }
  storage.actions[id] = action
  table.insert(storage.queue, id)
  return action
end

function actions.public(action)
  return {
    id = action.id,
    kind = action.kind,
    status = action.status,
    message = action.message,
    progress = action.progress,
    params = action.params,
  }
end

function actions.cancel_all()
  local cancelled = 0
  for _, id in pairs(storage.queue) do
    local a = storage.actions[id]
    if a and (a.status == "queued" or a.status == "running") then
      finish(a, "cancelled", "cancelled by request")
      cancelled = cancelled + 1
    end
  end
  storage.queue = {}
  return cancelled
end

---------------------------------------------------------------------------
-- Walking
---------------------------------------------------------------------------

local function request_path(action, character, goal, radius)
  local w = action.walk
  local req = character.surface.request_path {
    bounding_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
    collision_mask = character.prototype.collision_mask,
    start = character.position,
    goal = goal,
    force = character.force,
    radius = radius,
    entity_to_ignore = character,
    can_open_gates = true,
    path_resolution_modifier = 0,
    pathfind_flags = { cache = false, prefer_straight_paths = true, no_break = true },
  }
  w.request = req
  w.path = nil
  storage.path_requests[req] = action.id
end

-- Starts (or restarts) walking toward goal; arrival = within radius.
local function start_walk(action, character, goal, radius)
  action.walk = { goal = goal, radius = radius or 0.5, repaths = 0 }
  request_path(action, character, goal, action.walk.radius)
end

local octant_directions = {
  defines.direction.east, defines.direction.southeast, defines.direction.south, defines.direction.southwest,
  defines.direction.west, defines.direction.northwest, defines.direction.north, defines.direction.northeast,
}

local function direction_to(from, to)
  local angle = math.atan2(to.y - from.y, to.x - from.x) -- screen coords: +y is south
  local octant = math.floor((angle / (2 * math.pi)) * 8 + 8.5) % 8
  return octant_directions[octant + 1]
end

-- Advances walking by one tick. Returns "walking", "arrived" or "failed", message.
local function step_walk(action, player, character)
  local w = action.walk
  local pos = character.position
  if common.dist(pos, w.goal) <= w.radius then return "arrived" end
  if w.failed then return "failed", w.failed end
  if not w.path then return "walking" end -- waiting for pathfinder

  -- Skip waypoints we're already close to.
  local wp = w.path[w.index]
  while wp and w.index < #w.path and common.dist(pos, wp.position) < 0.6 do
    w.index = w.index + 1
    wp = w.path[w.index]
  end
  if not wp or (w.index >= #w.path and common.dist(pos, wp.position) < 0.25) then
    return "arrived"
  end

  -- Stuck detection.
  if w.last_pos and common.dist(w.last_pos, pos) < 0.05 then
    w.stuck = (w.stuck or 0) + 1
  else
    w.stuck = 0
  end
  w.last_pos = { x = pos.x, y = pos.y }
  if w.stuck > STUCK_TICKS then
    w.repaths = w.repaths + 1
    if w.repaths > MAX_REPATHS then return "failed", "stuck while walking" end
    w.stuck = 0
    request_path(action, character, w.goal, w.radius)
    player.walking_state = { walking = false, direction = defines.direction.north }
    return "walking"
  end

  player.walking_state = { walking = true, direction = direction_to(pos, wp.position) }
  return "walking"
end

function actions.on_path_finished(event)
  local action_id = storage.path_requests[event.id]
  if not action_id then return end
  storage.path_requests[event.id] = nil
  local action = storage.actions[action_id]
  if not (action and action.walk and action.walk.request == event.id) then return end
  local w = action.walk
  if event.path then
    w.path = event.path
    w.index = 1
  elseif event.try_again_later then
    local _, character = pcall(common.require_character)
    if character and character.valid then request_path(action, character, w.goal, w.radius) end
  else
    w.failed = "no path to target"
  end
end

---------------------------------------------------------------------------
-- Action handlers
---------------------------------------------------------------------------

local handlers = {}

handlers.walk_to = {
  start = function(action, player, character)
    local p = action.params
    start_walk(action, character, { x = p.x, y = p.y }, p.radius or 0.5)
  end,
  tick = function(action, player, character)
    local res, msg = step_walk(action, player, character)
    if res == "arrived" then return "done", string.format("arrived at %.1f, %.1f", character.position.x, character.position.y) end
    if res == "failed" then return "failed", msg end
  end,
}

local function find_mine_target(action, character)
  local p = action.params
  local filter = { position = character.position, radius = SEARCH_RADIUS }
  if p.x and p.y and not action.used_position then
    action.used_position = true
    local e = common.entity_at(character.surface, p.x, p.y, p.name ~= "tree" and p.name ~= "rock" and p.name or nil)
    if e then return e end
  end
  if p.name == "tree" then
    filter.type = "tree"
  elseif p.name == "rock" then
    filter.type = "simple-entity"
  else
    filter.name = p.name
  end
  local candidates = character.surface.find_entities_filtered(filter)
  if p.name == "rock" then
    local rocks = {}
    for _, e in pairs(candidates) do
      if e.name:find("rock") then rocks[#rocks + 1] = e end
    end
    candidates = rocks
  end
  if #candidates == 0 then return nil end
  return character.surface.get_closest(character.position, candidates)
end

handlers.mine = {
  start = function(action, player, character)
    local p = action.params
    p.count = p.count or 1
    action.progress = { mined = 0, target = p.count }
    action.mode = nil
  end,
  tick = function(action, player, character)
    local p = action.params
    local inv = player.get_main_inventory()

    -- Track progress.
    if action.target_is_resource and action.product then
      -- Resources count items gained.
      local now = inv.get_item_count(action.product)
      local gained = now - (action.product_base or now)
      action.product_base = now
      if gained > 0 then action.progress.mined = action.progress.mined + gained end
      if not action.target.valid then action.target = nil end
    elseif action.target and not action.target.valid then
      action.progress.mined = action.progress.mined + 1 -- trees/rocks count entities removed
      action.target = nil
    end
    if action.progress.mined >= p.count then return "done", "mined " .. action.progress.mined .. " " .. p.name end

    -- Pick a target.
    if not (action.target and action.target.valid) then
      action.target = find_mine_target(action, character)
      action.walk = nil
      if not action.target then
        return "failed", "no " .. p.name .. " within " .. SEARCH_RADIUS .. " tiles"
      end
      local products = action.target.prototype.mineable_properties.products
      action.product = products and products[1] and products[1].name
      action.product_base = action.product and inv.get_item_count(action.product) or 0
      action.target_is_resource = action.target.type == "resource"
      action.mine_ticks = 0
    end
    local target = action.target

    if action.product and not inv.can_insert({ name = action.product, count = 1 }) then
      return "failed", "inventory full"
    end

    -- Walk into reach first.
    local reach = target.type == "resource" and character.resource_reach_distance or character.reach_distance
    if common.dist(character.position, target.position) > reach - 0.5 then
      if not action.walk then start_walk(action, character, target.position, math.max(1, reach - 1.5)) end
      local res, msg = step_walk(action, player, character)
      if res == "failed" then return "failed", msg end
      if res ~= "arrived" then return end
    end
    if action.walk then
      action.walk = nil
      player.walking_state = { walking = false, direction = defines.direction.north }
    end

    -- Mine at real hand-mining speed: wait mining_time / mining_speed, then mine one unit.
    local speed = character.prototype.mining_speed *
      (1 + player.force.manual_mining_speed_modifier + character.character_mining_speed_modifier)
    local needed = math.max(1, math.ceil(60 * target.prototype.mineable_properties.mining_time / speed))
    action.mine_ticks = (action.mine_ticks or 0) + 1
    if action.mine_ticks >= needed then
      action.mine_ticks = 0
      local before = action.product and player.get_main_inventory().get_item_count(action.product) or 0
      local ok = player.mine_entity(target, false)
      -- mine_entity returns false for resources that aren't depleted, so judge resources by the inventory.
      if target.valid and target.type == "resource" then
        ok = player.get_main_inventory().get_item_count(action.product) > before
      end
      if not ok then return "failed", "could not mine " .. p.name end
    end
  end,
}

---------------------------------------------------------------------------
-- Tick loop
---------------------------------------------------------------------------

function actions.on_tick()
  local queue = storage.queue
  if not queue or #queue == 0 then return end
  local action = storage.actions[queue[1]]
  if not action or action.status ~= "queued" and action.status ~= "running" then
    table.remove(queue, 1)
    return
  end

  local ok, player, character = pcall(common.require_character)
  if not ok then
    finish(action, "failed", player)
    table.remove(queue, 1)
    return
  end

  local handler = handlers[action.kind]
  local status, message
  local success, err = pcall(function()
    if action.status == "queued" then
      action.status = "running"
      action.started_tick = game.tick
      if handler.start then handler.start(action, player, character) end
    end
    status, message = handler.tick(action, player, character)
  end)
  if not success then status, message = "failed", (tostring(err):gsub("^__claude%-bridge__/[%w_]+%.lua:%d+: ", "")) end
  if not status and game.tick - action.started_tick > MAX_ACTION_TICKS then
    status, message = "failed", "timed out"
  end
  if status then
    finish(action, status, message)
    table.remove(queue, 1)
  end
end

function actions.is_known(kind) return handlers[kind] ~= nil end

return actions
