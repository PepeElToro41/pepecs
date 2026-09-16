--!optimize 2
--!native

local bench = require "../bench"
local ecs = require "../../../src/"

-- cost of archetype creation while queries have to notice the new archetypes
local ARCHETYPES = 2000

local function setup()
	local world = ecs.world()
	local A = world.component()
	local B = world.component()
	local C = world.component()
	local entities = {}
	local tags = {}
	for i = 1, ARCHETYPES do
		local e = world.entity()
		world.set(e, A, i)
		world.set(e, B, i)
		world.set(e, C, i)
		entities[i] = e
		tags[i] = world.entity()
	end
	return world, A, B, C, entities, tags
end

bench.title "query rematch: create 2000 archetypes (add unique tag)"

do
	local world, _, _, _, entities, tags = setup()
	bench.run("no queries alive", ARCHETYPES, function(i)
		world.add(entities[i], tags[i])
	end)
end

do
	local world, A, B, _, entities, tags = setup()
	local q = world.query(A, B):cached()
	bench.run("1 cached query", ARCHETYPES, function(i)
		world.add(entities[i], tags[i])
	end)
end

do
	local world, A, B, C, entities, tags = setup()
	local q1 = world.query(A):cached()
	local q2 = world.query(A, B):cached()
	local q3 = world.query(B, C):cached()
	local q4 = world.query(A, B, C):cached()
	bench.run("4 cached queries", ARCHETYPES, function(i)
		world.add(entities[i], tags[i])
	end)
end

do
	local world, A, B, C, entities, tags = setup()
	local q1 = world.query(A):without(C):cached()
	local q2 = world.query(A, B):without(C):cached()
	local q3 = world.query(B):without(A):cached()
	local q4 = world.query(C):without(A, B):cached()
	bench.run("4 cached queries (with without)", ARCHETYPES, function(i)
		world.add(entities[i], tags[i])
	end)
end

bench.title "query rematch: match 2000 archetypes"

do
	local world, A, B, C, entities, tags = setup()
	for i = 1, ARCHETYPES do
		world.add(entities[i], tags[i])
	end

	bench.run("uncached archetypes(), 2 terms", 200, function()
		world.query(A, B):archetypes()
	end)
	bench.run("uncached archetypes(), 2 terms + without", 200, function()
		world.query(A, B):without(C):archetypes()
	end)

	local cached = world.query(A, B):cached()
	bench.run("cached archetypes(), 2 terms", 200, function()
		cached:archetypes()
	end)

	bench.run("build new cached query", 200, function()
		world.query(A, B):cached():cleanup()
	end)
end
