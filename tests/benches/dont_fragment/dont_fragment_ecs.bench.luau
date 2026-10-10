--!optimize 2
--!native

-- Fragmenting pairs against DontFragment pairs on the worst case for
-- archetypes: one distinct target per entity.

local bench = require "../bench"
local ecs = require "../../../src/"

local N = 2 ^ 15
local TARGETS = 1000
local PASSES = 20

local world = ecs.world()
local Frag = world.component()
local Sparse = world.component()
world.add(Sparse, ecs.DontFragment)
local A = world.component()

local targets = {}
for i = 1, TARGETS do
	targets[i] = world.entity()
end

local function fresh(): { ecs.Entity }
	local list = {}
	for i = 1, N do
		local e = world.entity()
		world.set(e, A, i)
		list[i] = e
	end
	return list
end

bench.title "dont_fragment: set"

local frag_entities = fresh()
bench.run("set pair, 1000 targets (fragmenting)", N, function(i)
	world.set(frag_entities[i], ecs.pair(Frag, targets[i % TARGETS + 1]), i)
end)

local sparse_entities = fresh()
bench.run("set pair, 1000 targets (DontFragment)", N, function(i)
	world.set(sparse_entities[i], ecs.pair(Sparse, targets[i % TARGETS + 1]), i)
end)

bench.title "dont_fragment: get / has / target"

bench.run("get pair (fragmenting)", N, function(i)
	world.get(frag_entities[i], ecs.pair(Frag, targets[i % TARGETS + 1]))
end)
bench.run("get pair (DontFragment)", N, function(i)
	world.get(sparse_entities[i], ecs.pair(Sparse, targets[i % TARGETS + 1]))
end)
bench.run("target (fragmenting)", N, function(i)
	world.target(frag_entities[i], Frag)
end)
bench.run("target (DontFragment)", N, function(i)
	world.target(sparse_entities[i], Sparse)
end)

bench.title "dont_fragment: query iteration"

local frag_query = world.query_build():term(A):with(Frag):wildcard():build()
bench.once("iter A + (Frag, *), 1000 archetypes", N * PASSES, function()
	for _ = 1, PASSES do
		for _ in frag_query do
		end
	end
end)

local sparse_query = world.query_build():term(A):with(Sparse):wildcard():build()
bench.once("iter A + (Sparse, *), per entity check", N * PASSES, function()
	for _ = 1, PASSES do
		for _ in sparse_query do
		end
	end
end)

local sparse_only = world.query_build():term(Sparse):wildcard():build()
bench.once("iter (Sparse, *) only, sparse driven", N * PASSES, function()
	for _ = 1, PASSES do
		for _ in sparse_only do
		end
	end
end)

bench.title "dont_fragment: each / fallback"

bench.once("world.each (Frag, target 1)", N // TARGETS * PASSES, function()
	for _ = 1, PASSES do
		for _ in world.each(ecs.pair(Frag, targets[1])) do
		end
	end
end)
bench.once("world.each (Sparse, target 1)", N // TARGETS * PASSES, function()
	for _ = 1, PASSES do
		for _ in world.each(ecs.pair(Sparse, targets[1])) do
		end
	end
end)

local fallback = world.query(A, ecs.pair(Sparse, targets[1]))
bench.once("world.query fallback, A + (Sparse, target 1)", N * PASSES, function()
	for _ = 1, PASSES do
		for _ in fallback do
		end
	end
end)

bench.title "dont_fragment: remove"

bench.run("remove pair (fragmenting)", N, function(i)
	world.remove(frag_entities[i], ecs.pair(Frag, targets[i % TARGETS + 1]))
end)
bench.run("remove pair (DontFragment)", N, function(i)
	world.remove(sparse_entities[i], ecs.pair(Sparse, targets[i % TARGETS + 1]))
end)
