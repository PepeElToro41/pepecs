--!optimize 2
--!native

local bench = require "../bench"
local jecs = require "../jecs"

-- cost of a cached query walking matched archetypes that hold no entities: every
-- entity gets a unique tag (one archetype each) and is then deleted, leaving the
-- archetype behind. queries are built up front so only iteration is timed
local ARCHETYPES = 10000
local PASSES = 1000

local world = jecs.world()
local A = world:component()
local B = world:component()
local C = world:component()
local D = world:component()
local E = world:component()

local entities = {}
for i = 1, ARCHETYPES do
	local e = world:entity()
	world:set(e, A, i)
	world:set(e, B, i)
	world:set(e, C, i)
	world:set(e, D, i)
	world:add(e, world:entity())
	entities[i] = e
end
for i = 1, ARCHETYPES do
	world:delete(entities[i])
end

local q1 = world:query(A):cached()
local q2 = world:query(A, B):cached()
local q4 = world:query(A, B, C, D):cached()
local q2_without = world:query(A, B):without(E):cached()

bench.title(`query dead: {#q4:archetypes()} empty archetypes, cached queries`)

bench.run("1 term", PASSES, function()
	for _, a in q1:iter() do
	end
end)
bench.run("2 terms", PASSES, function()
	for _, a, b in q2:iter() do
	end
end)
bench.run("4 terms", PASSES, function()
	for _, a, b, c, d in q4:iter() do
	end
end)
bench.run("2 terms, without 1", PASSES, function()
	for _, a, b in q2_without:iter() do
	end
end)
