--!optimize 2
--!native

local bench = require "../bench"
local ecs = require "../../../src/"

local N = 2 ^ 15
local ARCHETYPES = 2000

local world = ecs.world()
local C = {}
for i = 1, 17 do
	C[i] = world.component()
end
local Tag = world.entity()

local function make(count: number): { ecs.Entity }
	local list = {}
	for i = 1, N do
		local e = world.entity()
		for c = 1, count do
			world.set(e, C[c], c)
		end
		list[i] = e
	end
	return list
end

bench.title "insertion: set existing component (overwrite)"

local with8 = make(8)
bench.run("set 1 existing", N, function(i)
	world.set(with8[i], C[1], i)
end)

bench.run("set 8 existing", N, function(i)
	local e = with8[i]
	world.set(e, C[1], i)
	world.set(e, C[2], i)
	world.set(e, C[3], i)
	world.set(e, C[4], i)
	world.set(e, C[5], i)
	world.set(e, C[6], i)
	world.set(e, C[7], i)
	world.set(e, C[8], i)
end)

bench.run("set 8 existing, same entity", N, function(i)
	local e = with8[1]
	world.set(e, C[1], i)
	world.set(e, C[2], i)
	world.set(e, C[3], i)
	world.set(e, C[4], i)
	world.set(e, C[5], i)
	world.set(e, C[6], i)
	world.set(e, C[7], i)
	world.set(e, C[8], i)
end)

bench.title "insertion: set new component (archetype move, warm edge)"

local set0 = make(0)
bench.run("set on entity with 0 components", N, function(i)
	world.set(set0[i], C[1], i)
end)

local set4 = make(4)
bench.run("set on entity with 4 components", N, function(i)
	world.set(set4[i], C[5], i)
end)

local set16 = make(16)
bench.run("set on entity with 16 components", N, function(i)
	world.set(set16[i], C[17], i)
end)

bench.title "insertion: add tag (archetype move, warm edge)"

local add0 = make(0)
bench.run("add on entity with 0 components", N, function(i)
	world.add(add0[i], Tag)
end)

local add4 = make(4)
bench.run("add on entity with 4 components", N, function(i)
	world.add(add4[i], Tag)
end)

local add16 = make(16)
bench.run("add on entity with 16 components", N, function(i)
	world.add(add16[i], Tag)
end)

bench.run("add already present (no-op)", N, function(i)
	world.add(add4[i], Tag)
end)

bench.title "insertion: churn (insert then remove, edge cache)"

local churn = make(8)[1]
bench.run("set C9 + remove C9 on 8-wide entity", N, function(i)
	world.set(churn, C[9], i)
	world.remove(churn, C[9])
end)

bench.run("add Tag + remove Tag on 8-wide entity", N, function()
	world.add(churn, Tag)
	world.remove(churn, Tag)
end)

bench.title "insertion: new archetype per op (edge miss)"

local tags = {}
for i = 1, ARCHETYPES do
	tags[i] = world.entity()
end
local fresh = make(8)
bench.run("add unique tag (creates archetype)", ARCHETYPES, function(i)
	world.add(fresh[i], tags[i])
end)

-- same tags again, but every edge now exists
bench.run("add unique tag (archetype exists)", ARCHETYPES, function(i)
	world.add(fresh[ARCHETYPES + i], tags[i])
end)
