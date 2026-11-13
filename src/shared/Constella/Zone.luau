--!strict
--[=[
	Constella.Zone

	Enter/exit detection for players, parts, models or anything with a
	position, inside a box or sphere.

	How it works
	- Tracked items are point-tested against the zone every `Interval`
	  seconds (default 0.1) on Heartbeat, or whenever you call `Step()`.
	- A quick bounding-sphere distance check rejects far-away items before
	  the exact box test, so idle zones cost very little.
	- `ExitPadding` adds hysteresis: an item inside only exits once it is
	  more than ExitPadding studs outside, which stops flickering at edges.
	- Events fire after every item has been evaluated, in tracking order,
	  so handlers may freely Track/Untrack.
	- A zone made from a BasePart follows the part as it moves, and is
	  destroyed when the part is destroyed. Ball-shaped Parts are spheres;
	  every other part is treated as its bounding box.

	Item positions
	- Player   -> character HumanoidRootPart (outside when there is none)
	- BasePart -> Position;  Model -> GetPivot();  Attachment -> WorldPosition
	- anything else -> pass `getPosition` to Track
]=]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Signal)
local Cleanup = require(script.Parent.Cleanup)

export type BoxShape = { CFrame: CFrame, Size: Vector3 }
export type SphereShape = { Position: Vector3, Radius: number }
export type Shape = BasePart | BoxShape | SphereShape

export type Options = {
	--- Seconds between automatic updates. Defaults to 0.1.
	Interval: number?,
	--- Extra distance (studs) an item must travel past the edge to exit.
	ExitPadding: number?,
	--- Set false to only update when you call Step(). Defaults to true.
	AutoUpdate: boolean?,
	--- Receives errors from position callbacks. Defaults to re-raising on a new thread.
	OnError: ((message: string) -> ())?,
}

export type Zone = {
	Entered: Signal.Signal<any>,
	Exited: Signal.Signal<any>,
	Track: (self: any, item: any, getPosition: (() -> Vector3?)?) -> (),
	Untrack: (self: any, item: any) -> (),
	TrackPlayers: (self: any) -> (),
	Contains: (self: any, position: Vector3, padding: number?) -> boolean,
	IsInside: (self: any, item: any) -> boolean,
	GetInside: (self: any) -> { any },
	Step: (self: any) -> (),
	Destroy: (self: any) -> (),
}

local PREFIX = "[Constella.Zone] "
local DEFAULT_INTERVAL = 0.1

local function isFiniteNonNegative(value: any): boolean
	return type(value) == "number" and value == value and value >= 0 and value ~= math.huge
end

local function defaultPositionGetter(item: any): (() -> Vector3?)?
	if typeof(item) ~= "Instance" then
		return nil
	end
	if item:IsA("Player") then
		return function()
			local character = item.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			return if root and root:IsA("BasePart") then root.Position else nil
		end
	elseif item:IsA("BasePart") then
		return function()
			return item.Position
		end
	elseif item:IsA("Model") then
		return function()
			return item:GetPivot().Position
		end
	elseif item:IsA("Attachment") then
		return function()
			return item.WorldPosition
		end
	end
	return nil
end

-- Returns a function that reads the current geometry:
--   ("box", cframe, halfSize) or ("sphere", center, radius)
local function resolveShape(shape: any, level: number): () -> (string, any, any)
	if typeof(shape) == "Instance" then
		if not shape:IsA("BasePart") then
			error(PREFIX .. ("Zone shape must be a BasePart, box or sphere, got %s"):format(shape.ClassName), level)
		end
		local isBall = shape:IsA("Part") and (shape :: Part).Shape == Enum.PartType.Ball
		return function()
			if isBall then
				local size = shape.Size
				return "sphere", shape.Position, math.min(size.X, size.Y, size.Z) / 2
			end
			return "box", shape.CFrame, shape.Size / 2
		end
	end
	if type(shape) == "table" then
		if typeof(shape.CFrame) == "CFrame" and typeof(shape.Size) == "Vector3" then
			local cframe, half = shape.CFrame, shape.Size / 2
			return function()
				return "box", cframe, half
			end
		end
		if typeof(shape.Position) == "Vector3" and isFiniteNonNegative(shape.Radius) then
			local center, radius = shape.Position, shape.Radius
			return function()
				return "sphere", center, radius
			end
		end
	end
	error(PREFIX .. "Zone shape must be a BasePart, { CFrame, Size } or { Position, Radius }", level)
end

local function contains(kind: string, a: any, b: any, position: Vector3, padding: number): boolean
	if kind == "sphere" then
		return (position - a).Magnitude <= b + padding
	end
	local cframe: CFrame, half: Vector3 = a, b
	-- Cheap rejection: outside the box's bounding sphere.
	local reach = half.Magnitude + padding * 1.7320508
	if (position - cframe.Position).Magnitude > reach then
		return false
	end
	local localPosition = cframe:PointToObjectSpace(position)
	return math.abs(localPosition.X) <= half.X + padding
		and math.abs(localPosition.Y) <= half.Y + padding
		and math.abs(localPosition.Z) <= half.Z + padding
end

local ZoneClass = {}
ZoneClass.__index = ZoneClass

function ZoneClass.Contains(self: any, position: Vector3, padding: number?): boolean
	if typeof(position) ~= "Vector3" then
		error(PREFIX .. ("Contains expects a Vector3, got %s"):format(typeof(position)), 2)
	end
	local kind, a, b = self._geometry()
	return contains(kind, a, b, position, padding or 0)
