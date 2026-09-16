--!optimize 2
--!native

local bench = require "../bench"
local jecs = require "../jecs"

local N = 2 ^ 15
local TARGETS = 1000
local PASSES = 20

local world = jecs.world()
local Rel = world:component()
local TagRel = world:entity()
local A = world:component()

local targets = {}
for i = 1, TARGETS do
	targets[i] = world:entity()
end

local function fresh(): { jecs.Entity }
	local list = {}
	for i = 1, N do
		local e = world:entity()
		world:set(e, A, i)
		list[i] = e
	end
	return list
end

bench.title "pairs: add / set"

local one_target = fresh()
bench.run("add pair, same target (1 archetype)", N, function(i)
	world:add(one_target[i], jecs.pair(TagRel, targets[1]))
end)

local many_targets = fresh()
bench.run("add pair, 1000 targets (1000 archetypes)", N, function(i)
	world:add(many_targets[i], jecs.pair(TagRel, targets[i % TARGETS + 1]))
end)

local data_pairs = fresh()
bench.run("set pair data, 1000 targets", N, function(i)
	world:set(data_pairs[i], jecs.pair(Rel, targets[i % TARGETS + 1]), i)
end)

bench.run("set pair data, existing (overwrite)", N, function(i)
	world:set(data_pairs[i], jecs.pair(Rel, targets[i % TARGETS + 1]), i)
end)

bench.title "pairs: lookup"

bench.run("target(e, rel, 0)", N, function(i)
	local t = world:target(many_targets[i], TagRel, 0)
end)

bench.run("has(e, pair)", N, function(i)
	local ok = world:has(many_targets[i], jecs.pair(TagRel, targets[i % TARGETS + 1]))
end)

bench.run("get(e, pair)", N, function(i)
	local v = world:get(data_pairs[i], jecs.pair(Rel, targets[i % TARGETS + 1]))
end)

bench.title "pairs: iteration"

local parent = world:entity()
for i = 1, N do
	world:add(one_target[i], jecs.pair(jecs.ChildOf, parent))
end
bench.run("children(parent), 32k children", PASSES, function()
	for _ in world:children(parent) do
	end
end)

bench.run("parent(child)", N, function(i)
	local p = world:parent(one_target[i])
end)

bench.run("each(pair(rel, Wildcard)), 1000 archetypes", PASSES, function()
	for _ in world:each(jecs.pair(TagRel, jecs.Wildcard)) do
	end
end)

bench.run("query(pair(rel, Wildcard)), 1000 archetypes", PASSES, function()
	for _ in world:query(jecs.pair(TagRel, jecs.Wildcard)):iter() do
	end
end)

bench.run("query(A, pair(rel, Wildcard)), 1000 archetypes", PASSES, function()
	for _, a in world:query(A, jecs.pair(TagRel, jecs.Wildcard)):iter() do
	end
end)

bench.run("query(pair(Wildcard, target))", PASSES, function()
	for _ in world:query(jecs.pair(jecs.Wildcard, targets[1])):iter() do
	end
end)

bench.run("query(pair(Rel, Wildcard)) with data", PASSES, function()
	for _, v in world:query(jecs.pair(Rel, jecs.Wildcard)):iter() do
	end
end)

bench.title "pairs: remove"

bench.run("remove pair, 1000 targets", N, function(i)
	world:remove(many_targets[i], jecs.pair(TagRel, targets[i % TARGETS + 1]))
end)
