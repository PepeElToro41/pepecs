--!optimize 2
--!native
--!strict

type u24 = number
type u53 = number
type ArchetypeId = number
type Bitset = number
type Column = Array<any>
type Cleanup = () -> ()

type Map<T, V> = { [T]: V }
type Array<T> = { T }

export type Entity<T = any> = { __T: T }
export type Component<T = any> = { __T: T }
export type Id<T = any> = { __T: T }
export type Pair<R, T> = Id<R>

type ArchetypeChangedHook = (source: Archetype, destination: Archetype) -> ()
type SetHook<T = any> = (entity: Entity, id: Id<T>, value: T) -> ()
type RemovedHook<T = any> = (entity: Entity, id: Id<T>) -> (() -> ())?

export type ArchetypeMatch = (archetype: Archetype) -> boolean

type ArchetypeObserverCallback = (archetype: Archetype) -> ()
type ArchetypeObserver = { match: ArchetypeMatch, callback: ArchetypeObserverCallback }

type QueryMonitorCallback = (entity: u53) -> ()

type QueryIdMonitor = {
	match: ArchetypeMatch,
	added: QueryMonitorCallback?,
	removed: QueryMonitorCallback?,
}

type QueryIdObserver = {
	match: ArchetypeMatch,
	callback: QueryMonitorCallback,
}

export type Monitor = {
	cleanup: Cleanup,
	added: (entity: Entity) -> (),
	removed: (entity: Entity) -> (),
}

export type Query<T...> = typeof(setmetatable(
	{} :: {
		is_cached: boolean,
		with_ids: { Entity },
		without_ids: { Entity }?,
		terms: { Entity },

		with: (...Component) -> Query<T...>,
		without: (...Component) -> Query<T...>,
		clone: () -> Query<T...>,
		archetypes: () -> { Archetype },

		match: (Archetype) -> boolean,
		has: (entity: Entity) -> boolean,
		empty: () -> boolean,
		count: () -> number,
		entities: () -> { Entity },
		random: () -> Entity?,
		first: (predicator: ((Entity, T...) -> boolean)?) -> (Entity, T...),

		cached: () -> Query<T...>,
		cleanup: Cleanup,
		iter: () -> () -> (Entity, T...),
		update: (mapper: (entity: Entity, T...) -> T...) -> (),

		monitor: () -> Monitor,
		changed: (callback: (entity: Entity) -> ()) -> Cleanup,
	},
	{} :: {
		__iter: () -> () -> (Entity, T...),
	}
))

export type Archetype = {
	archetype_id: ArchetypeId,
	hash: string,
	alive: boolean,

	entities: { Entity },
	columns: Array<Column>,
	components: Array<u53>,

	columns_map: { [u53]: Column },
	forward_edges: Map<u53, Archetype>,
	backward_edges: Map<u53, Archetype>,
}

export type EntityRecord = {
	archetype: Archetype,
	archetype_row: number,
	dense: u24,
	deleting: boolean,

	archetype_changed: { ArchetypeChangedHook }?,
}

export type ComponentRecord = {
	column_index: Map<ArchetypeId, number>,
	id_count: Map<ArchetypeId, number>,

	-- only defined for pair(rel, *)
	pair_records: Map<u53, ComponentRecord>?,

	archetype_count: number,
	flags: Bitset,

	on_added: { SetHook }?,
	on_changed: { SetHook }?,
	on_removed: { RemovedHook }?,

	monitors: { QueryIdMonitor }?,

	-- observers_added will fire when the entity's archetype changes
	-- observers_changed will fire when the column value changes
	observers_added: { QueryIdObserver }?,
	observers_changed: { QueryIdObserver },
}

export type ComponentsLookup = Map<u53, ComponentRecord>

export type EntityIndex = {
	dense: Array<u53>,
	sparse: Map<u24, EntityRecord>,
	alive: number,
}

export type WorldInternal = {
	entity_index: EntityIndex,
	component_record_ensure: (id: u53) -> ComponentRecord,

	get_entity_any: (entity_id: u24) -> u53?,
	get_entity_alive: (entity_id: u24) -> u53?,

	get_entity_record: (entity: u53) -> EntityRecord?,
	get_entity_record_alive: (entity: u53) -> EntityRecord?,
	get_entity_record_asserts_alive: (entity: u53) -> EntityRecord?,

	archetype_creation_observers: Map<u53, { ArchetypeObserver }>,
	archetype_destruction_observers: Map<u53, { ArchetypeObserver }>,
}

export type World = {
	components_lookup: Map<u53, ComponentRecord>,
	archetypes_lookup: Map<string, Archetype>,
	internal: WorldInternal,

	archetypes: Map<ArchetypeId, Archetype>,
	ROOT_ARCHETYPE: Archetype,

	tag: () -> Entity,
	component: <T>() -> Component<T>,
	entity: () -> Entity,

	exists: () -> boolean,
	alive: () -> boolean,
	deleting: (entity: Entity) -> boolean,

	has: (entity: Entity, id: Component) -> boolean,
	get: & (<A>(Entity, Component<A>) -> A)
		& (<A, B>(Entity, Component<A>, Component<A>) -> (A, B))
		& (<A, B, C>(World, Entity, Component<A>, Component<A>, Component<A>) -> (A, B, C))
		& (<A, B, C, D>(Entity, Component<A>, Component<B>, Component<C>, Component<D>) -> (A, B, C, D)),

	parent: (child: Entity) -> Entity,
	children: (parent: Entity) -> () -> Entity,
	target: (entity: Entity, relation: Id, index: number?) -> Entity,
	pairs: (entity: Entity, relation: Id) -> () -> Entity,

	add: (entity: Entity, id: Component) -> (),
	set: <T>(entity: Entity, id: Component<T>, data: T) -> (),
	remove: (entity: Entity, id: Component) -> (),
	delete: (entity: Entity) -> (),

	wipe: (component: Id) -> (),
	clear: (entity: Entity) -> (),

	bulk_add: (entity: Entity, ids: { Id }) -> (),
	bulk_set: (entity: Entity, ids: { Id }, values: { any }) -> (),
	bulk_remove: (entity: Entity, ids: { Id }) -> (),

	added: <T>(id: Id<T>, callback: SetHook<T>) -> Cleanup,
	changed: <T>(id: Id<T>, callback: SetHook<T>) -> Cleanup,
	removed: <T>(id: Id<T>, callback: RemovedHook<T>) -> Cleanup,

	pair_first: <T>(Pair<T, any>) -> Id<T>,
	pair_second: <T>(Pair<any, T>) -> Id<T>,
	is_component: (Id) -> boolean,
	is_tag: (Id) -> boolean,

	each: (id: Component) -> () -> Entity,
	query: (() -> Query<nil>)
		& (<A>(Component<A>) -> Query<A>)
		& (<A, B>(Component<A>, Component<B>) -> Query<A, B>)
		& (<A, B, C>(Component<A>, Component<B>, Component<C>) -> Query<A, B, C>)
		& (<A, B, C, D>(Component<A>, Component<B>, Component<C>, Component<D>) -> Query<A, B, C, D>)
		& (<A, B, C, D, E>(
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>
		) -> Query<A, B, C, D, E>)
		& (<A, B, C, D, E, F>(
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>
		) -> Query<A, B, C, D, E, F>)
		& (<A, B, C, D, E, F, G>(
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>,
			Component<G>
		) -> Query<A, B, C, D, E, F, G>)
		& (<A, B, C, D, E, F, G, H>(
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>,
			Component<G>,
			Component<H>,
			...Component<any>
		) -> Query<A, B, C, D, E, F, G, H>),
}

local preregistered_count = 0
local preregistered_components: Map<u24, true> = {}

local MAX_COMPONENT_ID = _G.ECS_MAX_COMPONENT_ID or 256

local ENTITY_MASK = bit32.lshift(1, 24)
local GENERATION_MASK = bit32.lshift(1, 16)
local PAIR_OFFSET = 2 ^ 48

local BITSET_RANGE = 32
local BITSET_PAGE_SIZE = 8
local BITSET_MAX_ID = BITSET_RANGE * BITSET_PAGE_SIZE

local ECS_WILDCARD = MAX_COMPONENT_ID + 1
local ECS_CHILDOF = MAX_COMPONENT_ID + 2
local ECS_NAME = MAX_COMPONENT_ID + 3
local ECS_COMPONENT = MAX_COMPONENT_ID + 4
local ECS_EXCLUSIVE = MAX_COMPONENT_ID + 5
local ECS_REST = MAX_COMPONENT_ID + 6

local IS_COMPONENT_FLAG = bit32.lshift(1, 0)
local IS_EXCLUSIVE_FLAG = bit32.lshift(1, 1)

local NULL_ARRAY = table.freeze {} :: { any }

local function NOOP() end

local function IS_PAIR(e: number): boolean
	return e > PAIR_OFFSET
end

local function PAIR_FIRST(id: u53): u24
	return (id - PAIR_OFFSET) // ENTITY_MASK
end

local function PAIR_SECOND(id: u53): u24
	return (id - PAIR_OFFSET) % ENTITY_MASK
end

local function ECS_PAIR(first: u24, second: u24): u53
	first %= ENTITY_MASK
	second %= ENTITY_MASK

	return second + (first * ENTITY_MASK) + PAIR_OFFSET
end

local function ENTITY_ID(e: u53): u24
	return e % ENTITY_MASK
end

local function ENTITY_GENERATION(e: u53): u24
	return e // ENTITY_MASK
end

local function APPEND_GENERATION(id: number, generation: number): u53
	return id + (generation * ENTITY_MASK)
end

local function HASH_IDS(ids: { u53 })
	return table.concat(ids, "-")
end

local function FIND_INSERT(ids: { u53 }, added: u53)
	for i, id in ids do
		if id == added then
			return -1
		end
		if id > added then
			return i
		end
	end
	return #ids + 1
end

local function SET_COMPONENT_BITSETS(component_bitsets: Map<number, Bitset>, id: number)
	local bit = id - 1
	local bitset_page = bit // BITSET_RANGE
	local bit_index = bit - (bitset_page * BITSET_RANGE)

	local bitset_index = bitset_page + 1
	local bitset = component_bitsets[bitset_index] or 0
	component_bitsets[bitset_index] = bit32.bor(bitset, bit32.lshift(1, bit_index))
end

local CHECK_FLAG = bit32.btest

