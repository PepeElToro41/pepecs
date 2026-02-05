local ServerScriptService = game:GetService "ServerScriptService"

local ecs = require(ServerScriptService.ecs.ecs)

if game then
	ecs = require(ServerScriptService.ecs.ecs:Clone()) :: typeof(ecs)
end

local CHILD_AMOUNT = 50
local ARCHETYPE_SIZE = 20
local ARCHETYPE_COUNT = 50

local function ecs_create_components(world: ecs.World)
	local components: { ecs.Component } = {}

	for i = 1, ARCHETYPE_SIZE + ARCHETYPE_COUNT do
		components[i] = world.component()
	end
	return components
end

local function ecs_create_children(world: ecs.World, components: { ecs.Component })
	local children: { ecs.Entity } = {}

	for a = 0, ARCHETYPE_COUNT - 1 do
		for i = 1, CHILD_AMOUNT do
			local child = world.entity()
			children[1] = child

			local adding: { ecs.Component } = {}
			local values: { any } = {}

			for c = 1, ARCHETYPE_SIZE do
				table.insert(adding, components[c + a])
				table.insert(values, `value{c + a}`)
			end

			world.bulk_set(child, adding, values)
		end
	end

	return children
end

-- ecs
local ecs_benches = {
	on_delete_target_delete = function()
		local world = ecs.world()
		local components = ecs_create_components(world)
		local children = ecs_create_children(world, components)

		local rel = world.entity()
		world.add(rel, ecs.pair(ecs.OnDeleteTarget, ecs.Delete))

		local parent = world.entity()

		for _, child in children do
			world.add(child, ecs.pair(rel, parent))
		end

		return world, parent
	end,

	on_delete_target_remove = function()
		local world = ecs.world()
		local components = ecs_create_components(world)
		local children = ecs_create_children(world, components)

		local rel = world.entity()

		local parent = world.entity()

		for _, child in children do
			world.add(child, ecs.pair(rel, parent))
		end

		return world, parent
	end,

	on_delete_delete = function()
		local world = ecs.world()
		local components = ecs_create_components(world)
		local children = ecs_create_children(world, components)

		local parent = world.entity()
		world.add(parent, ecs.pair(ecs.OnDelete, ecs.Delete))

		for _, child in children do
			world.add(child, parent)
		end

		return world, parent
	end,

	on_delete_remove = function()
		local world = ecs.world()
		local components = ecs_create_components(world)
		local children = ecs_create_children(world, components)

		local parent = world.entity()

		for _, child in children do
			world.add(child, parent)
		end

		return world, parent
	end,
}

return {
	ParameterGenerator = function(key: string)
		return ecs_benches[key]()
	end,
	Functions = {
		on_delete_target_delete = function(profiler, world: ecs.World, parent: ecs.Entity)
			world.delete(parent)
		end,
		on_delete_target_remove = function(profiler, world: ecs.World, parent: ecs.Entity)
			world.delete(parent)
		end,
		on_delete_delete = function(profiler, world: ecs.World, parent: ecs.Entity)
			world.delete(parent)
		end,
		on_delete_remove = function(profiler, world: ecs.World, parent: ecs.Entity)
			world.delete(parent)
		end,
	},
}
