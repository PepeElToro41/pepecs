--!optimize 2
--!native

-- Archetype matching: bitset words, bloom and the columns map fallback.
-- Compare against the previous commit by running the same file from a
-- worktree of it (the single match section adapts to either internal API).

local bench = require "../bench"
local ecs = require "../../../src/"
local ARCHETYPES = 2000
local FINDS = 200

-- 2000 archetypes over a handful of components, a relation with 4 targets and
-- a unique tag so every entity gets its own archetype
local function setup_narrow()
	local world = ecs.world()
	local A = world.component()
	local B = world.component()
	local C = world.component()
	local D = world.component()
	local E = world.component()
	local Rel = world.tag()
	local targets = { world.entity(), world.entity(), world.entity(), world.entity() }
	local entities = {}
	local tags = {}
	for i = 1, ARCHETYPES do
		local e = world.entity()
		world.set(e, A, i)
		if i % 2 == 0 then
			world.set(e, B, i)
		end
		if i % 3 == 0 then
			world.set(e, C, i)
		end
		if i % 5 == 0 then
			world.set(e, D, i)
		end
		if i % 7 == 0 then
			world.set(e, E, i)
		end
		world.add(e, ecs.pair(Rel, targets[(i % 4) + 1]))
		entities[i] = e
		tags[i] = world.entity()
	end
	return world, { A = A, B = B, C = C, D = D, E = E, Rel = Rel, targets = targets }, entities, tags
end

-- 2000 archetypes of 6 components out of 200, spread over every bitset word
local function setup_wide()
	local world = ecs.world()
	local components = {}
	for i = 1, 200 do
		components[i] = world.component()
	end
	math.randomseed(42)
	local random = {
		NextInteger = function(_, a, b)
			return math.random(a, b)
		end,
	}
	for i = 1, ARCHETYPES do
		local e = world.entity()
		for _ = 1, 6 do
			world.set(e, components[random:NextInteger(1, 200)], i)
		end
		world.add(e, world.entity())
	end
	return world, components, random
end

-------------------------------------------------------------------------------

bench.title "archetype match: create 2000 archetypes with cached queries alive"

do
	local world, c, entities, tags = setup_narrow()
	local _queries: { any } = {
		world.query(c.A):cached(),
		world.query(c.A, c.B):cached(),
		world.query(c.B, c.C):cached(),
		world.query(c.A, c.B, c.C):cached(),
		world.query(c.A):without(c.B):cached(),
		world.query(c.A):without(c.B, c.C):cached(),
		world.query(c.C):without(c.A):cached(),
		world.query(c.B, ecs.pair(c.Rel, c.targets[1])):cached(),
	}
	bench.run("8 cached queries", ARCHETYPES, function(i)
		world.add(entities[i], tags[i])
	end)
end

bench.title "archetype match: find over 2000 narrow archetypes"

do
	local world, c, entities, tags = setup_narrow()
	for i = 1, ARCHETYPES do
		world.add(entities[i], tags[i])
	end
	local pair_1 = ecs.pair(c.Rel, c.targets[1])

	bench.run("(A): accept all 2000", FINDS, function()
		world.query(c.A):archetypes()
	end)
	bench.run("(B, C): 1000 probed, 1/3 accepted", FINDS, function()
		world.query(c.B, c.C):archetypes()
	end)
	bench.run("(A, B, C, D, E): 285 probed, few accepted", FINDS, function()
		world.query(c.A, c.B, c.C, c.D, c.E):archetypes()
	end)
	bench.run("(A) without (B): 2000 probed, half rejected", FINDS, function()
		world.query(c.A):without(c.B):archetypes()
	end)
	bench.run("(A) without (B, C, D, E): 2000 probed", FINDS, function()
		world.query(c.A):without(c.B, c.C, c.D, c.E):archetypes()
	end)
	bench.run("(B, pair): 500 probed by pair, half accepted", FINDS, function()
		world.query(c.B, pair_1):archetypes()
	end)
	bench.run("(B) without (pair): 1000 probed, 1/4 rejected", FINDS, function()
		world.query(c.B):without(pair_1):archetypes()
	end)
	bench.run("(B) without (Rel, *): 1000 probed, all rejected", FINDS, function()
		world.query(c.B):without(ecs.pair(c.Rel, ecs.Wildcard)):archetypes()
	end)