local function INCREMENT_GENERATION(e: u53): u53
	if e > ENTITY_MASK then
		local id = ENTITY_ID(e)
		local generation = ENTITY_GENERATION(e)

		local next_gen = generation + 1
		if next_gen >= GENERATION_MASK then
			return id
		end

		return APPEND_GENERATION(id, next_gen)
	end
	return APPEND_GENERATION(e, 1)
end

local function FIRE_SET_HOOKS(hooks: { SetHook }, entity: u53, id: u53, data: any)
	for _, hook in hooks do
		hook(entity :: any, id :: any, data)
	end
end

local function FIRE_REMOVE_HOOKS(hooks: { RemovedHook }, entity: u53, id: u53)
	local post_removed_callbacks: { () -> () }? = nil

	for _, hook in hooks do
		local post_removed = hook(entity :: any, id :: any)
		if post_removed then
			if post_removed_callbacks then
				table.insert(post_removed_callbacks, post_removed)
			else
				post_removed_callbacks = { post_removed }
			end
		end
	end

	return post_removed_callbacks
end

local function FIRE_MONITOR(monitor: QueryIdMonitor, entity: u53, source: Archetype, destination: Archetype)
	local match = monitor.match
	local matched_before = match(source)
	local matched_after = match(destination)

	if matched_before ~= matched_after then
		if matched_before then
			local removed = monitor.removed
			if removed then
				removed(entity)
			end
		else
			local added = monitor.added
			if added then
				added(entity)
			end
		end
	end
end

local function FIRE_QUERY_MONITORS(monitors: { QueryIdMonitor }, entity: u53, source: Archetype, destination: Archetype)
	for _, monitor in monitors do
		FIRE_MONITOR(monitor, entity, source, destination)
	end
end

local function FIRE_QUERY_OBSERVERS(observers: { QueryIdObserver }, entity: u53, archetype: Archetype)
	for _, observer in observers do
		if observer.match(archetype) then
			observer.callback(entity)
		end
	end
end

local function FIRE_QUERY_OBSERVERS_SET(observers_set: Map<QueryIdObserver, true>, entity: u53, archetype: Archetype)
	for observer in observers_set do
		if observer.match(archetype) then
			observer.callback(entity)
		end
	end
end

-- monitors/observers will be accumulated in a set in bulk operations
-- to prevent them from firing multiple times when bulk operations are used.
-- multiple monitors that belong to the same query are ovewritten and fire once per query
-- its slower but keeps monitors reliable
local function ACCUMULATE_MONITORS_SET(
	component_record: ComponentRecord,
	monitors_set: Map<QueryIdMonitor, true>?,
	observers_added_set: Map<QueryIdObserver, true>?,
	observers_changed_set: Map<QueryIdObserver, true>?
)
	if monitors_set then
		local monitors = component_record.monitors
		if monitors then
			for _, monitor in monitors do
				monitors_set[monitor] = true
			end
		end
	end

	if observers_added_set then
		local observers_added = component_record.observers_added
		if observers_added then
			for _, observer in observers_added do
				observers_added_set[observer] = true
			end
		end
	end

	if observers_changed_set then
		local observers_changed = component_record.observers_changed
		if observers_changed then
			for _, observer in observers_changed do
				observers_changed_set[observer] = true
			end
		end
	end
end

local function PREREGISTER_COMPONENT()
	local id = MAX_COMPONENT_ID - preregistered_count
	preregistered_count += 1
	preregistered_components[id] = true
	return id
end

local function PREREGISTER_TAG()
	local id = MAX_COMPONENT_ID - preregistered_count
	preregistered_count += 1
	return id
end

local function REMOVE_INSERTED_OBSERVERS<T>(inserted_in: { { T } }, observer: T)
	for _, observers in inserted_in do
		local index = table.find(observers, observer)
		if index then
			table.remove(observers, index)
		end
	end
end

local function MATCH_ARCHETYPES(world: World, with_ids: { number }, without_ids: { number }?, ignore_empty: boolean)
	local archetypes = world.archetypes
	local components_lookup = world.components_lookup

	local best_record: ComponentRecord? = nil
	local best_record_count = math.huge
	local compatible: { Archetype } = {}

	for _, id in with_ids do
		local record = components_lookup[id]
		if not record then
			continue
		end
		local archetype_count = record.archetype_count
		if archetype_count < best_record_count then
			best_record = record
			best_record_count = archetype_count
		end
	end

	if best_record == nil then
		return compatible
	end

	if ignore_empty then
		for archetype_id in best_record.column_index do
			local archetype = archetypes[archetype_id]
			if not archetype.alive then
				continue
			end
			local columns_map = archetype.columns_map
			local skip = false

			for _, component in with_ids do
				if not columns_map[component] then
					skip = true
					break
				end
			end
			if skip then
				continue
			end

			if without_ids then
				for _, component in without_ids do
					if columns_map[component] then
						skip = true
						break
					end
				end
				if skip then
					continue
				end
			end

			table.insert(compatible, archetype)
		end
	else
		for archetype_id in best_record.column_index do
			local archetype = archetypes[archetype_id]
			local columns_map = archetype.columns_map
			local skip = false

			for _, component in with_ids do
				if not columns_map[component] then
					skip = true
					break
				end
			end
			if skip then
				continue
			end

			if without_ids then
				for _, component in without_ids do
					if columns_map[component] then
						skip = true
						break
					end
				end
				if skip then
					continue
				end
			end

			table.insert(compatible, archetype)
		end
	end
	return compatible
end

local function OBSERVE_MATCHED_ARCHETYPES(
	world: World,
	with_ids: { number },
	without_ids: { number }?,
	match: ArchetypeMatch
)
	local internal = world.internal
	local archetype_creation_observers = internal.archetype_creation_observers
	local archetype_destruction_observers = internal.archetype_destruction_observers

	local compatible_archetypes = MATCH_ARCHETYPES(world, with_ids, without_ids, false)
	local compatible_archetypes_map: Map<ArchetypeId, number> = {}

	local observe_id = with_ids[1]

	for index, archetype in compatible_archetypes do
		compatible_archetypes_map[archetype.archetype_id] = index
	end

	local function creation_observer_callback(archetype: Archetype)
		local index = #compatible_archetypes + 1
		compatible_archetypes[index] = archetype
		compatible_archetypes_map[archetype.archetype_id] = index
	end

	local function destruction_observer_callback(archetype: Archetype)
		local archetype_id = archetype.archetype_id
		local row = compatible_archetypes_map[archetype_id]

		local last_row = #compatible_archetypes
		local last_archetype = compatible_archetypes[last_row]

		compatible_archetypes[row] = last_archetype
		compatible_archetypes[last_row] = nil

		compatible_archetypes_map[archetype_id] = nil
		compatible_archetypes_map[last_archetype.archetype_id] = row
	end

	local creation_observer: ArchetypeObserver = {
		match = match,
		callback = creation_observer_callback,
	}
	local destruction_observer: ArchetypeObserver = {
		match = match,
		callback = destruction_observer_callback,
	}

	local creation_observers = archetype_creation_observers[observe_id]
	if creation_observers then
		table.insert(creation_observers, creation_observer)
	else
		archetype_creation_observers[observe_id] = { creation_observer }
	end

	local destruction_observers = archetype_destruction_observers[observe_id]
	if destruction_observers then
		table.insert(destruction_observers, destruction_observer)
	else
		archetype_destruction_observers[observe_id] = { destruction_observer }
	end

	local function cleanup()
		local creation_index = table.find(creation_observers, creation_observer)
		if creation_index then
			table.remove(creation_observers, creation_index)
		end
	end

	return compatible_archetypes, compatible_archetypes_map, cleanup
end

local function observer_new(
	world: World,
	callback: QueryMonitorCallback,
	terms: { u53 },
	with_ids: { u53 },
	without_ids: { u53 }?,
	match: ArchetypeMatch
)
	local component_record_ensure = world.internal.component_record_ensure
	local _, archetypes_map, observers_cleanup = OBSERVE_MATCHED_ARCHETYPES(world, with_ids, without_ids, match)

	local function query_match(archetype: Archetype)
		return archetypes_map[archetype.archetype_id] ~= nil
	end

	local query_observer: QueryIdObserver = {
		match = query_match,
		callback = callback,
	}
	local inserted_in: { { QueryIdObserver } } = {}

	local function insert_added_observers(ids: { u53 })
		for _, id in ids do
			local component_record = component_record_ensure(id)
			local observers = component_record.observers_added
			if observers then
				table.insert(observers, query_observer)
			else
				observers = { query_observer }
				component_record.observers_added = observers
			end
			table.insert(inserted_in, observers :: { QueryIdObserver })
		end
	end

	insert_added_observers(with_ids)
	if without_ids then
		insert_added_observers(without_ids)
	end

	for _, id in terms do
		local component_record = component_record_ensure(id)
		local observers = component_record.observers_changed
		if observers then
			table.insert(observers, query_observer)
		else
			observers = { query_observer }
			component_record.observers_changed = observers
		end
		table.insert(inserted_in, observers :: { QueryIdObserver })
	end

	return function()
		observers_cleanup()
		REMOVE_INSERTED_OBSERVERS(inserted_in, query_observer)
	end
end

local function monitor_new(world: World, with_ids: { u53 }, without_ids: { u53 }?, match: ArchetypeMatch)
	local component_record_ensure = world.internal.component_record_ensure
	local _, archetypes_map, observers_cleanup = OBSERVE_MATCHED_ARCHETYPES(world, with_ids, without_ids, match)

	local function query_match(archetype: Archetype)
		return archetypes_map[archetype.archetype_id] ~= nil
	end

	local query_monitor: QueryIdMonitor = {
		match = query_match,
		added = nil,
		removed = nil,
	}

	local inserted_in: { { QueryIdMonitor } } = {}

	local function monitor_added(callback: QueryMonitorCallback)
		query_monitor.added = callback
	end

	local function monitor_removed(callback: QueryMonitorCallback)
		query_monitor.removed = callback
	end

	local function cleanup()
		observers_cleanup()
		REMOVE_INSERTED_OBSERVERS(inserted_in, query_monitor)
	end

	local function insert_monitors(ids: { u53 })
		for _, id in ids do
			local component_record = component_record_ensure(id)
			local monitors = component_record.monitors
			if monitors then
				table.insert(monitors, query_monitor)
			else
				monitors = { query_monitor }
				component_record.monitors = monitors
			end
			table.insert(inserted_in, monitors :: { QueryIdMonitor })
		end
	end

	local monitor: Monitor = {
		added = monitor_added :: any,
		removed = monitor_removed :: any,
		cleanup = cleanup,
	}

	insert_monitors(with_ids)
	if without_ids then
		insert_monitors(without_ids)
	end

	return monitor
