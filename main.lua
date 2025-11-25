--[[
AutoMine – fault-tolerant collaborative strip mining controller for CC: Tweaked turtles.

This script fulfils the design documented in project_design.md by providing:
	• Local-space coordinate tracking rooted at boot origin.
	• ACID-verify persistence for movements, mining, mutex claims, and deposits.
	• Multi-turtle master election plus mutex-protected tunnel allocation.
	• Bounding-box-aware 2×1 strip tunnelling with 2-block spacing across columns/layers.
	• Fuel/inventory autonomy, deposit cycles, and return-to-stack behaviour.

The code is intentionally single-file for turtle deployment while remaining modular via
local tables.
]]

local VERSION = "0.1.0"

-- Expose CC: Tweaked globals to satisfy static analyzers while keeping runtime references intact.
local fs = assert(rawget(_G, "fs"), "fs API unavailable")
local turtle = assert(rawget(_G, "turtle"), "turtle API unavailable")
local rednet = assert(rawget(_G, "rednet"), "rednet API unavailable")
local peripheral = assert(rawget(_G, "peripheral"), "peripheral API unavailable")
local textutils = assert(rawget(_G, "textutils"), "textutils API unavailable")
local osSleep = rawget(os, "sleep")
local sleepFn = rawget(_G, "sleep") or osSleep or function() end

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
	local line = string.format("[%s][%s] %s", os.date("!*t"), level, msg)
	print(line)
	with_handle(self.path, "a", function(h)
		h.writeLine(line)
	end)
end

---------------------------------------------------------------------
-- Configuration management
---------------------------------------------------------------------

local DEFAULT_CONFIG = {
	statePath = "automine_state.json",
	journalPath = "automine_acid.json",
	logPath = "automine.log",
	boundingBox = { x = 32, y = 15, z = 96 },
	tunnelSpacing = 3, -- 1 block width + 2 gap
	layerSpacing = 3,
	chunkLength = 16,
	protocol = "auto_mine/v1",
	heartbeatInterval = 2.0,
	heartbeatTimeout = 6.0,
	fuelReserve = 800,
	targetFuel = 4000,
	keepFuelItems = 16,
	depositKeepCoal = 16,
	restOffset = { x = -1, y = 0, z = -1 },
	depositOffset = { x = 0, y = 0, z = -1 },
	jobRetryInterval = 5.0,
	maxJobFailures = 5,
	allowedFuel = {
		["minecraft:coal"] = true,
		["minecraft:charcoal"] = true,
		["minecraft:coal_block"] = true,
		["minecraft:lava_bucket"] = true
	},
}

local Config = {}
Config.__index = Config

