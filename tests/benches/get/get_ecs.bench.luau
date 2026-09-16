--!optimize 2
--!native

local bench = require "../bench"
local ecs = require "../../../src/"

local N = 2 ^ 15

local world = ecs.world()
local C1 = world.component()
local C2 = world.component()
local C3 = world.component()
local C4 = world.component()
local Missing = world.component()
local Rel = world.component()
local TagRel = world.entity()
local Tag = world.entity()
local target = world.entity()

local RelPair = ecs.pair(Rel, target)
local TagPair = ecs.pair(TagRel, target)

local entities = {}
for i = 1, N do
	local e = world.entity()
	world.set(e, C1, i)
	world.set(e, C2, i)
	world.set(e, C3, i)
	world.set(e, C4, i)
	world.add(e, Tag)
	world.set(e, RelPair, i)
	world.add(e, TagPair)
	entities[i] = e
end

bench.title "get"

bench.run("get 1", N, function(i)
	local a = world.get(entities[i], C1)
end)
bench.run("get 2", N, function(i)
	local a, b = world.get(entities[i], C1, C2)
end)
bench.run("get 4", N, function(i)
	local a, b, c, d = world.get(entities[i], C1, C2, C3, C4)
end)
bench.run("get missing", N, function(i)
	local a = world.get(entities[i], Missing)
end)
bench.run("get pair value", N, function(i)
	local a = world.get(entities[i], RelPair)
end)

bench.title "has"

bench.run("has component", N, function(i)
	local ok = world.has(entities[i], C1)
end)
bench.run("has tag", N, function(i)
	local ok = world.has(entities[i], Tag)
end)
bench.run("has missing", N, function(i)
	local ok = world.has(entities[i], Missing)
end)
bench.run("has pair", N, function(i)
	local ok = world.has(entities[i], TagPair)
end)

bench.title "lookup"

bench.run("target(e, rel, 0)", N, function(i)
	local t = world.target(entities[i], TagRel, 0)
end)
bench.run("exists", N, function(i)
	local ok = world.exists(entities[i])
end)
