--!optimize 2
--!native

local ServerScriptService = game:GetService "ServerScriptService"

local jecs = require(ServerScriptService.ecs.tests.jecs)
local ecs = require(ServerScriptService.ecs.ecs)

if game then
	jecs = require(ServerScriptService.ecs.tests.jecs:Clone()) :: typeof(jecs)
	ecs = require(ServerScriptService.ecs.ecs:Clone()) :: typeof(ecs)
end

local jecs_world = jecs.world()
local ecs_world = ecs.world()

local D1 = jecs_world:component()
local D2 = jecs_world:component()
local D3 = jecs_world:component()
local D4 = jecs_world:component()
local D5 = jecs_world:component()
local D6 = jecs_world:component()
local D7 = jecs_world:component()
local D8 = jecs_world:component()

local E1 = ecs_world.component()
local E2 = ecs_world.component()
local E3 = ecs_world.component()
local E4 = ecs_world.component()
local E5 = ecs_world.component()
local E6 = ecs_world.component()
local E7 = ecs_world.component()
local E8 = ecs_world.component()

local function flip()
	return math.random() >= 0.3
end

local N = 2 ^ 16 - 2

for i = 1, N do
	local entity = jecs_world:entity()
	local m = ecs_world.entity()

	if flip() then
		jecs_world:set(entity, D1, true)
		ecs_world.set(m, E1, true)
	end
	if flip() then
		jecs_world:set(entity, D2, true)
		ecs_world.set(m, E2, true)
	end
	if flip() then
		jecs_world:set(entity, D3, true)
		ecs_world.set(m, E3, true)
	end
	if flip() then
		jecs_world:set(entity, D4, true)
		ecs_world.set(m, E4, true)
	end
	if flip() then
		jecs_world:set(entity, D5, true)
		ecs_world.set(m, E5, true)
	end
	if flip() then
		jecs_world:set(entity, D6, true)
		ecs_world.set(m, E6, true)
	end
	if flip() then
		jecs_world:set(entity, D7, true)
		ecs_world.set(m, E7, true)
	end
	if flip() then
		jecs_world:set(entity, D8, true)
		ecs_world.set(m, E8, true)
	end
end

return {
	ParameterGenerator = function()
		return
	end,

	Functions = {
		ecs = function()
			ecs_world.query(E2, E4, E6, E8):archetypes()
		end,

		jecs = function()
			jecs_world:query(D2, D4, D6, D8):archetypes()
		end,
	},
}
