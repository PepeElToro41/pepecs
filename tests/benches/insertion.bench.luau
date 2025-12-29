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

local C1 = jecs_world:component()
local C2 = jecs_world:component()
local C3 = jecs_world:component()
local C4 = jecs_world:component()
local C5 = jecs_world:component()
local C6 = jecs_world:component()
local C7 = jecs_world:component()
local C8 = jecs_world:component()

local E1 = ecs_world.component()
local E2 = ecs_world.component()
local E3 = ecs_world.component()
local E4 = ecs_world.component()
local E5 = ecs_world.component()
local E6 = ecs_world.component()
local E7 = ecs_world.component()
local E8 = ecs_world.component()

return {
	ParameterGenerator = function()
		return
	end,

	Functions = {
		Ecs = function()
			local e = ecs_world.entity()
			for i = 1, 5000 do
				ecs_world.set(e, E1, false)
				ecs_world.set(e, E2, false)
				ecs_world.set(e, E3, false)
				ecs_world.set(e, E4, false)
				ecs_world.set(e, E5, false)
				ecs_world.set(e, E6, false)
				ecs_world.set(e, E7, false)
				ecs_world.set(e, E8, false)
			end
		end,
		Jecs = function()
			local e = jecs_world:entity()
			for i = 1, 5000 do
				jecs_world:set(e, C1, false)
				jecs_world:set(e, C2, false)
				jecs_world:set(e, C3, false)
				jecs_world:set(e, C4, false)
				jecs_world:set(e, C5, false)
				jecs_world:set(e, C6, false)
				jecs_world:set(e, C7, false)
				jecs_world:set(e, C8, false)
			end
		end,
	},
}