function Config.load(path)
	path = path or "automine_config.json"
	local cfg
	if fs.exists(path) then
		cfg = with_handle(path, "r", function(h)
			local raw = h.readAll()
			if not raw or raw == "" then return {} end
			local decoded, err = textutils.unserializeJSON(raw)
			if not decoded then
				error("invalid JSON in config: " .. tostring(err))
			end
			return decoded
		end)
	else
		cfg = {}
		with_handle(path, "w", function(h)
			h.write(textutils.serializeJSON(DEFAULT_CONFIG, { allow_repetitions = true }))
		end)
	end
	merge(cfg, DEFAULT_CONFIG)
	cfg.path = path
	return setmetatable(cfg, Config)
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
			pose = { x = 0, y = 0, z = 0, dir = 0 },
			masterId = nil,
			turtles = {},
			tunnels = {},
			locks = {},
			metrics = { mined = 0 },
			journal = { nextId = 1, pending = {}, completed = {} },
			activeJob = nil,
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
		with_handle(self.path, "w", function(h) h.write(textutils.serializeJSON({ pending = {} })) end)
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
		if verifier then
			local ok = verifier(entry.payload)
			if ok then
				resolved[#resolved + 1] = id
			end
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

function Pose:move(delta)
	local pose = self.state.pose
	pose.x = pose.x + (delta.x or 0)
	pose.y = pose.y + (delta.y or 0)
	pose.z = pose.z + (delta.z or 0)
end

function Pose:setDir(dir)
	self.state.pose.dir = ((dir % 4) + 4) % 4
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

function Pose:face(target)
	local dir = self.state.pose.dir
	local turn
	if target == "forward" then
		turn = 0
	elseif target == "right" then
		turn = 1
	elseif target == "back" then
		turn = 2
	elseif target == "left" then
		turn = 3
	else
		error("invalid target dir " .. tostring(target))
	end
	local delta = (turn - dir) % 4
	if delta == 1 then
		self:turnRight()
	elseif delta == 2 then
		self:turnAround()
	elseif delta == 3 then
		self:turnLeft()
	end
end

---------------------------------------------------------------------
-- Fuel manager
---------------------------------------------------------------------

local Fuel = {}
Fuel.__index = Fuel

function Fuel.new(config, store)
	return setmetatable({ config = config, store = store }, Fuel)
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

function Fuel:refuel()
	if self:isUnlimited() then return true end
	for slot = 1, 16 do
		local detail = turtle.getItemDetail(slot)
		if self:isFuelItem(detail) then
			turtle.select(slot)
			local ok = turtle.refuel(1)
			if ok then
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

local function clearBlock(fnDetect, fnDig, fnAttack)
	local tries = 0
	while tries < 10 do
		if not fnDetect() then return true end
		fnDig()
		fnAttack()
		tries = tries + 1
		sleepFn(0.1)
	end
	return not fnDetect()
end

---------------------------------------------------------------------
-- Movement wrapper with ACID tracking
---------------------------------------------------------------------

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
	while true do
		local success, reason = turtle.forward()
		if success then
			self.pose:update(target)
			self.store:save()
			return true
		end
		if reason and reason:match("obstruct") then
			clearBlock(turtle.detect, turtle.dig, turtle.attack)
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
		if direction == "up" then
			clearBlock(turtle.detectUp, turtle.digUp, turtle.attackUp)
		else
			clearBlock(turtle.detectDown, turtle.digDown, turtle.attackDown)
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
	local payload = { origin = pose, target = target, axis = "forward" }
	local ok, err = self.acid:run("move_forward", payload, function()
		return self:_applyForward(target)
	end)
	return ok, err
end

function Movement:up()
	local target = deepcopy(self.pose:get())
	target.y = target.y + 1
	local payload = { origin = deepcopy(self.pose:get()), target = target, axis = "up" }
	return self.acid:run("move_up", payload, function()
		return self:_applyUp(target)
	end)
end

function Movement:down()
	local target = deepcopy(self.pose:get())
	target.y = target.y - 1
	local payload = { origin = deepcopy(self.pose:get()), target = target, axis = "down" }
	return self.acid:run("move_down", payload, function()
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
		local dir = (axis == "x") and (delta > 0 and "right" or "left") or (delta > 0 and "forward" or "back")
		self.pose:face(dir)
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
	local pose = self.pose:get()
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

function Navigator:faceForward()
	self.pose:face("forward")
end

---------------------------------------------------------------------
-- Tunnel planner and mutex model
---------------------------------------------------------------------

local TunnelPlanner = {}
TunnelPlanner.__index = TunnelPlanner

function TunnelPlanner.new(config, store)
	local planner = setmetatable({ config = config, store = store }, TunnelPlanner)
	planner:ensureTunnels()
	return planner
end

function TunnelPlanner:ensureTunnels()
	if self.store.data.tunnels and next(self.store.data.tunnels) then
		return
	end
	local tunnels = {}
	local id = 1
	for layer = 0, self.config.boundingBox.y, self.config.layerSpacing do
		if layer + 1 > self.config.boundingBox.y then break end
		for column = 0, self.config.boundingBox.x, self.config.tunnelSpacing do
			if column <= self.config.boundingBox.x then
				local tunnelId = string.format("T%03d", id)
				tunnels[tunnelId] = {
					id = tunnelId,
					origin = { x = column, y = layer, z = 0 },
					state = "idle",
					assignedTo = nil,
					progress = 0,
					length = self.config.boundingBox.z,
					updated = now(),
				}
				id = id + 1
			end
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
			tunnel.updated = now()
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
	tunnel.updated = now()
	self.store:save()
end

---------------------------------------------------------------------
-- Network and leader election
---------------------------------------------------------------------

local Network = {}
Network.__index = Network

function Network.new(config, logger)
	local self = setmetatable({ protocol = config.protocol, logger = logger, seq = 0 }, Network)
	local opened = false
	peripheral.find("modem", function(name)
		if not rednet.isOpen(name) then
			rednet.open(name)
		end
		opened = true
		return false
	end)
	if not opened then
		error("AutoMine requires at least one modem for rednet")
	end
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
		self.logger:write("INFO", "New master elected", masterId)
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
		self.network:send({ type = "heartbeat", status = jobStatus.state, job = jobStatus.job, fuel = jobStatus.fuel })
	end
end

---------------------------------------------------------------------
-- Inventory & deposit helpers
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

function Inventory:depositAll()
	self.navigator:goTo({ x = 0, y = 0, z = 0 })
	self.navigator:faceForward()
	self.pose:turnAround()
	local keepBudget = self.config.keepFuelItems or 0
	for slot = 1, 16 do
		local detail = turtle.getItemDetail(slot)
		if detail then
			local retain = 0
			if keepBudget > 0 and self.fuel:isFuelItem(detail) then
				retain = math.min(detail.count, keepBudget)
				keepBudget = keepBudget - retain
			end
			turtle.select(slot)
			local toDrop = detail.count - retain
			if toDrop > 0 then
				turtle.drop(toDrop)
			end
		end
	end
	self.pose:turnAround()
end

function Inventory:returnToStack()
	self.navigator:goTo({ x = 0, y = 0, z = 0 })
	self.navigator:faceForward()
	while true do
		local ok = self.movement.up(self.movement)
		if not ok then
			break
		end
	end
end

---------------------------------------------------------------------
-- Worker logic
---------------------------------------------------------------------


local Worker = {}
Worker.__index = Worker

function Worker.new(config, store, network, planner, pose, movement, navigator, inventory, fuel, logger)
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
		logger = logger,
		lastRequest = 0,
		failures = 0,
	}, Worker)
