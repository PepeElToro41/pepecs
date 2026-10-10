--!optimize 2
--!native

local bench = require "../bench"
local jecs = require "../jecs"

-- jecs has no depth or traverse: both are walked by hand with world:target.
local DEPTH = 32
local WIDTH = 64
local LEAVES = 2 ^ 14
local PASSES = 20

local world = jecs.world()
local Model = world:component()
local Tag = world:entity()

local root = world:entity()
world:set(root, Model, 0)
local chain = { root }
for i = 2, DEPTH do
	local e = world:entity()
	world:add(e, jecs.pair(jecs.ChildOf, chain[i - 1]))
	chain[i] = e
end
local deepest = chain[DEPTH]

local mids = {}
for i = 1, WIDTH do
	local mid = world:entity()
	world:add(mid, jecs.pair(jecs.ChildOf, deepest))
	mids[i] = mid
end
local leaves = {}
for i = 1, LEAVES do
	local leaf = world:entity()
	world:add(leaf, Tag)
	world:add(leaf, jecs.pair(jecs.ChildOf, mids[i % WIDTH + 1]))
	leaves[i] = leaf
end

local function depth(entity)
	local d = 0
	local parent = world:target(entity, jecs.ChildOf, 0)
	while parent do
		d += 1
		parent = world:target(parent, jecs.ChildOf, 0)
	end
	return d
end

local function traverse(entity, id)
	local parent = world:target(entity, jecs.ChildOf, 0)
	while parent do
		local value = world:get(parent, id)
		if value ~= nil then
			return parent, value
		end
		parent = world:target(parent, jecs.ChildOf, 0)
	end
	return nil
end

bench.title(`hierarchy: chain of {DEPTH}, {WIDTH} mids, {LEAVES} leaves`)

bench.run("depth(leaf), cached", LEAVES, function(i)
	local d = depth(leaves[i])
end)

bench.run("depth(leaf), after root move", LEAVES, function(i)
	world:add(root, Tag)
	world:remove(root, Tag)
	local d = depth(leaves[i])
end)

bench.run("traverse(leaf, ChildOf, Model), cached", LEAVES, function(i)
	local e, v = traverse(leaves[i], Model)
end)

bench.run("traverse(leaf, ChildOf, Model), after root move", LEAVES, function(i)
	world:add(root, Tag)
	world:remove(root, Tag)
	local e, v = traverse(leaves[i], Model)
end)

local up = world:query(Tag):cached()
bench.run("query :up(ChildOf) over leaves (manual walk)", PASSES, function()
	for e in up do
		local holder, v = traverse(e, Model)
	end
end)

bench.run("reparent leaf between mids", LEAVES, function(i)
	world:add(leaves[i], jecs.pair(jecs.ChildOf, mids[(i + 1) % WIDTH + 1]))
end)

-- every mid flips parent once per round of WIDTH ops, so each op is a real move
bench.run("reparent mid (subtree invalidation)", LEAVES, function(i)
	local mid = mids[i % WIDTH + 1]
	local round = i // WIDTH
	world:add(mid, jecs.pair(jecs.ChildOf, if round % 2 == 0 then deepest else chain[DEPTH - 1]))
end)