end

local function query_new(world: World, terms: { u53 }, with_ids: { u53 }, without_ids: { u53 }?): Query<any>
	local compatible_archetypes: { Archetype } = nil :: any
	local compatible_archetypes_map: { [ArchetypeId]: number } = {}
	local observers_cleanup: (() -> ())?

	local components_lookup = world.components_lookup
	local internal = world.internal
	local get_entity_record_alive = internal.get_entity_record_alive

	local query = {
		is_cached = false,
		with_ids = with_ids,
		without_ids = without_ids,
		terms = terms,
	}

	local function match_archetype(archetype: Archetype): boolean
		local columns_map = archetype.columns_map
		for _, id in with_ids do
			if not columns_map[id] then
				return false
			end
		end
		if without_ids then
			for _, id in without_ids do
				if columns_map[id] then
					return false
				end
			end
		end
		return true
	end

	local function query_match(archetype: Archetype): boolean
		if query.is_cached then
			return compatible_archetypes_map[archetype.archetype_id] ~= nil
		else
			return match_archetype(archetype)
		end
	end

	local function query_has(entity: u53): boolean
		local record = get_entity_record_alive(entity)
		if not record then
			return false
		end
		return query_match(record.archetype)
	end

	local function query_with(...: u53)
		local ids = { ... }
		table.move(ids, 1, #ids, #with_ids + 1, with_ids)
		return query
	end

	local function query_without(...: u53)
		local ids = { ... }
		if without_ids then
			table.move(ids, 1, #ids, #without_ids + 1, without_ids)
		else
			without_ids = ids
		end
		return query
	end

	local function query_clone()
		return query_new(world, table.clone(terms), table.clone(with_ids), without_ids and table.clone(without_ids))
	end

	local function query_archetypes(): { Archetype }
		if not compatible_archetypes then
			local matched = MATCH_ARCHETYPES(world, with_ids, without_ids, true)
			compatible_archetypes = matched
			return matched
		end
		return compatible_archetypes
	end

	local function query_empty(): boolean
		query_archetypes()
		for _, archetype in compatible_archetypes do
			if archetype.alive then
				return false
			end
		end
		return true
	end

	local function query_count(): number
		query_archetypes()
		local count = 0
		for _, archetype in compatible_archetypes do
			count += #archetype.entities
		end
		return count
	end

	local function query_entities(): { Entity }
		query_archetypes()
		local entities = {}
		for _, archetype in compatible_archetypes do
			if not archetype.alive then
				continue
			end
			local archetype_entities = archetype.entities
			table.move(archetype_entities, 1, #archetype_entities, #entities + 1, entities)
		end
		return entities
	end

	local function query_random(): u53?
		local count = query_count()
		local random = math.random(1, count)

		for _, archetype in compatible_archetypes do
			if not archetype.alive then
				continue
			end
			local entities = archetype.entities
			local entity_count = #entities
			if random <= entity_count then
				return entities[random] :: any
			end
			random -= entity_count
		end
		return nil
	end

	local function query_cached()
		if query.is_cached then
			return
		end
		query.is_cached = true

		-- stylua: ignore
		compatible_archetypes, compatible_archetypes_map, observers_cleanup = OBSERVE_MATCHED_ARCHETYPES(
			world, with_ids, without_ids, match_archetype
		)
	end

	local function query_cleanup()
		if query.is_cached and observers_cleanup then
			query.is_cached = false
			observers_cleanup()
			observers_cleanup = nil
		end
	end

	local function query_monitor(): Monitor
		return monitor_new(world, with_ids, without_ids, match_archetype)
	end

	local function query_changed(callback: QueryMonitorCallback): Cleanup
		return observer_new(world, callback, terms, with_ids, without_ids, match_archetype)
	end

	-- QUERY ITERATION

	local A, B, C, D, E, F, G, H, I = unpack(terms)

	local a: Column, b: Column, c: Column, d: Column
	local e: Column, f: Column, g: Column, h: Column

	local iter_archetype_index = 1
	local iter_archetype: Archetype
	local iter_columns_map: { [u53]: Column }

	local iter_entities: { Entity }
	local iter_entity_index = 0

	local query_iter_next

	local function query_iter(): () -> any
		iter_archetype_index = 1
		compatible_archetypes = query_archetypes()
		iter_archetype = compatible_archetypes[iter_archetype_index]

		if not iter_archetype then
			return NOOP
		end
		iter_entities = iter_archetype.entities
		iter_entity_index = #iter_entities

		iter_columns_map = iter_archetype.columns_map

		if not A then
		elseif not B then
			a = iter_columns_map[A]
		elseif not C then
			a = iter_columns_map[A]
			b = iter_columns_map[B]
		elseif not D then
			a = iter_columns_map[A]
			b = iter_columns_map[B]
			c = iter_columns_map[C]
		elseif not E then
			a = iter_columns_map[A]
			b = iter_columns_map[B]
			c = iter_columns_map[C]
			d = iter_columns_map[D]
		elseif not F then
			a = iter_columns_map[A]
			b = iter_columns_map[B]
			c = iter_columns_map[C]
			d = iter_columns_map[D]
			e = iter_columns_map[E]
		elseif not G then
			a = iter_columns_map[A]
			b = iter_columns_map[B]
			c = iter_columns_map[C]
			d = iter_columns_map[D]
			e = iter_columns_map[E]
			f = iter_columns_map[F]
		elseif not H then
			a = iter_columns_map[A]
			b = iter_columns_map[B]
			c = iter_columns_map[C]
			d = iter_columns_map[D]
			e = iter_columns_map[E]
			f = iter_columns_map[F]
			g = iter_columns_map[G]
		else
			a = iter_columns_map[A]
			b = iter_columns_map[B]
			c = iter_columns_map[C]
			d = iter_columns_map[D]
			e = iter_columns_map[E]
			f = iter_columns_map[F]
			g = iter_columns_map[G]
			h = iter_columns_map[H]
		end

		return query_iter_next
	end

	if not A then
		function query_iter_next(): Entity
			local entity = iter_entities[iter_entity_index]
			while entity == nil do
				iter_archetype_index += 1
				iter_archetype = compatible_archetypes[iter_archetype_index]
				if not iter_archetype then
					return nil :: any
				end
				if not iter_archetype.alive then
					continue
				end

				iter_entities = iter_archetype.entities
				iter_entity_index = #iter_entities
				entity = iter_entities[iter_entity_index]
			end
			iter_entity_index -= 1
			return entity
		end
	elseif not B then
		function query_iter_next(): (Entity, any)
			local entity = iter_entities[iter_entity_index]
			while entity == nil do
				iter_archetype_index += 1
				iter_archetype = compatible_archetypes[iter_archetype_index]
				if not iter_archetype then
					return nil :: any
				end
				if not iter_archetype.alive then
					continue
				end

				iter_entities = iter_archetype.entities
				iter_entity_index = #iter_entities
				entity = iter_entities[iter_entity_index]
				iter_columns_map = iter_archetype.columns_map

				a = iter_columns_map[A]
			end
			local row = iter_entity_index
			iter_entity_index -= 1

			return entity, a[row]
		end
	elseif not C then
		function query_iter_next(): (Entity, any, any)
			local entity = iter_entities[iter_entity_index]
			while entity == nil do
				iter_archetype_index += 1
				iter_archetype = compatible_archetypes[iter_archetype_index]
				if not iter_archetype then
					return nil :: any
				end
				if not iter_archetype.alive then
					continue
				end

				iter_entities = iter_archetype.entities
				iter_entity_index = #iter_entities
				entity = iter_entities[iter_entity_index]
				iter_columns_map = iter_archetype.columns_map

				a = iter_columns_map[A]
				b = iter_columns_map[B]
			end
			local row = iter_entity_index
			iter_entity_index -= 1

			return entity, a[row], b[row]
		end
	elseif not D then
		function query_iter_next(): (Entity, any, any, any)
			local entity = iter_entities[iter_entity_index]
			while entity == nil do
				iter_archetype_index += 1
				iter_archetype = compatible_archetypes[iter_archetype_index]
				if not iter_archetype then
					return nil :: any
				end
				if not iter_archetype.alive then
					continue
				end

				iter_entities = iter_archetype.entities
				iter_entity_index = #iter_entities
				entity = iter_entities[iter_entity_index]
				iter_columns_map = iter_archetype.columns_map

				a = iter_columns_map[A]
				b = iter_columns_map[B]
				c = iter_columns_map[C]
			end
			local row = iter_entity_index
			iter_entity_index -= 1

			return entity, a[row], b[row], c[row]
		end
	elseif not E then
		function query_iter_next(): (Entity, any, any, any, any)
			local entity = iter_entities[iter_entity_index]
			while entity == nil do
				iter_archetype_index += 1
				iter_archetype = compatible_archetypes[iter_archetype_index]
				if not iter_archetype then
					return nil :: any
				end
				if not iter_archetype.alive then
					continue
				end

				iter_entities = iter_archetype.entities
				iter_entity_index = #iter_entities
				entity = iter_entities[iter_entity_index]
				iter_columns_map = iter_archetype.columns_map

				a = iter_columns_map[A]
				b = iter_columns_map[B]
				c = iter_columns_map[C]
				d = iter_columns_map[D]
			end
			local row = iter_entity_index
			iter_entity_index -= 1

			return entity, a[row], b[row], c[row], d[row]
		end
	elseif not F then
		function query_iter_next(): (Entity, any, any, any, any, any)
			local entity = iter_entities[iter_entity_index]
			while entity == nil do
				iter_archetype_index += 1
				iter_archetype = compatible_archetypes[iter_archetype_index]
				if not iter_archetype then
					return nil :: any
				end
				if not iter_archetype.alive then
					continue
				end

				iter_entities = iter_archetype.entities
				iter_entity_index = #iter_entities
				entity = iter_entities[iter_entity_index]
				iter_columns_map = iter_archetype.columns_map

				a = iter_columns_map[A]
				b = iter_columns_map[B]
				c = iter_columns_map[C]
				d = iter_columns_map[D]
				e = iter_columns_map[E]
			end
			local row = iter_entity_index
			iter_entity_index -= 1

			return entity, a[row], b[row], c[row], d[row], e[row]
		end
	elseif not G then
		function query_iter_next(): Entity?
			local entity = iter_entities[iter_entity_index]
			while entity == nil do
				iter_archetype_index += 1
				iter_archetype = compatible_archetypes[iter_archetype_index]
				if not iter_archetype then
					return nil
				end
				if not iter_archetype.alive then
					continue
				end

				iter_entities = iter_archetype.entities
				iter_entity_index = #iter_entities
				entity = iter_entities[iter_entity_index]
				iter_columns_map = iter_archetype.columns_map

				a = iter_columns_map[A]
				b = iter_columns_map[B]
				c = iter_columns_map[C]
				d = iter_columns_map[D]
				e = iter_columns_map[E]
				f = iter_columns_map[F]
			end
			local row = iter_entity_index
			iter_entity_index -= 1

			return entity, a[row], b[row], c[row], d[row], e[row], f[row]
		end
	elseif not H then
		function query_iter_next(): Entity?
			local entity = iter_entities[iter_entity_index]
			while entity == nil do
				iter_archetype_index += 1
				iter_archetype = compatible_archetypes[iter_archetype_index]
				if not iter_archetype then
					return nil
				end
				if not iter_archetype.alive then
					continue
				end

				iter_entities = iter_archetype.entities
				iter_entity_index = #iter_entities
				entity = iter_entities[iter_entity_index]
				iter_columns_map = iter_archetype.columns_map

				a = iter_columns_map[A]
				b = iter_columns_map[B]
				c = iter_columns_map[C]
				d = iter_columns_map[D]
				e = iter_columns_map[E]
				f = iter_columns_map[F]
				g = iter_columns_map[G]
			end
			local row = iter_entity_index
			iter_entity_index -= 1

			return entity, a[row], b[row], c[row], d[row], e[row], f[row], g[row]
		end
	elseif not I then
		function query_iter_next(): Entity?
			local entity = iter_entities[iter_entity_index]
			while entity == nil do
				iter_archetype_index += 1
				iter_archetype = compatible_archetypes[iter_archetype_index]
				if not iter_archetype then
					return nil
				end
				if not iter_archetype.alive then
					continue
				end

				iter_entities = iter_archetype.entities
				iter_entity_index = #iter_entities
				entity = iter_entities[iter_entity_index]
				iter_columns_map = iter_archetype.columns_map

				a = iter_columns_map[A]
				b = iter_columns_map[B]
				c = iter_columns_map[C]
				d = iter_columns_map[D]
				e = iter_columns_map[E]
				f = iter_columns_map[F]
				g = iter_columns_map[G]
				h = iter_columns_map[H]
			end
			local row = iter_entity_index
			iter_entity_index -= 1

			return entity, a[row], b[row], c[row], d[row], e[row], f[row], g[row], h[row]
		end
	else
		local rest = {}
		local terms_count = #terms

		function query_iter_next(): Entity?
			local entity = iter_entities[iter_entity_index]
			while entity == nil do
				iter_archetype_index += 1
				iter_archetype = compatible_archetypes[iter_archetype_index]
				if not iter_archetype then
					return nil
				end
				if not iter_archetype.alive then
					continue
				end

				iter_entities = iter_archetype.entities
				iter_entity_index = #iter_entities
				entity = iter_entities[iter_entity_index]
				iter_columns_map = iter_archetype.columns_map

				a = iter_columns_map[A]
				b = iter_columns_map[B]
				c = iter_columns_map[C]
				d = iter_columns_map[D]
				e = iter_columns_map[E]
				f = iter_columns_map[F]
				g = iter_columns_map[G]
				h = iter_columns_map[H]
			end
			local row = iter_entity_index
			iter_entity_index -= 1

			for i = 9, terms_count do
				rest[i - 8] = iter_columns_map[terms[i]][row]
			end

			return entity, a[row], b[row], c[row], d[row], e[row], f[row], g[row], h[row], unpack(rest)
		end
	end

	local function query_first(predicator: ((Entity, ...any) -> boolean)?): (Entity, ...any)
		query_archetypes()

		if not A then
			for _, archetype in compatible_archetypes do
				if not archetype.alive then
					continue
				end
				local entities = archetype.entities
				local entity_count = #entities

				for row = entity_count, 1, -1 do
					local entity = entities[row] :: any
					if predicator then
						if predicator(entity) then
							return entity
						end
					else
						return entity
					end
				end
			end
		elseif not B then
			for _, archetype in compatible_archetypes do
				if not archetype.alive then
					continue
				end
				local entities = archetype.entities
				local entity_count = #entities

				local columns_map = archetype.columns_map
				local _a = columns_map[A]

				for row = entity_count, 1, -1 do
					local entity = entities[row] :: any

					local aa = _a[row]

					if predicator then
						if predicator(entity, aa) then
							return entity, aa
						end
					else
						return entity, aa
					end
				end
			end
		elseif not C then
			for _, archetype in compatible_archetypes do
				if not archetype.alive then
					continue
				end
				local entities = archetype.entities
				local entity_count = #entities

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]

				for row = entity_count, 1, -1 do
					local entity = entities[row] :: any

					local aa = _a[row]
					local bb = _b[row]

					if predicator then
						if predicator(entity, aa, bb) then
							return entity, aa, bb
						end
					else
						return entity, aa, bb
					end
				end
			end
		elseif not D then
			for _, archetype in compatible_archetypes do
				if not archetype.alive then
					continue
				end
				local entities = archetype.entities
				local entity_count = #entities

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]

				for row = entity_count, 1, -1 do
					local entity = entities[row] :: any

					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]

					if predicator then
						if predicator(entity, aa, bb, cc) then
							return entity, aa, bb, cc
						end
					else
						return entity, aa, bb, cc
					end
				end
			end
		elseif not E then
			for _, archetype in compatible_archetypes do
				if not archetype.alive then
					continue
				end
				local entities = archetype.entities
				local entity_count = #entities

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]
				local _d = columns_map[D]

				for row = entity_count, 1, -1 do
					local entity = entities[row] :: any

					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]
					local dd = _d[row]

					if predicator then
						if predicator(entity, aa, bb, cc, dd) then
							return entity, aa, bb, cc, dd
						end
					else
						return entity, aa, bb, cc, dd
					end
				end
			end
		elseif not F then
			for _, archetype in compatible_archetypes do
				if not archetype.alive then
					continue
				end
				local entities = archetype.entities
				local entity_count = #entities

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]
				local _d = columns_map[D]
				local _e = columns_map[E]

				for row = entity_count, 1, -1 do
					local entity = entities[row] :: any

					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]
					local dd = _d[row]
					local ee = _e[row]

					if predicator then
						if predicator(entity, aa, bb, cc, dd, ee) then
							return entity, aa, bb, cc, dd, ee
						end
					else
						return entity, aa, bb, cc, dd, ee
					end
				end
			end
		elseif not G then
			for _, archetype in compatible_archetypes do
				if not archetype.alive then
					continue
				end
				local entities = archetype.entities
				local entity_count = #entities

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]
				local _d = columns_map[D]
				local _e = columns_map[E]
				local _f = columns_map[F]

				for row = entity_count, 1, -1 do
					local entity = entities[row] :: any

					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]
					local dd = _d[row]
					local ee = _e[row]
					local ff = _f[row]

					if predicator then
						if predicator(entity, aa, bb, cc, dd, ee, ff) then
							return entity, aa, bb, cc, dd, ee, ff
						end
					else
						return entity, aa, bb, cc, dd, ee, ff
					end
				end
			end
		elseif not H then
			for _, archetype in compatible_archetypes do
				if not archetype.alive then
					continue
				end
				local entities = archetype.entities
				local entity_count = #entities

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]
				local _d = columns_map[D]
				local _e = columns_map[E]
				local _f = columns_map[F]
				local _g = columns_map[G]

				for row = entity_count, 1, -1 do
					local entity = entities[row] :: any

					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]
					local dd = _d[row]
					local ee = _e[row]
					local ff = _f[row]
					local gg = _g[row]

					if predicator then
						if predicator(entity, aa, bb, cc, dd, ee, ff, gg) then
							return entity, aa, bb, cc, dd, ee, ff, gg
						end
					else
						return entity, aa, bb, cc, dd, ee, ff, gg
					end
				end
			end
		elseif not I then
			for _, archetype in compatible_archetypes do
				if not archetype.alive then
					continue
				end
				local entities = archetype.entities
				local entity_count = #entities

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]
				local _d = columns_map[D]
				local _e = columns_map[E]
				local _f = columns_map[F]
				local _g = columns_map[G]
				local _h = columns_map[H]

				for row = entity_count, 1, -1 do
					local entity = entities[row] :: any

					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]
					local dd = _d[row]
					local ee = _e[row]
					local ff = _f[row]
					local gg = _g[row]
					local hh = _h[row]

					if predicator then
						if predicator(entity, aa, bb, cc, dd, ee, ff, gg, hh) then
							return entity, aa, bb, cc, dd, ee, ff, gg, hh
						end
					else
						return entity, aa, bb, cc, dd, ee, ff, gg, hh
					end
				end
			end
		else
			local rest = {}
			local terms_count = #terms

			for _, archetype in compatible_archetypes do
				if not archetype.alive then
					continue
				end
				local entities = archetype.entities
				local entity_count = #entities

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]
				local _d = columns_map[D]
				local _e = columns_map[E]
				local _f = columns_map[F]
				local _g = columns_map[G]
				local _h = columns_map[H]

				for row = entity_count, 1, -1 do
					local entity = entities[row] :: any

					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]
					local dd = _d[row]
					local ee = _e[row]
					local ff = _f[row]
					local gg = _g[row]
					local hh = _h[row]

					for i = 9, terms_count do
						rest[i - 8] = columns_map[terms[i]][row]
					end

					if predicator then
						if predicator(entity, aa, bb, cc, dd, ee, ff, gg, hh, unpack(rest)) then
							return entity, aa, bb, cc, dd, ee, ff, gg, hh, unpack(rest)
						end
					else
						return entity, aa, bb, cc, dd, ee, ff, gg, hh, unpack(rest)
					end
				end
			end
		end
		return nil :: any
	end

	local function query_update(mapper: (Entity: Entity, ...any) -> ...any)
		if not A then
			-- nothing to update
			return
		elseif not B then
			for _, archetype in compatible_archetypes do
				local entities = archetype.entities
				if not archetype.alive then
					continue
				end

				local columns_map = archetype.columns_map
				local _a = columns_map[A]

				for row, entity in entities do
					local aa = _a[row]
					local ar = mapper(entity, aa)

					_a[row] = ar
				end
			end
		elseif not C then
			for _, archetype in compatible_archetypes do
				local entities = archetype.entities
				if not archetype.alive then
					continue
				end

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]

				for row, entity in entities do
					local aa = _a[row]
					local bb = _b[row]

					local ar, br = mapper(entity, aa, bb)

					_a[row] = ar
					_b[row] = br
				end
			end
		elseif not D then
			for _, archetype in compatible_archetypes do
				local entities = archetype.entities
				if not archetype.alive then
					continue
				end

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]

				for row, entity in entities do
					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]

					local ar, br, cr = mapper(entity, aa, bb, cc)

					_a[row] = ar
					_b[row] = br
					_c[row] = cr
				end
			end
		elseif not E then
			for _, archetype in compatible_archetypes do
				local entities = archetype.entities
				if not archetype.alive then
					continue
				end

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]
				local _d = columns_map[D]

				for row, entity in entities do
					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]
					local dd = _d[row]

					local ar, br, cr, dr = mapper(entity, aa, bb, cc, dd)

					_a[row] = ar
					_b[row] = br
					_c[row] = cr
					_d[row] = dr
				end
			end
		elseif not F then
			for _, archetype in compatible_archetypes do
				local entities = archetype.entities
				if not archetype.alive then
					continue
				end

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]
				local _d = columns_map[D]
				local _e = columns_map[E]

				for row, entity in entities do
					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]
					local dd = _d[row]
					local ee = _e[row]

					local ar, br, cr, dr, er = mapper(entity, aa, bb, cc, dd, ee)

					_a[row] = ar
					_b[row] = br
					_c[row] = cr
					_d[row] = dr
					_e[row] = er
				end
			end
		elseif not G then
			for _, archetype in compatible_archetypes do
				local entities = archetype.entities
				if not archetype.alive then
					continue
				end

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]
				local _d = columns_map[D]
				local _e = columns_map[E]
				local _f = columns_map[F]

				for row, entity in entities do
					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]
					local dd = _d[row]
					local ee = _e[row]
					local ff = _f[row]

					local ar, br, cr, dr, er, fr = mapper(entity, aa, bb, cc, dd, ee, ff)

					_a[row] = ar
					_b[row] = br
					_c[row] = cr
					_d[row] = dr
					_e[row] = er
					_f[row] = fr
				end
			end
		elseif not H then
			for _, archetype in compatible_archetypes do
				local entities = archetype.entities
				if not archetype.alive then
					continue
				end

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]
				local _d = columns_map[D]
				local _e = columns_map[E]
				local _f = columns_map[F]
				local _g = columns_map[G]

				for row, entity in entities do
					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]
					local dd = _d[row]
					local ee = _e[row]
					local ff = _f[row]
					local gg = _g[row]

					local ar, br, cr, dr, er, fr, gr = mapper(entity, aa, bb, cc, dd, ee, ff, gg)

					_a[row] = ar
					_b[row] = br
					_c[row] = cr
					_d[row] = dr
					_e[row] = er
					_f[row] = fr
					_g[row] = gr
				end
			end
		elseif not I then
			for _, archetype in compatible_archetypes do
				local entities = archetype.entities
				if not archetype.alive then
					continue
				end

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]
				local _d = columns_map[D]
				local _e = columns_map[E]
				local _f = columns_map[F]
				local _g = columns_map[G]
				local _h = columns_map[H]

				for row, entity in entities do
					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]
					local dd = _d[row]
					local ee = _e[row]
					local ff = _f[row]
					local gg = _g[row]
					local hh = _h[row]

					local ar, br, cr, dr, er, fr, gr, hr = mapper(entity, aa, bb, cc, dd, ee, ff, gg, hh)

					_a[row] = ar
					_b[row] = br
					_c[row] = cr
					_d[row] = dr
					_e[row] = er
					_f[row] = fr
					_g[row] = gr
					_h[row] = hr
				end
			end
		else
			local rest = {}
			local terms_count = #terms

			for _, archetype in compatible_archetypes do
				local entities = archetype.entities
				if not archetype.alive then
					continue
				end

				local columns_map = archetype.columns_map
				local _a = columns_map[A]
				local _b = columns_map[B]
				local _c = columns_map[C]
				local _d = columns_map[D]
				local _e = columns_map[E]
				local _f = columns_map[F]
				local _g = columns_map[G]
				local _h = columns_map[H]

				for row, entity in entities do
					local aa = _a[row]
					local bb = _b[row]
					local cc = _c[row]
					local dd = _d[row]
					local ee = _e[row]
					local ff = _f[row]
					local gg = _g[row]
					local hh = _h[row]

					for i = 9, terms_count do
						rest[i - 8] = columns_map[terms[i]][row]
					end

					local values = { mapper(entity, aa, bb, cc, dd, ee, ff, gg, hh, unpack(rest)) }

					_a[row] = values[1]
					_b[row] = values[2]
					_c[row] = values[3]
					_d[row] = values[4]
					_e[row] = values[5]
					_f[row] = values[6]
					_g[row] = values[7]
					_h[row] = values[8]

					for i = 9, terms_count do
						columns_map[terms[i]][row] = values[i]
					end
				end
			end
		end
	end

	query.with = query_with
	query.without = query_without
	query.clone = query_clone
	query.archetypes = query_archetypes

	query.match = query_match
	query.has = query_has
	query.empty = query_empty
	query.count = query_count
	query.entities = query_entities
	query.random = query_random
	query.first = query_first

	query.cached = query_cached
	query.cleanup = query_cleanup
	query.iter = query_iter
	query.update = query_update

	query.monitor = query_monitor
	query.changed = query_changed

	return query :: any
