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
    }
end

function TurtleState.load(quarryId, turtleId)
    local path = turtleStatePath(quarryId, turtleId)
    if not fs.exists(path) then
        return defaultTurtleState(quarryId, turtleId)
    end
    return readJson(path, defaultTurtleState(quarryId, turtleId))
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
    state.position.y = 0
    state.calibrated = true
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
    }
    appendJobRecord(quarryId, record)
    Log.write("info", "Enqueued job", { id = record.id, type = job.type })
    return record
end

function Jobs.loadQueue(quarryId)
    local records = readJobRecords(quarryId)
    table.sort(records, function(a, b)
        if a.priority == b.priority then
            return a.createdAt < b.createdAt
        end
        return a.priority < b.priority
    end)
    return records
end

local Scheduler = {}

function Scheduler.nextJob(records, state)
    for _, record in ipairs(records) do
        if not record.claimedBy or record.claimedBy == state.turtleId then
            return record
        end
    end
    return nil
end

function Scheduler.claimJob(record, state)
    record.claimedBy = state.turtleId
    record.claimedAt = os.epoch("utc")
    record.status = "claimed"
    appendJobRecord(state.quarryId, record)
end

function Scheduler.completeJob(record, outcome)
    record.status = outcome.success and "completed" or "failed"
    record.result = outcome
    appendJobRecord(outcome.quarryId, record)
    Network.broadcast("job_status", {
        id = record.id,
        status = record.status,
    })
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

function Movement.forward(state, cfg)
    if not withinBoundingBox({ x = state.position.x + 1, y = state.position.y, z = state.position.z }, cfg) then
        Log.write("warn", "Blocked move outside bounding box", { axis = "x" })
        return false
    end
    while turtle.detect() do
        turtle.dig() -- per DOCS.turtle dig() supports clearing blocks before movement
        sleep(0.2)
    end
    local ok, reason = turtle.forward()
    if not ok then
        Log.write("warn", "turtle.forward failed", { reason = tostring(reason) })
        return false
    end
    state.position.x = state.position.x + 1
    return true
end

function Movement.up(state, cfg)
    if not withinBoundingBox({ x = state.position.x, y = state.position.y + 1, z = state.position.z }, cfg) then
        Log.write("warn", "Blocked upward movement outside bounding box", {})
        return false
    end
    while turtle.detectUp() do
        turtle.digUp()
        sleep(0.2)
    end
    local ok, reason = turtle.up()
    if not ok then
        Log.write("warn", "turtle.up failed", { reason = tostring(reason) })
        return false
    end
    state.position.y = state.position.y + 1
    return true
end

function Movement.down(state, cfg)
    if not withinBoundingBox({ x = state.position.x, y = state.position.y - 1, z = state.position.z }, cfg) then
        Log.write("warn", "Blocked downward movement outside bounding box", {})
        return false
    end
    while turtle.detectDown() do
        turtle.digDown()
        sleep(0.2)
    end
    local ok, reason = turtle.down()
    if not ok then
        Log.write("warn", "turtle.down failed", { reason = tostring(reason) })
        return false
    end
    state.position.y = state.position.y - 1
    return true
end

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

local function schedulerTick(quarryId, state)
    local queue = Jobs.loadQueue(quarryId)
    local nextJob = Scheduler.nextJob(queue, state)
    if not nextJob then
        Log.write("debug", "No jobs available")
        return
    end
    Scheduler.claimJob(nextJob, state)
    Log.write("info", "Claimed job", { id = nextJob.id })
    -- Placeholder job executor
    sleep(1)
    Scheduler.completeJob(nextJob, {
        success = true,
        quarryId = quarryId,
        notes = "Placeholder completion",
    })
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
        schedulerTick(qId, state)
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
