--[[
AutoMine – fault-tolerant collaborative strip mining controller for CC: Tweaked turtles.

This script fulfils project_design.md by providing:
    • Guided quarry configuration bootstrap/share via rednet.
    • ACID-backed persistence for pose, jobs, and restarts.
    • Cooperative tunnel planning + local job queues (refuel > ore > tunnel).
    • Bounding-box-safe 2×1 tunnelling with 6-face ore scanning and recall flow.
    • Spawn-column aware fueling/deposit logic plus wireless recall command.
]]

local VERSION = "0.2.0"

local fs = assert(rawget(_G, "fs"), "fs API unavailable")
local turtle = assert(rawget(_G, "turtle"), "turtle API unavailable")
local rednet = assert(rawget(_G, "rednet"), "rednet API unavailable")
local peripheral = assert(rawget(_G, "peripheral"), "peripheral API unavailable")
local textutils = assert(rawget(_G, "textutils"), "textutils API unavailable")
local osSleep = rawget(os, "sleep")
local sleepFn = rawget(_G, "sleep") or osSleep or function() end
local read = rawget(_G, "read") or function()
    error("term.read unavailable")
end

local function computerID()
    local getter = rawget(os, "getComputerID")
    if type(getter) == "function" then
        return getter()
    end
    return tonumber(os.getenv and os.getenv("COMPUTER_ID") or 0) or 0
end

---------------------------------------------------------------------
-- Utility helpers
---------------------------------------------------------------------

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = deepcopy(v)
    end
    return copy
end

