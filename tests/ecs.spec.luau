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

-- hierarchy -------------------------------------------------------------------

TEST("hierarchy", function()
	local function node_of(world: ecs.World, relation: any, target: any)
		local record = world.components_lookup[ecs.pair(relation, target)] :: any
		return record and record.node
	end

	CASE("depth counts hops up ChildOf and is 0 at a root", function()
		local world = ecs.world()
		local root = world.entity()
		local a = world.entity()
		local b = world.entity()
		local c = world.entity()
		world.add(a, ecs.pair(ecs.ChildOf, root))
		world.add(b, ecs.pair(ecs.ChildOf, a))
		world.add(c, ecs.pair(ecs.ChildOf, b))

		expect(world.depth(root)).to.equal(0)
		expect(world.depth(a)).to.equal(1)
		expect(world.depth(b)).to.equal(2)
		expect(world.depth(c)).to.equal(3)
		expect(world.depth(c, ecs.ChildOf)).to.equal(3)
		expect(world.depth(world.entity())).to.equal(0)
	end)

	CASE("depth follows reparenting, pair removal and parent deletion", function()
		local world = ecs.world()
		local root = world.entity()
		local a = world.entity()
		local b = world.entity()
		local c = world.entity()
		world.add(a, ecs.pair(ecs.ChildOf, root))
		world.add(b, ecs.pair(ecs.ChildOf, a))
		world.add(c, ecs.pair(ecs.ChildOf, b))
		expect(world.depth(c)).to.equal(3)

		-- reparent the middle of the chain: the subtree below shifts
		world.add(b, ecs.pair(ecs.ChildOf, root))
		expect(world.depth(b)).to.equal(1)
		expect(world.depth(c)).to.equal(2)

		-- removing the pair makes b a root
		world.remove(b, ecs.pair(ecs.ChildOf, root))
		expect(world.depth(b)).to.equal(0)
		expect(world.depth(c)).to.equal(1)

		-- re-attach deeper and then delete an ancestor: ChildOf cascades
		world.add(b, ecs.pair(ecs.ChildOf, a))
		expect(world.depth(c)).to.equal(3)
		world.delete(a)
		expect(world.alive(c)).to.equal(false)
		expect(world.depth(root)).to.equal(0)
	end)

	CASE("depth works through a custom traversable relation and the slow path", function()
		local world = ecs.world()
		local Trav = world.tag()
		world.add(Trav, ecs.Traversable)
		local Plain = world.tag()

		local root = world.entity()
		local a = world.entity()
		local b = world.entity()
		for _, R in { Trav, Plain } do
			world.add(a, ecs.pair(R, root))
			world.add(b, ecs.pair(R, a))
		end

		expect(node_of(world, Trav, root)).never.to.beNil()
		expect(node_of(world, Plain, root)).to.beNil()

		expect(world.depth(b, Trav)).to.equal(2)
		expect(world.depth(b, Plain)).to.equal(2)

		-- no cascade on a plain relation: removing the target's pair re-roots it
		world.remove(a, ecs.pair(Trav, root))
		world.remove(a, ecs.pair(Plain, root))
		expect(world.depth(b, Trav)).to.equal(1)
		expect(world.depth(b, Plain)).to.equal(1)

		-- deleting the target removes the pair from its holders
		world.delete(a)
		expect(world.depth(b, Trav)).to.equal(0)
		expect(world.depth(b, Plain)).to.equal(0)
	end)

	CASE("depth errors on a relation cycle, on both paths", function()
		local world = ecs.world()
		local a = world.entity()
		local b = world.entity()
		world.add(a, ecs.pair(ecs.ChildOf, b))
		world.add(b, ecs.pair(ecs.ChildOf, a))
		expect(function()
			world.depth(a)
		end).to.throw "cycle"

		local Plain = world.tag()
		local c = world.entity()
		local d = world.entity()
		world.add(c, ecs.pair(Plain, d))
		world.add(d, ecs.pair(Plain, c))
		expect(function()
			world.depth(c, Plain)
		end).to.throw "cycle"

		-- breaking the cycle recovers
		world.remove(b, ecs.pair(ecs.ChildOf, a))
		expect(world.depth(a)).to.equal(1)
		expect(world.depth(b)).to.equal(0)
	end)

	CASE("nodes mirror parent and children links and are released on delete", function()
		local world = ecs.world()
		local root = world.entity()
		local a = world.entity()
		local b = world.entity()
		local leaf = world.entity()
		world.add(a, ecs.pair(ecs.ChildOf, root))
		world.add(b, ecs.pair(ecs.ChildOf, root))
		world.add(leaf, ecs.pair(ecs.ChildOf, a))

		local root_node = node_of(world, ecs.ChildOf, root)
		local a_node = node_of(world, ecs.ChildOf, a)
		expect(root_node.parent).to.beNil()
		expect(a_node.parent).to.equal(root_node)
		expect(#root_node.children).to.equal(1)
		expect(root_node.children[1]).to.equal(a_node)
		-- leaves are nobody's target: no node, no bookkeeping
		expect(node_of(world, ecs.ChildOf, leaf)).to.beNil()
		expect(node_of(world, ecs.ChildOf, b)).to.beNil()

		local sparse = world.internal.entity_index.sparse
		expect(sparse[a].targets).to.equal(1)
		expect(sparse[leaf].targets).to.equal(0)

		-- a becomes a child of b: b gets a node, a relinks
		world.add(a, ecs.pair(ecs.ChildOf, b))
		local b_node = node_of(world, ecs.ChildOf, b)
		expect(a_node.parent).to.equal(b_node)
		expect(b_node.parent).to.equal(root_node)
		expect(#root_node.children).to.equal(1)
		expect(root_node.children[1]).to.equal(b_node)
		expect(#b_node.children).to.equal(1)

		-- deleting a cascades to leaf and releases a's node
		world.delete(a)
		expect(#b_node.children).to.equal(0)
		expect(node_of(world, ecs.ChildOf, a)).to.beNil()
		expect(sparse[a].targets).to.equal(0)
	end)

	CASE("traverse resolves through the reachable cache and follows every change", function()
		local world = ecs.world()
		local C = world.component()
		local D = world.component()
		local root = world.entity()
		local a = world.entity()
		local b = world.entity()
		local leaf = world.entity()
		world.add(a, ecs.pair(ecs.ChildOf, root))
		world.add(b, ecs.pair(ecs.ChildOf, a))
		world.add(leaf, ecs.pair(ecs.ChildOf, b))
		world.set(root, C, "root")

		expect(world.traverse(leaf, ecs.ChildOf, C)).to.equal(root)
		expect(world.traverse(leaf, ecs.ChildOf, D)).to.beNil()
		local b_node = node_of(world, ecs.ChildOf, b)
		expect(b_node.reachable.current).to.equal(b_node.generation)

		-- a closer holder appears: cache invalidated and re-resolved
		world.set(a, C, "a")
		expect(b_node.reachable.current).never.to.equal(b_node.generation)
		local found, value = world.traverse(leaf, ecs.ChildOf, C)
		expect(found).to.equal(a)
		expect(value).to.equal "a"

		-- value changes without a move are read live
		world.set(a, C, "a2")
		expect(select(2, world.traverse(leaf, ecs.ChildOf, C))).to.equal "a2"

		-- holder loses it: falls back to the next one up
		world.remove(a, C)
		expect(world.traverse(leaf, ecs.ChildOf, C)).to.equal(root)

		-- reparenting b under a sibling branch without C
		local other = world.entity()
		world.add(b, ecs.pair(ecs.ChildOf, other))
		expect(world.traverse(leaf, ecs.ChildOf, C)).to.beNil()
		world.set(other, D, 1)
		local found_d, value_d = world.traverse(leaf, ecs.ChildOf, D)
		expect(found_d).to.equal(other)
		expect(value_d).to.equal(1)

		-- the holder of the cached column changes row through a swap-remove
		local sibling = world.entity()
		world.set(sibling, D, 2)
		world.delete(sibling)
		expect(select(2, world.traverse(leaf, ecs.ChildOf, D))).to.equal(1)
		world.set(other, D, 3)
		expect(select(2, world.traverse(leaf, ecs.ChildOf, D))).to.equal(3)
	end)

	CASE("traverse survives bulk operations, clear, wipe and ancestor deletion", function()
		local world = ecs.world()
		local C = world.component()
		local D = world.component()
		local root = world.entity()
		local a = world.entity()
		local leaf = world.entity()
		world.add(a, ecs.pair(ecs.ChildOf, root))
		world.add(leaf, ecs.pair(ecs.ChildOf, a))

		world.bulk_set(root, { C, D }, { "rc", "rd" })
		expect(select(2, world.traverse(leaf, ecs.ChildOf, C))).to.equal "rc"
		world.bulk_set(a, { C }, { "ac" })
		expect(select(2, world.traverse(leaf, ecs.ChildOf, C))).to.equal "ac"
		expect(select(2, world.traverse(leaf, ecs.ChildOf, D))).to.equal "rd"

		world.bulk_remove(a, { C })
		expect(select(2, world.traverse(leaf, ecs.ChildOf, C))).to.equal "rc"

		world.clear(root)
		expect(world.traverse(leaf, ecs.ChildOf, C)).to.beNil()

		world.set(root, C, "rc2")
		world.set(a, C, "ac2")
		world.wipe(C)
		expect(world.traverse(leaf, ecs.ChildOf, C)).to.beNil()

		-- a custom traversable relation without cascade: deleting the middle
		-- re-roots the holder
		local Trav = world.tag()
		world.add(Trav, ecs.Traversable)
		local top = world.entity()
		local mid = world.entity()
		local bottom = world.entity()
		world.set(top, C, "top")
		world.add(mid, ecs.pair(Trav, top))
		world.add(bottom, ecs.pair(Trav, mid))
		expect(world.traverse(bottom, Trav, C)).to.equal(top)
		world.delete(mid)
		expect(world.traverse(bottom, Trav, C)).to.beNil()
		expect(world.depth(bottom, Trav)).to.equal(0)
	end)

	CASE("invalidation only walks nodes and keeps unrelated branches valid", function()
		local world = ecs.world()
		local C = world.component()
		local root = world.entity()
		local a = world.entity()
		local b = world.entity()
		local a_child = world.entity()
		local b_child = world.entity()
		world.add(a, ecs.pair(ecs.ChildOf, root))
		world.add(b, ecs.pair(ecs.ChildOf, root))
		world.add(a_child, ecs.pair(ecs.ChildOf, a))
		world.add(b_child, ecs.pair(ecs.ChildOf, b))
		world.set(root, C, 1)

		expect(world.traverse(a_child, ecs.ChildOf, C)).to.equal(root)
		expect(world.traverse(b_child, ecs.ChildOf, C)).to.equal(root)
		local a_node = node_of(world, ecs.ChildOf, a)
		local b_node = node_of(world, ecs.ChildOf, b)
		expect(world.depth(a_child)).to.equal(2)
		expect(a_node.depth.current).to.equal(a_node.generation)

		-- touching a invalidates a's subtree only
		world.set(a, C, 2)
		expect(a_node.reachable.current).never.to.equal(a_node.generation)
		expect(a_node.depth.current).never.to.equal(a_node.generation)
		expect(b_node.reachable.current).to.equal(b_node.generation)

		-- setting a value root already holds is not a move: nothing invalidates
		world.set(root, C, 3)
		expect(b_node.reachable.current).to.equal(b_node.generation)
		expect(select(2, world.traverse(b_child, ecs.ChildOf, C))).to.equal(3)

		-- moving root invalidates every node below
		world.add(root, world.tag())
		expect(b_node.reachable.current).never.to.equal(b_node.generation)
		expect(select(2, world.traverse(b_child, ecs.ChildOf, C))).to.equal(3)
		expect(select(2, world.traverse(a_child, ecs.ChildOf, C))).to.equal(2)
	end)

	CASE("up queries read through the cache and see reparenting and deletion", function()
		local world = ecs.world()
		local Model = world.component()
		local Tag = world.tag()
		local root = world.entity()
		local a = world.entity()
		local b = world.entity()
		local leaf = world.entity()
		world.set(root, Model, "root")
		world.add(a, ecs.pair(ecs.ChildOf, root))
		world.add(b, ecs.pair(ecs.ChildOf, a))
		world.add(leaf, ecs.pair(ecs.ChildOf, b))
		world.add(leaf, Tag)

		local query = world.query_build():with(Tag):term(Model):up(ecs.ChildOf):build()
		local function read()
			local seen = {}
			for entity, model in query do
				seen[entity] = model
			end
			return seen
		end

		expect(read()).to.equal { [leaf] = "root" }
		world.set(a, Model, "a")
		expect(read()).to.equal { [leaf] = "a" }
		world.add(b, ecs.pair(ecs.ChildOf, root))
		expect(read()).to.equal { [leaf] = "root" }
		world.remove(root, Model)
		expect(read()).to.equal {}
		world.set(b, Model, "b")
		expect(read()).to.equal { [leaf] = "b" }

		-- deleting an ancestor cascades: nothing is left to match
		world.delete(root)
		expect(read()).to.equal {}
	end)

	CASE("up monitors propagate through nodes to grandchildren", function()
		local world = ecs.world()
		local Position = world.component()
		local root = world.entity()
		local a = world.entity()
		local leaf = world.entity()
		world.add(a, ecs.pair(ecs.ChildOf, root))
		world.add(leaf, ecs.pair(ecs.ChildOf, a))

		local monitor = world.query_build():term(Position):up(ecs.ChildOf):build():monitor()
		local added, removed = {}, {}
		monitor.added(function(entity)
			table.insert(added, entity)
		end)
		monitor.removed(function(entity)
			table.insert(removed, entity)
		end)

		world.set(root, Position, 1)
		expect(sorted(added)).to.equal(sorted { a, leaf })
		world.remove(root, Position)
		expect(sorted(removed)).to.equal(sorted { a, leaf })
		monitor.cleanup()
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
		expect(#c_record.archetype_ids).to.equal(0)
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
		expect(#record.archetype_ids).to.equal(2)
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
		expect(#relation_record.archetype_ids).to.equal(2)
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
		expect(#record_a.archetype_ids).to.equal(1)
		expect(#record_b.archetype_ids).to.equal(0)
		expect(record_a.column_index[ab.archetype_id]).to.beNil()

		internal.archetype_destroy(ab)
		expect(#record_a.archetype_ids).to.equal(1)

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

TEST("cascade deletion under mutation", function()
	local pair = ecs.pair

	-- every record's dense archetype list must mirror its column_index map
	local function expect_record_lists_consistent(world: ecs.World)
		for id, record in world.components_lookup do
			local archetype_ids = record.archetype_ids
			expect(#archetype_ids).to.equal(count_keys(record.column_index))
			for slot, archetype_id in archetype_ids do
				expect(record.archetype_slots[archetype_id]).to.equal(slot)
				expect(record.column_index[archetype_id]).never.to.beNil()
				expect(world.archetypes[archetype_id]).never.to.beNil()
			end
		end
	end

	-- no archetype may keep a handle that is no longer alive
	local function expect_no_dead_rows(world: ecs.World)
		for _, archetype in world.archetypes do
			for _, entity in archetype.entities do
				expect(world.alive(entity)).to.equal(true)
			end
		end
	end

	CASE("archetypes created by a nested cascade are still swept for pairs to the dead target", function()
		local world = ecs.world()
		local Owns = world.tag()
		local Attached = world.tag()
		local RelX = world.tag()
		world.add(Owns, pair(ecs.OnDeleteTarget, ecs.Delete))

		local T = world.entity()
		-- extra archetypes referencing T perturb the sweep order
		for _ = 1, 4 do
			local D = world.tag()
			world.add(world.entity(), pair(D, T))
		end

		local child = world.entity()
		local grandchild = world.entity()
		-- grandchild's archetype exists before child's, so the sweep can reach
		-- child first and move grandchild into a brand new {pair(RelX, T)}
		world.add(grandchild, pair(Attached, child))
		world.add(grandchild, pair(RelX, T))
		world.add(child, pair(Owns, T))

		world.delete(T)

		expect(world.alive(child)).to.equal(false)
		expect(world.alive(grandchild)).to.equal(true)
		expect(world.has(grandchild, pair(RelX, T))).to.equal(false)
		expect(world.has(grandchild, pair(Attached, child))).to.equal(false)
		expect(world.target(grandchild, RelX)).to.beNil()
		expect(world.components_lookup[pair(RelX, T)]).to.beNil()

		-- a recycled id must not be re-targeted by a leftover pair
		local fresh = world.entity()
		expect(world.target(grandchild, RelX)).to.beNil()
		expect(world.has(grandchild, pair(RelX, fresh))).to.equal(false)

		expect_record_lists_consistent(world)
		expect_no_dead_rows(world)
	end)

	CASE("entities moved into a delete-flagged archetype mid-cascade are deleted too", function()
		local world = ecs.world()
		local Owns = world.tag()
		local Attached = world.tag()
		world.add(Owns, pair(ecs.OnDeleteTarget, ecs.Delete))

		local T = world.entity()
		local e1 = world.entity()
		local e2 = world.entity()
		world.add(e1, pair(Owns, T))
		-- deleting e1 strips pair(Attached, e1) from e2, moving e2 into e1's
		-- archetype while the outer sweep is still draining it
		world.add(e2, pair(Owns, T))
		world.add(e2, pair(Attached, e1))

		world.delete(T)

		expect(world.alive(T)).to.equal(false)
		expect(world.alive(e1)).to.equal(false)
		expect(world.alive(e2)).to.equal(false)
		expect(world.exists(e2)).to.equal(false)

		expect_record_lists_consistent(world)
		expect_no_dead_rows(world)
	end)

	CASE("longer chains through a delete-flagged archetype leave no survivors", function()
		local world = ecs.world()
		local Owns = world.tag()
		local Attached = world.tag()
		world.add(Owns, pair(ecs.OnDeleteTarget, ecs.Delete))

		local T = world.entity()
		local chain = {}
		for i = 1, 6 do
			local e = world.entity()
			world.add(e, pair(Owns, T))
			if i > 1 then
				world.add(e, pair(Attached, chain[i - 1]))
			end
			chain[i] = e
		end

		world.delete(T)

		for _, e in chain do
			expect(world.alive(e)).to.equal(false)
		end
		expect_record_lists_consistent(world)
		expect_no_dead_rows(world)
	end)

	CASE("a removed hook deleting a sibling during a cascade does not error", function()
		local world = ecs.world()
		local R = world.tag()
		local D = world.tag()
		world.add(R, pair(ecs.OnDeleteTarget, ecs.Delete))

		local T = world.entity()
		local e1 = world.entity()
		local e2 = world.entity()
		world.add(e1, pair(R, T))
		world.add(e1, D)
		world.add(e2, pair(R, T))
		world.add(e2, D)

		local fired = 0
		world.removed(D, function(entity)
			fired += 1
			local sibling = if entity == e1 then e2 else e1
			if world.alive(sibling) and not world.deleting(sibling) then
				world.delete(sibling)
			end
		end)

		world.delete(T)

		expect(world.alive(T)).to.equal(false)
		expect(world.alive(e1)).to.equal(false)
		expect(world.alive(e2)).to.equal(false)
		expect(world.deleting(T)).to.equal(false)
		expect(fired).to.equal(2)

		expect_record_lists_consistent(world)
		expect_no_dead_rows(world)
	end)

	CASE("a nested cascade may destroy the archetype the outer sweep holds", function()
		local world = ecs.world()
		local Owns = world.tag()
		world.add(Owns, pair(ecs.OnDeleteTarget, ecs.Delete))

		local T = world.entity()
		local c1 = world.entity()
		local c2 = world.entity()
		world.add(c1, pair(Owns, T))
		-- deleting c1 cascades into c2, which shares the outer archetype's pair
		world.add(c2, pair(Owns, T))
		world.add(c2, pair(Owns, c1))

		world.delete(T)

		expect(world.alive(T)).to.equal(false)
		expect(world.alive(c1)).to.equal(false)
		expect(world.alive(c2)).to.equal(false)

		expect_record_lists_consistent(world)
		expect_no_dead_rows(world)
	end)

	CASE("a removed hook whose delete empties the archetype being wiped is safe", function()
		local world = ecs.world()
		local R = world.tag()
		local Owns = world.tag()
		world.add(Owns, pair(ecs.OnDeleteTarget, ecs.Delete))

		local T = world.entity()
		local X = world.entity()
		local e = world.entity()
		world.add(e, pair(R, T))
		world.add(e, pair(Owns, X))

		-- stripping pair(R, T) fires this hook; deleting X cascades into e and
		-- destroys the very archetype that was being wiped
		world.removed(pair(R, ecs.Wildcard), function()
			if world.alive(X) then
				world.delete(X)
			end
		end)

		world.delete(T)

		expect(world.alive(T)).to.equal(false)
		expect(world.alive(X)).to.equal(false)
		expect(world.alive(e)).to.equal(false)

		expect_record_lists_consistent(world)
		expect_no_dead_rows(world)
	end)

	CASE("deleting a relation with a delete flag drains archetypes appended mid-cascade", function()
		local world = ecs.world()
		local R = world.tag()
		local Attached = world.tag()
		world.add(R, pair(ecs.OnDelete, ecs.Delete))

		local a = world.entity()
		local b = world.entity()
		local t1 = world.entity()
		local t2 = world.entity()
		world.add(a, pair(R, t1))
		world.add(b, pair(R, t2))
		world.add(b, pair(Attached, a))

		world.delete(R)

		expect(world.alive(R)).to.equal(false)
		expect(world.alive(a)).to.equal(false)
		expect(world.alive(b)).to.equal(false)
		expect(world.alive(t1)).to.equal(true)

		expect_record_lists_consistent(world)
		expect_no_dead_rows(world)
	end)

	CASE("world.each survives deleting the yielded entity and its archetype", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local C = world.tag()
		local seen = {}
		local all = {}
		for i = 1, 6 do
			local e = world.entity()
			world.add(e, A)
			if i % 2 == 0 then
				world.add(e, B)
			end
			if i % 3 == 0 then
				world.add(e, C)
			end
			table.insert(all, e)
		end

		for entity in world.each(A) do
			table.insert(seen, entity)
			world.delete(entity)
		end

		expect(sorted(seen)).to.equal(sorted(all))
		expect(collect(world.each(A))).to.equal {}
		expect_record_lists_consistent(world)
	end)

	CASE("bulk_add with a repeated id from the root archetype links the record once", function()
		local world = ecs.world()
		local A = world.tag()
		local e = world.entity()
		world.bulk_add(e, { A, A })

		local record = world.components_lookup[A]
		expect(#record.archetype_ids).to.equal(count_keys(record.column_index))
		expect_record_lists_consistent(world)
	end)
end)

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

-- query engine -------------------------------------------------------------------

TEST("query engine", function()
	local function rows(query: any): { { any } }
		local out = {}
		for entity, a, b, c in query do
			table.insert(out, { entity, a, b, c })
		end
		return out
	end

	local function entities_of(query: any): { any }
		local out = {}
		for entity in query do
			table.insert(out, entity)
		end
		return out
	end

	CASE("static: term outputs match world.query for 1 to 10 terms", function()
		for n = 1, 10 do
			local world = ecs.world()
			local e1 = world.entity()
			local ids = with_components(world, e1, n)
			local e2 = world.entity()
			for i, id in ids do
				world.set(e2, id, -i)
			end

			local builder = world.query_build()
			for _, id in ids do
				builder:term(id)
			end
			local query = builder:build()
			expect(query.is_static).to.equal(true)

			local seen = {}
			local iter = query:iter()
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

	CASE("static: with narrows, without excludes, no outputs yields entities only", function()
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

		expect(sorted(entities_of(world.query_build():with(A):with(B):build()))).to.equal(sorted { ab, abc })
		expect(entities_of(world.query_build():with(A):without(B):build())).to.equal { a }
		expect(entities_of(world.query_build():with(A):with(B):without(C):build())).to.equal { ab }
	end)

	CASE("static: optional yields nil when the component is missing", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local e1 = world.entity()
		local e2 = world.entity()
		world.set(e1, A, 1)
		world.set(e2, A, 2)
		world.set(e2, B, "b")

		local query = world.query_build():term(A):term(B):optional():build()
		expect(query.is_static).to.equal(true)
		local seen = {}
		for entity, a, b in query do
			seen[entity] = { a, b }
		end
		expect(seen[e1]).to.equal { 1 }
		expect(seen[e2]).to.equal { 2, "b" }
		expect(count_keys(seen)).to.equal(2)
	end)

	CASE("static: wildcard and concrete targets", function()
		local world = ecs.world()
		local R = world.component()
		local T1 = world.entity()
		local T2 = world.entity()
		local e1 = world.entity()
		local e2 = world.entity()
		world.set(e1, ecs.pair(R, T1), "one")
		world.set(e2, ecs.pair(R, T2), "two")

		local seen = {}
		for entity, value in world.query_build():term(R):wildcard():build() do
			seen[entity] = value
		end
		expect(seen).to.equal { [e1] = "one", [e2] = "two" }

		expect(rows(world.query_build():term(R):target(T2):build())).to.equal { { e2, "two" } }
		expect(entities_of(world.query_build():with(R):target(T1):build())).to.equal { e1 }

		local other = world.entity()
		world.add(other, T1)
		expect(entities_of(world.query_build():with(T1):without(R):wildcard():build())).to.equal { other }
	end)

	CASE("static: deleting the yielded entity mid-iteration visits every entity once", function()
		local world = ecs.world()
		local A = world.component()
		local expected = {}
		for i = 1, 20 do
			local e = world.entity()
			world.set(e, A, i)
			expected[e] = true
		end

		local seen = {}
		for entity in world.query_build():term(A):build() do
			expect(seen[entity]).to.beNil()
			seen[entity] = true
			world.delete(entity)
		end
		expect(seen).to.equal(expected)
		expect(entities_of(world.query_build():term(A):build())).to.equal {}
	end)

	CASE("non cached queries see new archetypes on the next iteration", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e1 = world.entity()
		world.add(e1, A)

		local query = world.query_build():with(A):build()
		expect(entities_of(query)).to.equal { e1 }
		expect(#query:archetypes()).to.equal(1)

		local e2 = world.entity()
		world.bulk_add(e2, { A, B })
		expect(sorted(entities_of(query))).to.equal(sorted { e1, e2 })
		expect(#query:archetypes()).to.equal(2)
	end)

	CASE("up walks the relation until the component is found", function()
		local world = ecs.world()
		local Model = world.component()
		local Tag = world.tag()
		local grandparent = world.entity()
		local parent = world.entity()
		local child1 = world.entity()
		local child2 = world.entity()
		local orphan = world.entity()
		local root = world.entity()
		world.set(grandparent, Model, "gp")
		world.add(parent, ecs.pair(ecs.ChildOf, grandparent))
		world.add(child1, ecs.pair(ecs.ChildOf, parent))
		world.add(child2, ecs.pair(ecs.ChildOf, parent))
		world.add(orphan, ecs.pair(ecs.ChildOf, root))
		world.add(root, Tag)
		world.add(orphan, Tag)
		world.add(child1, Tag)
		world.add(child2, Tag)
		world.add(parent, Tag)

		local query = world.query_build():with(Tag):term(Model):up(ecs.ChildOf):build()
		expect(query.is_static).to.equal(false)

		local seen = {}
		for entity, model in query do
			seen[entity] = model
		end
		expect(seen).to.equal { [parent] = "gp", [child1] = "gp", [child2] = "gp" }

		-- parent gains Model: children now read the closer value, re-resolved per iteration
		world.set(parent, Model, "p")
		seen = {}
		for entity, model in query do
			seen[entity] = model
		end
		expect(seen).to.equal { [parent] = "gp", [child1] = "p", [child2] = "p" }

		-- reparenting changes the result
		world.add(child1, ecs.pair(ecs.ChildOf, grandparent))
		seen = {}
		for entity, model in query do
			seen[entity] = model
		end
		expect(seen).to.equal { [parent] = "gp", [child1] = "gp", [child2] = "p" }
	end)

	CASE("up with optional, self and without", function()
		local world = ecs.world()
		local Model = world.component()
		local Disabled = world.tag()
		local Tag = world.tag()
		local parent = world.entity()
		local child = world.entity()
		local own = world.entity()
		local root = world.entity()
		world.set(parent, Model, "p")
		world.set(own, Model, "own")
		world.add(child, ecs.pair(ecs.ChildOf, parent))
		world.add(own, ecs.pair(ecs.ChildOf, parent))
		world.add(child, Tag)
		world.add(own, Tag)
		world.add(root, Tag)

		local seen = {}
		for entity, model in world.query_build():with(Tag):term(Model):up(ecs.ChildOf):optional():build() do
			seen[entity] = { model }
		end
		expect(seen).to.equal { [child] = { "p" }, [own] = { "p" }, [root] = {} }

		seen = {}
		for entity, model in world.query_build():with(Tag):term(Model):up(ecs.ChildOf):self():build() do
			seen[entity] = model
		end
		expect(seen).to.equal { [child] = "p", [own] = "own" }

		local disabled_parent = world.entity()
		local disabled_child = world.entity()
		world.add(disabled_parent, Disabled)
		world.add(disabled_child, ecs.pair(ecs.ChildOf, disabled_parent))
		world.add(disabled_child, Tag)

		expect(sorted(entities_of(world.query_build():with(Tag):without(Disabled):up(ecs.ChildOf):build()))).to.equal(
			sorted { child, own, root }
		)
		expect(entities_of(world.query_build():with(Tag):with(Disabled):up(ecs.ChildOf):build())).to.equal {
			disabled_child,
		}
	end)

	CASE("up terminates on relation cycles", function()
		local world = ecs.world()
		local R = world.tag()
		local Model = world.component()
		local Tag = world.tag()
		local a = world.entity()
		local b = world.entity()
		world.add(a, ecs.pair(R, b))
		world.add(b, ecs.pair(R, a))
		world.add(a, Tag)
		world.add(b, Tag)

		expect(entities_of(world.query_build():with(Tag):term(Model):up(R):build())).to.equal {}

		local seen = {}
		for entity, model in world.query_build():with(Tag):term(Model):up(R):optional():build() do
			seen[entity] = { model }
		end
		expect(seen).to.equal { [a] = {}, [b] = {} }
	end)

	CASE("deleting the yielded entity mid-iteration is safe with a program", function()
		local world = ecs.world()
		local Model = world.component()
		local parent = world.entity()
		world.set(parent, Model, "p")
		local expected = {}
		for _ = 1, 20 do
			local child = world.entity()
			world.add(child, ecs.pair(ecs.ChildOf, parent))
			expected[child] = true
		end

		local seen = {}
		for entity, model in world.query_build():term(Model):up(ecs.ChildOf):build() do
			expect(model).to.equal "p"
			expect(seen[entity]).to.beNil()
			seen[entity] = true
			world.delete(entity)
		end
		expect(seen).to.equal(expected)
	end)

	CASE("target variables bind once per pair and can be read back", function()
		local world = ecs.world()
		local Located = world.component()
		local Foo = world.component()
		local room1 = world.entity()
		local room2 = world.entity()
		local room3 = world.entity()
		world.set(room1, Foo, "foo1")
		world.set(room2, Foo, "foo2")
		local e = world.entity()
		local single = world.entity()
		world.set(e, ecs.pair(Located, room1), 1)
		world.set(e, ecs.pair(Located, room2), 2)
		world.set(single, ecs.pair(Located, room3), 3)

		local query = world.query_build():term(Located):target("$room"):build()
		local results = {}
		for entity, value in query do
			table.insert(results, { entity, value, query:var "$room" })
		end
		table.sort(results, function(x, y)
			return x[2] < y[2]
		end)
		expect(results).to.equal { { e, 1, room1 }, { e, 2, room2 }, { single, 3, room3 } }

		-- reading a component from the bound variable
		local sourced = world.query_build():term(Located):target("$room"):term(Foo):from("$room"):build()
		results = {}
		for entity, value, foo in sourced do
			table.insert(results, { entity, value, foo })
		end
		table.sort(results, function(x, y)
			return x[2] < y[2]
		end)
		expect(results).to.equal { { e, 1, "foo1" }, { e, 2, "foo2" } }

		local optional = world.query_build():term(Located):target("$room"):term(Foo):from("$room"):optional():build()
		results = {}
		for entity, value, foo in optional do
			table.insert(results, { entity, value, foo })
		end
		expect(#results).to.equal(3)

		-- deleting a target drops its pair
		world.delete(room2)
		results = {}
		for entity, value in query do
			table.insert(results, { entity, value })
		end
		table.sort(results, function(x, y)
			return x[2] < y[2]
		end)
		expect(results).to.equal { { e, 1 }, { single, 3 } }
	end)

	CASE("a variable bound twice is checked against the same target", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local t1 = world.entity()
		local t2 = world.entity()
		local both = world.entity()
		local one = world.entity()
		world.add(both, ecs.pair(A, t1))
		world.add(both, ecs.pair(B, t1))
		world.add(one, ecs.pair(A, t2))
		world.add(one, ecs.pair(B, t1))

		local query = world.query_build():with(A):target("$v"):with(B):target("$v"):build()
		local results = {}
		for entity in query do
			table.insert(results, { entity, query:var "$v" })
		end
		expect(results).to.equal { { both, t1 } }
	end)

	CASE("an unbound source scans every entity holding the component", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local a1 = world.entity()
		local a2 = world.entity()
		world.set(a1, A, "a1")
		world.set(a2, A, "a2")
		local b1 = world.entity()
		local b2 = world.entity()
		local b3 = world.entity()
		world.set(b1, B, "b1")
		world.set(b2, B, "b2")
		world.set(b3, B, "b3")
		world.set(b3, A, "a3")

		local names = { [b1] = "b1", [b2] = "b2", [b3] = "b3" }
		local query = world.query_build():term(A):term(B):from("$v"):build()
		local results = {}
		for _, a, b in query do
			table.insert(results, a .. ":" .. b .. ":" .. names[query:var "$v"])
		end
		table.sort(results)
		expect(results).to.equal {
			"a1:b1:b1",
			"a1:b2:b2",
			"a1:b3:b3",
			"a2:b1:b1",
			"a2:b2:b2",
			"a2:b3:b3",
			"a3:b1:b1",
			"a3:b2:b2",
			"a3:b3:b3",
		}
	end)

	CASE("reverse lookups yield one result per child", function()
		local world = ecs.world()
		local Parent = world.tag()
		local p1 = world.entity()
		local p2 = world.entity()
		local childless = world.entity()
		world.add(p1, Parent)
		world.add(p2, Parent)
		world.add(childless, Parent)
		local c1 = world.entity()
		local c2 = world.entity()
		local c3 = world.entity()
		world.add(c1, ecs.pair(ecs.ChildOf, p1))
		world.add(c2, ecs.pair(ecs.ChildOf, p1))
		world.add(c3, ecs.pair(ecs.ChildOf, p2))

		local query = world.query_build():with(Parent):with(ecs.ChildOf):from("$child"):target("$this"):build()
		local results = {}
		for entity in query do
			table.insert(results, { entity, query:var "$child" })
		end
		table.sort(results, function(x, y)
			return x[2] < y[2]
		end)
		expect(results).to.equal { { p1, c1 }, { p1, c2 }, { p2, c3 } }
	end)

	CASE("bor picks the first present alternative", function()
		local world = ecs.world()
		local A = world.component()
		local B = world.component()
		local C = world.component()
		local Tag = world.tag()
		local a = world.entity()
		local b = world.entity()
		local ab = world.entity()
		local c = world.entity()
		local none = world.entity()
		world.set(a, A, "a")
		world.set(b, B, "b")
		world.set(ab, A, "ab-a")
		world.set(ab, B, "ab-b")
		world.set(c, C, "c")
		for _, e in { a, b, ab, c, none } do
			world.add(e, Tag)
		end

		local seen = {}
		for entity, value in world.query_build():with(Tag):term(A):bor():term(B):build() do
			seen[entity] = value
		end
		expect(seen).to.equal { [a] = "a", [b] = "b", [ab] = "ab-a" }

		seen = {}
		for entity, value in world.query_build():with(Tag):term(A):bor():term(B):bor():term(C):build() do
			seen[entity] = value
		end
		expect(seen).to.equal { [a] = "a", [b] = "b", [ab] = "ab-a", [c] = "c" }

		seen = {}
		for entity, value in world.query_build():with(Tag):term(A):bor():term(B):optional():build() do
			seen[entity] = { value }
		end
		expect(seen).to.equal { [a] = { "a" }, [b] = { "b" }, [ab] = { "ab-a" }, [c] = {}, [none] = {} }

		expect(sorted(entities_of(world.query_build():with(Tag):with(A):bor():with(C):build()))).to.equal(
			sorted { a, ab, c }
		)
	end)

	CASE("bor can mix self and inherited terms", function()
		local world = ecs.world()
		local Model = world.component()
		local Tag = world.tag()
		local parent = world.entity()
		local child = world.entity()
		local own = world.entity()
		local root = world.entity()
		world.set(parent, Model, "p")
		world.set(own, Model, "own")
		world.add(child, ecs.pair(ecs.ChildOf, parent))
		for _, e in { child, own, root } do
			world.add(e, Tag)
		end

		local seen = {}
		for entity, model in world.query_build():with(Tag):term(Model):bor():term(Model):up(ecs.ChildOf):build() do
			seen[entity] = model
		end
		expect(seen).to.equal { [child] = "p", [own] = "own" }
	end)

	CASE("cached queries follow archetype creation and destruction", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e1 = world.entity()
		world.add(e1, A)

		local observers_before = #(world.internal.archetype_creation_observers[A] or {})
		local query = world.query_build():with(A):build():cached()
		expect(query.is_cached).to.equal(true)
		expect(query:cached()).to.equal(query)
		expect(#query:archetypes()).to.equal(1)

		local e2 = world.entity()
		world.bulk_add(e2, { A, B })
		expect(#query:archetypes()).to.equal(2)
		expect(sorted(entities_of(query))).to.equal(sorted { e1, e2 })
		expect(query:match(world.internal.get_entity_record(e2).archetype)).to.equal(true)

		-- deleting B destroys the { A, B } archetype and moves e2 into { A }
		world.delete(B)
		expect(#query:archetypes()).to.equal(1)
		expect(sorted(entities_of(query))).to.equal(sorted { e1, e2 })

		query:cleanup()
		expect(query.is_cached).to.equal(false)
		expect(#(world.internal.archetype_creation_observers[A] or {})).to.equal(observers_before)
	end)

	CASE("transitive relations match through a chain of pairs", function()
		local world = ecs.world()
		local LocatedIn = world.tag()
		local Contains = world.component()
		local Tag = world.tag()
		world.add(LocatedIn, ecs.Transitive)
		expect(world.get(ecs.Transitive, ecs.Name)).to.equal "ecs.Transitive"

		local earth = world.entity()
		local country = world.entity()
		local city = world.entity()
		local house = world.entity()
		local mars = world.entity()
		world.add(country, ecs.pair(LocatedIn, earth))
		world.add(city, ecs.pair(LocatedIn, country))
		world.add(house, ecs.pair(LocatedIn, city))
		world.set(country, ecs.pair(Contains, earth), "c")
		world.set(city, ecs.pair(Contains, country), "ci")
		world.set(house, ecs.pair(Contains, city), "h")
		for _, e in { earth, country, city, house, mars } do
			world.add(e, Tag)
		end

		-- relation carries the trait: transitive without asking
		local auto = world.query_build():with(Tag):with(LocatedIn):target(earth):build()
		expect(auto.is_static).to.equal(false)
		expect(sorted(entities_of(auto))).to.equal(sorted { country, city, house })
		expect(sorted(entities_of(world.query_build():with(Tag):with(ecs.pair(LocatedIn, earth)):build()))).to.equal(
			sorted { country, city, house }
		)
		expect(sorted(entities_of(world.query_build():with(Tag):without(LocatedIn):target(earth):build()))).to.equal(
			sorted { earth, mars }
		)

		-- relation without the trait: opt in per term, direct match otherwise
		expect(entities_of(world.query_build():with(Tag):with(Contains):target(earth):build())).to.equal { country }
		local manual = world.query_build():with(Tag):term(Contains):target(earth):transitive():build()
		local seen = {}
		for entity, value in manual do
			seen[entity] = value
		end
		expect(seen).to.equal { [country] = "c", [city] = "c", [house] = "c" }
	end)

	CASE("builder and compile errors", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local R = world.tag()
		local T = world.entity()

		expect(function()
			world.query_build():term(A):transitive():build()
		end).to.throw "needs a pair term"
		expect(function()
			world.query_build():term(R):target("$v"):transitive():build()
		end).to.throw "not supported yet"
		expect(function()
			world.query_build():term(R):target(T):up(R):transitive()
		end).to.throw ":transitive()"

		expect(function()
			world.query_build():optional()
		end).to.throw "without a term"
		expect(function()
			world.query_build():without(A):bor()
		end).to.throw ":bor()"
		expect(function()
			world.query_build():term(A):bor():without(B)
		end).to.throw ":bor()"
		expect(function()
			world.query_build():term(A):bor():build()
		end).to.throw "must be followed by a term"
		expect(function()
			world.query_build():term(ecs.pair(R, T)):target(T)
		end).to.throw "pair id"
		expect(function()
			world.query_build():term(A):up(ecs.pair(R, T))
		end).to.throw "relation"
		expect(function()
			world.query_build():term(A):self()
		end).to.throw "requires :up()"
		expect(function()
			world.query_build():term(A):from("$v"):build()
		end).to.throw "required term on $this"
		expect(function()
			world.query_build():with(A):without(R):target("$v"):build()
		end).to.throw "never bound"
		expect(function()
			world.query_build():term(A):target "v"
		end).to.throw "$variable"
	end)
end)

TEST("query cascade", function()
	-- yields every entity of the query with its ChildOf depth, in order
	local function depths(world: ecs.World, query: any, relation: any): ({ any }, { number })
		local entities, out = {}, {}
		for entity in query do
			table.insert(entities, entity)
			table.insert(out, world.depth(entity, relation))
		end
		return entities, out
	end

	local function is_sorted(list: { number }): boolean
		for i = 2, #list do
			if list[i] < list[i - 1] then
				return false
			end
		end
		return true
	end

	-- root (no pair) -> a, b -> a1, a2, b1 -> a1x; every entity carries Tag
	local function tree(world: ecs.World, Tag: any)
		local t = {}
		t.root = world.entity()
		t.a = world.entity()
		t.b = world.entity()
		t.a1 = world.entity()
		t.a2 = world.entity()
		t.b1 = world.entity()
		t.a1x = world.entity()
		for _, e in { t.root, t.a, t.b, t.a1, t.a2, t.b1, t.a1x } do
			world.add(e, Tag)
		end
		world.add(t.a, ecs.pair(ecs.ChildOf, t.root))
		world.add(t.b, ecs.pair(ecs.ChildOf, t.root))
		world.add(t.a1, ecs.pair(ecs.ChildOf, t.a))
		world.add(t.a2, ecs.pair(ecs.ChildOf, t.a))
		world.add(t.b1, ecs.pair(ecs.ChildOf, t.b))
		world.add(t.a1x, ecs.pair(ecs.ChildOf, t.a1))
		return t
	end

	CASE("results come parents first, roots and entities without the relation at the front", function()
		local world = ecs.world()
		local Tag = world.tag()
		local t = tree(world, Tag)
		local loose = world.entity()
		world.add(loose, Tag)

		local query = world.query_build():term(Tag):cascade(ecs.ChildOf):build()
		expect(query.is_static).to.equal(true)

		local entities, order = depths(world, query, ecs.ChildOf)
		expect(#entities).to.equal(8)
		expect(order).to.equal { 0, 0, 1, 1, 2, 2, 2, 3 }
		expect(entities[8]).to.equal(t.a1x)
		-- same depth keeps archetype creation order: (ChildOf, a) before
		-- (ChildOf, b). Rows inside one archetype iterate in reverse as usual.
		expect(sorted { entities[5], entities[6] }).to.equal(sorted { t.a1, t.a2 })
		expect(entities[7]).to.equal(t.b1)

		-- archetypes() exposes the same order
		local seen_depth = -1
		for _, archetype in query:archetypes() do
			local depth = world.internal.archetype_depth(archetype, ecs.ChildOf)
			expect(depth >= seen_depth).to.equal(true)
			seen_depth = depth
		end
	end)

	CASE("reparenting re-sorts cached and uncached queries, order is reused otherwise", function()
		local world = ecs.world()
		local Tag = world.tag()
		local t = tree(world, Tag)

		local uncached = world.query_build():term(Tag):cascade(ecs.ChildOf):build()
		local cached = world.query_build():term(Tag):cascade(ecs.ChildOf):build():cached()

		local first = cached:archetypes()
		expect(cached:archetypes()).to.equal(first)
		-- same table reused while nothing changed
		expect(rawequal(cached:archetypes(), first)).to.equal(true)

		-- b moves under a1x: b is now depth 4 and b1 depth 5
		world.add(t.b, ecs.pair(ecs.ChildOf, t.a1x))
		for _, query in { uncached, cached } do
			local entities, order = depths(world, query, ecs.ChildOf)
			expect(is_sorted(order)).to.equal(true)
			expect(order[#order]).to.equal(5)
			expect(entities[#entities]).to.equal(t.b1)
			expect(entities[#entities - 1]).to.equal(t.b)
		end

		-- a new archetype lands at its depth: a child of root with an extra component
		local Extra = world.component()
		local c = world.entity()
		world.add(c, Tag)
		world.set(c, Extra, 1)
		world.add(c, ecs.pair(ecs.ChildOf, t.root))
		for _, query in { uncached, cached } do
			local entities, order = depths(world, query, ecs.ChildOf)
			expect(is_sorted(order)).to.equal(true)
			expect(table.find(entities, c)).to.equal(3)
		end

		-- deleting a subtree keeps the rest ordered
		world.delete(t.a)
		for _, query in { uncached, cached } do
			local entities, order = depths(world, query, ecs.ChildOf)
			expect(is_sorted(order)).to.equal(true)
			expect(entities).to.equal { t.root, c }
		end
		cached:cleanup()
	end)

	CASE("world transforms propagate in one pass with :up()", function()
		local world = ecs.world()
		local Local = world.component()
		local World = world.component()
		local t = tree(world, world.tag())
		local all = { t.root, t.a, t.b, t.a1, t.a2, t.b1, t.a1x }
		for index, e in all do
			world.set(e, Local, index)
			world.set(e, World, 0)
		end

		local query = world
			.query_build()
			:term(Local)
			:term(World)
			:term(World)
			:up(ecs.ChildOf)
			:optional()
			:cascade(ecs.ChildOf)
			:build()
		expect(query.is_static).to.equal(false)

		for e, local_value, _, parent_world in query do
			world.set(e, World, (parent_world or 0) + local_value)
		end

		expect(world.get(t.root, World)).to.equal(1)
		expect(world.get(t.a, World)).to.equal(1 + 2)
		expect(world.get(t.b, World)).to.equal(1 + 3)
		expect(world.get(t.a1, World)).to.equal(1 + 2 + 4)
		expect(world.get(t.a2, World)).to.equal(1 + 2 + 5)
		expect(world.get(t.b1, World)).to.equal(1 + 3 + 6)
		expect(world.get(t.a1x, World)).to.equal(1 + 2 + 4 + 7)
	end)

	CASE("non traversable relations are sorted too and re-sort every iteration", function()
		local world = ecs.world()
		local Plain = world.tag()
		local Tag = world.tag()
		local root = world.entity()
		local a = world.entity()
		local b = world.entity()
		for _, e in { root, a, b } do
			world.add(e, Tag)
		end
		world.add(b, ecs.pair(Plain, root))
		world.add(a, ecs.pair(Plain, b))

		local query = world.query_build():term(Tag):cascade(Plain):build():cached()
		local entities = depths(world, query, Plain)
		expect(entities).to.equal { root, b, a }

		-- swap the chain without creating archetypes: b under a, a under root
		world.add(a, ecs.pair(Plain, root))
		world.add(b, ecs.pair(Plain, a))
		entities = depths(world, query, Plain)
		expect(entities).to.equal { root, a, b }
		query:cleanup()
	end)

	CASE("builder errors", function()
		local world = ecs.world()
		local A = world.component()
		local R = world.tag()
		local T = world.entity()
		expect(function()
			world.query_build():term(A):cascade(ecs.pair(R, T))
		end).to.throw "relation"
		expect(function()
			world.query_build():term(A):cascade(ecs.ChildOf):cascade(R)
		end).to.throw "one relation"
		-- the modifier is query wide, so it may come before the terms
		expect(function()
			world.query_build():cascade(ecs.ChildOf):term(A):build()
		end).never.to.throw()
	end)
end)

TEST("query engine monitor", function()
	-- collects added / removed events into two lists
	local function record(monitor: any)
		local log = { added = {}, removed = {} }
		monitor.added(function(entity)
			table.insert(log.added, entity)
		end)
		monitor.removed(function(entity)
			table.insert(log.removed, entity)
		end)
		return log
	end

	local function drain(log): ({ any }, { any })
		local added, removed = log.added, log.removed
		log.added, log.removed = {}, {}
		return added, removed
	end

	CASE("static queries reuse the plain monitor", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local e = world.entity()
		local log = record(world.query_build():with(A):without(B):build():monitor())

		world.add(e, A)
		expect(drain(log)).to.equal { e }
		world.add(e, B)
		local added, removed = drain(log)
		expect(added).to.equal {}
		expect(removed).to.equal { e }
		world.remove(e, B)
		expect(drain(log)).to.equal { e }
		world.delete(e)
		added, removed = drain(log)
		expect(added).to.equal {}
		expect(removed).to.equal { e }
	end)

	CASE("up: parent changes fire on the child immediately", function()
		local world = ecs.world()
		local Position = world.component()
		local p1 = world.entity()
		local p2 = world.entity()
		local child = world.entity()
		world.set(p1, Position, 1)

		local log = record(world.query_build():term(Position):up(ecs.ChildOf):build():monitor())

		world.add(child, ecs.pair(ecs.ChildOf, p1))
		expect(drain(log)).to.equal { child }

		world.remove(p1, Position)
		local added, removed = drain(log)
		expect(added).to.equal {}
		expect(removed).to.equal { child }

		world.set(p1, Position, 2)
		expect(drain(log)).to.equal { child }

		-- reparent to a parent without Position, then back
		world.add(child, ecs.pair(ecs.ChildOf, p2))
		added, removed = drain(log)
		expect(added).to.equal {}
		expect(removed).to.equal { child }

		world.add(child, ecs.pair(ecs.ChildOf, p1))
		expect(drain(log)).to.equal { child }

		world.remove(child, ecs.pair(ecs.ChildOf, p1))
		added, removed = drain(log)
		expect(added).to.equal {}
		expect(removed).to.equal { child }
	end)

	CASE("up: propagation reaches grandchildren through a child without the component", function()
		local world = ecs.world()
		local Position = world.component()
		local grandparent = world.entity()
		local parent = world.entity()
		local child = world.entity()
		world.set(grandparent, Position, 1)
		world.add(parent, ecs.pair(ecs.ChildOf, grandparent))
		world.add(child, ecs.pair(ecs.ChildOf, parent))

		local log = record(world.query_build():term(Position):up(ecs.ChildOf):build():monitor())
		expect(drain(log)).to.equal {}

		-- a new entity entering below an already matching chain
		local late = world.entity()
		world.add(late, ecs.pair(ecs.ChildOf, child))
		expect(drain(log)).to.equal { late }

		-- entities matching before the monitor existed are tracked silently
		world.remove(grandparent, Position)
		local added, removed = drain(log)
		expect(added).to.equal {}
		expect(sorted(removed)).to.equal(sorted { parent, child, late })

		world.set(grandparent, Position, 2)
		expect(sorted(drain(log))).to.equal(sorted { parent, child, late })

		-- the middle entity gains its own Position: nothing changes
		world.set(parent, Position, 3)
		added, removed = drain(log)
		expect(added).to.equal {}
		expect(removed).to.equal {}

		-- grandparent loses it now: only parent stops matching, child and late
		-- resolve through parent
		world.remove(grandparent, Position)
		added, removed = drain(log)
		expect(added).to.equal {}
		expect(removed).to.equal { parent }

		world.remove(parent, Position)
		added, removed = drain(log)
		expect(added).to.equal {}
		expect(sorted(removed)).to.equal(sorted { child, late })
	end)

	CASE("up: deleting the parent removes every descendant exactly once", function()
		local world = ecs.world()
		local Position = world.component()
		local parent = world.entity()
		local c1 = world.entity()
		local c2 = world.entity()
		local gc = world.entity()
		world.set(parent, Position, 1)

		local log = record(world.query_build():term(Position):up(ecs.ChildOf):build():monitor())
		world.add(c1, ecs.pair(ecs.ChildOf, parent))
		world.add(c2, ecs.pair(ecs.ChildOf, parent))
		world.add(gc, ecs.pair(ecs.ChildOf, c1))
		expect(sorted(drain(log))).to.equal(sorted { c1, c2, gc })

		world.delete(parent)
		local added, removed = drain(log)
		expect(added).to.equal {}
		expect(sorted(removed)).to.equal(sorted { c1, c2, gc })
	end)

	CASE("bor alternatives fire without leaving the prematched set", function()
		local world = ecs.world()
		local A = world.tag()
		local B = world.tag()
		local C = world.tag()
		local e = world.entity()
		local log = record(world.query_build():with(C):term(A):bor():term(B):build():monitor())

		world.add(e, C)
		expect(drain(log)).to.equal {}
		world.add(e, A)
		expect(drain(log)).to.equal { e }
		world.add(e, B)
		expect(drain(log)).to.equal {}
		world.remove(e, A)
		expect(drain(log)).to.equal {}
		world.remove(e, B)
		local added, removed = drain(log)
		expect(added).to.equal {}
		expect(removed).to.equal { e }
		world.add(e, A)
		expect(drain(log)).to.equal { e }
		world.remove(e, C)
		added, removed = drain(log)
		expect(added).to.equal {}
		expect(removed).to.equal { e }
	end)

	CASE("variable target: changes on the target propagate to its holders", function()
		local world = ecs.world()
		local Likes = world.tag()
		local Tag = world.tag()
		local apple = world.entity()
		local pear = world.entity()
		local e1 = world.entity()
		local e2 = world.entity()
		local e3 = world.entity()
		world.add(e1, ecs.pair(Likes, apple))
		world.add(e2, ecs.pair(Likes, apple))
		world.add(e3, ecs.pair(Likes, pear))

		local log = record(world.query_build():term(Likes):target("$v"):with(Tag):from("$v"):build():monitor())

		world.add(apple, Tag)
		expect(sorted(drain(log))).to.equal(sorted { e1, e2 })
		world.add(pear, Tag)
		expect(drain(log)).to.equal { e3 }
		world.remove(apple, Tag)
		local added, removed = drain(log)
		expect(added).to.equal {}
		expect(sorted(removed)).to.equal(sorted { e1, e2 })

		-- changing the target keeps the entity in the prematched set
		world.remove(e3, ecs.pair(Likes, pear))
		added, removed = drain(log)
		expect(removed).to.equal { e3 }
		world.add(e3, ecs.pair(Likes, apple))
		expect(drain(log)).to.equal {}
		world.add(e3, ecs.pair(Likes, pear))
		expect(drain(log)).to.equal { e3 }
	end)

	CASE("unwatched moves keep events balanced", function()
		local world = ecs.world()
		local Position = world.component()
		local Health = world.component()
		local parent = world.entity()
		local child = world.entity()
		world.set(parent, Position, 1)

		local log = record(world.query_build():term(Position):up(ecs.ChildOf):build():monitor())
		world.add(child, ecs.pair(ecs.ChildOf, parent))
		expect(drain(log)).to.equal { child }

		world.set(child, Health, 10)
		expect(drain(log)).to.equal {}
		world.remove(parent, Position)
		local added, removed = drain(log)
		expect(added).to.equal {}
		expect(removed).to.equal { child }
		world.remove(child, ecs.pair(ecs.ChildOf, parent))
		added, removed = drain(log)
		expect(added).to.equal {}
		expect(removed).to.equal {}
	end)

	CASE("spawning many children fires one added per child", function()
		local world = ecs.world()
		local Position = world.component()
		local parent = world.entity()
		world.set(parent, Position, 1)

		local calls = 0
		local monitor = world.query_build():term(Position):up(ecs.ChildOf):build():monitor()
		monitor.added(function()
			calls += 1
		end)

		for _ = 1, 50 do
			local child = world.entity()
			world.add(child, ecs.pair(ecs.ChildOf, parent))
		end
		expect(calls).to.equal(50)

		local removed = 0
		monitor.removed(function()
			removed += 1
		end)
		world.remove(parent, Position)
		expect(removed).to.equal(50)
		expect(calls).to.equal(50)
	end)

	CASE("callbacks may mutate the world", function()
		local world = ecs.world()
		local Position = world.component()
		local Seen = world.tag()
		local parent = world.entity()
		world.set(parent, Position, 1)

		local monitor = world.query_build():term(Position):up(ecs.ChildOf):build():monitor()
		local added, removed = 0, 0
		monitor.added(function(entity)
			added += 1
			world.add(entity, Seen)
		end)
		monitor.removed(function(entity)
			removed += 1
			world.delete(entity)
		end)

		local c1 = world.entity()
		local c2 = world.entity()
		world.add(c1, ecs.pair(ecs.ChildOf, parent))
		world.add(c2, ecs.pair(ecs.ChildOf, parent))
		expect(added).to.equal(2)
		expect(world.has(c1, Seen)).to.equal(true)

		world.remove(parent, Position)
		expect(removed).to.equal(2)
		expect(world.alive(c1)).to.equal(false)
		expect(world.alive(c2)).to.equal(false)
		expect(added).to.equal(2)
	end)

	CASE("per entity queries error and cleanup detaches every hook", function()
		local world = ecs.world()
		local A = world.tag()
		local Likes = world.tag()
		local Position = world.component()

		expect(function()
			world.query_build():with(A):with(Likes):from("$other"):target("$this"):build():monitor()
		end).to.throw "per entity"

		local parent = world.entity()
		local child = world.entity()
		world.set(parent, Position, 1)
		local monitor = world.query_build():term(Position):up(ecs.ChildOf):build():monitor()
		local log = record(monitor)
		world.add(child, ecs.pair(ecs.ChildOf, parent))
		expect(drain(log)).to.equal { child }

		monitor.cleanup()
		world.remove(parent, Position)
		world.remove(child, ecs.pair(ecs.ChildOf, parent))
		local added, removed = drain(log)
		expect(added).to.equal {}
		expect(removed).to.equal {}
	end)
end)

TEST("DontFragment relations", function()
	local function entities_of(query: any): { any }
		local out = {}
		for entity in query do
			table.insert(out, entity)
		end
		return out
	end

	local function rows(query: any): { any }
		local out = {}
		for entity, a, b in query do
			table.insert(out, { entity, a, b })
		end
		return out
	end

	local function record_of(world: ecs.World, entity: any)
		return world.internal.entity_index.sparse[(entity :: any) % 2 ^ 24]
	end

	local function node_of(world: ecs.World, relation: any, target: any)
		local record = world.components_lookup[ecs.pair(relation, target)] :: any
		return record and record.node
	end

	-- a DontFragment relation with a value, a tag one, and a few targets
	local function setup()
		local world = ecs.world()
		local Rel = world.component()
		world.add(Rel, ecs.DontFragment)
		local TagRel = world.tag()
		world.add(TagRel, ecs.DontFragment)
		local Tag = world.tag()
		local Model = world.component()
		return world, Rel, TagRel, Tag, Model, world.entity(), world.entity()
	end

	CASE("add / set / get / has / remove never create archetypes", function()
		local world, Rel, TagRel, Tag, Model, t1, t2 = setup()
		local e = world.entity()
		world.add(e, Tag)
		local archetypes = count_keys(world.archetypes)

		world.set(e, ecs.pair(Rel, t1), "one")
		world.set(e, ecs.pair(Rel, t2), "two")
		world.add(e, ecs.pair(TagRel, t1))
		expect(count_keys(world.archetypes)).to.equal(archetypes)
		expect(record_of(world, e).sparse_count).to.equal(3)

		expect(world.has(e, ecs.pair(Rel, t1))).to.equal(true)
		expect(world.has(e, ecs.pair(Rel, ecs.Wildcard))).to.equal(true)
		expect(world.has(e, ecs.pair(ecs.Wildcard, t1))).to.equal(true)
		expect(world.has(e, ecs.pair(TagRel, t2))).to.equal(false)
		expect(world.get(e, ecs.pair(Rel, t1))).to.equal "one"
		expect(world.get(e, ecs.pair(Rel, ecs.Wildcard))).to.equal "one"
		expect(world.get(e, ecs.pair(TagRel, t1))).to.beNil()
		local tag, two, model, one = world.get(e, Tag, ecs.pair(Rel, t2), Model, ecs.pair(Rel, t1))
		expect(tag).to.beNil()
		expect(two).to.equal "two"
		expect(model).to.beNil()
		expect(one).to.equal "one"

		-- set on a held pair updates it in place
		world.set(e, ecs.pair(Rel, t1), "uno")
		expect(world.get(e, ecs.pair(Rel, t1))).to.equal "uno"
		expect(record_of(world, e).sparse_count).to.equal(3)

		expect(function()
			world.set(e, ecs.pair(TagRel, t2), 1)
		end).to.throw "tag"

		world.remove(e, ecs.pair(Rel, t1))
		expect(world.has(e, ecs.pair(Rel, t1))).to.equal(false)
		expect(world.get(e, ecs.pair(Rel, t2))).to.equal "two"
		-- removing a missing pair is a no-op
		world.remove(e, ecs.pair(Rel, t1))
		expect(record_of(world, e).sparse_count).to.equal(2)

		-- an entity in the root archetype can still hold pairs
		local root_only = world.entity()
		world.set(root_only, ecs.pair(Rel, t1), "root")
		expect(world.get(root_only, ecs.pair(Rel, t1))).to.equal "root"
		expect(world.has(root_only, ecs.pair(Rel, t1))).to.equal(true)
		expect(world.get(root_only, Model)).to.beNil()
	end)

	CASE("target, pairs and each follow pair id order", function()
		local world, Rel, TagRel, Tag = setup()
		local t1, t2, t3 = world.entity(), world.entity(), world.entity()
		local e = world.entity()
		world.add(e, ecs.pair(Rel, t3))
		world.add(e, ecs.pair(Rel, t1))
		world.add(e, ecs.pair(Rel, t2))

		expect(world.target(e, Rel)).to.equal(t1)
		expect(world.target(e, Rel, 1)).to.equal(t2)
		expect(world.target(e, Rel, 2)).to.equal(t3)
		expect(world.target(e, Rel, 3)).to.beNil()
		expect(world.target(e, TagRel)).to.beNil()
		expect(collect(world.pairs(e, Rel))).to.equal {
			ecs.pair(Rel, t1),
			ecs.pair(Rel, t2),
			ecs.pair(Rel, t3),
		}

		local other = world.entity()
		world.add(other, Tag)
		world.add(other, ecs.pair(Rel, t1))
		expect(sorted(collect(world.each(ecs.pair(Rel, t1))))).to.equal(sorted { e, other })
		expect(sorted(collect(world.each(ecs.pair(Rel, ecs.Wildcard))))).to.equal(sorted { e, other })
		expect(collect(world.each(ecs.pair(Rel, t3)))).to.equal { e }
		-- (*, T) walks the sparse sets of every relation targeting T
		world.add(other, ecs.pair(TagRel, t1))
		expect(#collect(world.each(ecs.pair(ecs.Wildcard, t1)))).to.equal(3)

		-- deleting the yielded entity mid iteration is safe
		local seen = 0
		for entity in world.each(ecs.pair(Rel, t1)) do
			seen += 1
			world.delete(entity)
		end
		expect(seen).to.equal(2)
		expect(collect(world.each(ecs.pair(Rel, t1)))).to.equal {}
	end)

	CASE("exclusive relations swap the held pair", function()
		local world, Rel = setup()
		local Ex = world.component()
		world.add(Ex, ecs.DontFragment)
		world.add(Ex, ecs.Exclusive)
		local t1, t2 = world.entity(), world.entity()
		local e = world.entity()

		local log = {}
		world.added(ecs.pair(Ex, ecs.Wildcard), function(_, id)
			table.insert(log, { "added", id })
		end)
		world.removed(ecs.pair(Ex, ecs.Wildcard), function(_, id)
			table.insert(log, { "removed", id })
			return function()
				table.insert(log, { "post", id })
			end
		end)

		world.set(e, ecs.pair(Ex, t1), 1)
		world.set(e, ecs.pair(Ex, t2), 2)
		expect(world.has(e, ecs.pair(Ex, t1))).to.equal(false)
		expect(world.get(e, ecs.pair(Ex, t2))).to.equal(2)
		expect(collect(world.pairs(e, Ex))).to.equal { ecs.pair(Ex, t2) }
		expect(record_of(world, e).sparse_count).to.equal(1)
		expect(log).to.equal {
			{ "added", ecs.pair(Ex, t1) },
			{ "removed", ecs.pair(Ex, t1) },
			{ "added", ecs.pair(Ex, t2) },
			{ "post", ecs.pair(Ex, t1) },
		}

		-- a non exclusive relation keeps both
		world.add(e, ecs.pair(Rel, t1))
		world.add(e, ecs.pair(Rel, t2))
		expect(#collect(world.pairs(e, Rel))).to.equal(2)
	end)

	CASE("hooks fire for the pair and both wildcards", function()
		local world, Rel, _, _, _, t1 = setup()
		local e = world.entity()
		local log = {}
		local function hook(name: string)
			return function(entity, id, value)
				table.insert(log, { name, id, value })
			end
		end
		world.added(ecs.pair(Rel, t1), hook "added pair")
		world.added(ecs.pair(Rel, ecs.Wildcard), hook "added rel")
		world.added(ecs.pair(ecs.Wildcard, t1), hook "added tgt")
		world.changed(ecs.pair(Rel, ecs.Wildcard), hook "changed rel")
		world.removed(ecs.pair(ecs.Wildcard, t1), hook "removed tgt")

		world.set(e, ecs.pair(Rel, t1), 1)
		world.set(e, ecs.pair(Rel, t1), 2)
		world.remove(e, ecs.pair(Rel, t1))

		local names = {}
		for _, entry in log do
			table.insert(names, entry[1])
		end
		expect(sorted(names)).to.equal(sorted {
			"added pair",
			"added rel",
			"added tgt",
			"changed rel",
			"removed tgt",
		})
		expect(log[4]).to.equal { "changed rel", ecs.pair(Rel, t1), 2 }
	end)

	CASE("clear, wipe and bulk operations", function()
		local world, Rel, TagRel, Tag, Model, t1, t2 = setup()
		local e = world.entity()

		world.bulk_set(e, { Model, ecs.pair(Rel, t1), Tag, ecs.pair(Rel, t2) }, { "m", "one", nil, "two" })
		expect(world.get(e, Model)).to.equal "m"
		expect(world.has(e, Tag)).to.equal(true)
		expect(world.get(e, ecs.pair(Rel, t1))).to.equal "one"
		expect(world.get(e, ecs.pair(Rel, t2))).to.equal "two"
		expect(#world.internal.get_entity_record(e).archetype.components).to.equal(2)

		world.bulk_add(e, { ecs.pair(TagRel, t1), ecs.pair(TagRel, t2) })
		expect(record_of(world, e).sparse_count).to.equal(4)

		world.bulk_remove(e, { Tag, ecs.pair(Rel, t1), ecs.pair(TagRel, t2) })
		expect(world.has(e, Tag)).to.equal(false)
		expect(world.has(e, ecs.pair(Rel, t1))).to.equal(false)
		expect(world.has(e, ecs.pair(TagRel, t2))).to.equal(false)
		expect(record_of(world, e).sparse_count).to.equal(2)

		-- bulk with only sparse pairs from the root archetype
		local root = world.entity()
		world.bulk_add(root, { ecs.pair(TagRel, t1) })
		expect(world.internal.get_entity_record(root).archetype).to.equal(world.ROOT_ARCHETYPE)
		expect(world.has(root, ecs.pair(TagRel, t1))).to.equal(true)

		-- exclusive swap inside a batch
		local Ex = world.tag()
		world.add(Ex, ecs.DontFragment)
		world.add(Ex, ecs.Exclusive)
		world.add(root, ecs.pair(Ex, t1))
		world.bulk_add(root, { Tag, ecs.pair(Ex, t2) })
		expect(collect(world.pairs(root, Ex))).to.equal { ecs.pair(Ex, t2) }
		expect(world.has(root, Tag)).to.equal(true)

		-- clear removes archetype ids and sparse pairs, with removed hooks
		local removed = {}
		world.removed(ecs.pair(Rel, ecs.Wildcard), function(_, id)
			table.insert(removed, id)
		end)
		world.clear(e)
		expect(removed).to.equal { ecs.pair(Rel, t2) }
		expect(record_of(world, e).sparse_count).to.equal(0)
		expect(world.has(e, Model)).to.equal(false)
		expect(world.has(e, ecs.pair(TagRel, t1))).to.equal(false)

		-- clear of an entity holding only sparse pairs
		world.set(e, ecs.pair(Rel, t1), "again")
		world.clear(e)
		expect(world.has(e, ecs.pair(Rel, t1))).to.equal(false)

		-- wipe of a pair and of the whole relation
		local a, b = world.entity(), world.entity()
		world.add(a, ecs.pair(TagRel, t1))
		world.add(b, ecs.pair(TagRel, t1))
		world.add(b, ecs.pair(TagRel, t2))
		world.wipe(ecs.pair(TagRel, t1))
		expect(world.has(a, ecs.pair(TagRel, t1))).to.equal(false)
		expect(world.has(b, ecs.pair(TagRel, t2))).to.equal(true)
		world.wipe(ecs.pair(TagRel, ecs.Wildcard))
		expect(world.has(b, ecs.pair(TagRel, t2))).to.equal(false)
		expect(record_of(world, b).sparse_count).to.equal(0)
	end)

	CASE("deleting a target or the relation cleans every holder", function()
		local world, Rel, TagRel, Tag, Model, t1, t2 = setup()
		local Cascade = world.tag()
		world.add(Cascade, ecs.DontFragment)
		world.add(Cascade, ecs.pair(ecs.OnDeleteTarget, ecs.Delete))
		local Owned = world.tag()
		world.add(Owned, ecs.DontFragment)
		world.add(Owned, ecs.pair(ecs.OnDelete, ecs.Delete))

		local a, b, c = world.entity(), world.entity(), world.entity()
		world.add(a, ecs.pair(Rel, t1))
		world.add(b, ecs.pair(Rel, t1))
		world.add(b, ecs.pair(Rel, t2))
		world.add(c, ecs.pair(Cascade, t1))
		world.add(c, Tag)

		-- t1 dies: a and b lose their pair, c is deleted (OnDeleteTarget Delete)
		local removed = {}
		world.removed(ecs.pair(Rel, ecs.Wildcard), function(entity, id)
			table.insert(removed, entity)
		end)
		world.delete(t1)
		expect(sorted(removed)).to.equal(sorted { a, b })
		expect(world.has(a, ecs.pair(Rel, ecs.Wildcard))).to.equal(false)
		expect(world.target(b, Rel)).to.equal(t2)
		expect(world.alive(c)).to.equal(false)
		expect(world.components_lookup[ecs.pair(Rel, t1)]).to.beNil()
		expect(record_of(world, a).sparse_count).to.equal(0)

		-- the relation dies: pairs are removed (or holders deleted with OnDelete Delete)
		local d = world.entity()
		world.add(d, ecs.pair(Owned, t2))
		world.add(d, ecs.pair(TagRel, t2))
		local e = world.entity()
		world.add(e, ecs.pair(TagRel, t2))
		world.delete(TagRel)
		expect(world.alive(e)).to.equal(true)
		expect(record_of(world, e).sparse_count).to.equal(0)
		expect(world.components_lookup[ecs.pair(TagRel, ecs.Wildcard)]).to.beNil()
		expect(world.internal.dont_fragment_records[ecs.pair(TagRel, ecs.Wildcard)]).to.beNil()
		world.delete(Owned)
		expect(world.alive(d)).to.equal(false)

		-- deleting a holder releases its slots; a recycled id starts clean
		local holder = world.entity()
		world.add(holder, ecs.pair(Rel, t2))
		world.delete(holder)
		local recycled = world.entity()
		expect(ecs.PAIR_SECOND(recycled)).to.equal(ecs.PAIR_SECOND(holder))
		expect(world.has(recycled, ecs.pair(Rel, t2))).to.equal(false)
		expect(collect(world.each(ecs.pair(Rel, t2)))).to.equal { b }
		expect(#world.components_lookup[ecs.pair(Rel, t2)].sparse.dense).to.equal(1)
	end)

	CASE("cycles through a DontFragment relation are torn down", function()
		local world = ecs.world()
		local Link = world.tag()
		world.add(Link, ecs.DontFragment)
		world.add(Link, ecs.pair(ecs.OnDeleteTarget, ecs.Delete))

		local a, b = world.entity(), world.entity()
		world.add(a, ecs.pair(Link, b))
		world.add(b, ecs.pair(Link, a))
		world.add(a, ecs.pair(Link, a))
		world.delete(a)
		expect(world.alive(a)).to.equal(false)
		expect(world.alive(b)).to.equal(false)
		expect(world.components_lookup[ecs.pair(Link, a)]).to.beNil()
		expect(world.components_lookup[ecs.pair(Link, b)]).to.beNil()
	end)

	CASE("trait rules: relations only, before the first pair", function()
		local world = ecs.world()
		local Plain = world.component()
		world.add(Plain, ecs.DontFragment)
		local e = world.entity()
		expect(function()
			world.set(e, Plain, 1)
		end).to.throw "relations"

		local Late = world.tag()
		world.add(e, ecs.pair(Late, world.entity()))
		expect(function()
			world.add(Late, ecs.DontFragment)
		end).to.throw "before"

		-- adding it again to a relation that already has it is a no-op
		local Rel = world.tag()
		world.add(Rel, ecs.DontFragment)
		world.add(e, ecs.pair(Rel, world.entity()))
		world.add(Rel, ecs.DontFragment)
		expect(world.has(Rel, ecs.DontFragment)).to.equal(true)
	end)

	CASE("hierarchy: traversable DontFragment relations use nodes and caches", function()
		local world, Rel, _, _, Model, t1 = setup()
		local Ex = world.tag()
		world.add(Ex, ecs.DontFragment)
		world.add(Ex, ecs.Exclusive)
		world.add(Ex, ecs.Traversable)

		local root, mid, leaf = world.entity(), world.entity(), world.entity()
		world.set(root, Model, "root")
		world.add(mid, ecs.pair(Ex, root))
		world.add(leaf, ecs.pair(Ex, mid))

		local root_node = node_of(world, Ex, root)
		local mid_node = node_of(world, Ex, mid)
		expect(root_node).never.to.beNil()
		expect(mid_node.parent).to.equal(root_node)
		expect(#root_node.children).to.equal(1)
		expect(record_of(world, root).targets).to.equal(1)

		expect(world.depth(leaf, Ex)).to.equal(2)
		expect(world.depth(root, Ex)).to.equal(0)
		expect(world.traverse(leaf, Ex, Model)).to.equal(root)
		local _, value = world.traverse(leaf, Ex, Model)
		expect(value).to.equal "root"

		-- a DontFragment pair held by an ancestor is reachable too, and the
		-- cache follows changes on the ancestor
		world.set(root, ecs.pair(Rel, t1), "from root")
		local holder, held = world.traverse(leaf, Ex, ecs.pair(Rel, t1))
		expect(holder).to.equal(root)
		expect(held).to.equal "from root"
		world.set(mid, ecs.pair(Rel, t1), "from mid")
		holder, held = world.traverse(leaf, Ex, ecs.pair(Rel, t1))
		expect(holder).to.equal(mid)
		expect(held).to.equal "from mid"
		world.remove(mid, ecs.pair(Rel, t1))
		world.remove(root, ecs.pair(Rel, t1))
		expect(world.traverse(leaf, Ex, ecs.pair(Rel, t1))).to.beNil()

		-- re-parenting relinks the nodes and re-computes the depth
		local other = world.entity()
		world.add(mid, ecs.pair(Ex, other))
		expect(mid_node.parent).to.equal(node_of(world, Ex, other))
		expect(#root_node.children).to.equal(0)
		expect(world.depth(leaf, Ex)).to.equal(2)
		expect(world.traverse(leaf, Ex, Model)).to.beNil()

		-- removing the pair re-roots mid
		world.remove(mid, ecs.pair(Ex, other))
		expect(mid_node.parent).to.beNil()
		expect(world.depth(leaf, Ex)).to.equal(1)

		-- the non traversable slow path works per entity as well
		local Plain = world.tag()
		world.add(Plain, ecs.DontFragment)
		world.add(mid, ecs.pair(Plain, root))
		world.add(leaf, ecs.pair(Plain, mid))
		expect(node_of(world, Plain, root)).to.beNil()
		expect(world.depth(leaf, Plain)).to.equal(2)
		expect(world.traverse(leaf, Plain, Model)).to.equal(root)
		world.add(root, ecs.pair(Plain, leaf))
		expect(function()
			world.depth(leaf, Plain)
		end).to.throw "cycle"
	end)

	CASE("engine: terms are checked per entity, archetypes still drive", function()
		local world, Rel, TagRel, Tag, Model, t1, t2 = setup()
		local e1, e2, e3 = world.entity(), world.entity(), world.entity()
		world.add(e1, Tag)
		world.set(e1, ecs.pair(Rel, t1), "e1")
		world.add(e2, Tag)
		world.set(e2, ecs.pair(Rel, t1), "e2")
		world.set(e2, ecs.pair(Rel, t2), "e2-t2")
		world.add(e3, Tag)
		world.add(e3, ecs.pair(TagRel, t1))

		local query = world.query_build():with(Tag):term(ecs.pair(Rel, t1)):build()
		local results = rows(query)
		expect(#results).to.equal(2)
		for _, row in results do
			expect(row[2]).to.equal(if row[1] == e1 then "e1" else "e2")
		end
		-- the archetype of Tag holders is the only prematched one
		expect(#query:archetypes()).to.equal(1)
		expect(query:cached()).to.equal(query)
		expect(#rows(query)).to.equal(2)
		query:cleanup()

		expect(entities_of(world.query_build():with(Tag):without(ecs.pair(Rel, t1)):build())).to.equal { e3 }
		expect(entities_of(world.query_build():with(Tag):with(ecs.pair(TagRel, t1)):build())).to.equal { e3 }

		local optional = rows(world.query_build():with(Tag):term(ecs.pair(Rel, t2)):optional():build())
		expect(#optional).to.equal(3)
		for _, row in optional do
			expect(row[2]).to.equal(if row[1] == e2 then "e2-t2" else nil)
		end

		-- bor between a sparse and a fragmenting term
		world.set(e3, Model, "m3")
		local bor = rows(world.query_build():with(Tag):term(ecs.pair(Rel, t1)):bor():term(Model):build())
		expect(#bor).to.equal(3)
		for _, row in bor do
			expect(row[2]).to.equal(if row[1] == e3 then "m3" elseif row[1] == e1 then "e1" else "e2")
		end

		-- wildcard and concrete :target()
		expect(#rows(world.query_build():with(Tag):term(Rel):wildcard():build())).to.equal(2)
		expect(entities_of(world.query_build():with(Tag):with(Rel):target(t2):build())).to.equal { e2 }
		expect(sorted(entities_of(world.query_build():with(Tag):without(Rel):wildcard():build()))).to.equal(
			sorted { e3 }
		)
	end)

	CASE("engine: variables bind through sparse pairs", function()
		local world, Rel, _, Tag, Model, t1, t2 = setup()
		world.set(t1, Model, "model1")
		local e1, e2 = world.entity(), world.entity()
		world.add(e1, Tag)
		world.set(e1, ecs.pair(Rel, t1), "e1-t1")
		world.add(e2, Tag)
		world.set(e2, ecs.pair(Rel, t1), "e2-t1")
		world.set(e2, ecs.pair(Rel, t2), "e2-t2")

		-- :target("$t") enumerates the entity's pairs
		local query = world.query_build():with(Tag):term(Rel):target("$t"):build()
		local seen = 0
		for entity, value in query do
			seen += 1
			expect(world.get(entity, ecs.pair(Rel, query:var "$t"))).to.equal(value)
		end
		expect(seen).to.equal(3)

		-- a term from the bound target
		local from = rows(world.query_build():with(Tag):term(Rel):target("$t"):term(Model):from("$t"):build())
		expect(#from).to.equal(2)
		for _, row in from do
			expect(row[3]).to.equal "model1"
		end

		-- unbound source scanning a sparse set, and the reverse lookup
		local scan = rows(world.query_build():with(Model):term(ecs.pair(Rel, t1)):from("$h"):build())
		expect(#scan).to.equal(2)
		expect(scan[1][1]).to.equal(t1)
		local reverse = world.query_build():with(Model):term(Rel):from("$h"):target("$this"):build()
		expect(#rows(reverse)).to.equal(2)

		-- a variable bound by a sparse pair checked against a second sparse term
		local Other = world.tag()
		world.add(Other, ecs.DontFragment)
		world.add(e2, ecs.pair(Other, t2))
		local both = world.query_build():with(Tag):with(Rel):target("$t"):with(Other):target("$t"):build()
		expect(entities_of(both)).to.equal { e2 }
	end)

	CASE("engine: queries made of sparse terms iterate the sparse set", function()
		local world, Rel, _, Tag, Model, t1 = setup()
		local e1, e2, e3 = world.entity(), world.entity(), world.entity()
		world.set(e1, ecs.pair(Rel, t1), "e1")
		world.set(e2, ecs.pair(Rel, t1), "e2")
		world.add(e2, Tag)
		world.set(e3, ecs.pair(Rel, world.entity()), "e3")

		local query = world.query_build():term(ecs.pair(Rel, t1)):build()
		local results = rows(query)
		expect(#results).to.equal(2)
		for _, row in results do
			expect(row[2]).to.equal(if row[1] == e1 then "e1" else "e2")
		end
		expect(#entities_of(world.query_build():with(Rel):wildcard():build())).to.equal(3)
		-- fragmenting terms are checked per entity on top
		expect(entities_of(world.query_build():term(ecs.pair(Rel, t1)):with(Tag):build())).to.equal { e2 }
		local mixed = rows(world.query_build():term(ecs.pair(Rel, t1)):term(Model):optional():build())
		expect(#mixed).to.equal(2)

		-- no archetype list to expose, cached() is a no-op
		expect(query:cached()).to.equal(query)
		expect(query.is_cached).to.equal(false)
		expect(function()
			query:archetypes()
		end).to.throw "DontFragment"
		expect(function()
			query:match(world.ROOT_ARCHETYPE)
		end).to.throw "DontFragment"

		-- deleting the yielded entity mid iteration visits everyone once
		local seen = {}
		for entity in world.query_build():term(ecs.pair(Rel, t1)):build() do
			table.insert(seen, entity)
			world.delete(entity)
		end
		expect(sorted(seen)).to.equal(sorted { e1, e2 })
		expect(entities_of(world.query_build():term(ecs.pair(Rel, t1)):build())).to.equal {}
	end)

	CASE("engine: up traverses sparse relations and reaches sparse ids", function()
		local world, Rel, _, Tag, Model, t1 = setup()
		local Ex = world.tag()
		world.add(Ex, ecs.DontFragment)
		world.add(Ex, ecs.Exclusive)
		world.add(Ex, ecs.Traversable)

		local root, child, grandchild = world.entity(), world.entity(), world.entity()
		world.set(root, Model, "root")
		world.add(child, ecs.pair(Ex, root))
		world.add(child, Tag)
		world.add(grandchild, ecs.pair(Ex, child))
		world.add(grandchild, Tag)

		-- :up() through a sparse relation
		local up = rows(world.query_build():with(Tag):term(Model):up(Ex):build())
		expect(#up).to.equal(2)
		for _, row in up do
			expect(row[2]).to.equal "root"
		end
		expect(entities_of(world.query_build():with(Tag):without(Model):up(Ex):build())).to.equal {}
		-- only sparse terms: the (Ex, *) set drives
		expect(#rows(world.query_build():term(Model):up(Ex):build())).to.equal(2)

		-- a sparse id looked up on an ancestor through ChildOf uses the
		-- reachable cache and follows changes on the ancestor
		local parent, kid = world.entity(), world.entity()
		world.set(parent, ecs.pair(Rel, t1), "parent")
		world.add(kid, ecs.pair(ecs.ChildOf, parent))
		world.add(kid, Tag)
		local reach = world.query_build():with(Tag):term(ecs.pair(Rel, t1)):up(ecs.ChildOf):build()
		expect(rows(reach)).to.equal { { kid, "parent" } }
		world.set(parent, ecs.pair(Rel, t1), "changed")
		expect(rows(reach)).to.equal { { kid, "changed" } }
		world.remove(parent, ecs.pair(Rel, t1))
		expect(rows(reach)).to.equal {}
		world.set(parent, ecs.pair(Rel, t1), "back")
		expect(rows(reach)).to.equal { { kid, "back" } }

		-- :self() prefers the entity's own sparse pair, also for wildcards
		world.set(kid, ecs.pair(Rel, t1), "own")
		local own = world.query_build():with(Tag):term(ecs.pair(Rel, t1)):up(ecs.ChildOf):self():build()
		expect(rows(own)).to.equal { { kid, "own" } }
		local wildcard = world.query_build():with(Tag):term(Rel):wildcard():up(ecs.ChildOf):self():build()
		expect(rows(wildcard)).to.equal { { kid, "own" } }
		world.remove(kid, ecs.pair(Rel, t1))
		expect(rows(own)).to.equal { { kid, "back" } }

		-- transitive through a sparse relation
		local Located = world.tag()
		world.add(Located, ecs.DontFragment)
		world.add(Located, ecs.Exclusive)
		world.add(Located, ecs.Transitive)
		local earth, country, city = world.entity(), world.entity(), world.entity()
		world.add(country, ecs.pair(Located, earth))
		world.add(city, ecs.pair(Located, country))
		world.add(city, Tag)
		world.add(country, Tag)
		expect(sorted(entities_of(world.query_build():with(Tag):with(Located):target(earth):build()))).to.equal(
			sorted { country, city }
		)
	end)

	CASE("engine: unsupported features error", function()
		local world, Rel, _, Tag, Model, t1 = setup()
		local Ex = world.tag()
		world.add(Ex, ecs.DontFragment)
		world.add(Ex, ecs.Traversable)

		expect(function()
			world.query_build():with(Tag):cascade(Ex)
		end).to.throw "DontFragment"
		expect(function()
			world.query_build():with(Tag):term(ecs.pair(Rel, t1)):build():monitor()
		end).to.throw "DontFragment"
		expect(function()
			world.query_build():with(Tag):term(Model):up(Ex):build():monitor()
		end).to.throw "DontFragment"
		expect(function()
			world.query_build():with(Tag):term(Rel):target("$t"):term(Model):from("$t"):build():monitor()
		end).to.throw "DontFragment"
	end)

	CASE("world.query falls back to the engine", function()
		local world, Rel, _, Tag, Model, t1 = setup()
		-- created before any pair of the relation exists
		local early = world.query(Tag, ecs.pair(Rel, t1))
		local e1, e2 = world.entity(), world.entity()
		world.add(e1, Tag)
		world.set(e1, ecs.pair(Rel, t1), "v1")
		world.add(e2, Tag)
		world.set(e2, Model, "m2")

		expect(rows(early)).to.equal { { e1, nil, "v1" } }
		expect(early:count()).to.equal(1)
		expect(early:empty()).to.equal(false)
		expect(early:has(e1)).to.equal(true)
		expect(early:has(e2)).to.equal(false)
		expect(early:entities()).to.equal { e1 }
		expect(early:random()).to.equal(e1)
		local first, _, value = early:first()
		expect(first).to.equal(e1)
		expect(value).to.equal "v1"
		expect(early:first(function(entity)
			return entity ~= e1
		end)).to.beNil()
		expect(early:clone():count()).to.equal(1)

		-- :with() / :without() added later swap the query as well
		expect(entities_of(world.query(Tag):without(ecs.pair(Rel, t1)))).to.equal { e2 }
		local cached = world.query(Tag):with(ecs.pair(Rel, t1)):cached()
		expect(cached:count()).to.equal(1)
		expect(cached.is_cached).to.equal(true)
		cached:cleanup()

		for _, method in { "columns", "patch", "archetypes", "match", "rematch", "monitor", "observe", "changed" } do
			expect(function()
				(early :: any)[method](early)
			end).to.throw "DontFragment"
		end

		-- a query without such pairs keeps the archetype path
		local plain = world.query(Tag)
		expect(getmetatable(plain :: any)).never.to.equal(getmetatable(early :: any))
		expect(plain:count()).to.equal(2)
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
