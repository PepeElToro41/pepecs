--!nonstrict

local testlib = require "./testlib"
local ecs = require "../src/"

local expect = testlib.expect
local plan = testlib.plan()
local TEST, CASE = plan.TEST, plan.CASE

-- helpers -------------------------------------------------------------------

local function collect(iter: any): { any }
	local out = {}
	for entity in iter do
		table.insert(out, entity)
	end
	return out
end

local function sorted(list: { any }): { any }
	local copy = table.clone(list)
	table.sort(copy)
	return copy
end

local function count_keys(map: { [any]: any }): number
	local n = 0
	for _ in map do
		n += 1
	end
	return n
end

local function with_components(world: ecs.World, entity: ecs.Entity, n: number): { ecs.Component<number> }
	local ids = {}
	for i = 1, n do
		local c = world.component()
		ids[i] = c
		world.set(entity, c, i * 10)
	end
	return ids
end

-- id helpers -------------------------------------------------------------------

TEST("id helpers", function()
	CASE("ecs.pair packs relation and target and unpacks with PAIR_FIRST / PAIR_SECOND", function()
		local world = ecs.world()
		local R = world.tag()
		local T = world.entity()
		local pair = ecs.pair(R, T)

		expect(ecs.is_pair(pair)).to.equal(true)
		expect(ecs.is_pair(R)).to.equal(false)
		expect(ecs.is_pair(T)).to.equal(false)
		expect(ecs.PAIR_FIRST(pair)).to.equal(R)
		expect(ecs.PAIR_SECOND(pair)).to.equal(T)
	end)

	CASE("ecs.pair strips generations from both ids", function()
		local world = ecs.world()
		local internal = world.internal
		local R = world.tag()
		local T = world.entity()

		local T_gen = internal.APPEND_GENERATION(T, 3)
		expect(ecs.pair(R, T_gen)).to.equal(ecs.pair(R, T))
		expect(ecs.PAIR_SECOND(ecs.pair(R, T_gen) :: any)).to.equal(T)
	end)

	CASE("ENTITY_ID / ENTITY_GENERATION / APPEND_GENERATION round trip", function()
		local internal = ecs.world().internal
		local id = 1234
		local with_gen = internal.APPEND_GENERATION(id, 7)

		expect(with_gen).never.to.equal(id)
		expect(internal.ENTITY_ID(with_gen)).to.equal(id)
		expect(internal.ENTITY_GENERATION(with_gen)).to.equal(7)
		expect(internal.ENTITY_GENERATION(id)).to.equal(0)
	end)

	CASE("INCREMENT_GENERATION bumps the generation and wraps at GENERATION_MASK", function()
		local internal = ecs.world().internal
		local id = 42

		local gen1 = internal.INCREMENT_GENERATION(id)
		expect(internal.ENTITY_ID(gen1)).to.equal(id)
		expect(internal.ENTITY_GENERATION(gen1)).to.equal(1)

		local gen2 = internal.INCREMENT_GENERATION(gen1)
		expect(internal.ENTITY_GENERATION(gen2)).to.equal(2)

		local last = internal.APPEND_GENERATION(id, internal.GENERATION_MASK - 1)
		expect(internal.INCREMENT_GENERATION(last)).to.equal(id)
	end)

	CASE("FIND_INSERT returns the sorted insert position, -1 for duplicates", function()
		local internal = ecs.world().internal
		local ids = { 2, 4, 6 }

		expect(internal.FIND_INSERT(ids, 1)).to.equal(1)
		expect(internal.FIND_INSERT(ids, 3)).to.equal(2)
		expect(internal.FIND_INSERT(ids, 5)).to.equal(3)
		expect(internal.FIND_INSERT(ids, 7)).to.equal(4)
		expect(internal.FIND_INSERT(ids, 4)).to.equal(-1)
		expect(internal.FIND_INSERT({}, 4)).to.equal(1)
	end)

	CASE("HASH_IDS joins ids with dashes", function()
		local internal = ecs.world().internal
		expect(internal.HASH_IDS { 1, 2, 3 }).to.equal "1-2-3"
		expect(internal.HASH_IDS {}).to.equal ""
	end)

	CASE("REMOVE_ALL_PAIRS removes a contiguous range of ids", function()
		local internal = ecs.world().internal
		local ids = { 1, 2, 3, 4, 5 }

		expect(internal.REMOVE_ALL_PAIRS(ids, 5, 2, 2)).to.equal { 1, 4, 5 }
		expect(internal.REMOVE_ALL_PAIRS(ids, 5, 1, 2)).to.equal { 3, 4, 5 }
		expect(internal.REMOVE_ALL_PAIRS(ids, 5, 4, 2)).to.equal { 1, 2, 3 }
		expect(internal.REMOVE_ALL_PAIRS(ids, 5, 1, 5)).to.equal {}
	end)

	CASE("INSERT_COMPONENT_HOOK creates the list, appends, and disconnects", function()
		local internal = ecs.world().internal
		local a = function() end
		local b = function() end

		local hooks, disconnect_a = internal.INSERT_COMPONENT_HOOK(a, nil)
		expect(hooks).to.equal { a }

		local hooks2, disconnect_b = internal.INSERT_COMPONENT_HOOK(b, hooks)
		expect(hooks2).to.equal(hooks)
		expect(#hooks).to.equal(2)

		disconnect_a()
		expect(hooks).to.equal { b }
		disconnect_a()
		expect(hooks).to.equal { b }
		disconnect_b()
		expect(#hooks).to.equal(0)
	end)

	CASE("ecs.World.new is an alias of ecs.world", function()
		expect(ecs.World.new).to.equal(ecs.world)
	end)
end)

-- entities -------------------------------------------------------------------

TEST("entities", function()
	CASE("a new entity exists, is alive, is not deleting and lives in the root archetype", function()
		local world = ecs.world()
		local e = world.entity()

		expect(world.exists(e)).to.equal(true)
		expect(world.alive(e)).to.equal(true)
		expect(world.deleting(e)).to.equal(false)

		local record = world.internal.get_entity_record(e)
		expect(record).to.exist()
		expect((record :: any).archetype).to.equal(world.ROOT_ARCHETYPE)
	end)

	CASE("unknown ids do not exist and are not alive", function()
		local world = ecs.world()
		expect(world.exists(10 ^ 6)).to.equal(false)
		expect(world.alive(10 ^ 6)).to.equal(false)
		expect(world.deleting(10 ^ 6)).to.equal(false)
	end)

	CASE("entities are distinct and the alive count grows", function()
		local world = ecs.world()
		local alive_before = world.internal.entity_index.alive

		local a = world.entity()
		local b = world.entity()
		expect(a).never.to.equal(b)
		expect(world.internal.entity_index.alive).to.equal(alive_before + 2)

		world.delete(a)
		expect(world.internal.entity_index.alive).to.equal(alive_before + 1)
	end)

	CASE("delete makes the entity dead", function()
		local world = ecs.world()
		local e = world.entity()
		world.delete(e)

		expect(world.exists(e)).to.equal(false)
		expect(world.alive(e)).to.equal(false)
		expect(world.internal.get_entity_record_alive(e)).to.beNil()
		expect(world.internal.get_entity_alive(world.internal.ENTITY_ID(e))).to.beNil()
	end)

	CASE("using a dead entity errors for asserting operations and no-ops for the rest", function()
		local world = ecs.world()
		local A = world.component()
		local e = world.entity()
		world.set(e, A, 1)
		world.delete(e)

		expect(function()
			world.has(e, A)
		end).to.throw "attempted to use a dead entity"
		expect(function()
			world.get(e, A)
		end).to.throw "attempted to use a dead entity"
		expect(function()
			world.add(e, A)
		end).to.throw "attempted to use a dead entity"
		expect(function()
			world.delete(e)
		end).to.throw "attempted to use a dead entity"
		expect(function()
			world.clear(e)
		end).to.throw "attempted to use a dead entity"
		expect(function()
			world.bulk_add(e, { A })
		end).to.throw "attempted to use a dead entity"

		-- set / remove silently ignore dead entities
		expect(function()
			world.set(e, A, 2)
			world.remove(e, A)
		end).never.to.throw()
	end)

	CASE("deleted ids are recycled with a new generation", function()
		local world = ecs.world()
		local internal = world.internal
		local A = world.component()

		local old = world.entity()
		world.delete(old)
		local recycled = world.entity()

		expect(recycled).never.to.equal(old)
		expect(internal.ENTITY_ID(recycled)).to.equal(internal.ENTITY_ID(old))
		expect(internal.ENTITY_GENERATION(recycled)).to.equal(internal.ENTITY_GENERATION(old) + 1)

		expect(world.exists(old)).to.equal(false)
		expect(world.exists(recycled)).to.equal(true)
		expect(internal.get_entity_any(internal.ENTITY_ID(old))).to.equal(recycled)

		expect(function()
			world.add(old, A)
		end).to.throw "attempted to use an entity with a different generation"
	end)

	CASE("deleting an entity in the middle of the dense array keeps the index consistent", function()
		local world = ecs.world()
		local internal = world.internal
		local a = world.entity()
		local b = world.entity()
		local c = world.entity()

		world.delete(b)

		for _, e in { a, c } do
			local record = internal.get_entity_record(e) :: any
			expect(internal.entity_index.dense[record.dense]).to.equal(e)
			expect(world.alive(e)).to.equal(true)
		end

		local record_b = internal.get_entity_record(b) :: any
		expect(record_b.dense).to.be.greaterThan(internal.entity_index.alive)
	end)

	CASE("get_new_entity_id / delete_entity_id manage the sparse set directly", function()
		local world = ecs.world()
		local internal = world.internal
		local index = internal.entity_index

		local alive = index.alive
		local id = internal.get_new_entity_id()
		expect(index.alive).to.equal(alive + 1)
		expect(index.dense[index.alive]).to.equal(id)

		local record = internal.get_entity_record(id) :: any
		internal.delete_entity_id(id, record)
		expect(index.alive).to.equal(alive)
		expect(index.dense[record.dense]).to.equal(internal.INCREMENT_GENERATION(id))
	end)

	CASE("deleting is true while the entity is being torn down", function()
		local world = ecs.world()
		local A = world.tag()
		local e = world.entity()
		world.add(e, A)

		local seen_deleting, seen_alive, seen_exists = nil, nil, nil
		world.removed(A, function(entity)
			seen_deleting = world.deleting(entity)
			seen_alive = world.alive(entity)
			seen_exists = world.exists(entity)
		end)

		world.delete(e)
		expect(seen_deleting).to.equal(true)
		expect(seen_alive).to.equal(false)
		expect(seen_exists).to.equal(true)
		expect(world.deleting(e)).to.equal(false)
	end)

	CASE("deleting an entity from inside its own removal errors", function()
		local world = ecs.world()
		local A = world.tag()
		local e = world.entity()
		world.add(e, A)

		world.removed(A, function(entity)
			world.delete(entity)
		end)

		expect(function()
			world.delete(e)
		end).to.throw "attempted to destroy an entity twice"
	end)

	CASE("deleting an entity releases its archetype row for other entities", function()
		local world = ecs.world()
		local A = world.component()
		local e1 = world.entity()
		local e2 = world.entity()
		local e3 = world.entity()
		world.set(e1, A, 1)
		world.set(e2, A, 2)
		world.set(e3, A, 3)

		world.delete(e1)
		expect(world.get(e2, A)).to.equal(2)
		expect(world.get(e3, A)).to.equal(3)
		expect(world.query(A):count()).to.equal(2)
	end)
end)

-- tags and components -------------------------------------------------------------------

TEST("tags and components", function()
	CASE("world.tag creates a tag and world.component creates a component", function()
		local world = ecs.world()
		local T = world.tag()
		local C = world.component()

		expect(world.is_tag(T)).to.equal(true)
		expect(world.is_component(T)).to.equal(false)
		expect(world.is_component(C)).to.equal(true)
		expect(world.is_tag(C)).to.equal(false)
	end)

	CASE("tags hold no data", function()
		local world = ecs.world()
		local T = world.tag()
		local e = world.entity()
		world.add(e, T)

		expect(world.has(e, T)).to.equal(true)
		expect(world.get(e, T)).to.beNil()

		local record = world.internal.get_entity_record(e) :: any
		expect(table.isfrozen(record.archetype.columns_map[T])).to.equal(true)
	end)

	CASE("pair component-ness follows the relation, then the target, unless ForceTag", function()
		local world = ecs.world()
		local C = world.component()
		local T = world.tag()
		local FT = world.tag()
		world.add(FT, ecs.ForceTag)
		local target = world.entity()

		expect(world.is_component(ecs.pair(C, target))).to.equal(true)
		expect(world.is_component(ecs.pair(T, target))).to.equal(false)
		expect(world.is_component(ecs.pair(T, C))).to.equal(true)
		expect(world.is_component(ecs.pair(FT, C))).to.equal(false)
		expect(world.internal.check_is_component(T, C)).to.equal(true)
		expect(world.internal.check_is_component(FT, C)).to.equal(false)
	end)

	CASE("is_component uses the record flags once a record exists", function()
		local world = ecs.world()
		local C = world.component()
		local e = world.entity()
		world.set(e, C, 1)

		local record = world.components_lookup[C]
		expect(record).to.exist()
		expect(world.is_component(C)).to.equal(true)
	end)

	CASE("is_component is false for a pair whose ids are dead", function()
		local world = ecs.world()
		local C = world.component()
		local target = world.entity()
		local pair = ecs.pair(C, target)
		world.delete(target)

		expect(world.is_component(pair)).to.equal(false)
	end)

	CASE("builtin entities carry names", function()
		local world = ecs.world()
		expect(world.get(ecs.ChildOf, ecs.Name)).to.equal "ecs.ChildOf"
		expect(world.get(ecs.Wildcard, ecs.Name)).to.equal "ecs.Wildcard"
		expect(world.get(ecs.Name, ecs.Name)).to.equal "ecs.Name"
		expect(world.is_component(ecs.Name)).to.equal(true)
	end)

	CASE("exceeding the max component id errors", function()
		local world = ecs.world()
		expect(function()
			for _ = 1, world.internal.MAX_COMPONENT_ID + 1 do
				world.tag()
			end
		end).to.throw "max components exceeded"
	end)
end)

-- add / set / get / has / remove -------------------------------------------------------------------

TEST("add / set / get / has / remove", function()
	CASE("add then has, add is idempotent", function()
		local world = ecs.world()
		local A = world.tag()
		local e = world.entity()

		expect(world.has(e, A)).to.equal(false)
		world.add(e, A)
		expect(world.has(e, A)).to.equal(true)

		local record = world.internal.get_entity_record(e) :: any
		local archetype = record.archetype
		world.add(e, A)
		expect(record.archetype).to.equal(archetype)
		expect(#archetype.entities).to.equal(1)
	end)

	CASE("set stores and overwrites values", function()
		local world = ecs.world()
		local A = world.component()
		local e = world.entity()

		world.set(e, A, "first")
		expect(world.get(e, A)).to.equal "first"
		world.set(e, A, "second")
		expect(world.get(e, A)).to.equal "second"
		expect(world.has(e, A)).to.equal(true)
	end)

	CASE("get returns nil for a missing component or an empty entity", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local e = world.entity()

		expect(world.get(e, A)).to.beNil()
		world.set(e, A, 1)
		expect(world.get(e, B)).to.beNil()
		expect(select("#", world.get(e, A, B))).to.equal(2)
	end)

	CASE("get returns every requested component for 1 to 10 terms", function()
		for n = 1, 10 do
			local world = ecs.world()
			local e = world.entity()
			local ids = with_components(world, e, n)

			local values = { (world.get :: any)(e, unpack(ids)) }
			expect(#values).to.equal(n)
			for i = 1, n do
				expect(values[i]).to.equal(i * 10)
			end
		end
	end)

	CASE("get with a missing term in the middle returns nil in that position", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local C = world.component()
		local e = world.entity()
		world.set(e, A, 1)
		world.set(e, C, 3)

		local a, b, c = world.get(e, A, B, C)
		expect(a).to.equal(1)
		expect(b).to.beNil()
		expect(c).to.equal(3)
	end)

	CASE("remove drops the component and keeps the rest", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local e = world.entity()
		world.set(e, A, 1)
		world.set(e, B, 2)

		world.remove(e, A)
		expect(world.has(e, A)).to.equal(false)
		expect(world.get(e, A)).to.beNil()
		expect(world.get(e, B)).to.equal(2)
	end)

	CASE("removing the last component moves the entity back to the root archetype", function()
		local world = ecs.world()
		local A = world.component()
		local e = world.entity()
		world.set(e, A, 1)
		world.remove(e, A)

		local record = world.internal.get_entity_record(e) :: any
		expect(record.archetype).to.equal(world.ROOT_ARCHETYPE)
		expect(record.archetype_row).to.equal(-1)
		expect(world.alive(e)).to.equal(true)
	end)

	CASE("removing a component the entity does not have is a no-op", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local e = world.entity()
		world.set(e, A, 1)

		local fired = 0
		world.removed(B, function()
			fired += 1
		end)

		world.remove(e, B)
		expect(fired).to.equal(0)
		expect(world.get(e, A)).to.equal(1)
	end)

	CASE("swap-removing a row keeps other entities' data intact", function()
		local world = ecs.world()
		local A = world.component()
		local e1 = world.entity()
		local e2 = world.entity()
		local e3 = world.entity()
		world.set(e1, A, 1)
		world.set(e2, A, 2)
		world.set(e3, A, 3)

		world.remove(e1, A)
		expect(world.get(e2, A)).to.equal(2)
		expect(world.get(e3, A)).to.equal(3)

		world.set(e3, A, 33)
		expect(world.get(e2, A)).to.equal(2)
		expect(world.get(e3, A)).to.equal(33)
	end)

	CASE("moving between archetypes preserves existing values", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local C = world.tag()
		local e = world.entity()

		world.set(e, A, 1)
		world.set(e, B, 2)
		world.add(e, C)
		expect(world.get(e, A, B)).to.equal(1)
		local a, b = world.get(e, A, B)
		expect(a).to.equal(1)
		expect(b).to.equal(2)
		expect(world.has(e, C)).to.equal(true)
	end)

	CASE("archetype components are kept sorted regardless of insertion order", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e1 = world.entity()
		local e2 = world.entity()

		world.add(e1, B)
		world.add(e1, A)
		world.add(e2, A)
		world.add(e2, B)

		local r1 = world.internal.get_entity_record(e1) :: any
		local r2 = world.internal.get_entity_record(e2) :: any
		expect(r1.archetype).to.equal(r2.archetype)
		expect(r1.archetype.components).to.equal { A, B }
		expect(world.archetypes_lookup[world.internal.HASH_IDS { A, B }]).to.equal(r1.archetype)
	end)

	CASE("archetype alive flag follows its entity count", function()
		local world = ecs.world()
		local A = world.tag()
		local e = world.entity()
		world.add(e, A)

		local archetype = (world.internal.get_entity_record(e) :: any).archetype
		expect(archetype.alive).to.equal(true)
		world.remove(e, A)
		expect(archetype.alive).to.equal(false)
		world.add(e, A)
		expect(archetype.alive).to.equal(true)
	end)
end)

-- hooks -------------------------------------------------------------------

TEST("hooks", function()
	CASE("added fires on set with the value and on add with nil", function()
		local world = ecs.world()
		local A = world.component()
		local T = world.tag()
		local e = world.entity()

		local calls = {}
		world.added(A, function(entity, id, value)
			table.insert(calls, { entity, id, value })
		end)
		world.added(T, function(entity, id, value)
			table.insert(calls, { entity, id, value })
		end)

		world.set(e, A, 5)
		world.add(e, T)
		world.set(e, A, 6)

		expect(#calls).to.equal(2)
		expect(calls[1]).to.equal { e, A, 5 }
		expect(calls[2][1]).to.equal(e)
		expect(calls[2][2]).to.equal(T)
		expect(calls[2][3]).to.beNil()
	end)

	CASE("the new value is readable inside the added hook", function()
		local world = ecs.world()
		local A = world.component()
		local e = world.entity()

		local seen = nil
		world.added(A, function(entity, id)
			seen = world.get(entity, id)
		end)
		world.set(e, A, 9)
		expect(seen).to.equal(9)
	end)

	CASE("changed fires only when an existing component is set again", function()
		local world = ecs.world()
		local A = world.component()
		local e = world.entity()

		local calls = {}
		world.changed(A, function(entity, id, value)
			table.insert(calls, value)
		end)

		world.set(e, A, 1)
		expect(#calls).to.equal(0)
		world.set(e, A, 2)
		world.set(e, A, 3)
		expect(calls).to.equal { 2, 3 }
	end)

	CASE("removed fires before the component is gone and its post callback runs after", function()
		local world = ecs.world()
		local A = world.component()
		local e = world.entity()
		world.set(e, A, 1)

		local during, after = nil, nil
		world.removed(A, function(entity, id)
			during = { has = world.has(entity, id), value = world.get(entity, id) }
			return function()
				after = { has = world.has(entity, id), value = world.get(entity, id) }
			end
		end)

		world.remove(e, A)
		expect(during).to.equal { has = true, value = 1 }
		expect(after).to.equal { has = false }
	end)

	CASE("post removed callbacks may modify the entity", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e = world.entity()
		world.add(e, A)

		world.removed(A, function(entity)
			return function()
				world.add(entity, B)
			end
		end)

		world.remove(e, A)
		expect(world.has(e, A)).to.equal(false)
		expect(world.has(e, B)).to.equal(true)
	end)

	CASE("removed fires on delete, clear, wipe and bulk_remove", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local removed = {}
		world.removed(A, function(entity)
			table.insert(removed, entity)
		end)

		local e1 = world.entity()
		world.set(e1, A, 1)
		world.delete(e1)

		local e2 = world.entity()
		world.set(e2, A, 1)
		world.clear(e2)

		local e3 = world.entity()
		world.set(e3, A, 1)
		world.set(e3, B, 1)
		world.bulk_remove(e3, { A, B })

		local e4 = world.entity()
		world.set(e4, A, 1)
		world.wipe(A)

		expect(removed).to.equal { e1, e2, e3, e4 }
	end)

	CASE("added fires on bulk_add / bulk_set and changed fires for already present ids on bulk_set", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local added, changed = {}, {}
		world.added(A, function(_, _, value)
			table.insert(added, { "A", value })
		end)
		world.added(B, function(_, _, value)
			table.insert(added, { "B", value })
		end)
		world.changed(A, function(_, _, value)
			table.insert(changed, value)
		end)

		local e = world.entity()
		world.bulk_add(e, { A })
		world.bulk_set(e, { A, B }, { 1, 2 })

		expect(added[1][1]).to.equal "A"
		expect(added[1][2]).to.beNil()
		expect(added[2]).to.equal { "B", 2 }
		expect(#added).to.equal(2)
		expect(changed).to.equal { 1 }
	end)

	CASE("disconnecting a hook stops it and leaves the others", function()
		local world = ecs.world()
		local A = world.component()

		local first, second = 0, 0
		local disconnect = world.added(A, function()
			first += 1
		end)
		world.added(A, function()
			second += 1
		end)

		local e = world.entity()
		world.set(e, A, 1)
		disconnect()
		disconnect()

		local e2 = world.entity()
		world.set(e2, A, 1)

		expect(first).to.equal(1)
		expect(second).to.equal(2)
	end)

	CASE("hooks on a specific pair only fire for that pair", function()
		local world = ecs.world()
		local R = world.component()
		local T1 = world.entity()
		local T2 = world.entity()

		local fired = 0
		world.added(ecs.pair(R, T1), function()
			fired += 1
		end)

		local e = world.entity()
		world.set(e, ecs.pair(R, T2), 1)
		expect(fired).to.equal(0)
		world.set(e, ecs.pair(R, T1), 1)
		expect(fired).to.equal(1)
	end)

	CASE("exclusive swap fires removed for the old pair and added for the new one", function()
		local world = ecs.world()
		local R = world.component()
		world.add(R, ecs.Exclusive)
		local T1 = world.entity()
		local T2 = world.entity()

		local events = {}
		world.removed(ecs.pair(R, ecs.Wildcard), function(_, id)
			table.insert(events, { "removed", id })
		end)
		world.added(ecs.pair(R, ecs.Wildcard), function(_, id)
			table.insert(events, { "added", id })
		end)

		local e = world.entity()
		world.set(e, ecs.pair(R, T1), 1)
		world.set(e, ecs.pair(R, T2), 2)

		expect(events).to.equal {
			{ "added", ecs.pair(R, T1) },
			{ "removed", ecs.pair(R, T1) },
			{ "added", ecs.pair(R, T2) },
		}
	end)
end)

-- relationships -------------------------------------------------------------------

TEST("relationships", function()
	CASE("target returns the nth target of a relation", function()
		local world = ecs.world()
		local R = world.tag()
		local T1 = world.entity()
		local T2 = world.entity()
		local e = world.entity()

		expect(world.target(e, R)).to.beNil()
		world.add(e, ecs.pair(R, T1))
		world.add(e, ecs.pair(R, T2))

		local targets = { world.target(e, R, 0), world.target(e, R, 1) }
		expect(sorted(targets)).to.equal(sorted { T1, T2 })
		expect(world.target(e, R)).to.equal(world.target(e, R, 0))
		expect(world.target(e, R, 2)).to.beNil()
	end)

	CASE("target returns nil for unknown relations and dead entities", function()
		local world = ecs.world()
		local R = world.tag()
		local e = world.entity()
		expect(world.target(e, R)).to.beNil()
		world.delete(e)
		expect(world.target(e, R)).to.beNil()
	end)

	CASE("pairs iterates the pair ids of a relation", function()
		local world = ecs.world()
		local R = world.tag()
		local T1 = world.entity()
		local T2 = world.entity()
		local e = world.entity()
		world.add(e, ecs.pair(R, T1))
		world.add(e, ecs.pair(R, T2))

		local found = collect(world.pairs(e, R))
		expect(sorted(found)).to.equal(sorted { ecs.pair(R, T1), ecs.pair(R, T2) })
		expect(#collect(world.pairs(e, world.tag()))).to.equal(0)
		expect(#collect(world.pairs(10 ^ 6, R))).to.equal(0)
	end)

	CASE("pair_first / pair_second resolve the alive entities", function()
		local world = ecs.world()
		local R = world.tag()
		local T = world.entity()
		local pair = ecs.pair(R, T)

		expect(world.pair_first(pair)).to.equal(R)
		expect(world.pair_second(pair)).to.equal(T)

		world.delete(T)
		expect(world.pair_second(pair)).to.beNil()
	end)

	CASE("pairs with a component relation store data", function()
		local world = ecs.world()
		local R = world.component()
		local T = world.entity()
		local e = world.entity()

		world.set(e, ecs.pair(R, T), "data")
		expect(world.get(e, ecs.pair(R, T))).to.equal "data"
		expect(world.get(e, ecs.pair(R, ecs.Wildcard))).to.equal "data"
	end)

	CASE("pairs with a component target store data", function()
		local world = ecs.world()
		local R = world.tag()
		local C = world.component()
		local e = world.entity()

		world.set(e, ecs.pair(R, C), 7)
		expect(world.get(e, ecs.pair(R, C))).to.equal(7)
	end)

	CASE("exclusive relations replace the previous target", function()
		local world = ecs.world()
		local R = world.tag()
		world.add(R, ecs.Exclusive)
		local T1 = world.entity()
		local T2 = world.entity()
		local e = world.entity()

		world.add(e, ecs.pair(R, T1))
		world.add(e, ecs.pair(R, T2))

		expect(world.has(e, ecs.pair(R, T1))).to.equal(false)
		expect(world.has(e, ecs.pair(R, T2))).to.equal(true)
		expect(world.target(e, R)).to.equal(T2)
		expect(world.target(e, R, 1)).to.beNil()
		expect(#collect(world.pairs(e, R))).to.equal(1)
	end)

	CASE("exclusive set replaces the target and keeps only the new value", function()
		local world = ecs.world()
		local R = world.component()
		world.add(R, ecs.Exclusive)
		local T1 = world.entity()
		local T2 = world.entity()
		local e = world.entity()

		world.set(e, ecs.pair(R, T1), 1)
		world.set(e, ecs.pair(R, T2), 2)

		expect(world.get(e, ecs.pair(R, T1))).to.beNil()
		expect(world.get(e, ecs.pair(R, T2))).to.equal(2)
	end)

	CASE("ChildOf is exclusive and parent / children follow it", function()
		local world = ecs.world()
		local p1 = world.entity()
		local p2 = world.entity()
		local c1 = world.entity()
		local c2 = world.entity()

		expect(world.parent(c1)).to.beNil()
		world.add(c1, ecs.pair(ecs.ChildOf, p1))
		world.add(c2, ecs.pair(ecs.ChildOf, p1))
		expect(world.parent(c1)).to.equal(p1)
		expect(sorted(collect(world.children(p1)))).to.equal(sorted { c1, c2 })
		expect(#collect(world.children(p2))).to.equal(0)

		world.add(c1, ecs.pair(ecs.ChildOf, p2))
		expect(world.parent(c1)).to.equal(p2)
		expect(collect(world.children(p1))).to.equal { c2 }
		expect(collect(world.children(p2))).to.equal { c1 }
	end)

	CASE("traverse walks up a relation until it finds the component", function()
		local world = ecs.world()
		local C = world.component()
		local grandparent = world.entity()
		local parent = world.entity()
		local child = world.entity()
		world.add(parent, ecs.pair(ecs.ChildOf, grandparent))
		world.add(child, ecs.pair(ecs.ChildOf, parent))
		world.set(grandparent, C, "gp")

		local found, value = world.traverse(child, ecs.ChildOf, C)
		expect(found).to.equal(grandparent)
		expect(value).to.equal "gp"

		world.set(parent, C, "p")
		local found2, value2 = world.traverse(child, ecs.ChildOf, C)
		expect(found2).to.equal(parent)
		expect(value2).to.equal "p"
	end)

	CASE("traverse returns nil when nothing up the chain has the component", function()
		local world = ecs.world()
		local C = world.component()
		local R = world.tag()
		local parent = world.entity()
		local child = world.entity()

		expect(world.traverse(child, R, C)).to.beNil()
		world.add(child, ecs.pair(ecs.ChildOf, parent))
		expect(world.traverse(child, ecs.ChildOf, C)).to.beNil()
		world.delete(child)
		expect(world.traverse(child, ecs.ChildOf, C)).to.beNil()
	end)
end)

-- deletion cascades -------------------------------------------------------------------

TEST("deletion cascades", function()
	CASE("deleting a target removes its pairs from holders when the relation has no OnDeleteTarget", function()
		local world = ecs.world()
		local R = world.tag()
		local A = world.component()
		local T = world.entity()
		local e = world.entity()
		world.set(e, A, 1)
		world.add(e, ecs.pair(R, T))

		local archetype = (world.internal.get_entity_record(e) :: any).archetype
		world.delete(T)

		expect(world.alive(e)).to.equal(true)
		expect(world.has(e, ecs.pair(R, T))).to.equal(false)
		expect(world.get(e, A)).to.equal(1)
		expect(archetype.destroyed).to.equal(true)
		expect(world.archetypes[archetype.archetype_id]).to.beNil()
		expect(world.components_lookup[ecs.pair(R, T)]).to.beNil()
		expect(world.components_lookup[ecs.pair(ecs.Wildcard, T)]).to.beNil()
	end)

	CASE("deleting a target removes several pairs pointing at it at once", function()
		local world = ecs.world()
		local R1 = world.tag()
		local R2 = world.tag()
		local A = world.component()
		local T = world.entity()
		local e = world.entity()
		world.set(e, A, 1)
		world.add(e, ecs.pair(R1, T))
		world.add(e, ecs.pair(R2, T))

		world.delete(T)
		expect(world.has(e, ecs.pair(R1, T))).to.equal(false)
		expect(world.has(e, ecs.pair(R2, T))).to.equal(false)
		expect(world.get(e, A)).to.equal(1)
	end)

	CASE("OnDeleteTarget + Delete deletes holders recursively", function()
		local world = ecs.world()
		local R = world.tag()
		world.add(R, ecs.pair(ecs.OnDeleteTarget, ecs.Delete))
		local root = world.entity()
		local mid = world.entity()
		local leaf = world.entity()
		local bystander = world.entity()
		world.add(mid, ecs.pair(R, root))
		world.add(leaf, ecs.pair(R, mid))

		world.delete(root)
		expect(world.alive(root)).to.equal(false)
		expect(world.alive(mid)).to.equal(false)
		expect(world.alive(leaf)).to.equal(false)
		expect(world.alive(bystander)).to.equal(true)
	end)

	CASE("ChildOf deletes children when the parent is deleted", function()
		local world = ecs.world()
		local parent = world.entity()
		local child = world.entity()
		local grandchild = world.entity()
		world.add(child, ecs.pair(ecs.ChildOf, parent))
		world.add(grandchild, ecs.pair(ecs.ChildOf, child))

		world.delete(parent)
		expect(world.alive(child)).to.equal(false)
		expect(world.alive(grandchild)).to.equal(false)
	end)

	CASE("ChildOf cycles are torn down without recursion errors", function()
		local world = ecs.world()
		local a = world.entity()
		local b = world.entity()
		world.add(a, ecs.pair(ecs.ChildOf, b))
		world.add(b, ecs.pair(ecs.ChildOf, a))

		local removed = {}
		world.removed(ecs.pair(ecs.ChildOf, ecs.Wildcard), function(entity)
			table.insert(removed, entity)
		end)

		expect(function()
			world.delete(a)
		end).never.to.throw()
		expect(world.alive(a)).to.equal(false)
		expect(world.alive(b)).to.equal(false)
		expect(sorted(removed)).to.equal(sorted { a, b })
		expect(world.components_lookup[ecs.pair(ecs.ChildOf, a)]).to.beNil()
		expect(world.components_lookup[ecs.pair(ecs.ChildOf, b)]).to.beNil()
	end)

	CASE("longer cycles and extra components are torn down", function()
		local world = ecs.world()
		local A = world.component()
		local a = world.entity()
		local b = world.entity()
		local c = world.entity()
		world.add(a, ecs.pair(ecs.ChildOf, b))
		world.add(b, ecs.pair(ecs.ChildOf, c))
		world.add(c, ecs.pair(ecs.ChildOf, a))
		world.set(a, A, 1)
		world.set(b, A, 2)
		world.set(c, A, 3)

		local removed = {}
		world.removed(A, function(entity)
			table.insert(removed, entity)
		end)

		world.delete(b)
		expect(world.alive(a)).to.equal(false)
		expect(world.alive(b)).to.equal(false)
		expect(world.alive(c)).to.equal(false)
		expect(sorted(removed)).to.equal(sorted { a, b, c })
		expect(world.query(A):count()).to.equal(0)
	end)

	CASE("an entity that is its own parent can be deleted", function()
		local world = ecs.world()
		local A = world.component()
		local e = world.entity()
		world.add(e, ecs.pair(ecs.ChildOf, e))
		world.set(e, A, 1)

		local other = world.entity()
		world.set(other, A, 2)

		expect(function()
			world.delete(e)
		end).never.to.throw()
		expect(world.alive(e)).to.equal(false)
		expect(world.get(other, A)).to.equal(2)
		expect(world.components_lookup[ecs.pair(ecs.ChildOf, e)]).to.beNil()
	end)

	CASE("self pairs on a relation with OnDelete + Delete can be deleted", function()
		local world = ecs.world()
		local R = world.tag()
		world.add(R, ecs.pair(ecs.OnDelete, ecs.Delete))
		local e = world.entity()
		world.add(e, ecs.pair(R, e))
		world.add(R, ecs.pair(R, R))

		expect(function()
			world.delete(e)
		end).never.to.throw()
		expect(world.alive(e)).to.equal(false)

		expect(function()
			world.delete(R)
		end).never.to.throw()
		expect(world.alive(R)).to.equal(false)
	end)

	CASE("pair cycles without delete traits only strip the pairs", function()
		local world = ecs.world()
		local R = world.tag()
		local a = world.entity()
		local b = world.entity()
		world.add(a, ecs.pair(R, b))
		world.add(b, ecs.pair(R, a))

		world.delete(a)
		expect(world.alive(a)).to.equal(false)
		expect(world.alive(b)).to.equal(true)
		expect(world.has(b, ecs.pair(R, a))).to.equal(false)
	end)

	CASE("deleting a relation removes every pair using it", function()
		local world = ecs.world()
		local R = world.tag()
		local A = world.component()
		local T1 = world.entity()
		local T2 = world.entity()
		local e = world.entity()
		local only_pairs = world.entity()
		world.set(e, A, 1)
		world.add(e, ecs.pair(R, T1))
		world.add(e, ecs.pair(R, T2))
		world.add(only_pairs, ecs.pair(R, T1))
		world.add(only_pairs, ecs.pair(R, T2))

		world.delete(R)
		expect(world.alive(e)).to.equal(true)
		expect(world.has(e, ecs.pair(R, T1))).to.equal(false)
		expect(world.has(e, ecs.pair(R, T2))).to.equal(false)
		expect(world.get(e, A)).to.equal(1)
		expect((world.internal.get_entity_record(only_pairs) :: any).archetype).to.equal(world.ROOT_ARCHETYPE)
		expect(world.components_lookup[ecs.pair(R, ecs.Wildcard)]).to.beNil()
	end)

	CASE("OnDelete + Delete on a relation deletes holders", function()
		local world = ecs.world()
		local R = world.tag()
		world.add(R, ecs.pair(ecs.OnDelete, ecs.Delete))
		local T = world.entity()
		local e = world.entity()
		world.add(e, ecs.pair(R, T))

		world.delete(R)
		expect(world.alive(e)).to.equal(false)
		expect(world.alive(T)).to.equal(true)
	end)

	CASE("deleting a component id removes it from every entity", function()
		local world = ecs.world()
		local C = world.component()
		local A = world.component()
		local e = world.entity()
		world.set(e, C, 1)
		world.set(e, A, 2)

		world.delete(C)
		expect(world.alive(e)).to.equal(true)
		expect(world.has(e, C)).to.equal(false)
		expect(world.get(e, A)).to.equal(2)
		expect(world.components_lookup[C]).to.beNil()
	end)

	CASE("OnDelete + Delete on a component id deletes its holders", function()
		local world = ecs.world()
		local C = world.tag()
		world.add(C, ecs.pair(ecs.OnDelete, ecs.Delete))
		local e = world.entity()
		local other = world.entity()
		world.add(e, C)

		world.delete(C)
		expect(world.alive(e)).to.equal(false)
		expect(world.alive(other)).to.equal(true)
	end)

	CASE("delete fires removed hooks for every component of the entity", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.tag()
		local e = world.entity()
		world.set(e, A, 1)
		world.add(e, B)

		local removed = {}
		world.removed(A, function(_, id)
			table.insert(removed, id)
		end)
		world.removed(B, function(_, id)
			table.insert(removed, id)
		end)

		world.delete(e)
		expect(sorted(removed)).to.equal(sorted { A, B })
	end)
end)

-- clear / wipe / bulk -------------------------------------------------------------------

TEST("clear / wipe / bulk operations", function()
	CASE("clear removes every component but keeps the entity alive", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.tag()
		local e = world.entity()
		world.set(e, A, 1)
		world.add(e, B)

		world.clear(e)
		expect(world.alive(e)).to.equal(true)
		expect(world.has(e, A)).to.equal(false)
		expect(world.has(e, B)).to.equal(false)
		expect((world.internal.get_entity_record(e) :: any).archetype).to.equal(world.ROOT_ARCHETYPE)

		expect(function()
			world.clear(e)
		end).never.to.throw()
	end)

	CASE("wipe removes a component from every entity", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local e1 = world.entity()
		local e2 = world.entity()
		world.set(e1, A, 1)
		world.set(e2, A, 2)
		world.set(e2, B, 3)

		world.wipe(A)
		expect(world.has(e1, A)).to.equal(false)
		expect(world.has(e2, A)).to.equal(false)
		expect(world.get(e2, B)).to.equal(3)
		expect(world.query(A):count()).to.equal(0)

		expect(function()
			world.wipe(world.component())
		end).never.to.throw()
	end)

	CASE("bulk_add from the root archetype adds every id in one move", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local C = world.tag()
		local e = world.entity()

		world.bulk_add(e, { C, A, B })
		expect(world.has(e, A)).to.equal(true)
		expect(world.has(e, B)).to.equal(true)
		expect(world.has(e, C)).to.equal(true)
		expect((world.internal.get_entity_record(e) :: any).archetype.components).to.equal { A, B, C }
	end)

	CASE("bulk_add on an existing archetype only adds the missing ids", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.tag()
		local C = world.tag()
		local e = world.entity()
		world.set(e, A, 1)

		local added = 0
		world.added(A, function()
			added += 1
		end)

		world.bulk_add(e, { A, C, B })
		expect(added).to.equal(0)
		expect(world.get(e, A)).to.equal(1)
		expect((world.internal.get_entity_record(e) :: any).archetype.components).to.equal { A, B, C }

		local archetype = (world.internal.get_entity_record(e) :: any).archetype
		world.bulk_add(e, { A, B })
		expect((world.internal.get_entity_record(e) :: any).archetype).to.equal(archetype)
	end)

	CASE("bulk_set from the root archetype sets every value", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local e = world.entity()

		world.bulk_set(e, { B, A }, { "b", "a" })
		expect(world.get(e, A)).to.equal "a"
		expect(world.get(e, B)).to.equal "b"
	end)

	CASE("bulk_set on an existing archetype adds new ids and overwrites present ones", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local e = world.entity()
		world.set(e, A, 1)

		world.bulk_set(e, { A, B }, { 10, 20 })
		expect(world.get(e, A)).to.equal(10)
		expect(world.get(e, B)).to.equal(20)

		world.bulk_set(e, { A }, { 11 })
		expect(world.get(e, A)).to.equal(11)
		expect(world.get(e, B)).to.equal(20)
	end)

	CASE("bulk_set with nil clears the stored value", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local e = world.entity()
		world.set(e, A, 1)
		world.set(e, B, 2)

		world.bulk_set(e, { A, B }, { nil, 3 })
		expect(world.get(e, A)).to.beNil()
		expect(world.has(e, A)).to.equal(true)
		expect(world.get(e, B)).to.equal(3)
	end)

	CASE("bulk_remove removes the present ids and ignores the rest", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local C = world.component()
		local e = world.entity()
		world.set(e, A, 1)
		world.set(e, B, 2)

		world.bulk_remove(e, { A, C })
		expect(world.has(e, A)).to.equal(false)
		expect(world.get(e, B)).to.equal(2)

		world.bulk_remove(e, { B })
		expect((world.internal.get_entity_record(e) :: any).archetype).to.equal(world.ROOT_ARCHETYPE)
		expect(world.alive(e)).to.equal(true)

		expect(function()
			world.bulk_remove(e, { A })
		end).never.to.throw()
	end)

	CASE("bulk_remove with no matching ids leaves the entity untouched", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local e = world.entity()
		world.set(e, A, 1)

		local fired = 0
		world.removed(A, function()
			fired += 1
		end)

		world.bulk_remove(e, { B })
		expect(fired).to.equal(0)
		expect(world.get(e, A)).to.equal(1)
	end)
end)

-- each -------------------------------------------------------------------

TEST("world.each", function()
	CASE("iterates every entity with the id across archetypes", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e1 = world.entity()
		local e2 = world.entity()
		local e3 = world.entity()
		world.add(e1, A)
		world.add(e2, A)
		world.add(e2, B)
		world.add(e3, B)

		expect(sorted(collect(world.each(A)))).to.equal(sorted { e1, e2 })
		expect(collect(world.each(world.tag()))).to.equal {}
	end)

	CASE("skips archetypes that became empty", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e1 = world.entity()
		local e2 = world.entity()
		world.add(e1, A)
		world.add(e2, A)
		world.add(e2, B)
		world.remove(e2, B)
		world.remove(e2, A)

		expect(collect(world.each(A))).to.equal { e1 }
	end)
end)

-- queries -------------------------------------------------------------------

TEST("query iteration", function()
	CASE("iterates entities and values for 1 to 10 terms", function()
		for n = 1, 10 do
			local world = ecs.world()
			local e1 = world.entity()
			local ids = with_components(world, e1, n)
			local e2 = world.entity()
			for i, id in ids do
				world.set(e2, id, -i)
			end

			local seen = {}
			local iter = (world.query :: any)(unpack(ids)):iter()
			while true do
				local packed = { iter() }
				local entity = table.remove(packed, 1)
				if entity == nil then
					break
				end
				expect(#packed).to.equal(n)
				seen[entity] = packed
			end

			expect(count_keys(seen)).to.equal(2)
			for i = 1, n do
				expect(seen[e1][i]).to.equal(i * 10)
				expect(seen[e2][i]).to.equal(-i)
			end
		end
	end)

	CASE("a query with no terms only iterates with-filters", function()
		local world = ecs.world()
		local A = world.tag()
		local e1 = world.entity()
		world.entity()
		world.add(e1, A)

		local seen = collect(world.query():with(A))
		expect(seen).to.equal { e1 }
		expect(collect(world.query())).to.equal {}
	end)

	CASE("iterates across several archetypes", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.tag()
		local e1 = world.entity()
		local e2 = world.entity()
		local e3 = world.entity()
		world.set(e1, A, 1)
		world.set(e2, A, 2)
		world.add(e2, B)
		world.add(e3, B)

		local seen = {}
		for entity, a in world.query(A) do
			seen[entity] = a
		end
		expect(seen).to.equal { [e1] = 1, [e2] = 2 }
	end)

	CASE("with narrows and without excludes", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local C = world.tag()
		local ab = world.entity()
		local abc = world.entity()
		local a = world.entity()
		world.bulk_add(ab, { A, B })
		world.bulk_add(abc, { A, B, C })
		world.add(a, A)

		expect(sorted(collect(world.query():with(A, B)))).to.equal(sorted { ab, abc })
		expect(collect(world.query():with(A):without(B))).to.equal { a }
		expect(collect(world.query():with(A, B):without(C))).to.equal { ab }
		expect(collect(world.query():with(A):without(B):without(C))).to.equal { a }
	end)

	CASE("iterating wildcard pairs yields the pair column value", function()
		local world = ecs.world()
		local R = world.component()
		local T = world.entity()
		local e = world.entity()
		world.set(e, ecs.pair(R, T), "v")

		local seen = {}
		for entity, value in world.query(ecs.pair(R, ecs.Wildcard)) do
			seen[entity] = value
		end
		expect(seen).to.equal { [e] = "v" }
		expect(collect(world.query():with(ecs.pair(ecs.Wildcard, T)))).to.equal { e }
	end)

	CASE("a query on an id that was never used iterates nothing", function()
		local world = ecs.world()
		local A = world.component()
		expect(collect(world.query(A))).to.equal {}
		expect(world.query(A):count()).to.equal(0)
		expect(world.query(A):empty()).to.equal(true)
	end)

	CASE("adding terms after the query has matched errors", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local query = world.query():with(A)
		query:count()

		expect(function()
			query:with(B)
		end).to.throw "cannot add terms to a query after it has been matched"
		expect(function()
			query:without(B)
		end).to.throw "cannot add terms to a query after it has been matched"
	end)

	CASE("clone copies the terms so the copy can be extended independently", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local a = world.entity()
		local ab = world.entity()
		world.add(a, A)
		world.bulk_add(ab, { A, B })

		local base = world.query():with(A)
		local narrowed = base:clone():without(B)

		expect(sorted(collect(base))).to.equal(sorted { a, ab })
		expect(collect(narrowed)).to.equal { a }
	end)

	CASE("a matched query does not see new archetypes until rematch", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e1 = world.entity()
		world.add(e1, A)

		local query = world.query():with(A)
		expect(query:count()).to.equal(1)

		local e2 = world.entity()
		world.bulk_add(e2, { A, B })
		expect(query:count()).to.equal(1)

		query:rematch()
		expect(query:count()).to.equal(2)
	end)

	CASE("archetypes returns only alive archetypes for a non cached query", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e = world.entity()
		world.bulk_add(e, { A, B })
		world.remove(e, B)

		local query = world.query():with(A)
		expect(#query:archetypes()).to.equal(1)
		expect(query:archetypes()[1].components).to.equal { A }
		expect(query:archetypes()).to.equal(query:archetypes())
	end)

	CASE("match reports whether an archetype satisfies the terms", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local a = world.entity()
		local ab = world.entity()
		world.add(a, A)
		world.bulk_add(ab, { A, B })

		local arch_a = (world.internal.get_entity_record(a) :: any).archetype
		local arch_ab = (world.internal.get_entity_record(ab) :: any).archetype

		local query = world.query():with(A):without(B)
		expect(query:match(arch_a)).to.equal(true)
		expect(query:match(arch_ab)).to.equal(false)
		expect(query:match(world.ROOT_ARCHETYPE)).to.equal(false)

		local cached = world.query():with(A):cached()
		expect(cached:match(arch_a)).to.equal(true)
		expect(cached:match(arch_ab)).to.equal(true)
		expect(cached:match(world.ROOT_ARCHETYPE)).to.equal(false)
	end)

	CASE("has checks a single entity against the query", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e = world.entity()
		world.add(e, A)

		local query = world.query():with(A):without(B)
		expect(query:has(e)).to.equal(true)
		world.add(e, B)
		expect(query:has(e)).to.equal(false)
		world.delete(e)
		expect(query:has(e)).to.equal(false)
		expect(query:has(10 ^ 6)).to.equal(false)
	end)

	CASE("empty, count and entities", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()

		local query = world.query():with(A)
		expect(query:empty()).to.equal(true)
		expect(query:count()).to.equal(0)
		expect(query:entities()).to.equal {}

		local e1 = world.entity()
		local e2 = world.entity()
		world.add(e1, A)
		world.bulk_add(e2, { A, B })

		local query2 = world.query():with(A)
		expect(query2:empty()).to.equal(false)
		expect(query2:count()).to.equal(2)
		expect(sorted(query2:entities())).to.equal(sorted { e1, e2 })

		world.remove(e1, A)
		world.remove(e2, A)
		expect(query2:empty()).to.equal(true)
		expect(query2:entities()).to.equal {}
	end)

	CASE("random returns nil when empty and a matching entity otherwise", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()

		expect(world.query():with(A):random()).to.beNil()

		local e1 = world.entity()
		local e2 = world.entity()
		world.add(e1, A)
		world.bulk_add(e2, { A, B })

		local query = world.query():with(A)
		for _ = 1, 20 do
			local picked = query:random()
			expect(picked == e1 or picked == e2).to.equal(true)
		end
	end)

	CASE("first returns an entity and its values", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		expect(world.query(A):first()).to.beNil()

		local e = world.entity()
		world.set(e, A, 1)
		world.set(e, B, 2)

		local entity, a, b = world.query(A, B):first()
		expect(entity).to.equal(e)
		expect(a).to.equal(1)
		expect(b).to.equal(2)
	end)

	CASE("first with a predicate returns the first match for 0 to 10 terms", function()
		for n = 0, 10 do
			local world = ecs.world()
			local e1 = world.entity()
			local ids = with_components(world, e1, n)
			local e2 = world.entity()
			for i, id in ids do
				world.set(e2, id, -i)
			end
			local marker = world.tag()
			world.add(e1, marker)
			world.add(e2, marker)

			local query = (world.query :: any)(unpack(ids)):with(marker)
			local found = {
				query:first(function(entity, ...)
					local values = { ... }
					expect(#values).to.equal(n)
					return entity == e2
				end),
			}

			expect(found[1]).to.equal(e2)
			expect(#found).to.equal(n + 1)
			for i = 1, n do
				expect(found[i + 1]).to.equal(-i)
			end

			expect(query:first(function()
				return false
			end)).to.beNil()
		end
	end)

	CASE("patch rewrites the columns for 1, 2 and 10 terms", function()
		for _, n in { 1, 2, 10 } do
			local world = ecs.world()
			local e = world.entity()
			local ids = with_components(world, e, n);
			(world.query :: any)(unpack(ids)):patch(function(entity, ...)
				local values = { ... }
				for i, value in values do
					values[i] = value + 1
				end
				return unpack(values)
			end)

			local after = { (world.get :: any)(e, unpack(ids)) }
			for i = 1, n do
				expect(after[i]).to.equal(i * 10 + 1)
			end
		end
	end)

	CASE("patch with no terms is a no-op", function()
		local world = ecs.world()
		local A = world.tag()
		local e = world.entity()
		world.add(e, A)
		expect(function()
			world.query():with(A):patch(function(entity)
				return
			end)
		end).never.to.throw()
	end)

	CASE("columns yields each archetype with its columns", function()
		local world = ecs.world()
		local A = world.component()
		local T = world.tag()
		local e1 = world.entity()
		local e2 = world.entity()
		world.set(e1, A, 1)
		world.set(e2, A, 2)
		world.add(e2, T)

		local archetype_count = 0
		local values = {}
		for archetype, a in world.query(A):columns() do
			archetype_count += 1
			expect(a).to.equal(archetype.columns_map[A])
			for _, value in a do
				table.insert(values, value)
			end
		end
		expect(archetype_count).to.equal(2)
		expect(sorted(values)).to.equal { 1, 2 }

		for archetype, a, t in world.query(A, T):columns() do
			expect(table.isfrozen(t)).to.equal(true)
			expect(#a).to.equal(1)
		end

		for archetype in world.query():with(T):columns() do
			expect(archetype.columns_map[T]).to.exist()
		end

		expect(collect(world.query(world.component()):columns())).to.equal {}
	end)

	CASE("iteration skips archetypes that became empty", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e1 = world.entity()
		local e2 = world.entity()
		world.add(e1, A)
		world.bulk_add(e2, { A, B })

		local query = world.query():with(A):cached()
		world.remove(e2, A)
		expect(collect(query)).to.equal { e1 }
	end)
end)

TEST("cached queries", function()
	CASE("cached queries pick up archetypes created later", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e1 = world.entity()
		world.add(e1, A)

		local query = world.query():with(A):cached()
		expect(query.is_cached).to.equal(true)
		expect(query:count()).to.equal(1)

		local e2 = world.entity()
		world.bulk_add(e2, { A, B })
		expect(query:count()).to.equal(2)
		expect(sorted(collect(query))).to.equal(sorted { e1, e2 })
	end)

	CASE("cached queries honor without terms for new archetypes", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()

		local query = world.query():with(A):without(B):cached()
		local e1 = world.entity()
		local e2 = world.entity()
		world.add(e1, A)
		world.bulk_add(e2, { A, B })

		expect(collect(query)).to.equal { e1 }
	end)

	CASE("cached queries drop destroyed archetypes", function()
		local world = ecs.world()
		local R = world.tag()
		local A = world.tag()
		local T = world.entity()
		local e1 = world.entity()
		local e2 = world.entity()
		world.add(e1, A)
		world.add(e2, A)
		world.add(e2, ecs.pair(R, T))

		local query = world.query():with(A):cached()
		expect(#query:archetypes()).to.equal(2)

		world.delete(T)
		expect(#query:archetypes()).to.equal(1)
		expect(sorted(collect(query))).to.equal(sorted { e1, e2 })

		for index, archetype in query:archetypes() do
			expect(query.compatible_archetypes_map[archetype.archetype_id]).to.equal(index)
		end
	end)

	CASE("cached is idempotent and rematch returns the live list", function()
		local world = ecs.world()
		local A = world.tag()
		local query = world.query():with(A):cached()
		expect(query:cached()).to.equal(query)
		expect(query:rematch()).to.equal(query.compatible_archetypes)
	end)

	CASE("cleanup stops tracking new archetypes", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e1 = world.entity()
		world.add(e1, A)

		local query = world.query():with(A):cached()
		query:count()
		query:cleanup()
		expect(query.is_cached).to.equal(false)

		local e2 = world.entity()
		world.bulk_add(e2, { A, B })
		expect(query:count()).to.equal(1)

		expect(function()
			query:cleanup()
			world.query():with(A):cleanup()
		end).never.to.throw()
	end)

	CASE("caching a query with no terms errors", function()
		local world = ecs.world()
		expect(function()
			world.query():cached()
		end).to.throw "cannot use a query with no terms"
		expect(function()
			world.query():monitor()
		end).to.throw "cannot use a query with no terms"
		expect(function()
			world.query():observe(function() end)
		end).to.throw "cannot use a query with no terms"
	end)

	CASE("archetype observers are removed on cleanup", function()
		local world = ecs.world()
		local A = world.tag()
		local observers = world.internal.archetype_creation_observers

		local query = world.query():with(A):cached()
		expect(#observers[A]).to.equal(1)
		query:cleanup()
		expect(#observers[A]).to.equal(0)
		expect(#world.internal.archetype_destruction_observers[A]).to.equal(0)
	end)
end)

TEST("query observers on bulk changes", function()
	CASE("observe fires for changed values through bulk_set", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local e = world.entity()
		world.set(e, A, 1)
		world.set(e, B, 1)

		local count = 0
		world.query(A):observe(function()
			count += 1
		end)

		world.bulk_set(e, { A, B }, { 2, 2 })
		expect(count).to.equal(1)
	end)

	CASE("monitor removed fires when a component id is deleted", function()
		local world = ecs.world()
		local A = world.tag()
		local e = world.entity()
		world.add(e, A)

		local removed = {}
		local monitor = world.query():with(A):monitor()
		monitor.removed(function(entity)
			table.insert(removed, entity)
		end)

		world.delete(A)
		expect(removed).to.equal { e }
		expect(world.alive(e)).to.equal(true)
	end)

	CASE("monitor removed fires for entities cleared by wipe", function()
		local world = ecs.world()
		local A = world.tag()
		local e1 = world.entity()
		local e2 = world.entity()
		world.add(e1, A)
		world.add(e2, A)

		local removed = {}
		local monitor = world.query():with(A):monitor()
		monitor.removed(function(entity)
			table.insert(removed, entity)
		end)

		world.wipe(A)
		expect(sorted(removed)).to.equal(sorted { e1, e2 })
	end)
end)

-- internals: component records -------------------------------------------------------------------

TEST("internal: component records", function()
	CASE("component_record_create computes the component flag", function()
		local world = ecs.world()
		local internal = world.internal
		local C = world.component()
		local T = world.tag()

		expect(world.components_lookup[C]).to.beNil()
		local c_record = internal.component_record_create(C)
		local t_record = internal.component_record_create(T)

		expect(world.components_lookup[C]).to.equal(c_record)
		expect(bit32.btest(c_record.flags, 1)).to.equal(true)
		expect(bit32.btest(t_record.flags, 1)).to.equal(false)
		expect(c_record.archetype_count).to.equal(0)
	end)

	CASE("component_record_ensure returns the existing record", function()
		local world = ecs.world()
		local C = world.component()
		local record = world.internal.component_record_ensure(C)
		expect(world.internal.component_record_ensure(C)).to.equal(record)
	end)

	CASE("pair records are linked to both wildcard records", function()
		local world = ecs.world()
		local R = world.tag()
		local T = world.entity()
		local pair = ecs.pair(R, T)

		local record = world.internal.component_record_ensure(pair) :: any
		local relation_record = world.components_lookup[ecs.pair(R, ecs.Wildcard)] :: any
		local target_record = world.components_lookup[ecs.pair(ecs.Wildcard, T)] :: any

		expect(relation_record.first_records[pair]).to.equal(record)
		expect(target_record.second_records[pair]).to.equal(record)
		expect(world.internal.wildcard_record_ensure(ecs.pair(R, ecs.Wildcard))).to.equal(relation_record)
	end)

	CASE("wildcard records are not linked to themselves", function()
		local world = ecs.world()
		local R = world.tag()
		local wildcard = ecs.pair(R, ecs.Wildcard)
		local record = world.internal.component_record_ensure(wildcard) :: any
		expect(count_keys(record.first_records)).to.equal(0)
		expect(count_keys(record.second_records)).to.equal(0)
	end)

	CASE("exclusive and delete traits become record flags", function()
		local world = ecs.world()
		local R = world.tag()
		world.add(R, ecs.Exclusive)
		world.add(R, ecs.pair(ecs.OnDelete, ecs.Delete))
		world.add(R, ecs.pair(ecs.OnDeleteTarget, ecs.Delete))
		local T = world.entity()

		local IS_EXCLUSIVE_FLAG = bit32.lshift(1, 1)
		local HAS_DELETE_FLAG = bit32.lshift(1, 2)

		local pair_record = world.internal.component_record_ensure(ecs.pair(R, T))
		local relation_record = world.components_lookup[ecs.pair(R, ecs.Wildcard)]

		expect(bit32.btest(relation_record.flags, IS_EXCLUSIVE_FLAG)).to.equal(true)
		expect(bit32.btest(relation_record.flags, HAS_DELETE_FLAG)).to.equal(true)
		expect(bit32.btest(pair_record.flags, HAS_DELETE_FLAG)).to.equal(true)

		local plain = world.internal.component_record_ensure(world.tag())
		expect(bit32.btest(plain.flags, HAS_DELETE_FLAG)).to.equal(false)
		expect(bit32.btest(plain.flags, IS_EXCLUSIVE_FLAG)).to.equal(false)
	end)

	CASE("records track how many archetypes hold the id", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e1 = world.entity()
		local e2 = world.entity()
		world.add(e1, A)
		world.bulk_add(e2, { A, B })

		local record = world.components_lookup[A]
		expect(record.archetype_count).to.equal(2)
		expect(count_keys(record.column_index)).to.equal(2)
	end)

	CASE("wildcard records count archetypes once even with several pairs", function()
		local world = ecs.world()
		local R = world.tag()
		local T1 = world.entity()
		local T2 = world.entity()
		local e = world.entity()
		world.add(e, ecs.pair(R, T1))
		world.add(e, ecs.pair(R, T2))

		local archetype = (world.internal.get_entity_record(e) :: any).archetype
		local relation_record = world.components_lookup[ecs.pair(R, ecs.Wildcard)] :: any
		expect(relation_record.archetype_count).to.equal(2)
		expect(relation_record.pairs_count[archetype.archetype_id]).to.equal(2)
	end)
end)

-- internals: archetype graph -------------------------------------------------------------------

TEST("internal: archetype graph", function()
	CASE("archetype_ensure returns the root for no ids and reuses archetypes", function()
		local world = ecs.world()
		local internal = world.internal
		local A = world.tag()
		local B = world.component()

		expect(internal.archetype_ensure {}).to.equal(world.ROOT_ARCHETYPE)

		local archetype = internal.archetype_ensure { A, B }
		expect(internal.archetype_ensure { A, B }).to.equal(archetype)
		expect(archetype.components).to.equal { A, B }
		expect(archetype.hash).to.equal(internal.HASH_IDS { A, B })
		expect(archetype.alive).to.equal(false)
		expect(archetype.destroyed).to.equal(false)
		expect(world.archetypes[archetype.archetype_id]).to.equal(archetype)
		expect(world.archetypes_lookup[archetype.hash]).to.equal(archetype)

		expect(table.isfrozen(archetype.columns_map[A])).to.equal(true)
		expect(table.isfrozen(archetype.columns_map[B])).to.equal(false)
		expect(archetype.columns[1]).to.equal(archetype.columns_map[A])
		expect(archetype.columns[2]).to.equal(archetype.columns_map[B])
		expect(world.components_lookup[A].column_index[archetype.archetype_id]).to.equal(1)
		expect(world.components_lookup[B].column_index[archetype.archetype_id]).to.equal(2)
	end)

	CASE("archetype_find_with / archetype_find_without build and cache edges", function()
		local world = ecs.world()
		local internal = world.internal
		local A = world.tag()
		local B = world.tag()
		local root = world.ROOT_ARCHETYPE

		local a = internal.archetype_find_with(root, A)
		expect(a.components).to.equal { A }
		expect(root.forward_edges[A]).to.equal(a)
		expect(a.backwards_edges[A]).to.equal(root)
		expect(internal.archetype_find_with(root, A)).to.equal(a)

		local ab = internal.archetype_find_with(a, B)
		expect(ab.components).to.equal { A, B }
		expect(internal.archetype_find_without(ab, B)).to.equal(a)
		expect(internal.archetype_find_without(a, A)).to.equal(root)

		local b = internal.archetype_find_without(ab, A)
		expect(b.components).to.equal { B }
		expect(ab.backwards_edges[A]).to.equal(b)
		expect(b.forward_edges[A]).to.equal(ab)
	end)

	CASE("archetype_find_swap_with replaces an id in place and links swapped edges", function()
		local world = ecs.world()
		local internal = world.internal
		local A = world.tag()
		local B = world.tag()
		local C = world.tag()

		local ab = internal.archetype_ensure { A, B }
		local cb = internal.archetype_find_swap_with(ab, A, C, 1)

		expect(cb.components).to.equal { C, B }
		expect(ab.forward_edges[C]).to.equal(cb)
		expect(ab.swapped_edges[C]).to.equal(A)
		expect(cb.forward_edges[A]).to.equal(ab)
		expect(cb.swapped_edges[A]).to.equal(C)
		expect(internal.archetype_find_swap_with(ab, A, C, 1)).to.equal(cb)
	end)

	CASE("archetype_destroy unlinks the archetype and is idempotent", function()
		local world = ecs.world()
		local internal = world.internal
		local A = world.tag()
		local B = world.tag()
		local root = world.ROOT_ARCHETYPE

		local a = internal.archetype_find_with(root, A)
		local ab = internal.archetype_find_with(a, B)
		local record_a = world.components_lookup[A]
		local record_b = world.components_lookup[B]

		internal.archetype_destroy(ab)
		expect(ab.destroyed).to.equal(true)
		expect(world.archetypes[ab.archetype_id]).to.beNil()
		expect(world.archetypes_lookup[ab.hash]).to.beNil()
		expect(a.forward_edges[B]).to.beNil()
		expect(record_a.archetype_count).to.equal(1)
		expect(record_b.archetype_count).to.equal(0)
		expect(record_a.column_index[ab.archetype_id]).to.beNil()

		internal.archetype_destroy(ab)
		expect(record_a.archetype_count).to.equal(1)

		internal.archetype_destroy(root)
		expect(root.destroyed).to.equal(false)
	end)

	CASE("destroying an archetype clears swapped edges on both sides", function()
		local world = ecs.world()
		local internal = world.internal
		local A = world.tag()
		local B = world.tag()

		local a = internal.archetype_ensure { A }
		local b = internal.archetype_find_swap_with(a, A, B, 1)

		internal.archetype_destroy(b)
		expect(a.forward_edges[B]).to.beNil()
		expect(a.swapped_edges[B]).to.beNil()
	end)

	CASE("archetype_create fires creation observers", function()
		local world = ecs.world()
		local internal = world.internal
		local A = world.tag()
		local B = world.tag()

		local created = {}
		internal.archetype_creation_observers[A] = {
			{
				match = function(archetype)
					return archetype.columns_map[B] ~= nil
				end,
				callback = function(archetype)
					table.insert(created, archetype)
				end,
			},
		}

		local a = internal.archetype_ensure { A }
		local ab = internal.archetype_ensure { A, B }
		expect(created).to.equal { ab }
		expect(a.alive).to.equal(false)
	end)

	CASE("MATCH_ARCHETYPE and FIND_MATCHED_ARCHETYPES", function()
		local world = ecs.world()
		local internal = world.internal
		local A = world.tag()
		local B = world.tag()
		local e = world.entity()
		world.add(e, A)
		local a = (internal.get_entity_record(e) :: any).archetype
		local ab = internal.archetype_ensure { A, B }

		expect(internal.MATCH_ARCHETYPE({ A }, nil, a)).to.equal(true)
		expect(internal.MATCH_ARCHETYPE({ A, B }, nil, a)).to.equal(false)
		expect(internal.MATCH_ARCHETYPE({ A }, { B }, ab)).to.equal(false)
		expect(internal.MATCH_ARCHETYPE({ A }, { B }, a)).to.equal(true)

		local all = internal.FIND_MATCHED_ARCHETYPES(world, { A }, nil, false)
		expect(#all).to.equal(2)
		local alive = internal.FIND_MATCHED_ARCHETYPES(world, { A }, nil, true)
		expect(alive).to.equal { a }
		expect(internal.FIND_MATCHED_ARCHETYPES(world, { A }, { B }, false)).to.equal { a }
		expect(internal.FIND_MATCHED_ARCHETYPES(world, { world.tag() }, nil, false)).to.equal {}
		expect(internal.FIND_MATCHED_ARCHETYPES(world, { A, world.tag() }, nil, false)).to.equal {}
	end)
end)

-- internals: archetype rows -------------------------------------------------------------------

TEST("internal: archetype rows", function()
	CASE("archetype_insert_entity appends rows and marks the archetype alive", function()
		local world = ecs.world()
		local internal = world.internal
		local A = world.tag()
		local archetype = internal.archetype_ensure { A }

		expect(internal.archetype_insert_entity(1, archetype)).to.equal(1)
		expect(archetype.alive).to.equal(true)
		expect(internal.archetype_insert_entity(2, archetype)).to.equal(2)
		expect(archetype.entities).to.equal { 1, 2 }
	end)

	CASE("archetype_assign_entity updates the entity record", function()
		local world = ecs.world()
		local internal = world.internal
		local A = world.tag()
		local archetype = internal.archetype_ensure { A }
		local e = world.entity()
		local record = internal.get_entity_record(e) :: any

		internal.archetype_assign_entity(e, record, archetype)
		expect(record.archetype).to.equal(archetype)
		expect(record.archetype_row).to.equal(1)
		expect(world.has(e, A)).to.equal(true)
	end)

	CASE("archetype_delete_entity swaps the last row into the hole", function()
		local world = ecs.world()
		local internal = world.internal
		local A = world.component()
		local e1 = world.entity()
		local e2 = world.entity()
		local e3 = world.entity()
		world.set(e1, A, 1)
		world.set(e2, A, 2)
		world.set(e3, A, 3)

		local archetype = (internal.get_entity_record(e1) :: any).archetype
		internal.archetype_delete_entity(archetype, 1)

		expect(archetype.entities).to.equal { e3, e2 }
		expect(archetype.columns_map[A]).to.equal { 3, 2 }
		expect((internal.get_entity_record(e3) :: any).archetype_row).to.equal(1)

		internal.archetype_delete_entity(archetype, 2)
		internal.archetype_delete_entity(archetype, 1)
		expect(archetype.entities).to.equal {}
		expect(archetype.alive).to.equal(false)
	end)

	CASE("archetype_move_entity carries column values to the destination", function()
		local world = ecs.world()
		local internal = world.internal
		local A = world.component()
		local B = world.component()
		local e1 = world.entity()
		local e2 = world.entity()
		world.set(e1, A, 1)
		world.set(e2, A, 2)

		local source = (internal.get_entity_record(e1) :: any).archetype
		local destination = internal.archetype_ensure { A, B }
		local record = internal.get_entity_record(e1) :: any

		internal.archetype_move_entity(e1, record, source, destination)
		expect(record.archetype).to.equal(destination)
		expect(record.archetype_row).to.equal(1)
		expect(destination.columns_map[A]).to.equal { 1 }
		expect(source.entities).to.equal { e2 }
		expect(source.columns_map[A]).to.equal { 2 }
		expect((internal.get_entity_record(e2) :: any).archetype_row).to.equal(1)
		expect(destination.alive).to.equal(true)

		internal.archetype_move_entity(e2, internal.get_entity_record(e2) :: any, source, destination)
		expect(source.alive).to.equal(false)
		expect(destination.columns_map[A]).to.equal { 1, 2 }
	end)
end)

-- preregistration -------------------------------------------------------------------

TEST("preregistration", function()
	CASE("preregistered ids are available in every new world", function()
		local C = ecs.component()
		local T = ecs.tag()
		local E = ecs.entity()
		ecs.meta(E, C, "meta")
		ecs.meta(E, T)

		local world = ecs.world()
		expect(world.is_component(C)).to.equal(true)
		expect(world.is_tag(T)).to.equal(true)
		expect(world.alive(E)).to.equal(true)
		expect(world.get(E, C)).to.equal "meta"
		expect(world.has(E, T)).to.equal(true)

		local other = ecs.world()
		expect(other.get(E, C)).to.equal "meta"
		expect(world.entity()).never.to.equal(E)
	end)

	CASE("world ids never collide with preregistered ids", function()
		local C = ecs.component()
		local world = ecs.world()
		local W = world.component()
		expect(W).never.to.equal(C)
		expect(W).to.be.greaterThan(C)
	end)
end)

TEST("query:monitor() added", function()
	CASE("fires when an entity enters the query", function()
		local world = ecs.world()
		local A = world.component()

		local count = 0
		local monitor = world.query(A):monitor()
		monitor.added(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, A, 1)

		expect(count).to.equal(1)
	end)

	CASE("fires once per entity for multi-term queries on bulk_add", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local count = 0
		local monitor = world.query(A, B):monitor()
		monitor.added(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.bulk_add(e, { A, B })

		expect(count).to.equal(1)
	end)

	CASE("fires once per entity for multi-term queries on bulk_set", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local count = 0
		local monitor = world.query(A, B):monitor()
		monitor.added(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.bulk_set(e, { A, B }, { 1, 2 })

		expect(count).to.equal(1)
	end)

	CASE("fires when a without-term component is removed", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local count = 0
		local monitor = world.query(A):without(B):monitor()
		monitor.added(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, A, 1)
		world.add(e, B)
		count = 0

		world.remove(e, B)
		expect(count).to.equal(1)
	end)

	CASE("fires once on exclusive pair swap with a without-term", function()
		local world = ecs.world()
		local R = world.tag()
		world.add(R, ecs.Exclusive)
		local A = world.entity()
		local B = world.entity()

		local count = 0
		local monitor = world.query():with(ecs.pair(R, B)):without(ecs.pair(R, A)):monitor()
		monitor.added(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.add(e, ecs.pair(R, A))
		world.add(e, ecs.pair(R, B))

		expect(count).to.equal(1)
	end)

	CASE("fires once when relation and target wildcard terms match the same pair", function()
		local world = ecs.world()
		local R = world.tag()
		local T = world.entity()

		local count = 0
		local monitor = world.query():with(ecs.pair(R, ecs.Wildcard)):with(ecs.pair(ecs.Wildcard, T)):monitor()
		monitor.added(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.add(e, ecs.pair(R, T))

		expect(count).to.equal(1)
	end)

	CASE("does not fire for non-matching entities", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local count = 0
		local monitor = world.query(A):monitor()
		monitor.added(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, B, 1)

		expect(count).to.equal(0)
	end)

	CASE("does not fire again when a matching entity moves archetype but keeps matching", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local count = 0
		local monitor = world.query(A):monitor()
		monitor.added(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, A, 1)
		world.add(e, B)

		expect(count).to.equal(1)
	end)

	CASE("stops firing after cleanup", function()
		local world = ecs.world()
		local A = world.component()

		local count = 0
		local monitor = world.query(A):monitor()
		monitor.added(function(entity)
			count += 1
		end)
		monitor.cleanup()

		local e = world.entity()
		world.set(e, A, 1)

		expect(count).to.equal(0)
	end)
end)

TEST("query:monitor() removed", function()
	CASE("fires when a component is removed", function()
		local world = ecs.world()
		local A = world.component()

		local count = 0
		local monitor = world.query(A):monitor()
		monitor.removed(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, A, 1)
		world.remove(e, A)

		expect(count).to.equal(1)
	end)

	CASE("fires once per entity for multi-term queries on delete", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local count = 0
		local monitor = world.query(A, B):monitor()
		monitor.removed(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, A, 1)
		world.set(e, B, 2)
		world.delete(e)

		expect(count).to.equal(1)
	end)

	CASE("fires once per entity for multi-term queries on clear", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local count = 0
		local monitor = world.query(A, B):monitor()
		monitor.removed(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, A, 1)
		world.set(e, B, 2)
		world.clear(e)

		expect(count).to.equal(1)
	end)

	CASE("fires once per entity for multi-term queries on bulk_remove", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local count = 0
		local monitor = world.query(A, B):monitor()
		monitor.removed(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, A, 1)
		world.set(e, B, 2)
		world.bulk_remove(e, { A, B })

		expect(count).to.equal(1)
	end)

	CASE("fires once when deleting an entity with multiple pairs of the same relation", function()
		local world = ecs.world()
		local R = world.tag()
		local T1 = world.entity()
		local T2 = world.entity()

		local count = 0
		local monitor = world.query():with(ecs.pair(R, ecs.Wildcard)):monitor()
		monitor.removed(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.add(e, ecs.pair(R, T1))
		world.add(e, ecs.pair(R, T2))
		count = 0

		world.delete(e)
		expect(count).to.equal(1)
	end)

	CASE("fires once per entity when deleting a pair target matched by multiple terms", function()
		local world = ecs.world()
		local R1 = world.tag()
		local R2 = world.tag()
		local T = world.entity()

		local count = 0
		local monitor = world.query():with(ecs.pair(R1, T)):with(ecs.pair(R2, T)):monitor()
		monitor.removed(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.add(e, ecs.pair(R1, T))
		world.add(e, ecs.pair(R2, T))
		count = 0

		world.delete(T)
		expect(count).to.equal(1)
	end)

	CASE("fires for every entity when deleting a pair target shared by many entities", function()
		local world = ecs.world()
		local R1 = world.tag()
		local R2 = world.tag()
		local T = world.entity()

		local fired: { [any]: number } = {}
		local monitor = world.query():with(ecs.pair(R1, T)):with(ecs.pair(R2, T)):monitor()
		monitor.removed(function(entity)
			fired[entity] = (fired[entity] or 0) + 1
		end)

		local e1 = world.entity()
		local e2 = world.entity()
		for _, e in { e1, e2 } do
			world.add(e, ecs.pair(R1, T))
			world.add(e, ecs.pair(R2, T))
		end
		table.clear(fired)

		world.delete(T)
		expect(fired[e1]).to.equal(1)
		expect(fired[e2]).to.equal(1)
	end)

	CASE("fires when a with-term is removed while a without-term is present elsewhere", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local count = 0
		local monitor = world.query(A):without(B):monitor()
		monitor.removed(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, A, 1)
		count = 0

		-- entity leaves the query by gaining the without-term
		world.add(e, B)
		expect(count).to.equal(1)
	end)

	CASE("does not fire when a non-matching entity is deleted", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local count = 0
		local monitor = world.query(A):monitor()
		monitor.removed(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, B, 1)
		world.delete(e)

		expect(count).to.equal(0)
	end)

	CASE("stops firing after cleanup", function()
		local world = ecs.world()
		local A = world.component()

		local count = 0
		local monitor = world.query(A):monitor()
		monitor.removed(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, A, 1)
		monitor.cleanup()

		world.remove(e, A)
		expect(count).to.equal(0)
	end)
end)

TEST("query:observe()", function()
	CASE("fires when a matching component is added", function()
		local world = ecs.world()
		local A = world.component()

		local count = 0
		world.query(A):observe(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, A, 1)

		expect(count).to.equal(1)
	end)

	CASE("fires when a matching component is changed", function()
		local world = ecs.world()
		local A = world.component()

		local count = 0
		world.query(A):observe(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.set(e, A, 1)
		world.set(e, A, 2)

		expect(count).to.equal(2)
	end)

	CASE("fires once per entity for multi-term queries on bulk_add", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local count = 0
		world.query(A, B):observe(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.bulk_add(e, { A, B })

		expect(count).to.equal(1)
	end)

	CASE("fires once when relation and target wildcard terms match the same pair", function()
		local world = ecs.world()
		local R = world.tag()
		local T = world.entity()

		local count = 0
		world.query():with(ecs.pair(R, ecs.Wildcard)):with(ecs.pair(ecs.Wildcard, T)):observe(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.add(e, ecs.pair(R, T))

		expect(count).to.equal(1)
	end)

	CASE("does not fire for entities excluded by a without-term", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local count = 0
		world.query(A):without(B):observe(function(entity)
			count += 1
		end)

		local e = world.entity()
		world.add(e, B)
		world.set(e, A, 1)

		expect(count).to.equal(0)
	end)

	CASE("stops firing after cleanup", function()
		local world = ecs.world()
		local A = world.component()

		local count = 0
		local cleanup = world.query(A):observe(function(entity)
			count += 1
		end)
		cleanup()

		local e = world.entity()
		world.set(e, A, 1)

		expect(count).to.equal(0)
	end)
end)

TEST("query:changed()", function()
	CASE("collects an entity once per iteration even after multiple sets", function()
		local world = ecs.world()
		local A = world.component()

		local changed = world.query(A):changed()

		local e = world.entity()
		world.set(e, A, 1)
		world.set(e, A, 2)
		world.set(e, A, 3)

		local count = 0
		for entity in changed.iter() do
			count += 1
			expect(entity).to.equal(e)
		end
		expect(count).to.equal(1)
	end)

	CASE("does not return entities that left the query before iteration", function()
		local world = ecs.world()
		local A = world.component()

		local changed = world.query(A):changed()

		local e = world.entity()
		world.set(e, A, 1)
		world.remove(e, A)

		local count = 0
		for entity in changed.iter() do
			count += 1
		end
		expect(count).to.equal(0)
	end)

	CASE("queue is drained after iteration", function()
		local world = ecs.world()
		local A = world.component()

		local changed = world.query(A):changed()

		local e = world.entity()
		world.set(e, A, 1)

		for entity in changed.iter() do
		end

		local count = 0
		for entity in changed.iter() do
			count += 1
		end
		expect(count).to.equal(0)
	end)
end)

TEST("pair hook propagation", function()
	-- Hooks on (R, *), (*, T) and (R, T) must all fire for an entity that gets
	-- (R, T), no matter in which order the hooks were registered relative to
	-- each other and relative to the creation of the (R, T) record.
	--
	-- This guards the wiring done by component_record_ensure (merging wildcard
	-- hooks into a freshly created pair record) and PROPAGATE_PAIR_EVENTS
	-- (pushing wildcard hooks into pair records that already exist, and
	-- pulling both wildcards into a pair record that gets its first hook).
	local function permutations(list: { string }): { { string } }
		local out = {}
		local function walk(arr: { string }, k: number)
			if k > #arr then
				table.insert(out, table.clone(arr))
				return
			end
			for i = k, #arr do
				arr[k], arr[i] = arr[i], arr[k]
				walk(arr, k + 1)
				arr[k], arr[i] = arr[i], arr[k]
			end
		end
		walk(list, 1)
		return out
	end

	local orders = permutations { "relation", "target", "pair", "touch" }

	for _, kind in { "added", "changed", "removed" } do
		CASE(`{kind} hooks fire for every registration order`, function()
			for _, order in orders do
				local world = ecs.world()
				local R = world.component()
				local T = world.entity()
				local scratch = world.entity()
				local fired = { relation = 0, target = 0, pair = 0 }

				for _, step in order do
					if step == "relation" then
						(world :: any)[kind](ecs.pair(R, ecs.Wildcard), function()
							fired.relation += 1
						end)
					elseif step == "target" then
						(world :: any)[kind](ecs.pair(ecs.Wildcard, T), function()
							fired.target += 1
						end)
					elseif step == "pair" then
						(world :: any)[kind](ecs.pair(R, T), function()
							fired.pair += 1
						end)
					else
						-- create the (R, T) record and archetype before some hooks exist
						world.set(scratch, ecs.pair(R, T), 0)
						world.remove(scratch, ecs.pair(R, T))
					end
				end

				fired.relation, fired.target, fired.pair = 0, 0, 0

				local e = world.entity()
				world.set(e, ecs.pair(R, T), 1)
				if kind == "changed" then
					world.set(e, ecs.pair(R, T), 2)
				elseif kind == "removed" then
					world.remove(e, ecs.pair(R, T))
				end

				-- One string per ordering so a failure names the order that broke.
				local label = table.concat(order, " > ")
				local got = `{label}: relation={fired.relation} target={fired.target} pair={fired.pair}`
				expect(got).to.equal(`{label}: relation=1 target=1 pair=1`)
			end
		end)
	end

	CASE("wildcard hook survives deleting the last target", function()
		local world = ecs.world()
		local count = 0
		world.added(ecs.pair(ecs.ChildOf, ecs.Wildcard), function()
			count += 1
		end)

		local parent = world.entity()
		local child = world.entity()
		world.add(child, ecs.pair(ecs.ChildOf, parent))
		expect(count).to.equal(1)

		world.delete(parent)
		expect(world.alive(child)).to.equal(false)

		local parent2 = world.entity()
		local child2 = world.entity()
		world.add(child2, ecs.pair(ecs.ChildOf, parent2))
		expect(count).to.equal(2)
	end)

	CASE("component hook survives its last archetype being destroyed", function()
		local world = ecs.world()
		local A = world.component()
		local count = 0
		world.added(A, function()
			count += 1
		end)

		local target = world.entity()
		local e = world.entity()
		world.add(e, A)
		world.add(e, ecs.pair(ecs.ChildOf, target))
		world.delete(target)
		expect(world.alive(e)).to.equal(false)

		local e2 = world.entity()
		world.add(e2, A)
		expect(count).to.equal(2)
	end)
end)

local report = testlib.run(plan)
testlib.report(report)

for _, suite in report.suites do
	if suite.status == "failed" then
		error("test suite failed: " .. suite.name)
	end
	for _, case in suite.cases do
		if case.status == "failed" then
			error(`test case failed: {suite.name} / {case.name}`)
		end
	end
end
