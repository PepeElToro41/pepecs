--!optimize 2
--!native

local bench = require "../bench"
local ecs = require "../../../src/"

-- hierarchy lookups: depth, traverse and :up() queries against a ChildOf tree.
-- Lookups hit the (R, T) node caches; "after move" cases pay one rebuild.
local DEPTH = 32
local WIDTH = 64
local LEAVES = 2 ^ 14
local PASSES = 20

local world = ecs.world()
local Model = world.component()
local Tag = world.tag()

-- a chain of DEPTH nodes, the root holds Model
local root = world.entity()
world.set(root, Model, 0)
local chain = { root }
for i = 2, DEPTH do
	local e = world.entity()
	world.add(e, ecs.pair(ecs.ChildOf, chain[i - 1]))
	chain[i] = e
end
local deepest = chain[DEPTH]

-- LEAVES leaves spread under WIDTH mid nodes that hang off the deepest link
local mids = {}
for i = 1, WIDTH do
	local mid = world.entity()
	world.add(mid, ecs.pair(ecs.ChildOf, deepest))
	mids[i] = mid
end
local leaves = {}
for i = 1, LEAVES do
	local leaf = world.entity()
	world.add(leaf, Tag)
	world.add(leaf, ecs.pair(ecs.ChildOf, mids[i % WIDTH + 1]))
	leaves[i] = leaf
end

bench.title(`hierarchy: chain of {DEPTH}, {WIDTH} mids, {LEAVES} leaves`)

bench.run("depth(leaf), cached", LEAVES, function(i)
	local d = world.depth(leaves[i])
end)

bench.run("depth(leaf), after root move", LEAVES, function(i)
	world.add(root, Tag)
	world.remove(root, Tag)
	local d = world.depth(leaves[i])
end)

bench.run("traverse(leaf, ChildOf, Model), cached", LEAVES, function(i)
	local e, v = world.traverse(leaves[i], ecs.ChildOf, Model)
end)

bench.run("traverse(leaf, ChildOf, Model), after root move", LEAVES, function(i)
	world.add(root, Tag)
	world.remove(root, Tag)
	local e, v = world.traverse(leaves[i], ecs.ChildOf, Model)
end)

local up = world.query_build():with(Tag):term(Model):up(ecs.ChildOf):build()
bench.run("query :up(ChildOf) over leaves", PASSES, function()
	for e, v in up do
	end
end)

local cascade = world.query_build():with(Tag):term(Model):up(ecs.ChildOf):cascade(ecs.ChildOf):build()
bench.run("query :up():cascade(ChildOf), order cached", PASSES, function()
	for e, v in cascade do
	end
end)

bench.run("query :cascade(ChildOf), re-sort after reparent", PASSES, function(i)
	world.add(mids[1], ecs.pair(ecs.ChildOf, if i % 2 == 0 then deepest else chain[DEPTH - 1]))
	for e, v in cascade do
	end
end)

bench.run("reparent leaf between mids", LEAVES, function(i)
	world.add(leaves[i], ecs.pair(ecs.ChildOf, mids[(i + 1) % WIDTH + 1]))
end)

-- every mid flips parent once per round of WIDTH ops, so each op is a real move
bench.run("reparent mid (subtree invalidation)", LEAVES, function(i)
	local mid = mids[i % WIDTH + 1]
	local round = i // WIDTH
	world.add(mid, ecs.pair(ecs.ChildOf, if round % 2 == 0 then deepest else chain[DEPTH - 1]))
end)

-- cascade sort over ~1000 archetypes: every parent is its own (ChildOf, P)
-- archetype, spread over 10 levels. The order is reused until a parent link
-- changes, then re-sorted with one counting sort.
local PARENTS = 1000
local TREE_DEPTH = 10
local CHILDREN = 4

for _, mode in { "ChildOf (nodes)", "plain relation (slow path)" } do
	local big = ecs.world()
	local relation = if mode == "ChildOf (nodes)" then ecs.ChildOf else big.tag()
	local BigTag = big.tag()
	local root = big.entity()
	big.add(root, BigTag)

	local per_level = PARENTS // TREE_DEPTH
	local levels = { { root } }
	local parents = {}
	for level = 1, TREE_DEPTH do
		local above = levels[level]
		local row = {}
		for i = 1, per_level do
			local p = big.entity()
			big.add(p, BigTag)
			big.add(p, ecs.pair(relation, above[(i - 1) % #above + 1]))
			row[i] = p
			parents[#parents + 1] = p
		end
		levels[level + 1] = row
	end
	for _, p in parents do
		for _ = 1, CHILDREN do
			local c = big.entity()
			big.add(c, BigTag)
			big.add(c, ecs.pair(relation, p))
		end
	end

	local sorted = big.query_build():term(BigTag):cascade(relation):build():cached()
	local flip = parents[#parents]
	local p1, p2 = levels[TREE_DEPTH][1], levels[TREE_DEPTH][2]

	bench.title(`cascade sort, {mode}: {#sorted:archetypes()} archetypes`)

	bench.run("archetypes(), order reused", PASSES, function()
		sorted:archetypes()
	end)
	bench.run("archetypes(), re-sort after reparent", PASSES, function(i)
		big.add(flip, ecs.pair(relation, if i % 2 == 0 then p1 else p2))
		sorted:archetypes()
	end)
	bench.run("iterate, re-sort after reparent", PASSES, function(i)
		big.add(flip, ecs.pair(relation, if i % 2 == 0 then p1 else p2))
		for _ in sorted do
		end
	end)
end
