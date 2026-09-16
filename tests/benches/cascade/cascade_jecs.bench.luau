--!optimize 2
--!native

local bench = require "../bench"
local jecs = require "../jecs"

-- every case is prepared REPS times (untimed), then each prepared world is deleted once (timed)
local REPS = 3
local CHILDREN = 10_000
local DEPTH = 200
local WIDTH = 100
local ARCHETYPES = 20

type Prepared = { world: jecs.World, root: jecs.Entity }

-- children get 4 components chosen by index so they spread over ARCHETYPES archetypes
local function child(world: jecs.World, C: { jecs.Component }, index: number): jecs.Entity
	local e = world:entity()
	local offset = index % ARCHETYPES
	world:set(e, C[offset + 1], index)
	world:set(e, C[offset + 2], index)
	world:set(e, C[offset + 3], index)
	world:set(e, C[offset + 4], index)
	return e
end

local function components(world: jecs.World): { jecs.Component }
	local C = {}
	for i = 1, ARCHETYPES + 4 do
		C[i] = world:component()
	end
	return C
end

local cases: { [string]: () -> Prepared } = {
	-- ChildOf ships with (OnDeleteTarget, Delete)
	["ChildOf flat: 1 parent, 10k children"] = function()
		local world = jecs.world()
		local C = components(world)
		local root = world:entity()
		for i = 1, CHILDREN do
			world:add(child(world, C, i), jecs.pair(jecs.ChildOf, root))
		end
		return { world = world, root = root }
	end,

	["ChildOf chain: depth 200"] = function()
		local world = jecs.world()
		local C = components(world)
		local root = world:entity()
		local parent = root
		for i = 1, DEPTH do
			local e = child(world, C, i)
			world:add(e, jecs.pair(jecs.ChildOf, parent))
			parent = e
		end
		return { world = world, root = root }
	end,

	["ChildOf tree: 100 x 100"] = function()
		local world = jecs.world()
		local C = components(world)
		local root = world:entity()
		for i = 1, WIDTH do
			local mid = child(world, C, i)
			world:add(mid, jecs.pair(jecs.ChildOf, root))
			for j = 1, WIDTH do
				world:add(child(world, C, i * WIDTH + j), jecs.pair(jecs.ChildOf, mid))
			end
		end
		return { world = world, root = root }
	end,

	["custom rel (OnDeleteTarget, Delete): 10k"] = function()
		local world = jecs.world()
		local C = components(world)
		local rel = world:entity()
		world:add(rel, jecs.pair(jecs.OnDeleteTarget, jecs.Delete))
		local root = world:entity()
		for i = 1, CHILDREN do
			world:add(child(world, C, i), jecs.pair(rel, root))
		end
		return { world = world, root = root }
	end,

	["custom rel default (remove pair): 10k"] = function()
		local world = jecs.world()
		local C = components(world)
		local rel = world:entity()
		local root = world:entity()
		for i = 1, CHILDREN do
			world:add(child(world, C, i), jecs.pair(rel, root))
		end
		return { world = world, root = root }
	end,

	["tag (OnDelete, Delete): 10k"] = function()
		local world = jecs.world()
		local C = components(world)
		local tag = world:entity()
		world:add(tag, jecs.pair(jecs.OnDelete, jecs.Delete))
		for i = 1, CHILDREN do
			world:add(child(world, C, i), tag)
		end
		return { world = world, root = tag }
	end,

	["tag default (remove): 10k"] = function()
		local world = jecs.world()
		local C = components(world)
		local tag = world:entity()
		for i = 1, CHILDREN do
			world:add(child(world, C, i), tag)
		end
		return { world = world, root = tag }
	end,
}

local order = {
	"ChildOf flat: 1 parent, 10k children",
	"ChildOf chain: depth 200",
	"ChildOf tree: 100 x 100",
	"custom rel (OnDeleteTarget, Delete): 10k",
	"custom rel default (remove pair): 10k",
	"tag (OnDelete, Delete): 10k",
	"tag default (remove): 10k",
}

bench.title "cascade deletion (one op = full cascade)"

for _, name in order do
	local prepare = cases[name]
	local prepared: { Prepared } = {}
	for i = 1, REPS do
		prepared[i] = prepare()
	end
	bench.run(name, REPS, function(i)
		local p = prepared[i]
		p.world:delete(p.root)
	end)
end
