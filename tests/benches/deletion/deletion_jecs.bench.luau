local ServerScriptService = game:GetService "ServerScriptService"

local jecs = require(ServerScriptService.ecs.tests.jecs)

if game then
	jecs = require(ServerScriptService.ecs.tests.jecs:Clone()) :: typeof(jecs)
end

local CHILD_AMOUNT = 50
local ARCHETYPE_SIZE = 20
local ARCHETYPE_COUNT = 50

local function ecs_create_components(world: jecs.World)
	local components: { jecs.Component } = {}

	for i = 1, ARCHETYPE_SIZE + ARCHETYPE_COUNT do
		components[i] = world:component()
	end
	return components
end

local function ecs_create_children(world: jecs.World, components: { jecs.Component })
	local children: { jecs.Entity } = {}

	for a = 0, ARCHETYPE_COUNT - 1 do
		for i = 1, CHILD_AMOUNT do
			local child = world:entity()
			children[1] = child

			local adding: { jecs.Component } = {}
			local values: { any } = {}

			for c = 1, ARCHETYPE_SIZE do
				table.insert(adding, components[c + a])
				table.insert(values, `value{c + a}`)
			end

			jecs.bulk_insert(world, child, adding, values)
		end
	end

	return children
end

-- ecs
local ecs_benches = {
	on_delete_target_delete = function()
		local world = jecs.world()
		local components = ecs_create_components(world)
		local children = ecs_create_children(world, components)

		local rel = world:entity()
		world:add(rel, jecs.pair(jecs.OnDeleteTarget, jecs.Delete))

		local parent = world:entity()

		for _, child in children do
			world:add(child, jecs.pair(rel, parent))
		end

		return world, parent
	end,

	on_delete_target_remove = function()
		local world = jecs.world()
		local components = ecs_create_components(world)
		local children = ecs_create_children(world, components)

		local rel = world:entity()
		local parent = world:entity()

		for _, child in children do
			world:add(child, jecs.pair(rel, parent))
		end

		return world, parent
	end,

	on_delete_delete = function()
		local world = jecs.world()
		local components = ecs_create_components(world)
		local children = ecs_create_children(world, components)

		local parent = world:entity()
		world:add(parent, jecs.pair(jecs.OnDelete, jecs.Delete))

		for _, child in children do
			world:add(child, parent)
		end

		return world, parent
	end,

	on_delete_remove = function()
		local world = jecs.world()
		local components = ecs_create_components(world)
		local children = ecs_create_children(world, components)

		local parent = world:entity()

		for _, child in children do
			world:add(child, parent)
		end

		return world, parent
	end,
}

return {
	ParameterGenerator = function(key: string)
		return ecs_benches[key]()
	end,
	Functions = {
		on_delete_target_delete = function(profiler, world: jecs.World, parent: jecs.Entity)
			world:delete(parent)
		end,
		on_delete_target_remove = function(profiler, world: jecs.World, parent: jecs.Entity)
			world:delete(parent)
		end,
		on_delete_delete = function(profiler, world: jecs.World, parent: jecs.Entity)
			world:delete(parent)
		end,
		on_delete_remove = function(profiler, world: jecs.World, parent: jecs.Entity)
			world:delete(parent)
		end,
	},
}
