--!optimize 2
--!native

-- Compares the compiled query engine against world.query and against manual
-- traversal. Run with: lune run tests/benches/engine.bench

local bench = require "./bench"
local ecs = require "../../src/"

local ENTITIES = 100_000
local PARENTS = 1_000
local ITERATIONS = 20

local world = ecs.world()

local A = world.component()
local B = world.component()
local C = world.component()
local D = world.component()
local E = world.component()
local F = world.component()
local Model = world.component()
local Located = world.component()
local Foo = world.component()

-- 64 archetypes: random subsets of six components
local components = { A, B, C, D, E, F }
math.randomseed(42)
for i = 1, ENTITIES do
	local entity = world.entity()
	for _, component in components do
		if math.random() < 0.6 then
			world.set(entity, component, i)
		end
	end
end

-- parents holding Model, children under them
local parents = table.create(PARENTS)
for i = 1, PARENTS do
	local parent = world.entity()
	world.set(parent, Model, i)
	parents[i] = parent
end

local children_count = 0
for entity, a in world.query(A) do
	world.add(entity, ecs.pair(ecs.ChildOf, parents[(a % PARENTS) + 1]))
	children_count += 1
end

-- rooms with Foo, entities located in one of them
local rooms = table.create(PARENTS)
for i = 1, PARENTS do
	local room = world.entity()
	world.set(room, Foo, i)
	rooms[i] = room
end

local located_count = 0
for entity, b in world.query(B) do
	world.set(entity, ecs.pair(Located, rooms[(b % PARENTS) + 1]), b)
	located_count += 1
end

local function consume(query: any)
	local count = 0
	for _ in query do
		count += 1
	end
	return count
end

bench.title "static queries: world.query vs query_build"

local legacy_3 = world.query(A, B, C)
local engine_3 = world.query_build():term(A):term(B):term(C):build()
local engine_3_cached = world.query_build():term(A):term(B):term(C):build():cached()

bench.run("world.query(A, B, C)", ITERATIONS, function()
	consume(legacy_3)
end)
bench.run("query_build():term(A):term(B):term(C)", ITERATIONS, function()
	consume(engine_3)
end)
bench.run("... :cached()", ITERATIONS, function()
	consume(engine_3_cached)
end)

local legacy_filter = world.query(A):with(B):without(C)
local engine_filter = world.query_build():term(A):with(B):without(C):build()

bench.run("world.query(A):with(B):without(C)", ITERATIONS, function()
	consume(legacy_filter)
end)
bench.run("query_build():term(A):with(B):without(C)", ITERATIONS, function()
	consume(engine_filter)
end)

local engine_optional = world.query_build():term(A):term(F):optional():build()
bench.run("query_build():term(A):term(F):optional()", ITERATIONS, function()
	consume(engine_optional)
end)

bench.title "up traversal"

local manual_up = world.query(A)
bench.run("world.query(A) + world.traverse(ChildOf, Model)", ITERATIONS, function()
	local count = 0
	for entity in manual_up do
		local _, model = world.traverse(entity, ecs.ChildOf, Model)
		if model then
			count += 1
		end
	end
end)

local engine_up = world.query_build():term(A):term(Model):up(ecs.ChildOf):build()
bench.run("query_build():term(A):term(Model):up(ChildOf)", ITERATIONS, function()
	consume(engine_up)
end)

local engine_up_cached = world.query_build():term(A):term(Model):up(ecs.ChildOf):build():cached()
bench.run("... :cached()", ITERATIONS, function()
	consume(engine_up_cached)
end)

bench.title "pair target variables"

local manual_target = world.query(B)
bench.run("world.query(B) + world.target + world.get", ITERATIONS, function()
	local count = 0
	for entity in manual_target do
		local room = world.target(entity, Located)
		if room and world.get(room, Foo) then
			count += 1
		end
	end
end)

local engine_target = world.query_build():term(B):term(Located):target("$room"):term(Foo):from("$room"):build()
bench.run("query_build():term(Located):target($room):term(Foo):from($room)", ITERATIONS, function()
	consume(engine_target)
end)

print()
print(`entities: {ENTITIES}, children: {children_count}, located: {located_count}`)
