--!strict
-- Fires pooled projectiles: parts are reused instead of created and destroyed.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Pool = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Constella"):WaitForChild("Pool"))

local template = Instance.new("Part")
template.Name = "PooledBullet"
template.Size = Vector3.new(0.5, 0.5, 2)
template.Anchored = true
template.CanCollide = false
template.Color = Color3.fromRGB(255, 200, 60)

local bullets = Pool.instances(template, {
	MaxIdle = 16, -- keep at most 16 spare bullets
	MaxActive = 32, -- never more than 32 in flight
	Prewarm = 8,
})

local function fire(origin: Vector3, direction: Vector3)
	local bullet = bullets:TryAcquire()
	if bullet == nil then
		return -- pool exhausted: skip instead of creating unbounded parts
	end
	bullet.CFrame = CFrame.lookAt(origin, origin + direction)
	bullet.Parent = workspace
	task.delay(0.5, function()
		bullets:Release(bullet) -- unparented and kept for reuse
	end)
end

for index = 1, 40 do
	fire(Vector3.new(0, 5, 0), Vector3.new(math.cos(index), 0, math.sin(index)))
	task.wait(0.05)
end

task.wait(1)
local stats = bullets:GetStats()
print(("[Pool] created %d, reused %d, idle %d, active %d"):format(stats.Created, stats.Reused, stats.Idle, stats.Active))
bullets:Destroy()
template:Destroy()