end

function ZoneClass.Track(self: any, item: any, getPosition: (() -> Vector3?)?)
	if self._destroyed then
		error(PREFIX .. "Cannot track items on a destroyed Zone", 2)
	end
	if item == nil then
		error(PREFIX .. "Cannot track nil", 2)
	end
	if self._entries[item] then
		return
	end
	local getter = getPosition or defaultPositionGetter(item)
	if type(getter) ~= "function" then
		error(PREFIX .. ("Cannot get a position from %s; pass getPosition"):format(typeof(item)), 2)
	end
	local entry = { item = item, getPosition = getter, inside = false }
	self._entries[item] = entry
	table.insert(self._order, entry)
	if typeof(item) == "Instance" and not item:IsA("Player") then
		self._cleanup:Set(
			entry,
			item.Destroying:Connect(function()
				self:Untrack(item)
			end)
		)
	end
end

function ZoneClass.Untrack(self: any, item: any)
	local entry = self._entries[item]
	if entry == nil then
		return
	end
	self._entries[item] = nil
	local index = table.find(self._order, entry)
	if index then
		table.remove(self._order, index)
	end
	self._cleanup:Remove(entry)
	if entry.inside and not self._destroyed then
		entry.inside = false
		self.Exited:Fire(item)
	end
end

--- Tracks every current and future player until they leave.
function ZoneClass.TrackPlayers(self: any)
	if self._trackingPlayers then
		return
	end
	self._trackingPlayers = true
	for _, player in Players:GetPlayers() do
		self:Track(player)
	end
	self._cleanup:Connect(Players.PlayerAdded, function(player: Player)
		self:Track(player)
	end)
	self._cleanup:Connect(Players.PlayerRemoving, function(player: Player)
		self:Untrack(player)
	end)
end

function ZoneClass.IsInside(self: any, item: any): boolean
	local entry = self._entries[item]
	return entry ~= nil and entry.inside
end

function ZoneClass.GetInside(self: any): { any }
	local inside = {}
	for _, entry in self._order do
		if entry.inside then
			table.insert(inside, entry.item)
		end
	end
	return inside
end

--- Evaluates every tracked item now and fires Entered/Exited.
function ZoneClass.Step(self: any)
	if self._destroyed then
		return
	end
	local kind, a, b = self._geometry()
	local padding = self._exitPadding
	local changes = {}
	local order: { any } = table.clone(self._order)
	for _, entry in order do
		local ok, position = pcall(entry.getPosition)
		if not ok then
			self._onError(
				PREFIX .. ("Position callback failed for %s: %s"):format(tostring(entry.item), tostring(position))
			)
			position = nil
		end
		local inside = false
		if typeof(position) == "Vector3" then
			inside = contains(kind, a, b, position, if entry.inside then padding else 0)
		end
		if inside ~= entry.inside then
			entry.inside = inside
			table.insert(changes, entry)
		end
	end
	for _, entry in changes do
		-- Skip items untracked by an earlier handler in this same step.
		if self._entries[entry.item] == entry and entry.inside then
			self.Entered:Fire(entry.item)
		elseif self._entries[entry.item] == entry then
			self.Exited:Fire(entry.item)
		end
	end
end

--- Stops updates and disconnects everything. Exited is NOT fired for items
--- that were inside.
function ZoneClass.Destroy(self: any)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self._cleanup:Destroy()
	table.clear(self._entries)
	table.clear(self._order)
	self.Entered:Destroy()
	self.Exited:Destroy()
end

local Zone = {}

function Zone.new(shape: Shape, options: Options?): Zone
	local geometry = resolveShape(shape, 3)
	local opts: Options = options or {}
	if type(opts) ~= "table" then
		error(PREFIX .. "Options must be a table", 2)
	end
	local interval = opts.Interval or DEFAULT_INTERVAL
	if not isFiniteNonNegative(interval) then
		error(PREFIX .. "Interval must be a non-negative number of seconds", 2)
	end
	local exitPadding = opts.ExitPadding or 0
	if not isFiniteNonNegative(exitPadding) then
		error(PREFIX .. "ExitPadding must be a non-negative number of studs", 2)
	end
	if opts.OnError ~= nil and type(opts.OnError) ~= "function" then
		error(PREFIX .. "OnError must be a function", 2)
	end

	local self = setmetatable({
		Entered = Signal.new(),
		Exited = Signal.new(),
		_geometry = geometry,
		_exitPadding = exitPadding,
		_entries = {},
		_order = {},
		_cleanup = Cleanup.new(),
		_destroyed = false,
		_trackingPlayers = false,
		_onError = opts.OnError or function(message: string)
			task.spawn(error, message, 0)
		end,
	}, ZoneClass)

	if typeof(shape) == "Instance" then
		self._cleanup:Connect((shape :: Instance).Destroying, function()
			self:Destroy()
		end)
	end

	if opts.AutoUpdate ~= false then
		local elapsed = 0
		self._cleanup:Connect(RunService.Heartbeat, function(deltaTime: number)
			elapsed += deltaTime
			if elapsed >= interval then
				elapsed = 0
				self:Step()
			end
		end)
	end

	return (self :: any) :: Zone
end

return table.freeze(Zone)
