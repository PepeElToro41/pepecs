--!optimize 2
--!native

local bench = require "../bench"
local ecs = require "../../../src/"

local N = 2 ^ 15

local world = ecs.world()
local C = {}
for i = 1, 16 do
	C[i] = world.component()
end
local Tag = world.entity()

local function make(count: number, tag: boolean?): { ecs.Entity }
	local list = {}
	for i = 1, N do
		local e = world.entity()
		for c = 1, count do
			world.set(e, C[c], c)
		end
		if tag then
			world.add(e, Tag)
		end
		list[i] = e
	end
	return list
end

bench.title "removal: remove component (archetype move)"

local first = make(8)
bench.run("remove first of 8", N, function(i)
	world.remove(first[i], C[1])
end)

local middle = make(8)
bench.run("remove middle of 8", N, function(i)
	world.remove(middle[i], C[4])
end)

local last = make(8)
bench.run("remove last of 8", N, function(i)
	world.remove(last[i], C[8])
end)

local wide = make(16)
bench.run("remove middle of 16", N, function(i)
	world.remove(wide[i], C[8])
end)

local tagged = make(8, true)
bench.run("remove tag from 8-wide entity", N, function(i)
	world.remove(tagged[i], Tag)
end)

bench.run("remove missing (no-op)", N, function(i)
	world.remove(first[i], C[1])
end)

bench.title "removal: clear"

local clear8 = make(8)
bench.run("clear entity with 8 components", N, function(i)
	world.clear(clear8[i])
end)

local clear16 = make(16)
bench.run("clear entity with 16 components", N, function(i)
	world.clear(clear16[i])
end)
