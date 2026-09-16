--!optimize 2
--!native

local bench = require "../bench"
local ecs = require "../../../src/"

local N = 2 ^ 15

local world = ecs.world()
local C = {}
for i = 1, 32 do
	C[i] = world.component()
end
local Rel = {}
for i = 1, 4 do
	Rel[i] = world.entity()
end
local target = world.entity()

local function make(count: number, pairs_count: number?): { ecs.Entity }
	local list = {}
	for i = 1, N do
		local e = world.entity()
		for c = 1, count do
			world.set(e, C[c], c)
		end
		for p = 1, pairs_count or 0 do
			world.add(e, ecs.pair(Rel[p], target))
		end
		list[i] = e
	end
	return list
end

bench.title "deletion: plain delete (no cleanup traits)"

local empty = make(0)
bench.run("delete empty entity", N, function(i)
	world.delete(empty[i])
end)

local with8 = make(8)
bench.run("delete entity with 8 components", N, function(i)
	world.delete(with8[i])
end)

local with32 = make(32)
bench.run("delete entity with 32 components", N, function(i)
	world.delete(with32[i])
end)

local with_pairs = make(4, 4)
bench.run("delete entity with 4 components + 4 pairs", N, function(i)
	world.delete(with_pairs[i])
end)

-- delete from the back so every delete is a pop, not a swap-remove
local from_back = make(8)
bench.run("delete 8-wide entity, back to front", N, function(i)
	world.delete(from_back[N - i + 1])
end)
