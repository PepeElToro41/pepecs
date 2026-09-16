--!optimize 2
--!native

local bench = require "../bench"
local jecs = require "../jecs"

local N = 2 ^ 15

local function noop() end

-- each case gets its own world so hooks registered for one case never leak into another
local function setup(hooks: number, kind: "added" | "changed" | "removed" | nil)
	local world = jecs.world()
	local C = {}
	for i = 1, 8 do
		C[i] = world:component()
	end
	if kind then
		for _, c in C do
			for _ = 1, hooks do
				world[kind](world, c, noop)
			end
		end
	end
	local entities = {}
	for i = 1, N do
		entities[i] = world:entity()
	end
	return world, C, entities
end

local function fill(world: jecs.World, C, entities, count: number)
	for i = 1, N do
		for c = 1, count do
			world:set(entities[i], C[c], i)
		end
	end
end

for _, hooks in { 0, 1, 3 } do
	bench.title(`hooks: {hooks} hook(s) per component`)

	do
		local world, C, entities = setup(hooks, "added")
		bench.run("set new (added hook)", N, function(i)
			world:set(entities[i], C[1], i)
		end)
	end

	do
		local world, C, entities = setup(hooks, "changed")
		fill(world, C, entities, 1)
		bench.run("set existing (changed hook)", N, function(i)
			world:set(entities[i], C[1], i)
		end)
	end

	do
		local world, C, entities = setup(hooks, "removed")
		fill(world, C, entities, 1)
		bench.run("remove (removed hook)", N, function(i)
			world:remove(entities[i], C[1])
		end)
	end

	do
		local world, C, entities = setup(hooks, "removed")
		fill(world, C, entities, 8)
		bench.run("delete 8-wide entity (removed hook x8)", N, function(i)
			world:delete(entities[i])
		end)
	end
end