local function merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            merge(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

local function clamp(val, lo, hi)
    if val < lo then return lo end
    if val > hi then return hi end
    return val
end

local function now()
    if os.epoch then
        return os.epoch("utc") / 1000
    end
    return os.clock()
end

local function with_handle(path, mode, writer)
    local handle, err = fs.open(path, mode)
    if not handle then
        error("fs.open failed for " .. path .. ": " .. tostring(err))
    end
    local ok, res = pcall(writer, handle)
    handle.close()
    if not ok then
        error(res)
    end
    return res
end

local function posKey(pos)
    return string.format("%d:%d:%d", pos.x, pos.y, pos.z)
end

local function addVec(a, b)
    return { x = (a.x or 0) + (b.x or 0), y = (a.y or 0) + (b.y or 0), z = (a.z or 0) + (b.z or 0) }
end

local function formatPos(pos)
    return string.format("(%d,%d,%d)", pos.x, pos.y, pos.z)
end

local CARDINAL_TO_DIR = {
    north = 2,
    south = 0,
    east = 1,
    west = 3,
}

local DIR_TO_CARDINAL = {
    [0] = "south",
    [1] = "east",
    [2] = "north",
    [3] = "west",
}

---------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------

local Logger = {}
Logger.__index = Logger

function Logger.new(path)
    return setmetatable({ path = path }, Logger)
end

function Logger:write(level, ...)
    local msg = table.concat({ ... }, " ")
    local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local line = string.format("[%s][%s] %s", stamp, level, msg)
    print(line)
    if not self.path then return end
    with_handle(self.path, "a", function(h)
        h.writeLine(line)
    end)
end

local function debugLog(config, logger, ...)
    if config and config.debug then
        logger:write("DEBUG", ...)
    end
end

---------------------------------------------------------------------
-- Terminal UI helpers
---------------------------------------------------------------------

local function prompt(question, default, validator)
    while true do
        if default then
            io.write(string.format("%s [%s]: ", question, tostring(default)))
        else
            io.write(question .. ": ")
        end
        local input = read()
        if not input then input = "" end
        input = input:match("^%s*(.-)%s*$")
        if input == "" and default then
            input = tostring(default)
        end
        if validator then
            local ok, msg, value = validator(input)
            if ok then
                return value or input
            end
            print("Invalid input: " .. msg)
        else
            return input
        end
    end
end

local function promptNumber(question, default, minVal)
    return prompt(question, default, function(value)
        local num = tonumber(value)
        if not num then
            return false, "enter a number"
        end
        if minVal and num < minVal then
            return false, "must be >= " .. tostring(minVal)
        end
        return true, nil, num
    end)
end

---------------------------------------------------------------------
-- Configuration management
---------------------------------------------------------------------

local DEFAULT_CONFIG = {
    configVersion = 1,
    statePath = "automine_state.json",
    journalPath = "automine_acid.json",
    logPath = "automine.log",
    protocol = "auto_mine/v2",
    boundingBox = { x = 32, y = 24, z = 96 },
    tunnelSpacing = 3,
    layerSpacing = 3,
    chunkLength = 24,
    heartbeatInterval = 2.0,
    heartbeatTimeout = 6.0,
    fuelReserve = 800,
    targetFuel = 4800,
    keepFuelItems = 24,
    depositKeepCoal = 16,
    spawnFacing = "south",
    fuelChestOffset = { x = 0, y = 0, z = -1 },
    depositOffset = { x = 0, y = 1, z = -1 },
    restOffset = { x = -1, y = 0, z = -1 },
    jobRetryInterval = 5.0,
    maxJobFailures = 5,
    allowedFuel = {
        ["minecraft:coal"] = true,
        ["minecraft:charcoal"] = true,
        ["minecraft:coal_block"] = true,
        ["minecraft:lava_bucket"] = true
    },
    oreTags = {
        ["minecraft:ores"] = true,
        ["forge:ores"] = true,
    },
    debug = false,
}

local Config = {}
Config.__index = Config

function Config.path(quarryId)
    return string.format("quarry_%s_config.json", quarryId)
end

function Config.load(path)
    if not path or not fs.exists(path) then
        return nil
    end
    local cfg = with_handle(path, "r", function(h)
        local raw = h.readAll()
        if not raw or raw == "" then return nil end
        local decoded, err = textutils.unserializeJSON(raw)
        if not decoded then
            error("invalid JSON in config: " .. tostring(err))
        end
        return decoded
    end)
    if not cfg then
        return nil
    end
    merge(cfg, DEFAULT_CONFIG)
    cfg.path = path
    if cfg.spawnFacing then
        cfg.spawnDir = CARDINAL_TO_DIR[cfg.spawnFacing:lower()] or 0
    else
        cfg.spawnDir = 0
    end
    return setmetatable(cfg, Config)
end

function Config.save(path, cfg)
    cfg.configVersion = (cfg.configVersion or 0) + 1
    with_handle(path, "w", function(h)
        h.write(textutils.serializeJSON(cfg, { allow_repetitions = true }))
    end)
end

local function ensureModem()
    local opened = false
    peripheral.find("modem", function(name)
        if not rednet.isOpen(name) then
            rednet.open(name)
        end
        opened = true
        return false
    end)
    if not opened then
        error("AutoMine requires an attached modem")
    end
end

local function waitForConfig(quarryId, timeout)
    ensureModem()
    rednet.broadcast({ type = "config_request", quarryId = quarryId }, DEFAULT_CONFIG.protocol)
    local deadline = now() + (timeout or 5)
    while true do
        local remaining = deadline - now()
        if remaining <= 0 then
            break
        end
        local sender, msg = rednet.receive(DEFAULT_CONFIG.protocol, remaining)
        if sender and type(msg) == "table" and msg.type == "config_response" and msg.quarryId == quarryId then
            return msg.config
        end
    end
    return nil
end

local function broadcastConfig(config)
    ensureModem()
    rednet.broadcast({ type = "config_update", quarryId = config.quarryId, config = config }, config.protocol or DEFAULT_CONFIG.protocol)
end

local function interactiveConfig(quarryId)
    print("No config found for quarry '" .. quarryId .. "'. Let's create one.")
    local bbX = promptNumber("Bounding box X length", DEFAULT_CONFIG.boundingBox.x, 4)
    local bbY = promptNumber("Bounding box Y height", DEFAULT_CONFIG.boundingBox.y, 4)
    local bbZ = promptNumber("Bounding box Z length", DEFAULT_CONFIG.boundingBox.z, 4)
    local spacing = promptNumber("Tunnel spacing (>=3)", DEFAULT_CONFIG.tunnelSpacing, 3)
    local layers = promptNumber("Layer spacing (>=3)", DEFAULT_CONFIG.layerSpacing, 3)
    local chunkLength = promptNumber("Tunnel chunk length", DEFAULT_CONFIG.chunkLength, 4)
    local fuelReserve = promptNumber("Fuel reserve", DEFAULT_CONFIG.fuelReserve, 100)
    local targetFuel = promptNumber("Target fuel", DEFAULT_CONFIG.targetFuel, fuelReserve)
    local cfg = deepcopy(DEFAULT_CONFIG)
    cfg.boundingBox = { x = bbX, y = bbY, z = bbZ }
    cfg.tunnelSpacing = spacing
    cfg.layerSpacing = layers
    cfg.chunkLength = chunkLength
    cfg.fuelReserve = fuelReserve
    cfg.targetFuel = targetFuel
    cfg.spawnFacing = DEFAULT_CONFIG.spawnFacing
    cfg.spawnDir = CARDINAL_TO_DIR[cfg.spawnFacing]
    cfg.quarryId = quarryId
    return cfg
end

local function ensureConfig(quarryId, logger)
    local path = Config.path(quarryId)
    local cfg = Config.load(path)
    if cfg then
        cfg.quarryId = quarryId
        return cfg
    end
    local networkConfig = waitForConfig(quarryId, 8)
    if networkConfig then
        logger:write("INFO", "Fetched quarry config from network")
        networkConfig.spawnDir = CARDINAL_TO_DIR[networkConfig.spawnFacing or "south"] or 0
        Config.save(path, networkConfig)
        return Config.load(path)
    end
    cfg = interactiveConfig(quarryId)
    Config.save(path, cfg)
    broadcastConfig(cfg)
    return Config.load(path)
end

---------------------------------------------------------------------
-- Persistent state
---------------------------------------------------------------------

local StateStore = {}
StateStore.__index = StateStore

function StateStore.new(config)
    return setmetatable({ path = config.statePath, data = nil }, StateStore)
end

function StateStore:load()
    if fs.exists(self.path) then
        self.data = with_handle(self.path, "r", function(h)
            local raw = h.readAll()
            if not raw or raw == "" then
                return nil
            end
            local decoded, err = textutils.unserializeJSON(raw)
            if not decoded then
                error("state load failed: " .. tostring(err))
            end
            return decoded
        end)
    end
    if not self.data then
        self.data = {
            version = VERSION,
            turtleId = computerID(),
            quarryId = nil,
            pose = { x = 0, y = 0, z = 0, dir = 0 },
            calibration = { floorY = 0, spawnFacing = 0, calibrated = false },
            turtles = {},
            tunnels = {},
            locks = {},
            metrics = { mined = 0, ore = 0 },
            journal = { nextId = 1, pending = {} },
            activeJob = nil,
            jobs = { seq = 0, pending = {}, active = nil },
            oreRegistry = {},
            recall = { active = false, issuedAt = 0 },
        }
        self:save()
    end
    return self.data
end

function StateStore:save()
    with_handle(self.path, "w", function(h)
        h.write(textutils.serializeJSON(self.data, { allow_repetitions = true }))
    end)
end

function StateStore:update(mutator)
    mutator(self.data)
    self:save()
end

---------------------------------------------------------------------
-- ACID journal support
---------------------------------------------------------------------

local Acid = {}
Acid.__index = Acid

function Acid.new(config, store)
    local self = setmetatable({ path = config.journalPath, store = store, registry = {} }, Acid)
    if not fs.exists(self.path) then
        with_handle(self.path, "w", function(h)
            h.write(textutils.serializeJSON({ pending = {} }, { allow_repetitions = true }))
        end)
    end
    self:load()
    return self
end

function Acid:load()
    self.state = with_handle(self.path, "r", function(h)
        local raw = h.readAll()
        if not raw or raw == "" then
            return { pending = {} }
        end
        local decoded = textutils.unserializeJSON(raw)
        if not decoded then
            return { pending = {} }
        end
        if not decoded.pending then decoded.pending = {} end
        return decoded
    end)
end

function Acid:save()
    with_handle(self.path, "w", function(h)
        h.write(textutils.serializeJSON(self.state, { allow_repetitions = true }))
    end)
end

function Acid:register(kind, verifyFn)
    self.registry[kind] = verifyFn
end

function Acid:begin(kind, payload)
    local id = string.format("%s:%d", kind, self.store.data.journal.nextId)
    self.store.data.journal.nextId = self.store.data.journal.nextId + 1
    self.state.pending[id] = { kind = kind, payload = payload, started = now() }
    self:save()
    self.store:save()
    return id
end

function Acid:complete(id)
    self.state.pending[id] = nil
    self:save()
end

function Acid:resume()
    local resolved = {}
    for id, entry in pairs(self.state.pending) do
        local verifier = self.registry[entry.kind]
        if verifier and verifier(entry.payload) then
            resolved[#resolved + 1] = id
        end
    end
    for _, id in ipairs(resolved) do
        self.state.pending[id] = nil
    end
    if #resolved > 0 then
        self:save()
    end
end

function Acid:run(kind, payload, fn)
    local id = self:begin(kind, payload)
    local ok, err = fn()
    if ok then
        self:complete(id)
    end
    return ok, err
end

---------------------------------------------------------------------
-- Bounding box utilities
---------------------------------------------------------------------

local BoundingBox = {}
BoundingBox.__index = BoundingBox

function BoundingBox.new(box)
    return setmetatable({ max = box }, BoundingBox)
end

function BoundingBox:contains(pos)
    return pos.x >= 0 and pos.y >= 0 and pos.z >= 0
        and pos.x <= self.max.x and pos.y <= self.max.y and pos.z <= self.max.z
end

function BoundingBox:clamp(pos)
    return {
        x = clamp(pos.x, 0, self.max.x),
        y = clamp(pos.y, 0, self.max.y),
        z = clamp(pos.z, 0, self.max.z),
    }
end

---------------------------------------------------------------------
-- Orientation helpers
---------------------------------------------------------------------

local DIRECTIONS = { "forward", "right", "back", "left" }
local DIR_VECTORS = {
    [0] = { x = 0, z = 1 },
    [1] = { x = 1, z = 0 },
    [2] = { x = 0, z = -1 },
    [3] = { x = -1, z = 0 },
}

local Pose = {}
Pose.__index = Pose

function Pose.wrap(state)
    return setmetatable({ state = state }, Pose)
end

function Pose:get()
    return self.state.pose
end

function Pose:dirVector()
    return DIR_VECTORS[self.state.pose.dir]
end

function Pose:update(newPose)
    self.state.pose = newPose
end

function Pose:setDir(dir)
    self.state.pose.dir = ((dir % 4) + 4) % 4
end

function Pose:move(delta)
    local pose = self.state.pose
    pose.x = pose.x + (delta.x or 0)
    pose.y = pose.y + (delta.y or 0)
    pose.z = pose.z + (delta.z or 0)
end

function Pose:turnLeft()
    turtle.turnLeft()
    self:setDir(self.state.pose.dir - 1)
end

function Pose:turnRight()
    turtle.turnRight()
    self:setDir(self.state.pose.dir + 1)
end

function Pose:turnAround()
    self:turnLeft()
    self:turnLeft()
end

function Pose:face(direction)
    if direction == "forward" then
        return
    elseif direction == "right" then
        self:turnRight()
    elseif direction == "back" then
        self:turnAround()
    elseif direction == "left" then
        self:turnLeft()
    else
        error("invalid relative direction " .. tostring(direction))
    end
end

function Pose:faceAbsoluteDir(targetDir)
    local dir = self.state.pose.dir
    local turns = (targetDir - dir) % 4
    if turns == 1 then
        self:turnRight()
    elseif turns == 2 then
        self:turnAround()
    elseif turns == 3 then
        self:turnLeft()
    end
end

function Pose:faceAxis(axis, positive)
    local target
    if axis == "x" then
        target = positive and 1 or 3
    elseif axis == "z" then
        target = positive and 0 or 2
    else
        error("invalid axis " .. tostring(axis))
    end
    self:faceAbsoluteDir(target)
end

---------------------------------------------------------------------
-- Movement wrapper with ACID tracking
---------------------------------------------------------------------

local function clearBlock(fnDetect, fnDig, fnAttack)
    local tries = 0
    while tries < 12 do
        if not fnDetect() then return true end
        fnDig()
        fnAttack()
        tries = tries + 1
        sleepFn(0.1)
    end
    return not fnDetect()
end

local Movement = {}
Movement.__index = Movement

function Movement.new(store, pose, acid, bbox, fuel)
    return setmetatable({ store = store, pose = pose, acid = acid, bbox = bbox, fuel = fuel }, Movement)
end

function Movement:_poseMatches(target)
    local pose = self.pose:get()
    return pose.x == target.x and pose.y == target.y and pose.z == target.z and pose.dir == target.dir
end

function Movement:_applyForward(target)
    if not self.bbox:contains(target) then
        return false, "move would escape bounding box"
    end
    self.fuel:ensure(1)
    local tries = 0
    while true do
        local success, reason = turtle.forward()
        if success then
            self.pose:update(target)
            self.store:save()
            return true
        end
        tries = tries + 1
        if reason and reason:match("obstruct") then
            clearBlock(turtle.detect, turtle.dig, turtle.attack)
        elseif tries > 20 then
            return false, reason or "blocked"
        else
            sleepFn(0.2)
        end
    end
end

local function applyVertical(self, target, direction)
    if not self.bbox:contains(target) then
        return false, direction == "up" and "move up outside bounds" or "below bounding box"
    end
    self.fuel:ensure(1)
    local tries = 0
    while true do
        local success
        if direction == "up" then
            success = turtle.up()
        else
            success = turtle.down()
        end
        if success then
            self.pose:update(target)
            self.store:save()
            return true
        end
        tries = tries + 1
        local cleared
        if direction == "up" then
            cleared = clearBlock(turtle.detectUp, turtle.digUp, turtle.attackUp)
        else
            cleared = clearBlock(turtle.detectDown, turtle.digDown, turtle.attackDown)
        end
        if not cleared and tries > 10 then
            return false, "blocked"
        end
        sleepFn(0.1)
    end
end

function Movement:_applyUp(target)
    return applyVertical(self, target, "up")
end

function Movement:_applyDown(target)
    return applyVertical(self, target, "down")
end

function Movement:attachVerifiers()
    local function verify(target, replayer)
        if self:_poseMatches(target) then
            return true
        end
        local ok = replayer(target)
        return ok
    end

    self.acid:register("move_forward", function(payload)
        return verify(payload.target, function(t)
            return self:_applyForward(t)
        end)
    end)

    self.acid:register("move_up", function(payload)
        return verify(payload.target, function(t)
            return self:_applyUp(t)
        end)
    end)

    self.acid:register("move_down", function(payload)
        return verify(payload.target, function(t)
            return self:_applyDown(t)
        end)
    end)
end

function Movement:forward()
    local pose = deepcopy(self.pose:get())
    local dirVec = DIR_VECTORS[pose.dir]
    local target = { x = pose.x + dirVec.x, y = pose.y, z = pose.z + dirVec.z, dir = pose.dir }
    local payload = { origin = pose, target = target }
    local ok, err = self.acid:run("move_forward", payload, function()
        return self:_applyForward(target)
    end)
    return ok, err
end

function Movement:up()
    local pose = deepcopy(self.pose:get())
    local target = { x = pose.x, y = pose.y + 1, z = pose.z, dir = pose.dir }
    return self.acid:run("move_up", { origin = pose, target = target }, function()
        return self:_applyUp(target)
    end)
end

function Movement:down()
    local pose = deepcopy(self.pose:get())
    local target = { x = pose.x, y = pose.y - 1, z = pose.z, dir = pose.dir }
    return self.acid:run("move_down", { origin = pose, target = target }, function()
        return self:_applyDown(target)
    end)
end

function Movement:digForward()
    return self.acid:run("dig_forward", { pos = deepcopy(self.pose:get()) }, function()
        clearBlock(turtle.detect, turtle.dig, turtle.attack)
        turtle.digUp()
        return true
    end)
end

function Movement:digDown()
    return self.acid:run("dig_down", {}, function()
        turtle.digDown()
        return true
    end)
end

---------------------------------------------------------------------
-- Navigator
---------------------------------------------------------------------

local Navigator = {}
Navigator.__index = Navigator

function Navigator.new(pose, movement, bbox)
    return setmetatable({ pose = pose, movement = movement, bbox = bbox }, Navigator)
end

function Navigator:moveAxis(axis, delta)
    local moveFn
    if axis == "y" then
        moveFn = delta > 0 and self.movement.up or self.movement.down
    else
        self.pose:faceAxis(axis, delta > 0)
        moveFn = self.movement.forward
    end
    for _ = 1, math.abs(delta) do
        local ok, err = moveFn(self.movement)
        if not ok then return false, err end
    end
    return true
end

function Navigator:goTo(target)
    target = self.bbox:clamp(target)
    local pose = deepcopy(self.pose:get())
    local steps = {
        { axis = "y", delta = target.y - pose.y },
        { axis = "x", delta = target.x - pose.x },
        { axis = "z", delta = target.z - pose.z },
    }
    for _, step in ipairs(steps) do
        if step.delta ~= 0 then
            local ok, err = self:moveAxis(step.axis, step.delta)
            if not ok then return false, err end
        end
    end
    return true
end

---------------------------------------------------------------------
-- Calibration
---------------------------------------------------------------------

local Calibrator = {}
Calibrator.__index = Calibrator

function Calibrator.new(store, pose, movement, bbox, logger)
    return setmetatable({ store = store, pose = pose, movement = movement, bbox = bbox, logger = logger }, Calibrator)
end

function Calibrator:run(config)
    local calibration = self.store.data.calibration or {}
    if calibration.calibrated then
        return
    end
    self.logger:write("INFO", "Calibrating turtle space origin…")
    self.pose:faceAbsoluteDir(config.spawnDir or 0)
    local attempts = 0
    while attempts < 8 do
        local moved = false
        while true do
            local ok, err = self.movement:down()
            if not ok then
                if err == "blocked" then
                    break
                end
                break
            else
                moved = true
            end
        end
        if not moved then
            local climbed = false
            for _ = 1, 3 do
                local upOk = self.movement:up()
                if not upOk then break end
                climbed = true
            end
            if climbed then sleepFn(0.5) end
            attempts = attempts + 1
            if not climbed then break end
        else
            break
        end
    end
    calibration.floorY = self.pose:get().y
    calibration.spawnFacing = config.spawnDir or self.pose:get().dir
    calibration.calibrated = true
    self.store.data.calibration = calibration
    self.store:save()
    self.logger:write("INFO", string.format("Calibrated floor at y=%d", calibration.floorY))
end

---------------------------------------------------------------------
-- Fuel manager
---------------------------------------------------------------------

local Fuel = {}
Fuel.__index = Fuel

function Fuel.new(config)
    return setmetatable({ config = config }, Fuel)
end

function Fuel:isUnlimited()
    return turtle.getFuelLevel() == "unlimited"
end

function Fuel:level()
    local lvl = turtle.getFuelLevel()
    if lvl == "unlimited" then
        return math.huge
    end
    return lvl
end

function Fuel:isFuelItem(detail)
    if not detail then return false end
    return self.config.allowedFuel[detail.name] == true
end

function Fuel:refuel(amount)
    if self:isUnlimited() then return true end
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if self:isFuelItem(detail) then
            turtle.select(slot)
            local needed = amount or detail.count
            if turtle.refuel(needed) then
                return true
            end
        end
    end
    return false
end

function Fuel:ensure(distance)
    if self:isUnlimited() then return true end
    local needed = math.max(distance or 1, self.config.fuelReserve)
    if self:level() >= needed then return true end
    return self:refuel()
end

function Fuel:refuelTo(target)
    if self:isUnlimited() then return true end
    while self:level() < target do
        if not self:refuel() then
            return false
        end
    end
    return true
end

---------------------------------------------------------------------
-- Inventory & spawn helpers
---------------------------------------------------------------------

local Inventory = {}
Inventory.__index = Inventory

function Inventory.new(config, navigator, pose, movement, fuel)
    return setmetatable({ config = config, navigator = navigator, pose = pose, movement = movement, fuel = fuel }, Inventory)
end

function Inventory:isFull()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) == 0 then
            return false
        end
    end
    return true
end

function Inventory:stackSpace()
    local total = 0
    for slot = 1, 16 do
        total = total + turtle.getItemSpace(slot)
    end
    return total
end

function Inventory:goToOffset(offset)
    local target = { x = offset.x or 0, y = offset.y or 0, z = offset.z or 0 }
    return self.navigator:goTo(target)
end

function Inventory:faceSpawnColumn()
    local backDir = ((self.config.spawnDir or 0) + 2) % 4
    self.pose:faceAbsoluteDir(backDir)
end

function Inventory:depositAll()
    self:goToOffset(self.config.depositOffset)
    self:faceSpawnColumn()
    local keepBudget = self.config.keepFuelItems or 0
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail then
            turtle.select(slot)
            local retain = 0
            if keepBudget > 0 and self.fuel:isFuelItem(detail) then
                retain = math.min(detail.count, keepBudget)
                keepBudget = keepBudget - retain
            end
            local drop = detail.count - retain
            if drop > 0 then
                turtle.drop(drop)
            end
        end
    end
end

function Inventory:withdrawFuel(targetFuel)
    self:goToOffset(self.config.fuelChestOffset)
    self:faceSpawnColumn()
    while self.fuel:level() < targetFuel do
        if turtle.suck() then
            self.fuel:refuelTo(targetFuel)
        else
            return false
        end
    end
    return true
end

function Inventory:returnToStack()
    self.navigator:goTo({ x = 0, y = 0, z = 0 })
    self.pose:faceAbsoluteDir(self.config.spawnDir or 0)
end

---------------------------------------------------------------------
-- Local job queue (per turtle)
---------------------------------------------------------------------

local JOB_PRIORITY = {
    recall = 0,
    refuel = 1,
    ore_mine = 2,
    tunnel_mine = 3,
}

local JobQueue = {}
JobQueue.__index = JobQueue

function JobQueue.new(store, logger)
    local jobs = store.data.jobs
    jobs.pending = jobs.pending or {}
    jobs.active = jobs.active or nil
    jobs.seq = jobs.seq or 0
    return setmetatable({ store = store, logger = logger }, JobQueue)
end

function JobQueue:nextId(prefix)
    local jobs = self.store.data.jobs
    jobs.seq = jobs.seq + 1
    self.store:save()
    return string.format("%s-%05d", prefix or "job", jobs.seq)
end

function JobQueue:hasJob(predicate)
    local jobs = self.store.data.jobs
    if jobs.active and predicate(jobs.active) then
        return true
    end
    for _, job in ipairs(jobs.pending) do
        if predicate(job) then
            return true
        end
    end
    return false
end

function JobQueue:queue(job)
    local jobs = self.store.data.jobs
    jobs.pending[#jobs.pending + 1] = job
    self.store:save()
    self.logger:write("INFO", "Queued job", job.id, job.type)
end

function JobQueue:ensureRefuel(fuelLevel, config)
    if fuelLevel >= config.fuelReserve then return end
    if self:hasJob(function(job) return job.type == "refuel" end) then return end
    local job = {
        id = self:nextId("refuel"),
        type = "refuel",
        priority = JOB_PRIORITY.refuel,
        payload = { target = config.targetFuel },
    }
    self:queue(job)
end

function JobQueue:ensureRecall(active)
    if not active then return end
    if self:hasJob(function(job) return job.type == "recall" end) then return end
    local job = {
        id = self:nextId("recall"),
        type = "recall",
        priority = JOB_PRIORITY.recall,
        payload = {},
    }
    self:queue(job)
end

function JobQueue:addTunnelJob(tunnel)
    if self:hasJob(function(job)
        return job.type == "tunnel_mine" and job.payload.tunnelId == tunnel.id
    end) then
        return
    end
    local job = {
        id = string.format("tunnel-%s", tunnel.id),
        type = "tunnel_mine",
        priority = JOB_PRIORITY.tunnel_mine,
        payload = { tunnelId = tunnel.id },
    }
    self:queue(job)
end

function JobQueue:addOreJob(pos, blockName)
    local key = posKey(pos)
    if self:hasJob(function(job)
        return job.type == "ore_mine" and job.payload.key == key
    end) then
        return
    end
    local job = {
        id = self:nextId("ore"),
        type = "ore_mine",
        priority = JOB_PRIORITY.ore_mine,
        payload = { origin = deepcopy(pos), block = blockName, key = key },
    }
    self:queue(job)
end

function JobQueue:active()
    return self.store.data.jobs.active
end

function JobQueue:popNext()
    local jobs = self.store.data.jobs
    if jobs.active then
        return jobs.active
    end
    table.sort(jobs.pending, function(a, b)
        if a.priority == b.priority then
            return a.id < b.id
        end
        return a.priority < b.priority
    end)
    jobs.active = table.remove(jobs.pending, 1)
    self.store:save()
    return jobs.active
end

function JobQueue:complete()
    self.store.data.jobs.active = nil
    self.store:save()
end

function JobQueue:fail(requeue)
    local jobs = self.store.data.jobs
    local job = jobs.active
    jobs.active = nil
    if job and requeue then
        jobs.pending[#jobs.pending + 1] = job
    end
    self.store:save()
end

---------------------------------------------------------------------
-- Ore registry & scanner
---------------------------------------------------------------------

local OreRegistry = {}
OreRegistry.__index = OreRegistry

function OreRegistry.new(store, config, jobs, logger)
    return setmetatable({ store = store, config = config, jobs = jobs, logger = logger }, OreRegistry)
end

function OreRegistry:isOre(detail)
    if not detail then return false end
    if detail.tags then
        for tag in pairs(detail.tags) do
            if self.config.oreTags[tag] then
                return true
            end
        end
    end
    if detail.name and detail.name:match("_ore$") then
        return true
    end
    return false
end

function OreRegistry:record(observation)
    if not observation.detail or not observation.detail.name then return end
    if not self:isOre(observation.detail) then return end
    local key = posKey(observation.pos)
    local entry = self.store.data.oreRegistry[key]
    if entry and entry.status == "queued" then
        return
    end
    self.store.data.oreRegistry[key] = {
        name = observation.detail.name,
        status = "queued",
        recorded = now(),
    }
    self.store:save()
    self.jobs:addOreJob(observation.pos, observation.detail.name)
    self.logger:write("INFO", "Queued ore vein at", formatPos(observation.pos))
end

function OreRegistry:markComplete(key)
    local entry = self.store.data.oreRegistry[key]
    if entry then
        entry.status = "mined"
        self.store:save()
    end
end

local Scanner = {}
Scanner.__index = Scanner

function Scanner.new(pose, movement, oreRegistry, logger)
    return setmetatable({ pose = pose, movement = movement, registry = oreRegistry, logger = logger }, Scanner)
end

local function vectorLeft(dir)
    return DIR_VECTORS[(dir + 3) % 4]
end

local function vectorRight(dir)
    return DIR_VECTORS[(dir + 1) % 4]
end

local function relPos(pose, vec)
    return { x = pose.x + (vec.x or 0), y = pose.y + (vec.y or 0), z = pose.z + (vec.z or 0) }
end

function Scanner:_record(vec, detail)
    if detail and detail.name then
        local pos = relPos(self.pose:get(), vec)
        self.registry:record({ pos = pos, detail = detail })
    end
end

function Scanner:inspectForward()
    local dirVec = self.pose:dirVector()
    local success, detail = turtle.inspect()
    if success then
        self:_record(dirVec, detail)
    end
end

function Scanner:scanNeighbors()
    local downOk, downDetail = turtle.inspectDown()
    if downOk then
        self:_record({ x = 0, y = -1, z = 0 }, downDetail)
    end
    local upOk, upDetail = turtle.inspectUp()
    if upOk then
        self:_record({ x = 0, y = 1, z = 0 }, upDetail)
    end

    local function scanSide(turnFn, undoFn)
        turnFn(self.pose)
        local dirVec = self.pose:dirVector()
        local ok, detail = turtle.inspect()
        if ok then
            self:_record(dirVec, detail)
        end
        if not turtle.detectUp() then
            local movedUp = self.movement:up()
            if movedUp then
                ok, detail = turtle.inspect()
                if ok then
                    self:_record(addVec(dirVec, { y = 1 }), detail)
                end
                self.movement:down()
            end
        end
        undoFn(self.pose)
    end

    scanSide(function(p) p:turnLeft() end, function(p) p:turnRight() end)
    scanSide(function(p) p:turnRight() end, function(p) p:turnLeft() end)
    self.pose:face("forward")
end

---------------------------------------------------------------------
-- Tunnel planner and mutex model
---------------------------------------------------------------------

local TunnelPlanner = {}
TunnelPlanner.__index = TunnelPlanner

function TunnelPlanner.new(config, store, logger)
    local planner = setmetatable({ config = config, store = store, logger = logger }, TunnelPlanner)
    planner:ensureTunnels()
    return planner
end

function TunnelPlanner:ensureTunnels()
    if self.store.data.tunnels and next(self.store.data.tunnels) then
        return
    end
    local tunnels = {}
    local id = 1
    for layer = 0, self.config.boundingBox.y - 1, self.config.layerSpacing do
        for column = 0, self.config.boundingBox.x, self.config.tunnelSpacing do
            local tunnelId = string.format("T%03d", id)
            tunnels[tunnelId] = {
                id = tunnelId,
                origin = { x = column, y = layer, z = 0 },
                state = "idle",
                progress = 0,
                length = self.config.chunkLength,
            }
            id = id + 1
        end
    end
    self.store.data.tunnels = tunnels
    self.store:save()
end

function TunnelPlanner:list()
    return self.store.data.tunnels
end

function TunnelPlanner:claimNext(turtleId)
    for _, tunnel in pairs(self.store.data.tunnels) do
        if tunnel.state == "idle" then
            tunnel.state = "claimed"
            tunnel.assignedTo = turtleId
            self.store:save()
            return deepcopy(tunnel)
        end
    end
    return nil
end

function TunnelPlanner:updateProgress(tunnelId, progress, state)
    local tunnel = self.store.data.tunnels[tunnelId]
    if not tunnel then return end
    tunnel.progress = progress
    tunnel.state = state or tunnel.state
    self.store:save()
end

---------------------------------------------------------------------
-- Network and leader election
---------------------------------------------------------------------

local Network = {}
Network.__index = Network

function Network.new(config, logger)
    ensureModem()
    local self = setmetatable({ protocol = config.protocol, logger = logger, seq = 0 }, Network)
    self.id = computerID()
    return self
end

function Network:nextSeq()
    self.seq = self.seq + 1
    return self.seq
end

function Network:send(message, target)
    message.sender = self.id
    message.seq = self:nextSeq()
    message.timestamp = now()
    if target then
        rednet.send(target, message, self.protocol)
    else
        rednet.broadcast(message, self.protocol)
    end
end

function Network:receive(timeout)
    local sender, payload = rednet.receive(self.protocol, timeout)
    return sender, payload
end

local Leader = {}
Leader.__index = Leader

function Leader.new(store, network, config, logger)
    return setmetatable({ store = store, network = network, config = config, logger = logger, lastHeartbeat = 0 }, Leader)
end

function Leader:isMaster()
    return self.store.data.masterId == self.network.id
end

function Leader:updateMaster()
    local candidates = {}
    for id, turtleInfo in pairs(self.store.data.turtles) do
        if now() - turtleInfo.lastSeen <= self.config.heartbeatTimeout then
            candidates[#candidates + 1] = id
        end
    end
    if #candidates == 0 then
        candidates[#candidates + 1] = self.network.id
    end
    table.sort(candidates)
    local masterId = candidates[1]
    if masterId ~= self.store.data.masterId then
        self.logger:write("INFO", "New master elected", tostring(masterId))
        self.store.data.masterId = masterId
        self.store:save()
    end
end

function Leader:recordHeartbeat(msg)
    self.store.data.turtles[msg.sender] = {
        status = msg.status,
        job = msg.job,
        fuel = msg.fuel,
        lastSeen = now(),
    }
    self.store:save()
end

function Leader:tick(jobStatus)
    local timeSince = now() - self.lastHeartbeat
    if timeSince >= self.config.heartbeatInterval then
        self.lastHeartbeat = now()
        self.network:send({ type = "heartbeat", status = jobStatus.state, job = jobStatus.job, fuel = jobStatus.fuel, quarryId = self.config.quarryId })
    end
end

---------------------------------------------------------------------
-- Worker logic
---------------------------------------------------------------------

local Worker = {}
Worker.__index = Worker

function Worker.new(config, store, network, planner, pose, movement, navigator, inventory, fuel, jobs, oreRegistry, scanner, logger)
    return setmetatable({
        config = config,
        store = store,
        network = network,
        planner = planner,
        pose = pose,
        movement = movement,
        navigator = navigator,
        inventory = inventory,
        fuel = fuel,
        jobs = jobs,
        oreRegistry = oreRegistry,
        scanner = scanner,
        logger = logger,
        lastRequest = 0,
        failures = 0,
    }, Worker)
end

function Worker:activeJob()
    return self.jobs:active()
end

function Worker:queueTunnel(job)
    self.jobs:addTunnelJob(job)
end

function Worker:requestTunnelJob()
    if now() - self.lastRequest < self.config.jobRetryInterval then
        return
    end
    self.lastRequest = now()
    if self.store.data.masterId == self.network.id then
        local job = self.planner:claimNext(self.network.id)
        if job then
            self:queueTunnel(job)
        end
    else
        self.network:send({ type = "job_request" }, self.store.data.masterId)
    end
end

function Worker:handleMessage(msg)
    if msg.type == "assign" and msg.target == self.network.id then
        self.logger:write("INFO", "Received tunnel assignment", msg.job.id)
        self:queueTunnel(msg.job)
    elseif msg.type == "job_request" and self.store.data.masterId == self.network.id then
        local job = self.planner:claimNext(msg.sender)
        if job then
            self.network:send({ type = "assign", target = msg.sender, job = job }, msg.sender)
        end
    elseif msg.type == "config_update" and msg.quarryId == self.config.quarryId then
        self.logger:write("INFO", "Received config update v" .. tostring(msg.config.configVersion))
        local path = Config.path(msg.quarryId)
        with_handle(path, "w", function(h)
            h.write(textutils.serializeJSON(msg.config, { allow_repetitions = true }))
        end)
        self.config = Config.load(path)
    elseif msg.type == "config_request" and msg.quarryId == self.config.quarryId then
        self.network:send({ type = "config_response", quarryId = msg.quarryId, config = self.config }, msg.sender)
    elseif msg.type == "recall" and msg.quarryId == self.config.quarryId then
        self.store.data.recall.active = msg.active
        self.store:save()
    end
end

function Worker:ensureSystemJobs()
    self.jobs:ensureRefuel(self.fuel:level(), self.config)
    self.jobs:ensureRecall(self.store.data.recall.active)
end

function Worker:ensureTunnelJob()
    if not self:hasPendingTunnel() then
        self:requestTunnelJob()
    end
end

function Worker:hasPendingTunnel()
    return self.jobs:hasJob(function(job)
        return job.type == "tunnel_mine"
    end)
end

function Worker:runRefuel(job)
    self.inventory:depositAll()
    if not self.inventory:withdrawFuel(job.payload.target or self.config.targetFuel) then
        self.logger:write("WARN", "Fuel chest empty; retrying later")
        return false, true
    end
    return true, false
end

local floodDirs = {
    { x = 1, y = 0, z = 0 }, { x = -1, y = 0, z = 0 },
    { x = 0, y = 1, z = 0 }, { x = 0, y = -1, z = 0 },
    { x = 0, y = 0, z = 1 }, { x = 0, y = 0, z = -1 },
}

function Worker:gotoPosition(pos)
    return self.navigator:goTo(pos)
end

function Worker:runOreJob(job)
    local root = job.payload.origin
    local visited = {}
    local stack = { deepcopy(root) }
    while #stack > 0 do
        local node = table.remove(stack)
        local key = posKey(node)
        if not visited[key] then
            visited[key] = true
            self:gotoPosition({ x = node.x, y = node.y, z = node.z })
            self.pose:face("forward")
            self.movement:digForward()
            for _, dir in ipairs(floodDirs) do
                stack[#stack + 1] = { x = node.x + dir.x, y = node.y + dir.y, z = node.z + dir.z }
            end
        end
    end
    self.oreRegistry:markComplete(job.payload.key)
    self.store.data.metrics.ore = (self.store.data.metrics.ore or 0) + 1
    self.store:save()
    return true, false
end

function Worker:runTunnelJob(job)
    local tunnel = self.store.data.tunnels[job.payload.tunnelId]
    if not tunnel then
        return true, false
    end
    local target = {
        x = tunnel.origin.x,
        y = tunnel.origin.y,
        z = tunnel.origin.z + tunnel.progress,
    }
    self.navigator:goTo(target)
    self.pose:face("forward")
    self.scanner:inspectForward()
    self.movement:digForward()
    local ok = self.movement:forward()
    if not ok then
        return false, true
    end
    self.scanner:scanNeighbors()
    tunnel.progress = tunnel.progress + 1
    self.store.data.metrics.mined = self.store.data.metrics.mined + 1
    if tunnel.progress >= tunnel.length then
        tunnel.state = "done"
    else
        tunnel.state = "active"
    end
    self.store:save()
    if self.inventory:isFull() or self.inventory:stackSpace() < 4 then
        self.inventory:depositAll()
    end
    return tunnel.state == "done", false
end

function Worker:runRecallJob()
    self.inventory:depositAll()
    self.inventory:returnToStack()
    return true, false
end

function Worker:stepJob(job)
    if job.type == "refuel" then
        return self:runRefuel(job)
    elseif job.type == "ore_mine" then
        return self:runOreJob(job)
    elseif job.type == "tunnel_mine" then
        return self:runTunnelJob(job)
    elseif job.type == "recall" then
        return self:runRecallJob(job)
    end
    return true, false
end

function Worker:tick()
    self:ensureSystemJobs()
    self:ensureTunnelJob()
    local job = self.jobs:popNext()
    if not job then
        return { state = "idle", job = nil, fuel = self.fuel:level() }
    end
    local done, retry = self:stepJob(job)
    if done then
        self.logger:write("INFO", "Completed job", job.id, job.type)
        self.jobs:complete()
    elseif retry then
        self.jobs:fail(true)
    else
        self.jobs:fail(false)
    end
    return { state = job.type, job = job.id, fuel = self.fuel:level() }
end

---------------------------------------------------------------------
-- Message pump
---------------------------------------------------------------------

local function messageLoop(network, leader, worker, logger)
    while true do
        local sender, msg = network:receive(0.1)
        if sender and type(msg) == "table" then
            if msg.type == "heartbeat" then
                leader:recordHeartbeat(msg)
                leader:updateMaster()
            else
                worker:handleMessage(msg)
            end
        end
        local status = worker:tick()
        leader:tick(status)
        leader:updateMaster()
    end
end

---------------------------------------------------------------------
-- CLI helpers
---------------------------------------------------------------------

local function ensureQuarryId(store)
    if store.data.quarryId then
        return store.data.quarryId
    end
    local id = prompt("Enter quarry id", "default", function(value)
        if value == "" then
            return false, "cannot be empty"
        end
        return true, nil, value:lower()
    end)
    store:update(function(data)
        data.quarryId = id
    end)
    return id
end

local function runRecallBroadcast(quarryId)
    ensureModem()
    rednet.broadcast({ type = "recall", quarryId = quarryId, active = true }, DEFAULT_CONFIG.protocol)
    print("Recall broadcast sent for quarry " .. quarryId)
end

---------------------------------------------------------------------
-- Main bootstrap
---------------------------------------------------------------------

local function main(...)
    local args = { ... }
    if args[1] == "recall" then
        local quarryId = args[2] or prompt("Quarry id to recall", "default")
        runRecallBroadcast(quarryId)
        return
    end
    local configFile = args[1]
    local bootstrapConfig = Config.load(configFile) or merge({ path = configFile or DEFAULT_CONFIG.statePath }, deepcopy(DEFAULT_CONFIG))
    local store = StateStore.new(bootstrapConfig)
    store:load()
    local quarryId = ensureQuarryId(store)
    local logger = Logger.new(bootstrapConfig.logPath)
    local config = ensureConfig(quarryId, logger)
    config.quarryId = quarryId
    local bbox = BoundingBox.new(config.boundingBox)
    local fuel = Fuel.new(config)
    local pose = Pose.wrap(store.data)
    pose:setDir(config.spawnDir or pose:get().dir)
    local acid = Acid.new(config, store)
    local movement = Movement.new(store, pose, acid, bbox, fuel)
    movement:attachVerifiers()
    acid:register("dig_forward", function()
        return not turtle.detect()
    end)
    acid:register("dig_down", function()
        return not turtle.detectDown()
    end)
    acid:resume()

    local navigator = Navigator.new(pose, movement, bbox)
    local inventory = Inventory.new(config, navigator, pose, movement, fuel)
    local planner = TunnelPlanner.new(config, store, logger)
    local jobs = JobQueue.new(store, logger)
    local oreRegistry = OreRegistry.new(store, config, jobs, logger)
    local scanner = Scanner.new(pose, movement, oreRegistry, logger)
    local network = Network.new(config, logger)
    local leader = Leader.new(store, network, config, logger)
    local worker = Worker.new(config, store, network, planner, pose, movement, navigator, inventory, fuel, jobs, oreRegistry, scanner, logger)

    local calibrator = Calibrator.new(store, pose, movement, bbox, logger)
    calibrator:run(config)

    messageLoop(network, leader, worker, logger)
end

main(...)
