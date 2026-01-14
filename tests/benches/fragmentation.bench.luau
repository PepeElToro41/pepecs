local ServerScriptService = game:GetService "ServerScriptService"

local jecs = require(ServerScriptService.ecs.tests.jecs)
local ecs = require(ServerScriptService.ecs.ecs)

if game then
	jecs = require(ServerScriptService.ecs.tests.jecs:Clone()) :: typeof(jecs)
	ecs = require(ServerScriptService.ecs.ecs:Clone()) :: typeof(ecs)
end

local function flip()
	return math.random() >= 0.3
end

local ecs_worlds: { ecs.World } = {}
local jecs_worlds: { jecs.World } = {}

local N = 2 ^ 17

local n = 2
local ecs_world = ecs.world()
local jecs_world = jecs.world()

local D1 = ecs_world.component()
local D2 = ecs_world.component()
local D3 = ecs_world.component()
local D4 = ecs_world.component()

local B1 = jecs_world:component()
local B2 = jecs_world:component()
local B3 = jecs_world:component()
local B4 = jecs_world:component()

for i = 1, N, n do
	local ecs_entity = ecs_world.entity()
	local jecs_entity = jecs_world:entity()

	for j = 1, n do
		local ecs_id = ecs_world.entity()
		local jecs_id = jecs_world:entity()

		if flip() then
			ecs_world.set(ecs_id, D1, true)
			jecs_world:set(jecs_id, B1, true)
		end
		if flip() then
			ecs_world.set(ecs_id, D2, true)
			jecs_world:set(jecs_id, B2, true)
		end
		if flip() then
			ecs_world.set(ecs_id, D3, true)
			jecs_world:set(jecs_id, B3, true)
		end
		if flip() then
			ecs_world.set(ecs_id, D4, true)
			jecs_world:set(jecs_id, B4, true)
		end

		ecs_world.add(ecs_id, ecs_entity)
		jecs_world:add(jecs_id, jecs_entity)
	end
end
ecs_worlds[n] = ecs_world
jecs_worlds[n] = jecs_world

return {
	Functions = {
		ecs = function(profiler)
			for count, world in ecs_worlds do
				profiler.Begin(`{count} entities per archetype`)
				local q = world.query(D1, D2, D3, D4)
				q:archetypes()
				profiler.End()
			end
		end,
		jecs = function(profiler)
			for count, world in jecs_worlds do
				profiler.Begin(`{count} entities per archetype`)
				local q = world:query(D1, D2, D3, D4)
				q:archetypes()
				profiler.End()
			end
		end,
	},
}