end

local function world_new()
	local dense_arr = {}
	local sparse_arr = {}

	local archetypes_count = 1
	local archetypes: Map<ArchetypeId, Archetype> = {}
	local archetypes_lookup: Map<string, Archetype> = {}

	local component_count = 0
	local components_lookup = table.create(ECS_REST) :: ComponentsLookup

	local archetype_creation_observers: Map<u53, { ArchetypeObserver }> = {}
	local archetype_destruction_observers: Map<u53, { ArchetypeObserver }> = {}

	local entity_index: EntityIndex = {
		dense = dense_arr,
		sparse = sparse_arr,
		alive = 0,
	}

	local ROOT_ARCHETYPE: Archetype = {
		archetype_id = archetypes_count,
		hash = "",
		alive = false,

		entities = {},
		columns = {},
		components = {},

		columns_map = {},
		forward_edges = {},
		backward_edges = {},
	}
	archetypes[1] = ROOT_ARCHETYPE
	archetypes_lookup[""] = ROOT_ARCHETYPE

	local function get_entity_record(entity: u53): EntityRecord?
		return sparse_arr[ENTITY_ID(entity)]
	end

	local function get_entity_record_asserts_alive(entity: u53): EntityRecord?
		local record = sparse_arr[ENTITY_ID(entity)]
		if record == nil then
			return nil
		end
		local dense = record.dense
		if record.dense > entity_index.alive then
			error "attempted to use a dead entity"
		end
		local dense_id = dense_arr[dense]
		if dense_id ~= entity then
			error "attempted to use an entity with a different generation"
		end
		return record
	end

	local function get_entity_record_alive(entity: u53): EntityRecord?
		local record = sparse_arr[ENTITY_ID(entity)]
		if record == nil then
			return nil
		end
		local dense = record.dense
		if dense > entity_index.alive then
			return nil
		end
		local dense_id = dense_arr[dense]
		if dense_id ~= entity then
			return nil
		end
		return record
	end

	local function get_entity_any(entity_id: u24): u53?
		local record = sparse_arr[entity_id]
		return dense_arr[record.dense]
	end

	local function get_entity_alive(entity_id: u24): u53?
		local record = sparse_arr[entity_id]
		if record.dense > entity_index.alive then
			return nil
		end
		return dense_arr[record.dense]
	end

	local function get_new_entity_id(): u53
		local alive = entity_index.alive
		local count = #sparse_arr

		if alive >= count then
			local next_id = count + 1
			local new_record = {
				dense = next_id,
				archetype = ROOT_ARCHETYPE,
			} :: EntityRecord
			table.insert(sparse_arr, new_record)
			table.insert(dense_arr, next_id)
			entity_index.alive = next_id

			return next_id
		end

		alive += 1
		entity_index.alive = alive
		return dense_arr[alive]
	end

	local function delete_entity_id(id: u24)
		local alive = entity_index.alive

		local dense_index = sparse_arr[id].dense
		if dense_index ~= alive then
			local last = dense_arr[alive]
			dense_arr[dense_index] = last
		end
		local new_generation = INCREMENT_GENERATION(dense_arr[dense_index])
		dense_arr[alive] = new_generation
		entity_index.alive -= 1
	end

	local function fetch(columns: { [u53]: Column }, id: u53, row: number)
		local column = columns[id]
		if not column then
			return nil
		end
		return column[row]
	end

	local function world_has(entity: u53, id: u53)
		local record = get_entity_record_asserts_alive(entity)
		if not record then
			return false
		end

		local archetype = record.archetype
		return archetype.columns_map[id] ~= nil
	end

	local function world_get(entity: u53, a: u53, b: u53, c: u53, d: u53, e: u53, ...): any
		local record = get_entity_record_asserts_alive(entity)
		if not record then
			return nil
		end
		local archetype = record.archetype
		if archetype == ROOT_ARCHETYPE then
			return nil
		end

		local columns_map = archetype.columns_map
		local row = record.archetype_row

		if not b then
			return fetch(columns_map, a, row)
		elseif not c then
			return fetch(columns_map, a, row), fetch(columns_map, b, row)
		elseif not d then
			return fetch(columns_map, a, row), fetch(columns_map, b, row), fetch(columns_map, c, row)
		elseif not e then
			return fetch(columns_map, a, row),
				fetch(columns_map, b, row),
				fetch(columns_map, c, row),
				fetch(columns_map, d, row)
		else
			local rest = { ... }
			for index, id in rest do
				rest[index] = fetch(columns_map, id, row)
			end

			return fetch(columns_map, a, row),
				fetch(columns_map, b, row),
				fetch(columns_map, c, row),
				fetch(columns_map, d, row),
				fetch(columns_map, e, row),
				unpack(rest)
		end
	end

	local function component_record_create(id: u53)
		local is_component = world_has(id, ECS_COMPONENT) or (preregistered_components[id] or false)

		local record: ComponentRecord = {
			column_index = {},
			id_count = {},
			pair_records = nil,

			archetype_count = 0,
			flags = bit32.bor((is_component and IS_COMPONENT_FLAG) or 0),

			monitors = {},
			observers_added = {},
			observers_changed = {},
		}

		components_lookup[id] = record
		return record
	end

	local function component_record_ensure(id: u53)
		local record = components_lookup[id]
		if record then
			return record
		end

		return component_record_create(id)
	end

	local function fire_created_archetype(archetype: Archetype)
		local columns_map = archetype.columns_map
		for id in columns_map do
			local observers = archetype_creation_observers[id]
			if not observers then
				continue
			end
			for _, observer in observers do
				if observer.match(archetype) then
					observer.callback(archetype)
				end
			end
		end
	end

	local function fire_destroyed_archetype(archetype: Archetype)
		local columns_map = archetype.columns_map
		for id in columns_map do
			local observers = archetype_destruction_observers[id]
			if not observers then
				continue
			end
			for _, observer in observers do
				if observer.match(archetype) then
					observer.callback(archetype)
				end
			end
		end
	end

	local function archetype_append_to_record(
		record: ComponentRecord,
		archetype_id: ArchetypeId,
		index: number
	): boolean
		local column_index = record.column_index
		local id_count = record.id_count

		if not column_index[archetype_id] then
			column_index[archetype_id] = index
			id_count[archetype_id] = 1
			return true
		else
			id_count[archetype_id] += 1
			return false
		end
	end

	local function archetype_move_column_rows(
		source: Archetype,
		destination: Archetype,
		source_row: number,
		destination_row: number,
		last_row: number
	)
		local source_columns = source.columns

		if source_row == last_row then
			for index, column in source_columns do
				if column == NULL_ARRAY then
					continue
				end

				local destination_column = destination.columns_map[source.components[index]]
				if destination_column then
					destination_column[destination_row] = column[source_row]
				end

				column[last_row] = nil
			end
		else
			for index, column in source_columns do
				if column == NULL_ARRAY then
					continue
				end

				local destination_column = destination.columns_map[source.components[index]]
				if destination_column then
					destination_column[destination_row] = column[source_row]
				end

				column[source_row] = column[last_row]
				column[last_row] = nil
			end
		end
	end

	local function archetype_insert_entity(entity: u53, archetype: Archetype): number
		local entities = archetype.entities
		local last_row = #entities
		local assign_row = last_row + 1

		entities[assign_row] = entity :: any

		if last_row == 0 then
			archetype.alive = true
		end

		return assign_row
	end

	local function archetype_move_entity(entity: u53, record: EntityRecord, source: Archetype, destination: Archetype)
		local source_entities = source.entities
		local destination_entities = destination.entities

		local last_source_row = #source_entities
		local last_destination_row = #destination_entities

		local source_row = record.archetype_row
		local destination_row = last_destination_row + 1

		archetype_move_column_rows(source, destination, source_row, destination_row, last_source_row)

		if source_row == last_source_row then
			source_entities[last_source_row] = nil
			source.alive = false
		else
			local swapped_entity: u53 = source_entities[last_source_row] :: any
			source_entities[source_row] = swapped_entity :: any

			local swapped_record = get_entity_record(swapped_entity) :: EntityRecord
			swapped_record.archetype_row = source_row
			source_entities[last_source_row] = nil
		end

		destination_entities[destination_row] = entity :: any
		record.archetype_row = destination_row
		record.archetype = destination

		if last_destination_row == 0 then
			destination.alive = true
		end
	end

	local function archetype_assign_entity(entity: u53, record: EntityRecord, archetype: Archetype)
		local assigned_row = archetype_insert_entity(entity, archetype)
		record.archetype = archetype
		record.archetype_row = assigned_row
	end

	local function archetype_delete_entity(archetype: Archetype, row: number)
		local columns = archetype.columns
		local entities = archetype.entities
		local last_row = #entities
		local swap = entities[last_row]

		if last_row == row then
			-- delete last column
			for _, column in columns do
				if column ~= NULL_ARRAY then
					column[last_row] = nil
				end
			end
			entities[last_row] = nil

			archetype.alive = false
		else
			-- swap column, and delete last
			local swap_record = get_entity_record(swap :: any)
			if swap_record then
				swap_record.archetype_row = row
			end
			entities[row] = swap

			for _, column in columns do
				if column ~= NULL_ARRAY then
					column[row] = column[last_row]
					column[last_row] = nil
				end
			end
			entities[last_row] = nil
		end
	end

	local function archetype_create(ids: { u53 }, hash: string): Archetype
		local archetype_id = archetypes_count + 1
		archetypes_count = archetype_id

		local columns_length = #ids
		local columns = table.create(columns_length) :: { Column }

		local columns_map: Map<u53, Column> = {}

		local archetype: Archetype = {
			archetype_id = archetype_id,
			hash = hash,
			alive = false,

			entities = {},
			columns = columns,
			components = ids,

			columns_map = columns_map,
			forward_edges = {},
			backward_edges = {},
		}

		for index, id in ids do
			local id_record = component_record_ensure(id)
			id_record.archetype_count += 1

			local is_tag = not CHECK_FLAG(id_record.flags, IS_COMPONENT_FLAG)
			local column = if is_tag then NULL_ARRAY else {}
			columns[index] = column
			columns_map[id] = column

			archetype_append_to_record(id_record, archetype_id, index)

			if IS_PAIR(id) then
				local relation = PAIR_FIRST(id)
				local target = PAIR_SECOND(id)

				local relation_wildcard = ECS_PAIR(relation, ECS_WILDCARD)
				local relation_record = component_record_ensure(relation_wildcard)
				relation_record.archetype_count += 1

				local relation_appended = archetype_append_to_record(relation_record, archetype_id, index)
				if relation_appended then
					columns_map[relation_wildcard] = column
				end

				local pair_records = relation_record.pair_records
				if pair_records then
					pair_records[id] = id_record
				else
					relation_record.pair_records = {
						[id] = id_record,
					}
				end

				local target_wildcard = ECS_PAIR(ECS_WILDCARD, target)
				local target_record = component_record_ensure(target_wildcard)
				target_record.archetype_count += 1

				local target_appended = archetype_append_to_record(target_record, archetype_id, index)
				if target_appended then
					columns_map[target_wildcard] = column
				end
			end
		end

		archetypes[archetype_id] = archetype
		archetypes_lookup[hash] = archetype

		return archetype
	end

	local function archetype_ensure(ids: { u53 }): Archetype
		if #ids < 1 then
			return ROOT_ARCHETYPE
		end

		local hash = HASH_IDS(ids)
		local archetype = archetypes_lookup[hash]
		if archetype then
			return archetype
		end

		return archetype_create(ids, hash)
	end

	local function archetype_find_with(source: Archetype, id: u53): Archetype
		if source.columns_map[id] then
			return source
		end

		local edges = source.forward_edges
		local destination = edges[id]
		if not destination then
			local destination_components = table.clone(source.components)
			local insert_at = FIND_INSERT(destination_components, id)
			table.insert(destination_components, insert_at, id)

			local found = archetype_ensure(destination_components)
			edges[id] = found
			found.backward_edges[id] = source
			return found
		end

		return destination
	end

	local function archetype_find_without(source: Archetype, id: u53)
		local edges = source.backward_edges
		local destination = edges[id]
		if not destination then
			local destination_components = table.clone(source.components)
			local remove_at = table.find(destination_components, id)
			table.remove(destination_components, remove_at)

			local found = archetype_ensure(destination_components)
			edges[id] = found
			found.forward_edges[id] = source
			return found
		end

		return destination
	end

	local function archetype_bulk_modify_columns(row: number, archetype: Archetype, ids: { number }, values: { any })
		local columns_map = archetype.columns_map
		for index, id in ids do
			local value = values[index]
			local column = columns_map[id]
			if value ~= nil then
				column[row] = value
			else
				if column ~= NULL_ARRAY then
					column[row] = nil
				end
			end
		end
	end

	local function world_entity(): u53
		return get_new_entity_id()
	end

	local function world_set(entity: u53, id: u53, data: any)
		local record = get_entity_record_alive(entity)
		if not record then
			return
		end

		local source = record.archetype
		local column = source.columns_map[id]

		if column then
			column[record.archetype_row] = data

			local component_record = components_lookup[id]

			local observers = component_record.observers_changed
			if observers then
				FIRE_QUERY_OBSERVERS(observers, entity, source)
			end

			local changed_hooks = component_record.on_changed
			if changed_hooks then
				FIRE_SET_HOOKS(changed_hooks, entity, id, data)
			end
		else
			local destination = archetype_find_with(source, id)

			if source == ROOT_ARCHETYPE then
				archetype_assign_entity(entity, record, destination)
			else
				archetype_move_entity(entity, record, source, destination)
			end

			local new_column = destination.columns_map[id]
			new_column[record.archetype_row] = data
			local component_record = components_lookup[id]

			local monitors = component_record.monitors
			if monitors then
				FIRE_QUERY_MONITORS(monitors, entity, source, destination)
			end

			local observers = component_record.observers_added
			if observers then
				FIRE_QUERY_OBSERVERS(observers, entity, destination)
			end

			local added_hooks = component_record.on_added
			if added_hooks then
				FIRE_SET_HOOKS(added_hooks, entity, id, data)
			end
		end
	end

	local function world_add(entity: u53, id: u53)
		local record = get_entity_record_alive(entity)
		if not record then
			return
		end

		local source = record.archetype
		if source.columns_map[id] then
			return
		end

		local destination = archetype_find_with(source, id)

		if source == ROOT_ARCHETYPE then
			archetype_assign_entity(entity, record, destination)
		else
			archetype_move_entity(entity, record, source, destination)
		end

		local component_record = components_lookup[id]

		local monitors = component_record.monitors
		if monitors then
			FIRE_QUERY_MONITORS(monitors, entity, source, destination)
		end

		local observers = component_record.observers_added
		if observers then
			FIRE_QUERY_OBSERVERS(observers, entity, destination)
		end

		local added_hooks = component_record.on_added
		if added_hooks then
			FIRE_SET_HOOKS(added_hooks, entity, id)
		end
	end

	local function world_remove(entity: u53, id: u53)
		local record = get_entity_record_alive(entity)
		if not record then
			return
		end

		local source = record.archetype
		if not source.columns_map[id] then
			return
		end

		local component_record = components_lookup[id]
		local removed_hooks = component_record.on_removed
		local post_removed = removed_hooks and FIRE_REMOVE_HOOKS(removed_hooks, entity, id) or nil

		local destination = archetype_find_without(source, id)
		archetype_move_entity(entity, record, source, destination)

		local monitors = component_record.monitors
		if monitors then
			FIRE_QUERY_MONITORS(monitors, entity, source, destination)
		end

		local observers = component_record.observers_added
		if observers then
			FIRE_QUERY_OBSERVERS(observers, entity, destination)
		end

		-- important that post-removed callbacks are called after monitors
		-- because these callbacks should be able to edit the entity archetype freely
		-- so it can cause to fire a monitor_removed event before monitor_added, or viseversa
		if post_removed then
			for _, callback in post_removed do
				callback()
			end
		end
	end

	local function world_delete(entity: u53) end

	local function world_wipe(component: u53)
		local component_record = components_lookup[component]
		if not component_record then
			return
		end

		local on_removed = component_record.on_removed
		local monitors = component_record.monitors
		local observers_added = component_record.observers_added

		for archetype_id in component_record.column_index do
			local source = archetypes[archetype_id]
			if not source.alive then
				continue
			end
			local destination = archetype_find_without(source, component)

			local should_fire = false
			local monitors_added: { QueryIdMonitor }? = nil
			local monitors_removed: { QueryIdMonitor }? = nil
			local valid_observers: { QueryIdObserver }? = nil

			if monitors then
				monitors_added = {}
				monitors_removed = {}

				for _, monitor in monitors do
					local match = monitor.match
					local matched_before = match(source)
					local matched_after = match(destination)

					if matched_before ~= matched_after then
						if matched_before then
							local removed = monitor.removed
							if removed then
								table.insert(monitors_removed, monitor)
								should_fire = true
							end
						else
							local added = monitor.added
							if added then
								table.insert(monitors_added, monitor)
								should_fire = true
							end
						end
					end
				end
			end

			if observers_added then
				valid_observers = {}
				for _, observer in observers_added do
					if observer.match(destination) then
						table.insert(valid_observers, observer)
						should_fire = true
					end
				end
			end

			local source_entities = source.entities
			local columns_map = source.columns_map
			local destination_columns = destination.columns
			local destination_components = destination.components

			local columns_array_map = table.create(#destination_components) :: Array<Column>
			for index, id in destination_components do
				local column = columns_map[id]
				columns_array_map[index] = column
			end

			local post_removed_callbacks: Array<{ () -> () }>

			for row, entity in source_entities do
				if on_removed then
					local post_removed = FIRE_REMOVE_HOOKS(on_removed, entity :: any, component)
					if post_removed then
						if post_removed_callbacks then
							table.insert(post_removed_callbacks, post_removed)
						else
							post_removed_callbacks = { post_removed }
						end
					end
				end

				local record = get_entity_record(entity :: any) :: EntityRecord
				local destination_row = archetype_insert_entity(entity :: any, destination)
				record.archetype = destination
				record.archetype_row = destination_row

				for index, destination_column in destination_columns do
					local column = columns_array_map[index]
					destination_column[destination_row] = column[row]
				end
			end

			source.alive = false
			source.entities = {}

			for _, column in source.columns do
				if column ~= NULL_ARRAY then
					table.clear(column)
				end
			end

			if should_fire then
				for _, entity in source_entities do
					if monitors_added then
						for _, monitor in monitors_removed :: { QueryIdMonitor } do
							local removed = monitor.removed :: (Entity) -> ()
							removed(entity)
						end
						for _, monitor in monitors_added :: { QueryIdMonitor } do
							local added = monitor.added :: (Entity) -> ()
							added(entity)
						end
					end
					if valid_observers then
						for _, observer in valid_observers :: { QueryIdObserver } do
							observer.callback(entity :: any)
						end
					end
				end
			end

			if post_removed_callbacks then
				for _, post_removed in post_removed_callbacks :: Array<{ () -> () }> do
					for _, callback in post_removed do
						callback()
					end
				end
			end
		end
	end

	local function world_clear(entity: u53)
		local record = get_entity_record_asserts_alive(entity)
		if not record then
			return
		end

		local archetype = record.archetype
		if archetype == ROOT_ARCHETYPE then
			return
		end

		local post_removed_callbacks: Array<{ () -> () }>
		local monitors_set: Map<QueryIdMonitor, true> = {}

		for _, id in archetype.components do
			local component_record = components_lookup[id]
			ACCUMULATE_MONITORS_SET(component_record, monitors_set)

			local removed_hooks = component_record.on_removed
			if removed_hooks then
				local post_removed = FIRE_REMOVE_HOOKS(removed_hooks, entity, id)
				if post_removed then
					if post_removed_callbacks then
						table.insert(post_removed_callbacks, post_removed)
					else
						post_removed_callbacks = { post_removed }
					end
				end
			end
		end

		archetype_delete_entity(archetype, record.archetype_row)
		record.archetype = ROOT_ARCHETYPE
		record.archetype_row = nil :: any

		for monitor in monitors_set do
			local removed = monitor.removed
			if removed then
				if monitor.match(archetype) then
					removed(entity)
				end
			end
		end

		if post_removed_callbacks then
			for _, post_removed in post_removed_callbacks do
				for _, callback in post_removed do
					callback()
				end
			end
		end
	end

	local function world_bulk_add(entity: u53, ids: { u53 })
		local record = get_entity_record_asserts_alive(entity)
		if not record then
			return
		end
		local source = record.archetype

		if source == ROOT_ARCHETYPE then
			local destination_ids = table.clone(ids)
			table.sort(destination_ids)

			local destination = archetype_ensure(destination_ids)
			archetype_assign_entity(entity, record, destination)

			-- notifying
			local monitors_set: Map<QueryIdMonitor, true> = {}
			local observers_added_set: Map<QueryIdObserver, true> = {}
			local firing_hooks: Map<number, { SetHook }> = {}

			-- hooks are added in an array to keep the same order things are fired
			-- monitors/observers sets are fired before changed hooks
			-- so this means monitor sets should be fully accumulated before firing added hooks
			for index, id in ids do
				local component_record = components_lookup[id]
				ACCUMULATE_MONITORS_SET(component_record, monitors_set, observers_added_set)
				local on_added = component_record.on_added
				if on_added then
					firing_hooks[index] = on_added
				end
			end

			for monitor in monitors_set do
				local added = monitor.added
				if added then
					local matched = monitor.match(destination)
					if matched then
						added(entity)
					end
				end
			end

			FIRE_QUERY_OBSERVERS_SET(observers_added_set, entity, destination)

			for index, hooks in firing_hooks do
				FIRE_SET_HOOKS(hooks, entity, ids[index], nil)
			end
		else
			local destination_ids = table.clone(source.components)
			local inserted: Array<number> = {}

			-- inserting ids
			for index, id in ids do
				local at = FIND_INSERT(destination_ids, id)
				if at ~= -1 then
					table.insert(destination_ids, id, at)
					table.insert(inserted, index)
				end
			end

			local destination = archetype_ensure(destination_ids)

			-- notifying
			if destination ~= source then
				archetype_move_entity(entity, record, source, destination)

				local monitors_set: Map<QueryIdMonitor, true> = {}
				local observers_added_set: Map<QueryIdObserver, true> = {}
				local firing_hooks: Map<number, { SetHook }> = {}

				for _, index in inserted do
					local id = ids[index]
					local component_record = components_lookup[id]
					ACCUMULATE_MONITORS_SET(component_record, monitors_set, observers_added_set)
					local on_added = component_record.on_added
					if on_added then
						firing_hooks[index] = on_added
					end
				end

				for monitor in monitors_set do
					FIRE_MONITOR(monitor, entity, source, destination)
				end

				FIRE_QUERY_OBSERVERS_SET(observers_added_set, entity, destination)

				for index, hooks in firing_hooks do
					FIRE_SET_HOOKS(hooks, entity, ids[index], nil)
				end
			end
		end
	end

	local function world_bulk_set(entity: u53, ids: { u53 }, values: { any })
		local record = get_entity_record_asserts_alive(entity)
		if not record then
			return
		end
		local source = record.archetype

		if source == ROOT_ARCHETYPE then
			local destination_ids = table.clone(ids)
			table.sort(destination_ids)

			local destination = archetype_ensure(destination_ids)
			archetype_assign_entity(entity, record, destination)
			archetype_bulk_modify_columns(record.archetype_row, destination, ids, values)

			-- notifying
			local monitors_set: Map<QueryIdMonitor, true> = {}
			local observers_added_set: Map<QueryIdObserver, true> = {}
			local firing_hooks: Map<number, { SetHook }> = {}

			for index, id in ids do
				local component_record = components_lookup[id]
				ACCUMULATE_MONITORS_SET(component_record, monitors_set, observers_added_set)
				local on_added = component_record.on_added
				if on_added then
					firing_hooks[index] = on_added
				end
			end

			for monitor in monitors_set do
				local added = monitor.added
				if added then
					local matched = monitor.match(destination)
					if matched then
						added(entity)
					end
				end
			end

			FIRE_QUERY_OBSERVERS_SET(observers_added_set, entity, destination)

			for index, hooks in firing_hooks do
				FIRE_SET_HOOKS(hooks, entity, ids[index], values[index])
			end
		else
			local destination_ids = table.clone(source.components)
			local inserted: Map<number, boolean> = {}

			-- inserting ids
			for index, id in ids do
				local at = FIND_INSERT(destination_ids, id)
				if at == -1 then
					inserted[index] = false
				else
					table.insert(destination_ids, id, at)
					inserted[index] = true
				end
			end

			local destination = archetype_ensure(destination_ids)
			if destination ~= source then
				archetype_move_entity(entity, record, source, destination)
			end

			archetype_bulk_modify_columns(record.archetype_row, destination, ids, values)

			-- notifying
			if destination ~= source then
				local monitors_set: Map<QueryIdMonitor, true> = {}
				local observers_set: Map<QueryIdObserver, true> = {}
				local firing_hooks: Map<number, { SetHook }> = {}

				for index, was_inserted in inserted do
					local id = ids[index]
					local component_record = components_lookup[id]

					local hooks: { SetHook }? = nil
					if was_inserted then
						-- accumulates monitors and observers_added
						ACCUMULATE_MONITORS_SET(component_record, monitors_set, observers_set)
						hooks = component_record.on_added
					else
						-- accumulates observers_changed only
						ACCUMULATE_MONITORS_SET(component_record, nil, nil, observers_set)
						hooks = component_record.on_changed
					end
					if hooks then
						firing_hooks[index] = hooks
					end
				end

				for monitor in monitors_set do
					FIRE_MONITOR(monitor, entity, source, destination)
				end

				FIRE_QUERY_OBSERVERS_SET(observers_set, entity, destination)

				for index, hooks in firing_hooks do
					FIRE_SET_HOOKS(hooks, entity, ids[index], values[index])
				end
			else
				local observers_changed_set: Map<QueryIdObserver, true> = {}
				local firing_hooks: Map<number, { SetHook }> = {}

				for index, id in ids do
					local component_record = components_lookup[id]
					ACCUMULATE_MONITORS_SET(component_record, nil, nil, observers_changed_set)
					local on_changed = component_record.on_changed
					if on_changed then
						firing_hooks[index] = on_changed
					end
				end

				FIRE_QUERY_OBSERVERS_SET(observers_changed_set, entity, destination)

				for index, hooks in firing_hooks do
					FIRE_SET_HOOKS(hooks, entity, ids[index], values[index])
				end
			end
		end
	end

	local function world_bulk_remove(entity: u53, ids: { u53 })
		local record = get_entity_record_asserts_alive(entity)
		if not record then
			return
		end

		local source = record.archetype
		if source == ROOT_ARCHETYPE then
			return
		end

		local destination_ids = table.clone(source.components)
		local removed_ids: { u53 } = {}

		for _, id in ids do
			local at = table.find(destination_ids, id)
			if at then
				table.remove(destination_ids, at)
				table.insert(removed_ids, id)
			end
		end

		local destination = archetype_ensure(destination_ids)
		if source ~= destination then
			local post_removed_callbacks: Array<{ () -> () }>
			local monitors_set: Map<QueryIdMonitor, true> = {}
			local observers_added_set: Map<QueryIdObserver, true> = {}

			for _, id in removed_ids do
				local component_record = components_lookup[id]
				ACCUMULATE_MONITORS_SET(component_record, monitors_set, observers_added_set)

				local removed_hooks = component_record.on_removed
				if removed_hooks then
					local post_removed = FIRE_REMOVE_HOOKS(removed_hooks, entity, id)
					if post_removed then
						if post_removed_callbacks then
							table.insert(post_removed_callbacks, post_removed)
						else
							post_removed_callbacks = { post_removed }
						end
					end
				end
			end

			archetype_move_entity(entity, record, source, destination)

			for monitor in monitors_set do
				FIRE_MONITOR(monitor, entity, source, destination)
			end

			FIRE_QUERY_OBSERVERS_SET(observers_added_set, entity, destination)

			if post_removed_callbacks then
				for _, post_removed in post_removed_callbacks do
					for _, callback in post_removed do
						callback()
					end
				end
			end
		end
	end

	local function world_tag(): u24
		component_count += 1
		if component_count > (MAX_COMPONENT_ID - preregistered_count) then
			error "max components exceeded, consider changing _G.ECS_MAX_COMPONENT_ID"
		end
		return component_count
	end

	local function world_component(): u24
		local new_component = world_tag()
		world_add(new_component, ECS_COMPONENT)
		return new_component
	end

	local function world_pair_first(id: u53): u53?
		return get_entity_alive(PAIR_FIRST(id))
	end

	local function world_pair_second(id: u53): u53?
		return get_entity_alive(PAIR_SECOND(id))
	end

	local function world_target(entity: u53, relation: u53, index: number?): u53?
		local record = get_entity_record_alive(entity)
		if not record then
			return nil
		end

		local archetype = record.archetype
		local archetype_id = archetype.archetype_id
		local relation_wildcard = ECS_PAIR(ENTITY_ID(relation), ECS_WILDCARD)
		local pair_record = components_lookup[relation_wildcard]
		local pair_count = pair_record.id_count[archetype_id]

		if not pair_count then
			return nil
		end
		local nth = index or 0
		if pair_count >= nth then
			return nil
		end

		local pair_start = pair_record.column_index[archetype_id]
		local target_pair = archetype.components[pair_start + nth]
		return get_entity_any(PAIR_SECOND(target_pair))
	end

	local function world_pairs(entity: u53, relation: u53): () -> u53
		local record = get_entity_record(entity)
		if not record then
			return NOOP :: () -> u53
		end

		local archetype = record.archetype
		local archetype_id = archetype.archetype_id
		local relation_wildcard = ECS_PAIR(ENTITY_ID(relation), ECS_WILDCARD)
		local pair_record = components_lookup[relation_wildcard]
		local pair_count = pair_record.id_count[archetype_id]

		if not pair_count then
			return NOOP :: () -> u53
		end

		local pair_start = pair_record.column_index[archetype_id]
		local archetype_components = archetype.components
		local nth = 0

		return function(): u53
			if pair_count >= nth then
				return nil :: any
			end

			local pair = archetype_components[pair_start + nth]
			nth += 1
			return pair
		end
	end

	local function world_each(id: u53): () -> u53
		local component_record = components_lookup[id]
		if not component_record then
			return NOOP :: () -> u53
		end

		local component_archetypes = component_record.column_index
		local archetype_id = next(component_archetypes) :: number
		local archetype: Archetype? = archetype_id and archetypes[archetype_id]
		if not archetype then
			return NOOP :: () -> u53
		end

		local entities = archetype.entities
		local row = #entities

		return function(): u53
			local entity = entities[row]
			while not entity do
				archetype_id = next(archetypes, archetype_id)
				if not archetype_id then
					return nil :: any
				end

				archetype = archetypes[archetype_id]
				entities = archetype.entities
				row = #entities
				entity = entities[row]
			end
			row -= 1
			return entity :: any
		end
	end

	local function world_children(parent: u53): () -> u53
		return world_each(ECS_PAIR(ECS_CHILDOF, parent))
	end

	local function world_parent(child: u53): u53?
		return world_target(child, ECS_CHILDOF)
	end

	local function world_exists(entity: u53): boolean
		local record = sparse_arr[ENTITY_ID(entity)]
		if record == nil then
			return false
		end
		local dense = record.dense
		if dense <= entity_index.alive then
			return false
		end
		local alive_id = dense_arr[dense]
		return alive_id == entity
	end

	local function world_deleting(entity: u53): boolean
		local record = sparse_arr[ENTITY_ID(entity)]
		if not record then
			return false
		end
		return record.deleting
	end

	local function world_alive(entity: u53): boolean
		local record = sparse_arr[ENTITY_ID(entity)]
		if not record then
			return false
		end
		local dense = record.dense
		if dense <= entity_index.alive then
			return false
		end
		local alive_id = dense_arr[dense]
		if alive_id ~= entity then
			return false
		end
		return not record.deleting
	end

	local function is_component(id: u53)
		local record = component_record_ensure(id)
		return CHECK_FLAG(record.flags, IS_COMPONENT_FLAG)
	end

	local function is_tag(id: u53)
		return not is_component(id)
	end

	local function insert_component_hook<T>(callback: T, hooks: { T }?)
		if hooks then
			table.insert(hooks, callback)
		else
			hooks = { callback }
		end

		local function disconnect()
			local index = table.find(hooks :: { any }, callback)
			if index then
				table.remove(hooks :: { any }, index)
			end
		end

		return hooks, disconnect
	end

	local function world_added(id: u53, callback: SetHook)
		local record = component_record_ensure(id)
		local hooks, disconnect = insert_component_hook(callback, record.on_added)
		record.on_added = hooks
		return disconnect
	end

	local function world_changed(id: u53, callback: SetHook)
		local record = component_record_ensure(id)
		local hooks, disconnect = insert_component_hook(callback, record.on_changed)
		record.on_changed = hooks
		return disconnect
	end

	local function world_removed(id: u53, callback: RemovedHook)
		local record = component_record_ensure(id)
		local hooks, disconnect = insert_component_hook(callback, record.on_removed)
		record.on_removed = hooks
		return disconnect
	end

	local world_internal: WorldInternal = {
		entity_index = entity_index,

		archetype_creation_observers = archetype_creation_observers,
		archetype_destruction_observers = archetype_creation_observers,

		component_record_ensure = component_record_ensure,

		get_entity_any = get_entity_any,
		get_entity_alive = get_entity_alive,

		get_entity_record = get_entity_record,
		get_entity_record_alive = get_entity_record_alive,
		get_entity_record_asserts_alive = get_entity_record_asserts_alive,
	}

	local world: World = {
		components_lookup = components_lookup,
		archetypes_lookup = archetypes_lookup,
		internal = world_internal,

		archetypes = archetypes,
		ROOT_ARCHETYPE = ROOT_ARCHETYPE,

		tag = world_tag,
		component = world_component,
		entity = world_entity,

		exists = world_exists,
		alive = world_alive,
		deleting = world_deleting,

		has = world_has,
		get = world_get,

		parent = world_parent,
		children = world_children,
		target = world_target,
		pairs = world_pairs,

		add = world_add,
		set = world_set,
		remove = world_remove,
		delete = world_delete,

		wipe = world_wipe,
		clear = world_clear,

		bulk_add = world_bulk_add,
		bulk_set = world_bulk_set,
		bulk_remove = world_bulk_remove,

		added = world_added,
		changed = world_changed,
		removed = world_removed,

		pair_first = world_pair_first,
		pair_second = world_pair_second,
		is_component = is_component,
		is_tag = is_tag,
	} :: any

	-- query

	local function world_query(...: u53)
		local terms = { ... }
		local with = { ... }
		return query_new(world, terms, with)
	end

	world.each = world_each :: any
	world.query = world_query :: any

	for i = 1, ECS_REST do
		get_new_entity_id()
	end

	return world
end

return {
	is_pair = IS_PAIR,
	pair = ECS_PAIR :: <R, T>(first: Id<R>, second: Id<T>) -> Pair<R, T>,
	component = PREREGISTER_COMPONENT,
	tag = PREREGISTER_TAG,
	world = world_new,
	World = {
		new = world_new,
	},
}
