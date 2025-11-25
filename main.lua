---@diagnostic disable: undefined-global, undefined-field
-- Project: automine main entry point
-- All turtle/rednet/textutils API usages are validated against the local CC: Tweaked docs in cc_docs/tweaked.cc/module/*.html.
-- Keep this file self-contained per project requirements.

local VERSION = "0.1.0-dev"

local DOCS = {
    turtle = "cc_docs/tweaked.cc/module/turtle.html",
    rednet = "cc_docs/tweaked.cc/module/rednet.html",
    textutils = "cc_docs/tweaked.cc/module/textutils.html",
    fs = "cc_docs/tweaked.cc/module/fs.html",
    peripheral = "cc_docs/tweaked.cc/module/peripheral.html",
}

local function verifyApi(name, docPath)
    if not _G[name] then
        error(("Missing API '%s'. Consult %s to install/enable it before running."):format(name, docPath))
    end
end

verifyApi("turtle", DOCS.turtle)
verifyApi("textutils", DOCS.textutils)
verifyApi("rednet", DOCS.rednet)
verifyApi("fs", DOCS.fs)
verifyApi("peripheral", DOCS.peripheral)

local turtle = _G.turtle
local textutils = _G.textutils
local rednet = _G.rednet
local fs = _G.fs
local peripheral = _G.peripheral
local term = _G.term
local read = _G.read
local sleep = _G.sleep
local os = _G.os
local printError = _G.printError

local function shallowCopy(tbl)
    local copy = {}
    for k, v in pairs(tbl) do
        copy[k] = v
    end
    return copy
end

local function deepMerge(base, overrides)
    local out = {}
    for k, v in pairs(base) do
        if type(v) == "table" then
            out[k] = deepMerge(v, {})
        else
            out[k] = v
        end
    end
    for k, v in pairs(overrides or {}) do
        if type(v) == "table" and type(out[k]) == "table" then
            out[k] = deepMerge(out[k], v)
        else
            out[k] = v
        end
    end
    return out
end

local function mergeDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                target[k] = shallowCopy(v)
            else
                target[k] = v
            end
        elseif type(v) == "table" and type(target[k]) == "table" then
            mergeDefaults(target[k], v)
        end
    end
end

local function ensureDir(path)
    if fs.exists(path) and not fs.isDir(path) then
        error(("Expected directory at %s but found file."):format(path))
    elseif not fs.exists(path) then
        fs.makeDir(path)
    end
end

local Json = {}
Json.encode = function(tbl)
    -- textutils.serialiseJSON supports producing RFC-compliant JSON (docs: DOCS.textutils)
    return textutils.serialiseJSON(tbl, { allow_repetitions = false, unicode_strings = true })
end
Json.decode = function(str)
    local value, err = textutils.unserialiseJSON(str)
    if not value and err then
        error("Failed to parse JSON: " .. tostring(err))
    end
    return value
end

local function readFile(path)
    if not fs.exists(path) then
        return nil
    end
    local handle = fs.open(path, "r")
    if not handle then
        error("Unable to open file for reading: " .. path)
    end
    local data = handle.readAll()
    handle.close()
    return data
end

local function writeAtomic(path, contents)
    local dir = fs.getDir(path)
    if dir ~= "" then
        ensureDir(dir)
    end
    local tempPath = path .. ".tmp"
    local handle = fs.open(tempPath, "w")
    if not handle then
        error("Unable to open temp file for writing: " .. tempPath)
    end
    handle.write(contents)
    handle.close()
    if fs.exists(path) then
        fs.delete(path)
    end
    fs.move(tempPath, path)
end

local function readJson(path, defaultValue)
    local raw = readFile(path)
    if not raw then
        return shallowCopy(defaultValue)
    end
    local ok, decoded = pcall(Json.decode, raw)
    if not ok then
        error(("Corrupt JSON file %s: %s"):format(path, decoded))
    end
    return decoded
end

local function writeJson(path, tbl)
    writeAtomic(path, Json.encode(tbl))
end

local function simpleHash(str)
    -- FNV-1a 32-bit for deterministic checksums
    local hash = 2166136261
    for i = 1, #str do
        hash = hash ~ string.byte(str, i)
        hash = (hash * 16777619) % 4294967296
    end
    return hash
end

local function serializeForHash(tbl)
    return textutils.serialise(tbl, { compact = true })
end

local function clonePosition(pos)
    if not pos then
        return { x = 0, y = 0, z = 0 }
    end
    return { x = pos.x, y = pos.y, z = pos.z }
end

local function sign(num)
    if num > 0 then
        return 1
    elseif num < 0 then
        return -1
    end
    return 0
end

local Orientation = {}

Orientation.VECTORS = {
    [0] = { x = 1, z = 0 },
    [1] = { x = 0, z = 1 },
    [2] = { x = -1, z = 0 },
    [3] = { x = 0, z = -1 },
}

function Orientation.normalize(facing)
    local normalized = facing % 4
    if normalized < 0 then
        normalized = normalized + 4
    end
    return normalized
end

function Orientation.vector(facing)
    return Orientation.VECTORS[Orientation.normalize(facing)]
end

function Orientation.left(facing)
    return Orientation.normalize(facing - 1)
end

function Orientation.right(facing)
    return Orientation.normalize(facing + 1)
end

function Orientation.opposite(facing)
    return Orientation.normalize(facing + 2)
end

function Orientation.facingForVector(vec)
    local normalized = { x = sign(vec.x), z = sign(vec.z) }
    for facing, v in pairs(Orientation.VECTORS) do
        if v.x == normalized.x and v.z == normalized.z then
            return facing
        end
    end
    return nil
end

function Orientation.vectorForRelative(facing, direction)
    if direction == "forward" then
        local vec = Orientation.vector(facing)
        return { x = vec.x, y = 0, z = vec.z }
    elseif direction == "back" then
        local vec = Orientation.vector(Orientation.opposite(facing))
        return { x = vec.x, y = 0, z = vec.z }
    elseif direction == "left" then
        local vec = Orientation.vector(Orientation.left(facing))
        return { x = vec.x, y = 0, z = vec.z }
    elseif direction == "right" then
        local vec = Orientation.vector(Orientation.right(facing))
        return { x = vec.x, y = 0, z = vec.z }
    elseif direction == "up" then
        return { x = 0, y = 1, z = 0 }
    elseif direction == "down" then
        return { x = 0, y = -1, z = 0 }
    end
    error("Unknown relative direction: " .. tostring(direction))
end

function Orientation.describe(facing)
    local names = { "+X", "+Z", "-X", "-Z" }
    return names[Orientation.normalize(facing) + 1]
end

local Log = {
    fileEnabled = false,
    logPath = nil,
    fileHandle = nil,
    consoleVerbosity = "info",
    docRefs = DOCS,
}

local LEVELS = {
    trace = 1,
    debug = 2,
    info = 3,
    warn = 4,
    error = 5,
}

local function severityAllowed(level, threshold)
    return LEVELS[level] >= LEVELS[threshold]
end

function Log.configure(opts)
    Log.fileEnabled = not not opts.fileEnabled
    Log.logPath = opts.logPath
    Log.consoleVerbosity = opts.consoleVerbosity or "info"
    if Log.fileHandle then
        Log.fileHandle.close()
        Log.fileHandle = nil
    end
    if Log.fileEnabled and Log.logPath then
        local dir = fs.getDir(Log.logPath)
        if dir ~= "" then
            ensureDir(dir)
        end
        Log.fileHandle = fs.open(Log.logPath, "a")
        if not Log.fileHandle then
            error("Unable to open log file: " .. Log.logPath)
        end
    end
end

local function fmtContext(ctx)
    if not ctx then
        return ""
    end
    local parts = {}
    for k, v in pairs(ctx) do
        parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    table.sort(parts)
    if #parts == 0 then
        return ""
    end
    return " [" .. table.concat(parts, ",") .. "]"
end

function Log.write(level, msg, ctx)
    if not LEVELS[level] then
        error("Unknown log level: " .. tostring(level))
    end
    local timestamp = os.epoch and os.epoch("utc") or os.clock()
    local line = ("[%s] %s %s%s"):format(level:upper(), tostring(timestamp), tostring(msg), fmtContext(ctx))
    if severityAllowed(level, Log.consoleVerbosity) then
        if level == "error" or level == "warn" then
            printError(line)
        else
            print(line)
        end
    end
    if Log.fileHandle and Log.fileEnabled then
        Log.fileHandle.writeLine(line)
        Log.fileHandle.flush()
    end
end

local STATE_ROOT = "/state"
local CONFIG_ROOT = STATE_ROOT .. "/configs"
local TURTLE_STATE_ROOT = STATE_ROOT .. "/turtles"
local JOB_ROOT = STATE_ROOT .. "/jobs"
local LOG_ROOT = "/logs"

local DEFAULT_CONFIG = {
    version = 1,
    boundingBox = {
        originForward = { x = 0, y = 0, z = 1 },
        secondPoint = { x = 16, y = 16, z = 16 },
    },
    spawn = {
        column = { x = 0, z = 0 },
        topY = 0,
    },
    layers = {
        spacing = 2,
        startY = 0,
    },
    logging = {
        fileEnabled = true,
        consoleVerbosity = "info",
    },
    fuel = {
        reserve = 500,
    },
    job = {
        retryLimit = 5,
        maxOreNodes = 96,
    },
}

local function configPath(quarryId)
    return ("%s/%s.json"):format(CONFIG_ROOT, quarryId)
end

local function turtleStatePath(quarryId, turtleId)
    return ("%s/%s_%s.json"):format(TURTLE_STATE_ROOT, quarryId, turtleId)
end

local function jobQueuePath(quarryId)
    return ("%s/%s_queue.log"):format(JOB_ROOT, quarryId)
end

local function ensureRoots()
    ensureDir(STATE_ROOT)
    ensureDir(CONFIG_ROOT)
    ensureDir(TURTLE_STATE_ROOT)
    ensureDir(JOB_ROOT)
    ensureDir(LOG_ROOT)
end

ensureRoots()

local function prompt(message, default)
    term.write(message)
    if default ~= nil then
        term.write((" [%s]"):format(default))
    end
    term.write(": ")
    local value = read()
    if value == "" and default ~= nil then
        return default
    end
    return value
end

local function promptNumber(message, default)
    while true do
        local input = prompt(message, default and tostring(default) or nil)
        local num = tonumber(input)
        if num then
            return num
        end
        print("Invalid number, try again.")
    end
end

local function promptBoolean(message, default)
    local defaultHint = default and "y" or "n"
    while true do
        local input = prompt(message .. " (y/n)", defaultHint)
        input = input:lower()
        if input == "y" or input == "yes" then
            return true
        elseif input == "n" or input == "no" then
            return false
        elseif input == "" and default ~= nil then
            return default
        end
        print("Please enter y or n.")
    end
end

local function createConfigInteractively(quarryId)
    print("No configuration found for quarry '" .. quarryId .. "'. Let's create one.")
    local cfg = deepMerge(DEFAULT_CONFIG, {})
    cfg.boundingBox.secondPoint.x = promptNumber("Bounding box X (second point relative to origin)", cfg.boundingBox.secondPoint.x)
    cfg.boundingBox.secondPoint.y = promptNumber("Bounding box Y", cfg.boundingBox.secondPoint.y)
    cfg.boundingBox.secondPoint.z = promptNumber("Bounding box Z", cfg.boundingBox.secondPoint.z)
    cfg.spawn.column.x = promptNumber("Spawn column X", cfg.spawn.column.x)
    cfg.spawn.column.z = promptNumber("Spawn column Z", cfg.spawn.column.z)
    cfg.spawn.topY = promptNumber("Spawn column top Y", cfg.spawn.topY)
    cfg.layers.spacing = promptNumber("Layer spacing (must be >=2)", cfg.layers.spacing)
    cfg.layers.startY = promptNumber("First layer Y", cfg.layers.startY)
    cfg.logging.fileEnabled = promptBoolean("Enable file logging?", cfg.logging.fileEnabled)
    cfg.logging.consoleVerbosity = prompt("Console verbosity (trace/debug/info/warn/error)", cfg.logging.consoleVerbosity)
    cfg.fuel.reserve = promptNumber("Fuel reserve threshold", cfg.fuel.reserve)
    cfg.job.retryLimit = promptNumber("Job retry limit", cfg.job.retryLimit)
    cfg.job.maxOreNodes = promptNumber("Max ore nodes per job", cfg.job.maxOreNodes)
    cfg.version = (cfg.version or 0) + 1
    writeJson(configPath(quarryId), cfg)
    return cfg
end

local function loadOrInitConfig(quarryId)
    local path = configPath(quarryId)
    if not fs.exists(path) then
        return createConfigInteractively(quarryId)
    end
    local cfg = readJson(path, DEFAULT_CONFIG)
    cfg = deepMerge(DEFAULT_CONFIG, cfg)
    cfg.version = (cfg.version or 0) + 1
    writeJson(path, cfg)
    return cfg
end

local TurtleState = {}

local function defaultTurtleState(quarryId, turtleId)
    return {
        quarryId = quarryId,
        turtleId = turtleId,
        position = { x = 0, y = 0, z = 0 },
        facing = 0,
        calibrated = false,
        lastConfigVersion = 0,
        jobCursor = nil,
        fuelLog = {},
        oreBookmarks = {},
    }
end

function TurtleState.load(quarryId, turtleId)
    local path = turtleStatePath(quarryId, turtleId)
    local defaults = defaultTurtleState(quarryId, turtleId)
    if not fs.exists(path) then
        return defaults
    end
    local state = readJson(path, defaults)
    mergeDefaults(state, defaults)
    return state
end

function TurtleState.save(state)
    writeJson(turtleStatePath(state.quarryId, state.turtleId), state)
end

local function turtleId()
    return tostring(os.getComputerID())
end

local function calibrateVertical(state, cfg)
    Log.write("info", "Starting vertical calibration", { turtle = state.turtleId })
    local movedDown = 0
    while true do
        local ok, reason = turtle.down() -- validated API (DOCS.turtle)
        if not ok then
            Log.write("debug", "down blocked", { reason = tostring(reason) })
            break
        end
        movedDown = movedDown + 1
    end
    local movedUp = 0
    while true do
        local ok, reason = turtle.up()
        if not ok then
            Log.write("debug", "up blocked", { reason = tostring(reason) })
            break
        end
        movedUp = movedUp + 1
    end
    -- Return to bottom of spawn column to align with turtle space
    for _ = 1, movedUp do
        local ok, reason = turtle.down()
        if not ok then
            Log.write("warn", "Unable to return back down fully", { reason = tostring(reason) })
            break
        end
    end
    state.position.x = cfg.spawn.column.x
    state.position.z = cfg.spawn.column.z
    state.position.y = 0
    state.calibrated = true
    local facing = Orientation.facingForVector(cfg.boundingBox.originForward or { x = 0, z = 1 })
    if facing then
        state.facing = facing
    end
    Log.write("info", "Vertical calibration complete", { down = movedDown, up = movedUp })
end

local function ensureFuelReserve(cfg)
    local fuelLevel = turtle.getFuelLevel()
    if fuelLevel == "unlimited" then
        return true
    end
    local reserve = cfg.fuel.reserve or 0
    if fuelLevel >= reserve then
        return true
    end
    Log.write("warn", "Fuel below reserve; attempting refuel", { level = fuelLevel, reserve = reserve })
    for slot = 1, 16 do
        turtle.select(slot)
        local ok, err = turtle.refuel(0) -- docs allow count=0 check (DOCS.turtle)
        if ok then
            local consumed = turtle.refuel()
            if consumed then
                Log.write("info", "Refuelled from slot", { slot = slot })
                break
            end
        else
            if err and err ~= "Cannot refuel with a non-fuel item" then
                Log.write("debug", "Refuel probe failed", { slot = slot, err = err })
            end
        end
    end
    turtle.select(1)
    return turtle.getFuelLevel() >= reserve
end

local Network = {
    quarryId = nil,
    protocol = nil,
    open = false,
}

local function ensureModemsOpen()
    local openedAny = false
    peripheral.find("modem", function(name)
        rednet.open(name) -- per DOCS.rednet open(modem)
        openedAny = true
    end)
    if not openedAny then
        error("No wireless modem found. Attach one and retry.")
    end
    return true
end

function Network.init(quarryId)
    ensureModemsOpen()
    Network.quarryId = quarryId
    Network.protocol = "automine:" .. quarryId
    Network.open = true
    Log.write("info", "Network ready", { protocol = Network.protocol })
end

function Network.broadcast(messageType, payload)
    if not Network.open then
        error("Network not initialised")
    end
    local envelope = {
        type = messageType,
        quarryId = Network.quarryId,
        payload = payload,
        timestamp = os.epoch("utc"),
    }
    local ok = rednet.broadcast(envelope, Network.protocol)
    if not ok then
        Log.write("warn", "Broadcast failed", { type = messageType })
    end
end

function Network.send(targetId, messageType, payload)
    if not Network.open then
        error("Network not initialised")
    end
    local envelope = {
        type = messageType,
        quarryId = Network.quarryId,
        payload = payload,
        timestamp = os.epoch("utc"),
    }
    local ok = rednet.send(targetId, envelope, Network.protocol)
    if not ok then
        Log.write("warn", "Send failed", { target = targetId, type = messageType })
    end
end

local Jobs = {}

local function appendJobRecord(quarryId, record)
    local path = jobQueuePath(quarryId)
    local serialized = Json.encode(record)
    local handle = fs.open(path, "a")
    if not handle then
        error("Failed to open job log: " .. path)
    end
    handle.writeLine(serialized)
    handle.close()
end

local function readJobRecords(quarryId)
    local path = jobQueuePath(quarryId)
    if not fs.exists(path) then
        return {}
    end
    local handle = fs.open(path, "r")
    local jobs = {}
    while true do
        local line = handle.readLine()
        if not line then
            break
        end
        local ok, decoded = pcall(Json.decode, line)
        if ok then
            jobs[#jobs + 1] = decoded
        else
            Log.write("error", "Corrupt job record", { line = line })
        end
    end
    handle.close()
    return jobs
end

function Jobs.enqueue(quarryId, job)
    local record = {
        id = os.epoch("utc") .. "-" .. simpleHash(serializeForHash(job)),
        job = job,
        priority = job.priority or 3,
        createdAt = os.epoch("utc"),
        status = "queued",
        attempts = 0,
    }
    appendJobRecord(quarryId, record)
    Log.write("info", "Enqueued job", { id = record.id, type = job.type })
    return record
end

function Jobs.loadQueue(quarryId)
    local history = readJobRecords(quarryId)
    local latest = {}
    for _, record in ipairs(history) do
        latest[record.id] = record
    end
    local queued = {}
    for _, record in pairs(latest) do
        if record.status == "queued" or record.status == "claimed" then
            queued[#queued + 1] = record
        end
    end
    table.sort(queued, function(a, b)
        if a.priority == b.priority then
            return a.createdAt < b.createdAt
        end
        return a.priority < b.priority
    end)
    return queued
end

local Scheduler = {}
local JobExecutors = {}

function Scheduler.register(jobType, handler)
    JobExecutors[jobType] = handler
end

function Scheduler.execute(quarryId, record, state, cfg)
    local handler = JobExecutors[record.job.type]
    if not handler then
        return false, { success = false, error = "unknown job type" }
    end
    local ctx = {
        quarryId = quarryId,
        state = state,
        cfg = cfg,
        job = record.job,
        record = record,
        enqueue = function(job)
            return Jobs.enqueue(quarryId, job)
        end,
    }
    local ok, result = pcall(handler, ctx)
    if not ok then
        Log.write("error", "Job handler crashed", { id = record.id, err = tostring(result) })
        return false, { success = false, error = tostring(result) }
    end
    if result == nil then
        result = { success = true }
    end
    if result.success == nil then
        result.success = true
    end
    return result.success, result
end

function Scheduler.nextJob(records, state)
    for _, record in ipairs(records) do
        if (record.status == "queued" and not record.claimedBy)
            or (record.status == "claimed" and record.claimedBy == state.turtleId) then
            return record
        end
    end
    return nil
end

function Scheduler.claimJob(quarryId, record, state)
    record.claimedBy = state.turtleId
    record.claimedAt = os.epoch("utc")
    record.status = "claimed"
    appendJobRecord(quarryId, record)
end

function Scheduler.completeJob(quarryId, record, outcome)
    record.status = outcome.success and "completed" or "failed"
    record.result = outcome
    appendJobRecord(quarryId, record)
    Network.broadcast("job_status", {
        id = record.id,
        status = record.status,
    })
end

function Scheduler.failJob(quarryId, record, reason, cfg)
    record.attempts = (record.attempts or 0) + 1
    record.lastError = reason
    if record.attempts >= (cfg.job.retryLimit or DEFAULT_CONFIG.job.retryLimit) then
        record.status = "failed"
        appendJobRecord(quarryId, record)
        Network.broadcast("job_status", {
            id = record.id,
            status = record.status,
            error = reason,
        })
        return
    end
    record.status = "queued"
    record.claimedBy = nil
    record.claimedAt = nil
    appendJobRecord(quarryId, record)
end

local function withinBoundingBox(pos, cfg)
    local minX = math.min(0, cfg.boundingBox.secondPoint.x)
    local maxX = math.max(0, cfg.boundingBox.secondPoint.x)
    local minY = math.min(0, cfg.boundingBox.secondPoint.y)
    local maxY = math.max(0, cfg.boundingBox.secondPoint.y)
    local minZ = math.min(0, cfg.boundingBox.secondPoint.z)
    local maxZ = math.max(0, cfg.boundingBox.secondPoint.z)
    return pos.x >= minX and pos.x <= maxX
        and pos.y >= minY and pos.y <= maxY
        and pos.z >= minZ and pos.z <= maxZ
end

local Movement = {}

local CLEAR_OPS = {
    forward = { detect = turtle.detect, dig = turtle.dig },
    up = { detect = turtle.detectUp, dig = turtle.digUp },
    down = { detect = turtle.detectDown, dig = turtle.digDown },
}

local INSPECT_OPS = {
    forward = turtle.inspect,
    up = turtle.inspectUp,
    down = turtle.inspectDown,
}

local function clearDirection(direction)
    local ops = CLEAR_OPS[direction]
    if not ops then
        return
    end
    while ops.detect() do
        ops.dig() -- DOCS.turtle: dig/digUp/digDown clear blocks before motion
        sleep(0.2)
    end
end

local function applyDelta(pos, delta)
    return {
        x = pos.x + (delta.x or 0),
        y = pos.y + (delta.y or 0),
        z = pos.z + (delta.z or 0),
    }
end

local function commitPosition(state, newPos)
    state.position.x = newPos.x
    state.position.y = newPos.y
    state.position.z = newPos.z
end

function Movement.turnLeft(state)
    local ok, err = turtle.turnLeft() -- DOCS.turtle turnLeft rotates 90°
    if not ok then
        Log.write("warn", "turnLeft failed", { err = tostring(err) })
        return false
    end
    state.facing = Orientation.left(state.facing)
    return true
end

function Movement.turnRight(state)
    local ok, err = turtle.turnRight()
    if not ok then
        Log.write("warn", "turnRight failed", { err = tostring(err) })
        return false
    end
    state.facing = Orientation.right(state.facing)
    return true
end

function Movement.face(state, targetFacing)
    targetFacing = Orientation.normalize(targetFacing)
    while state.facing ~= targetFacing do
        local clockwise = (targetFacing - state.facing) % 4
        if clockwise == 3 then
            if not Movement.turnLeft(state) then
                return false
            end
        else
            if not Movement.turnRight(state) then
                return false
            end
        end
    end
    return true
end

local function attemptMove(fn, direction)
    local ok, reason = fn()
    if not ok then
        Log.write("warn", "turtle move failed", { direction = direction, reason = tostring(reason) })
        return false
    end
    return true
end

function Movement.forward(state, cfg)
    local delta = Orientation.vectorForRelative(state.facing, "forward")
    local target = applyDelta(state.position, delta)
    if not withinBoundingBox(target, cfg) then
        Log.write("warn", "Blocked move outside bounding box", { axis = "forward" })
        return false
    end
    clearDirection("forward")
    if not attemptMove(turtle.forward, "forward") then
        return false
    end
    commitPosition(state, target)
    return true
end

function Movement.back(state, cfg)
    local delta = Orientation.vectorForRelative(state.facing, "back")
    local target = applyDelta(state.position, delta)
    if not withinBoundingBox(target, cfg) then
        Log.write("warn", "Blocked backward move outside box", {})
        return false
    end
    if not attemptMove(turtle.back, "back") then -- DOCS.turtle back()
        return false
    end
    commitPosition(state, target)
    return true
end

function Movement.up(state, cfg)
    local delta = Orientation.vectorForRelative(state.facing, "up")
    local target = applyDelta(state.position, delta)
    if not withinBoundingBox(target, cfg) then
        Log.write("warn", "Blocked upward movement outside bounding box", {})
        return false
    end
    clearDirection("up")
    if not attemptMove(turtle.up, "up") then
        return false
    end
    commitPosition(state, target)
    return true
end

function Movement.down(state, cfg)
    local delta = Orientation.vectorForRelative(state.facing, "down")
    local target = applyDelta(state.position, delta)
    if not withinBoundingBox(target, cfg) then
        Log.write("warn", "Blocked downward movement outside bounding box", {})
        return false
    end
    clearDirection("down")
    if not attemptMove(turtle.down, "down") then
        return false
    end
    commitPosition(state, target)
    return true
end

function Movement.step(state, cfg, direction)
    if direction == "forward" then
        return Movement.forward(state, cfg)
    elseif direction == "back" then
        return Movement.back(state, cfg)
    elseif direction == "up" then
        return Movement.up(state, cfg)
    elseif direction == "down" then
        return Movement.down(state, cfg)
    elseif direction == "left" then
        if not Movement.turnLeft(state) then
            return false
        end
        local ok = Movement.forward(state, cfg)
        Movement.turnRight(state)
        return ok
    elseif direction == "right" then
        if not Movement.turnRight(state) then
            return false
        end
        local ok = Movement.forward(state, cfg)
        Movement.turnLeft(state)
        return ok
    end
    error("Unsupported move direction: " .. tostring(direction))
end

function Movement.inspect(state, direction)
    local inspector = INSPECT_OPS[direction]
    if inspector then
        return inspector()
    end
    if direction == "left" then
        if not Movement.turnLeft(state) then
            return false, nil
        end
        local ok, data = turtle.inspect()
        Movement.turnRight(state)
        return ok, data
    elseif direction == "right" then
        if not Movement.turnRight(state) then
            return false, nil
        end
        local ok, data = turtle.inspect()
        Movement.turnLeft(state)
        return ok, data
    elseif direction == "back" then
        if not Movement.turnRight(state) then
            return false, nil
        end
        if not Movement.turnRight(state) then
            Movement.turnLeft(state) -- attempt to restore orientation if second turn fails
            return false, nil
        end
        local ok, data = turtle.inspect()
        Movement.turnRight(state)
        Movement.turnRight(state)
        return ok, data
    end
    error("Unsupported inspect direction: " .. tostring(direction))
end

function Movement.faceVector(state, vec)
    local facing = Orientation.facingForVector(vec)
    if facing == nil then
        return false, "vector not cardinal"
    end
    return Movement.face(state, facing), nil
end

function Movement.clear(direction)
    clearDirection(direction)
end

function Movement.project(state, direction)
    local delta = Orientation.vectorForRelative(state.facing, direction)
    return applyDelta(state.position, delta)
end

function Movement.clearRelative(state, direction)
    if direction == "forward" or direction == "up" or direction == "down" then
        clearDirection(direction)
        return true
    elseif direction == "left" then
        if not Movement.turnLeft(state) then
            return false
        end
        clearDirection("forward")
        Movement.turnRight(state)
        return true
    elseif direction == "right" then
        if not Movement.turnRight(state) then
            return false
        end
        clearDirection("forward")
        Movement.turnLeft(state)
        return true
    elseif direction == "back" then
        if not Movement.turnRight(state) then
            return false
        end
        if not Movement.turnRight(state) then
            Movement.turnLeft(state)
            return false
        end
        clearDirection("forward")
        Movement.turnRight(state)
        Movement.turnRight(state)
        return true
    end
    error("Unsupported clear direction: " .. tostring(direction))
end

local Navigator = {}

local function moveAxis(state, cfg, axis, target)
    local delta = target - state.position[axis]
    if delta == 0 then
        return true
    end
    local step = delta > 0 and 1 or -1
    local facing
    if axis == "x" then
        facing = (step > 0) and 0 or 2
    elseif axis == "z" then
        facing = (step > 0) and 1 or 3
    else
        error("Unsupported axis: " .. tostring(axis))
    end
    if not Movement.face(state, facing) then
        return false
    end
    while state.position[axis] ~= target do
        if not Movement.forward(state, cfg) then
            return false
        end
    end
    return true
end

local function moveVertical(state, cfg, targetY)
    while state.position.y < targetY do
        if not Movement.up(state, cfg) then
            return false
        end
    end
    while state.position.y > targetY do
        if not Movement.down(state, cfg) then
            return false
        end
    end
    return true
end

function Navigator.moveTo(state, cfg, target)
    if not moveVertical(state, cfg, target.y or state.position.y) then
        return false
    end
    if not moveAxis(state, cfg, "x", target.x or state.position.x) then
        return false
    end
    if not moveAxis(state, cfg, "z", target.z or state.position.z) then
        return false
    end
    return true
end

function Navigator.returnToSpawn(state, cfg)
    local target = {
        x = cfg.spawn.column.x,
        y = cfg.spawn.topY,
        z = cfg.spawn.column.z,
    }
    return Navigator.moveTo(state, cfg, target)
end

function Navigator.faceInventories(state, cfg)
    local facing = Orientation.facingForVector(cfg.boundingBox.originForward or { x = 0, z = 1 }) or 1
    local inventoryFacing = Orientation.opposite(facing)
    return Movement.face(state, inventoryFacing)
end

local function isOreBlock(block)
    if not block or not block.name then
        return false
    end
    if block.tags then
        for tag, present in pairs(block.tags) do
            if present and tag:find("ore") then
                return true
            end
        end
    end
    return block.name:find("ore") ~= nil
end

local function oreKey(pos, blockName)
    return ("%d:%d:%d:%s"):format(pos.x, pos.y, pos.z, blockName or "?")
end

local function queueOreJob(ctx, orePos, blockName, direction)
    local key = oreKey(orePos, blockName)
    ctx.state.oreBookmarks = ctx.state.oreBookmarks or {}
    if ctx.state.oreBookmarks[key] then
        return
    end
    local jobDetails = {
        target = clonePosition(orePos),
        block = blockName,
        approach = clonePosition(ctx.state.position),
        approachFacing = ctx.state.facing,
        entryDirection = direction,
        oreKey = key,
        maxNodes = ctx.cfg.job and ctx.cfg.job.maxOreNodes or 128,
    }
    local record = ctx.enqueue({
        type = "ore",
        priority = 2,
        details = jobDetails,
    })
    ctx.state.oreBookmarks[key] = record.id
    TurtleState.save(ctx.state)
    Log.write("info", "Queued ore job", {
        job = record.id,
        pos = key,
        block = blockName,
    })
end

local ORE_SCAN_DIRECTIONS = { "left", "right", "up", "down" }

local function scanForSideOres(ctx)
    for _, direction in ipairs(ORE_SCAN_DIRECTIONS) do
        local ok, block = Movement.inspect(ctx.state, direction)
        if ok and block and isOreBlock(block) then
            local orePos = Movement.project(ctx.state, direction)
            if withinBoundingBox(orePos, ctx.cfg) then
                queueOreJob(ctx, orePos, block.name, direction)
            else
                Log.write("debug", "Ore detected outside bounding box, skipping", {
                    dir = direction,
                    block = block.name,
                })
            end
        end
    end
end

local FLOOD_DIRECTIONS = { "forward", "back", "left", "right", "up", "down" }
local OPPOSITE_DIRECTION = {
    forward = "back",
    back = "forward",
    left = "right",
    right = "left",
    up = "down",
    down = "up",
}

local function refuelFromSpawn(state, cfg, targetLevel)
    local function currentFuel()
        local level = turtle.getFuelLevel()
        if level == "unlimited" then
            return math.huge
        end
        return level
    end
    if currentFuel() >= targetLevel then
        return true
    end
    if not Navigator.returnToSpawn(state, cfg) then
        return false, "navigation_failed"
    end
    if not Navigator.faceInventories(state, cfg) then
        return false, "inventory_orientation_failed"
    end
    local attempts = 0
    repeat
        attempts = attempts + 1
        local sucked, err = turtle.suck(64) -- DOCS.turtle suck pulls items from inventory in front
        if not sucked and err and err ~= "No items to take" then
            Log.write("warn", "Fuel chest interaction failed", { err = tostring(err) })
            break
        end
        for slot = 1, 16 do
            turtle.select(slot)
            if turtle.getItemCount(slot) > 0 then
                local probe = turtle.refuel(0)
                if probe then
                    local consumed = turtle.refuel()
                    if not consumed then
                        turtle.drop() -- Drop non-fuel items back into the inventory (DOCS.turtle drop)
                    end
                else
                    turtle.drop()
                end
            end
        end
        sleep(0.1)
    until currentFuel() >= targetLevel or attempts >= 6
    turtle.select(1)
    local finalLevel = currentFuel()
    if finalLevel >= targetLevel then
        Log.write("info", "Refuelled from spawn inventory", { level = finalLevel })
        return true
    end
    return false, "insufficient_fuel"
end

local function ensureFuelForJob(state, cfg, minimum)
    minimum = minimum or cfg.fuel.reserve
    local level = turtle.getFuelLevel()
    if level == "unlimited" or level >= minimum then
        return true
    end
    local ok = ensureFuelReserve(cfg)
    if ok and turtle.getFuelLevel() >= minimum then
        return true
    end
    local success = refuelFromSpawn(state, cfg, minimum)
    return success
end

local function carveTunnelStep(ctx)
    Movement.clearRelative(ctx.state, "up")
    if not Movement.forward(ctx.state, ctx.cfg) then
        return false, "forward_blocked"
    end
    Movement.clearRelative(ctx.state, "up")
    scanForSideOres(ctx)
    return true
end

local function runTunnelJob(ctx)
    local details = ctx.job.details or {}
    local start = details.start or ctx.state.position
    local target = {
        x = start.x,
        y = details.layerY or start.y or ctx.state.position.y,
        z = start.z,
    }
    if not Navigator.moveTo(ctx.state, ctx.cfg, target) then
        return false, "navigation_failed"
    end
    local direction = details.direction or ctx.cfg.boundingBox.originForward or { x = 0, z = 1 }
    local faced = select(1, Movement.faceVector(ctx.state, direction))
    if not faced then
        return false, "direction_invalid"
    end
    local length = details.length or ctx.cfg.layers.spacing or 2
    for step = 1, length do
        if not ensureFuelForJob(ctx.state, ctx.cfg, ctx.cfg.fuel.reserve * 2) then
            return false, "fuel_depleted"
        end
        local ok, reason = carveTunnelStep(ctx)
        if not ok then
            return false, reason
        end
    end
    return true, length
end

local function floodFillOre(ctx)
    local details = ctx.job.details or {}
    local approach = details.approach or ctx.state.position
    if not Navigator.moveTo(ctx.state, ctx.cfg, approach) then
        return false, "navigation_failed"
    end
    if details.approachFacing then
        if not Movement.face(ctx.state, details.approachFacing) then
            return false, "approach_facing_failed"
        end
    end
    local targetBlock = details.block
    if not targetBlock then
        return false, "missing_target_block"
    end
    if not ensureFuelForJob(ctx.state, ctx.cfg, ctx.cfg.fuel.reserve * 3) then
        return false, "fuel_depleted"
    end
    local maxNodes = details.maxNodes or (ctx.cfg.job and ctx.cfg.job.maxOreNodes) or 96
    local mined = 0
    local visited = {}

    local function explore(direction)
        if mined >= maxNodes then
            return
        end
        local targetPos = Movement.project(ctx.state, direction)
        if not withinBoundingBox(targetPos, ctx.cfg) then
            return
        end
        local key = oreKey(targetPos, targetBlock)
        if visited[key] then
            return
        end
        local ok, data = Movement.inspect(ctx.state, direction)
        if not ok or not data or data.name ~= targetBlock then
            return
        end
        if not Movement.clearRelative(ctx.state, direction) then
            return
        end
        if not Movement.step(ctx.state, ctx.cfg, direction) then
            return
        end
        visited[key] = true
        mined = mined + 1
        for _, nextDir in ipairs(FLOOD_DIRECTIONS) do
            explore(nextDir)
        end
        local backDir = OPPOSITE_DIRECTION[direction]
        if backDir then
            if not Movement.step(ctx.state, ctx.cfg, backDir) then
                Log.write("warn", "Failed to retreat during ore flood", { dir = direction })
            end
        end
    end

    explore(details.entryDirection or "forward")
    if details.oreKey and ctx.state.oreBookmarks then
        ctx.state.oreBookmarks[details.oreKey] = nil
    end
    return mined > 0, mined
end

local function registerJobExecutors()
    Scheduler.register("diagnostic", function(ctx)
        Log.write("info", "Diagnostic job executed", { requester = ctx.job.details and ctx.job.details.requestedBy })
        return { success = true, notes = "diagnostic_complete" }
    end)

    Scheduler.register("fuel", function(ctx)
        local details = ctx.job.details or {}
        local target = details.targetLevel or (ctx.cfg.fuel.reserve * 2)
        if turtle.getFuelLevel() >= target then
            return { success = true, fuel = turtle.getFuelLevel(), notes = "already_full" }
        end
        local ok, reason = refuelFromSpawn(ctx.state, ctx.cfg, target)
        if not ok then
            return { success = false, error = reason or "refuel_failed", fuel = turtle.getFuelLevel() }
        end
        return { success = true, fuel = turtle.getFuelLevel() }
    end)

    Scheduler.register("tunnel", function(ctx)
        local ok, result = runTunnelJob(ctx)
        if not ok then
            return { success = false, error = result }
        end
        return { success = true, length = result }
    end)

    Scheduler.register("ore", function(ctx)
        local ok, mined = floodFillOre(ctx)
        if not ok then
            return { success = false, error = mined }
        end
        return { success = true, mined = mined }
    end)
end

registerJobExecutors()

local function cliMenu()
    print("\n=== AutoMine Menu ===")
    print("1) Status")
    print("2) Toggle file logging")
    print("3) Broadcast recall")
    print("4) Enqueue test job")
    print("5) Exit")
    term.write("Select option: ")
    return tonumber(read())
end

local function printStatus(state, cfg)
    print("--- STATUS ---")
    print("Quarry: " .. state.quarryId)
    print("Turtle: " .. state.turtleId)
    print("Config version: " .. tostring(cfg.version))
    print("Calibrated: " .. tostring(state.calibrated))
    print("Position: x=" .. state.position.x .. " y=" .. state.position.y .. " z=" .. state.position.z)
    print("Fuel: " .. tostring(turtle.getFuelLevel()))
end

local function toggleFileLogging(cfg, quarryId)
    cfg.logging.fileEnabled = not cfg.logging.fileEnabled
    writeJson(configPath(quarryId), cfg)
    Log.configure({
        fileEnabled = cfg.logging.fileEnabled,
        logPath = ("%s/%s.log"):format(LOG_ROOT, quarryId),
        consoleVerbosity = cfg.logging.consoleVerbosity or "info",
    })
    Log.write("info", "File logging toggled", { enabled = tostring(cfg.logging.fileEnabled) })
end

local function broadcastRecall()
    Network.broadcast("recall", { reason = "manual" })
end

local function enqueueTestJob(quarryId)
    local job = {
        type = "diagnostic",
        priority = 2,
        details = { requestedBy = turtleId() },
    }
    Jobs.enqueue(quarryId, job)
end

local function schedulerTick(quarryId, state, cfg)
    local queue = Jobs.loadQueue(quarryId)
    local nextJob = Scheduler.nextJob(queue, state)
    if not nextJob then
        Log.write("debug", "No jobs available")
        return
    end
    Scheduler.claimJob(quarryId, nextJob, state)
    Log.write("info", "Claimed job", { id = nextJob.id, type = nextJob.job.type })
    TurtleState.save(state)
    local success, outcome = Scheduler.execute(quarryId, nextJob, state, cfg)
    if success then
        outcome.quarryId = quarryId
        Scheduler.completeJob(quarryId, nextJob, outcome)
    else
        Scheduler.failJob(quarryId, nextJob, outcome.error or "unknown", cfg)
    end
    TurtleState.save(state)
end

local function main()
    print("AutoMine v" .. VERSION)
    print("Docs verified: turtle(" .. DOCS.turtle .. "), rednet(" .. DOCS.rednet .. ")")
    local qId = prompt("Enter quarry ID", "default")
    local cfg = loadOrInitConfig(qId)
    Log.configure({
        fileEnabled = cfg.logging.fileEnabled,
        logPath = ("%s/%s.log"):format(LOG_ROOT, qId),
        consoleVerbosity = cfg.logging.consoleVerbosity or "info",
    })
    Network.init(qId)
    local state = TurtleState.load(qId, turtleId())
    if not state.calibrated then
        calibrateVertical(state, cfg)
        TurtleState.save(state)
    end
    ensureFuelReserve(cfg)

    while true do
        schedulerTick(qId, state, cfg)
        local choice = cliMenu()
        if choice == 1 then
            printStatus(state, cfg)
        elseif choice == 2 then
            toggleFileLogging(cfg, qId)
        elseif choice == 3 then
            broadcastRecall()
        elseif choice == 4 then
            enqueueTestJob(qId)
        elseif choice == 5 then
            Log.write("info", "Exiting per user request", {})
            break
        else
            print("Invalid choice")
        end
        TurtleState.save(state)
    end
end

local ok, err = pcall(main)
if not ok then
    Log.write("error", "Fatal error", { err = tostring(err) })
    error(err)
end