end

bench.title "archetype match: find over 2000 wide archetypes (200 components)"

do
	local world, components, random = setup_wide()
	local pairs_of = {}
	local triples_of = {}
	for i = 1, 50 do
		pairs_of[i] = { components[random:NextInteger(1, 200)], components[random:NextInteger(1, 200)] }
		triples_of[i] = {
			components[random:NextInteger(1, 200)],
			components[random:NextInteger(1, 200)],
			components[random:NextInteger(1, 200)],
		}
	end
	local total = 0
	for _, ids in pairs_of do
		total += #world.query(ids[1], ids[2]):archetypes()
	end
	print(`    (2 random terms match {total / 50} archetypes on average)`)

	bench.run("50 x (X, Y) random terms", 20, function()
		for _, ids in pairs_of do
			world.query(ids[1], ids[2]):archetypes()
		end
	end)
	bench.run("50 x (X, Y, Z) random terms", 20, function()
		for _, ids in triples_of do
			world.query(ids[1], ids[2], ids[3]):archetypes()
		end
	end)
	bench.run("50 x (X) without (Y, Z) random terms", 20, function()
		for _, ids in triples_of do
			world.query(ids[1]):without(ids[2], ids[3]):archetypes()
		end
	end)
end

bench.title "archetype match: single match call"

do
	local world, c, entities = setup_narrow()
	local internal: any = world.internal
	local get_entity_record = internal.get_entity_record

	local hit = get_entity_record(entities[6]).archetype -- A B C (Rel, t3)
	local miss_second = get_entity_record(entities[2]).archetype -- A B (Rel, t3)
	local miss_first = get_entity_record(entities[3]).archetype -- A C (Rel, t4)
	local pair_3 = ecs.pair(c.Rel, c.targets[3])

	local function matcher(with_ids: { any }, without_ids: { any }?): (any) -> boolean
		if internal.ARCHETYPE_MATCHER_NEW then
			return internal.ARCHETYPE_MATCHER_MATCH(internal.ARCHETYPE_MATCHER_NEW(with_ids, without_ids))
		end
		local MATCH_ARCHETYPE = internal.MATCH_ARCHETYPE
		return function(archetype)
			return MATCH_ARCHETYPE(with_ids, without_ids, archetype)
		end
	end

	local ITERATIONS = 1_000_000
	local bc = matcher { c.B, c.C }
	local bc_without_d = matcher({ c.B, c.C }, { c.D })
	local b_pair = matcher { c.B, pair_3 }
	local b_without_pair = matcher({ c.B }, { pair_3 })

	bench.run("(B, C) hit", ITERATIONS, function()
		bc(hit)
	end)
	bench.run("(B, C) miss on C", ITERATIONS, function()
		bc(miss_second)
	end)
	bench.run("(B, C) miss on B", ITERATIONS, function()
		bc(miss_first)
	end)
	bench.run("(B, C) without (D) hit", ITERATIONS, function()
		bc_without_d(hit)
	end)
	bench.run("(B, pair) hit", ITERATIONS, function()
		b_pair(hit)
	end)
	bench.run("(B, pair) miss on pair", ITERATIONS, function()
		b_pair(miss_first)
	end)
	bench.run("(B) without (pair) hit", ITERATIONS, function()
		b_without_pair(miss_first)
	end)
	bench.run("(B) without (pair) miss", ITERATIONS, function()
		b_without_pair(hit)
	end)
end