end

function Worker:activeJob()
	return self.store.data.activeJob
end

function Worker:setJob(job)
	self.store.data.activeJob = job
	self.store:save()
end

function Worker:requestJob()
	if now() - self.lastRequest < self.config.jobRetryInterval then
		return
	end
	self.lastRequest = now()
	if self.store.data.masterId == self.network.id then
		local job = self.planner:claimNext(self.network.id)
		if job then
			self.logger:write("INFO", "Self-assigned tunnel", job.id)
			self:setJob(job)
		end
	else
		self.network:send({ type = "job_request" }, self.store.data.masterId)
	end
end

function Worker:handleMessage(msg)
	if msg.type == "assign" and msg.target == self.network.id then
		self.logger:write("INFO", "Received assignment", msg.job.id)
		self:setJob(msg.job)
	elseif msg.type == "job_release" and self.store.data.masterId == self.network.id then
		self.planner:updateProgress(msg.jobId, msg.progress, msg.state)
	elseif msg.type == "job_request" and self.store.data.masterId == self.network.id then
		local job = self.planner:claimNext(msg.sender)
		if job then
			self.network:send({ type = "assign", target = msg.sender, job = job }, msg.sender)
		end
	end
end

function Worker:ensureAtWorkface(job)
	local target = {
		x = job.origin.x,
		y = job.origin.y,
		z = job.origin.z + job.progress,
	}
	return self.navigator:goTo(target)
end

function Worker:stepJob(job)
	self:ensureAtWorkface(job)
	self.navigator:faceForward()
	self.movement:digForward()
	local ok, err = self.movement:forward()
	if not ok then
		return false, err
	end
	self.movement:digForward()
	job.progress = job.progress + 1
	self.planner:updateProgress(job.id, job.progress, "active")
	self.store:save()
	self.store.data.metrics.mined = self.store.data.metrics.mined + 1
	if job.progress >= job.length then
		job.state = "done"
	end
	return true
end

function Worker:completeJob(job)
	self.logger:write("INFO", "Finished tunnel", job.id)
	self.planner:updateProgress(job.id, job.length, "done")
	self.network:send({ type = "job_release", jobId = job.id, progress = job.length, state = "done" })
	self:setJob(nil)
end

function Worker:tick()
	local job = self:activeJob()
	if not job then
		self:requestJob()
		return { state = "idle", job = nil, fuel = self.fuel:level() }
	end
	if self.inventory:isFull() or self.inventory:stackSpace() < 4 then
		self.inventory:depositAll()
	end
	if not self.fuel:ensure(self.config.fuelReserve) then
		self.logger:write("WARN", "Out of fuel, attempting to refuel at home")
		self.inventory:depositAll()
		if not self.fuel:refuel() then
			return { state = "waiting_fuel", job = job.id, fuel = self.fuel:level() }
		end
	end
	local ok, err = self:stepJob(job)
	if not ok then
		self.failures = self.failures + 1
		self.logger:write("ERROR", "Failed job step", err)
		if self.failures >= self.config.maxJobFailures then
			self:setJob(nil)
		end
	else
		self.failures = 0
		if job.state == "done" then
			self:completeJob(job)
			self.inventory:returnToStack()
		else
			self:setJob(job)
		end
	end
	return { state = job.state or "active", job = job.id, fuel = self.fuel:level() }
end

---------------------------------------------------------------------
-- Message pump
---------------------------------------------------------------------

local function messageLoop(network, leader, worker, logger)
	while true do
		local sender, msg = network:receive(0.1)
		if sender and msg then
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
		sleepFn(0)
	end
end

---------------------------------------------------------------------
-- Main bootstrap
---------------------------------------------------------------------

local function main(...)
	local args = { ... }
	local configPath = args[1]
	local config = Config.load(configPath)
	local store = StateStore.new(config)
	store:load()
	local logger = Logger.new(config.logPath)
	local bbox = BoundingBox.new(config.boundingBox)
	local acid = Acid.new(config, store)

	local pose = Pose.wrap(store.data)
	local fuel = Fuel.new(config, store)
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
	local planner = TunnelPlanner.new(config, store)
	local network = Network.new(config, logger)
	local leader = Leader.new(store, network, config, logger)
	local inventory = Inventory.new(config, navigator, pose, movement, fuel)
	local worker = Worker.new(config, store, network, planner, pose, movement, navigator, inventory, fuel, logger)

	messageLoop(network, leader, worker, logger)
end

main(...)
