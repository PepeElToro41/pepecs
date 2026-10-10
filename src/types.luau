--!strict

-- Shared type definitions for the world (init.luau) and the query engine
-- (engine.luau). Both modules alias what they need from here.

export type u24 = number
export type u53 = number
export type ArchetypeId = number
export type Bitset = number
export type Column = Array<any>
export type Cleanup = () -> ()

export type Map<T, V> = { [T]: V }
export type Array<T> = { T }

export type Entity<T = any> = { __T: T }
export type Component<T = any> = { __T: T }
export type Id<T = any> = { __T: T }
export type Pair<R, T> = Id<R>

export type ArchetypeChangedHook = (source: Archetype, destination: Archetype) -> ()

export type SetHook<T = any> = (entity: Entity, id: Id<T>, value: T) -> ()
export type RemovedHook<T = any> = ((entity: Entity, id: Id<T>) -> () -> ()?) | (entity: Entity, id: Id<T>) -> ()?

export type ArchetypeMatch = (archetype: Archetype) -> boolean

-- Precomputed with/without test against an archetype's signature. Ids inside
-- the bitset range are checked as word masks, everything else (pairs,
-- wildcards, entities used as tags) falls back to the columns map.
export type ArchetypeMatcher = {
	with_ids: { u53 },
	without_ids: { u53 },
	-- archetype.bloom must contain with_bloom
	with_bloom: number,
	-- flat (byte offset, mask) pairs into archetype.bitset: every with word
	-- must contain its mask, no without word may intersect its mask
	with_words: { number },
	without_words: { number },
	-- ids outside the bitset range, checked against archetype.columns_map.
	-- A without id whose bloom is not in archetype.bloom skips the lookup.
	with_slow: { u53 },
	without_slow: { u53 },
	without_slow_blooms: { number },
	-- closure form, built by ARCHETYPE_MATCHER_MATCH on first use
	match: ArchetypeMatch?,
}

export type ArchetypeObserverCallback = (archetype: Archetype) -> ()
export type ArchetypeObserver = { match: ArchetypeMatch, callback: ArchetypeObserverCallback }

-- archetype is the destination for added callbacks and the source for removed ones
export type QueryMonitorCallback = (entity: u53, operation_id: number?, archetype: Archetype?) -> ()

export type QueryIdMonitor = {
	match: ArchetypeMatch,
	added: QueryMonitorCallback?,
	removed: QueryMonitorCallback?,
}

export type QueryIdObserver = {
	match: ArchetypeMatch,
	callback: QueryMonitorCallback,
}

export type Monitor = {
	cleanup: Cleanup,
	added: ((entity: Entity) -> ()) -> (),
	removed: ((entity: Entity) -> ()) -> (),
}

export type QueryChanged<T...> = typeof(setmetatable(
	{} :: {
		iter: () -> () -> (Entity, T...),
		cleanup: Cleanup,
	},
	{} :: {
		__iter: () -> () -> (Entity, T...),
	}
))

export type Query<T...> = typeof(setmetatable(
	{} :: {
		is_cached: boolean,

		with: (Query<T...>, ...Component) -> Query<T...>,
		without: (Query<T...>, ...Component) -> Query<T...>,
		clone: (Query<T...>) -> Query<T...>,
		rematch: (Query<T...>) -> { Archetype },
		archetypes: (Query<T...>) -> { Archetype },
		columns: (Query<T...>) -> () -> ...{ any },

		match: (Query<T...>, Archetype) -> boolean,
		has: (Query<T...>, entity: Entity) -> boolean,
		empty: (Query<T...>) -> boolean,
		count: (Query<T...>) -> number,
		entities: (Query<T...>) -> { Entity },
		random: (Query<T...>) -> Entity?,
		first: (Query<T...>, predicator: ((Entity, T...) -> boolean)?) -> (Entity, T...),

		cached: (Query<T...>) -> Query<T...>,
		cleanup: (Query<T...>) -> (),
		iter: (Query<T...>) -> () -> (Entity, T...),
		patch: (Query<T...>, mapper: (entity: Entity, T...) -> T...) -> (),

		monitor: (Query<T...>) -> Monitor,
		observe: (Query<T...>, callback: (entity: Entity) -> ()) -> Cleanup,
		changed: (Query<T...>) -> QueryChanged<T...>,
	},
	{} :: {
		__iter: () -> () -> (Entity, T...),
	}
))

export type QueryInternal = Query<any> & {
	terms: { u53 },
	with_ids: { u53 },
	without_ids: { u53 }?,
	-- built on the first match, terms are final from then on
	matcher: ArchetypeMatcher?,
	cache_cleanup: (() -> ())?,

	world: World,
	compatible_archetypes: Array<Archetype>,
	compatible_archetypes_map: Map<ArchetypeId, number>,
}

export type Archetype = {
	archetype_id: ArchetypeId,
	hash: string,
	-- alive: holds at least one entity. destroyed: removed from the world,
	-- edges cleared and component records unlinked; must never be reused.
	alive: boolean,
	destroyed: boolean,

	entities: { Entity },
	columns: Array<Column>,
	components: Array<u53>,

	columns_map: { [u53]: Column },
	-- signature used by ArchetypeMatcher: one bit per id inside the bitset
	-- range (u32 words) and a 32 bit bloom over every key of columns_map
	bitset: buffer,
	bloom: number,
	-- (R, *) wildcard id -> the single (R, T) pair this archetype holds, for
	-- every exclusive relation R. Lets add/set/bulk ops find the pair to swap
	-- out with one lookup.
	exclusive_pairs: Map<u53, u53>,
	forward_edges: Map<u53, Archetype>,
	backwards_edges: Map<u53, Archetype>,
	swapped_edges: Map<u53, u53>,

	traversable_count: number,
	traversable_ids: { u53 },
}

export type EntityRecord = {
	archetype: Archetype,
	archetype_row: number,
	dense: u24,
	deleting: boolean,
	-- number of hierarchy nodes (R, this) targeting the entity. Non zero means
	-- an archetype move has to re-hydrate those nodes.
	targets: number,
	-- number of DontFragment pairs the entity holds (sparse storage). Zero
	-- lets every op skip the sparse paths.
	sparse_count: number,

	archetype_changed: { ArchetypeChangedHook }?,
}

-------------------------------------------------------------------------------
-- sparse storage (DontFragment)
-------------------------------------------------------------------------------

-- Storage of a DontFragment pair record. `dense` lists the holders, `index`
-- maps an entity id to its slot and `values` is aligned with `dense`
-- (NULL_ARRAY for tags). On a (R, *) record the values are the per entity
-- lists of (R, T) pair ids, sorted by pair id.
export type SparseSet = {
	dense: { u53 },
	index: Map<u24, number>,
	values: Column,
}

-------------------------------------------------------------------------------
-- hierarchy
-------------------------------------------------------------------------------

-- The nearest holder of an id up a traversable relation. `record` is read
-- live for the row: a swap-remove changes rows without an archetype move.
-- `sparse` is set when the id is a DontFragment pair: the row is then the
-- holder's slot in that set, also read live.
export type ReachableElement = {
	entity: u53,
	record: EntityRecord,
	column: Column,
	sparse: SparseSet?,
}

export type ReachableCache = {
	current: number,
	reachable: Map<u53, ReachableElement>,
}

export type DepthCache = {
	current: number,
	depth: number,
}

-- One node per (R, T) pair record whose relation R is traversable. The node
-- mirrors T's position in the R hierarchy: parent is the node of T's first
-- R target, children are the nodes of every entity holding (R, T). Leaves
-- (entities that are nobody's target) never get a node.
export type HierarchyNode = {
	id: u53,
	target: u24,
	record: PairRecord,
	relation_record: PairRecord,

	parent: HierarchyNode?,
	children: { HierarchyNode },
	child_slots: Map<u53, number>,

	-- bumped on every invalidation; caches compare their `current` to it
	generation: number,
	-- walk stamp, guards subtree walks against relation cycles
	visited: number,

	depth: DepthCache,
	reachable: ReachableCache,
}

export type Hierarchy = {
	-- bumped whenever a parent link changes; depth orderings key on it
	link_generation: number,

	node_create: (record: PairRecord, relation_record: PairRecord, id: u53) -> HierarchyNode,
	node_release: (record: PairRecord) -> (),
	-- re-hydrates every node targeting the entity after its ids changed
	-- (archetype move or DontFragment pair change); reads record.archetype
	moved: (record: EntityRecord) -> (),
	invalidate: (node: HierarchyNode) -> (),
	depth: (node: HierarchyNode) -> number,
	reachable: (node: HierarchyNode) -> Map<u53, ReachableElement>,
	-- appends the node and every descendant to `out`, cycle safe
	collect: (node: HierarchyNode, out: { HierarchyNode }) -> { HierarchyNode },
}

export type PairRecord = ComponentRecord & {
	pairs_count: Map<ArchetypeId, number>,

	-- all records that share the same relation: (R, *)
	first_records: Map<u53, PairRecord>,
	-- all records that share the same target: (*, T)
	second_records: Map<u53, PairRecord>,
	-- all records with a traversable relation that share the same target:
	-- (R, T) where R is any id with ECS_TRAVERSABLE trait
	trav_records: Map<u53, PairRecord>,

	-- set on (R, T) records whose relation is traversable
	node: HierarchyNode?,
	-- set on every record of a DontFragment relation
	sparse: SparseSet?,
}

export type ComponentRecord = {
	-- archetype id -> column index of this id inside that archetype. Lookup only.
	column_index: Map<ArchetypeId, number>,
	-- dense list of every archetypeid with this component.
	archetype_ids: { ArchetypeId },
	-- archetype id -> position in archetype_ids, for swap-remove
	archetype_slots: Map<ArchetypeId, number>,

	flags: Bitset,

	on_added: Array<{ SetHook }>?,
	on_changed: Array<{ SetHook }>?,
	on_removed: Array<{ RemovedHook }>?,

	monitors: Array<{ QueryIdMonitor }>?,

	-- observers_added will fire when the entity's archetype changes
	-- observers_changed will fire when the column value changes
	observers_added: Array<{ QueryIdObserver }>?,
	observers_changed: Array<{ QueryIdObserver }>?,
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

	-- entity index
	get_new_entity_id: () -> u53,
	delete_entity_id: (id: u24, record: EntityRecord) -> (),

	-- component records
	component_record_create: (id: u53) -> ComponentRecord,
	wildcard_record_ensure: (wildcard: u53) -> PairRecord,
	check_is_component: (relation: u53, target: u53?) -> boolean,

	-- archetype graph
	archetype_create: (ids: { u53 }, hash: string) -> Archetype,
	archetype_ensure: (ids: { u53 }) -> Archetype,
	archetype_destroy: (archetype: Archetype) -> (),
	archetype_find_with: (source: Archetype, id: u53) -> Archetype,
	archetype_find_without: (source: Archetype, id: u53) -> Archetype,
	archetype_find_swap_with: (source: Archetype, old: u53, new: u53, column: number) -> Archetype,

	-- archetype rows
	archetype_insert_entity: (entity: u53, archetype: Archetype) -> number,
	archetype_assign_entity: (entity: u53, record: EntityRecord, archetype: Archetype) -> (),
	archetype_move_entity: (entity: u53, record: EntityRecord, source: Archetype, destination: Archetype) -> (),
	archetype_delete_entity: (archetype: Archetype, row: number) -> (),

	-- module level helpers (stateless)
	ENTITY_MASK: number,
	GENERATION_MASK: number,
	MAX_COMPONENT_ID: number,
	ENTITY_ID: (e: u53) -> u24,
	ENTITY_GENERATION: (e: u53) -> u24,
	APPEND_GENERATION: (id: number, generation: number) -> u53,
	INCREMENT_GENERATION: (e: u53) -> u53,
	FIND_INSERT: (ids: { u53 }, added: u53) -> number,
	HASH_IDS: (ids: { u53 }) -> string,
	REMOVE_ALL_PAIRS: (
		components: { u53 },
		components_count: number,
		pair_start: number,
		pair_count: number
	) -> { u53 },
	INSERT_COMPONENT_HOOK: <T>(callback: T, hooks: { T }?) -> ({ T }, Cleanup),
	ARCHETYPE_MATCHER_NEW: (with_ids: { u53 }, without_ids: { u53 }?) -> ArchetypeMatcher,
	ARCHETYPE_MATCHER_MATCH: (matcher: ArchetypeMatcher) -> ArchetypeMatch,
	FIND_MATCHED_ARCHETYPES: (world: World, matcher: ArchetypeMatcher, ignore_empty: boolean) -> { Archetype },
	OBSERVE_MATCHED_ARCHETYPES: (
		world: World,
		matcher: ArchetypeMatcher
	) -> ({ Archetype }, Map<ArchetypeId, number>, Cleanup),
	MONITOR_ATTACH: (world: World, ids: { u53 }, monitor: QueryIdMonitor) -> Cleanup,
	OBSERVER_ATTACH: (world: World, ids: { u53 }, observer: QueryIdObserver) -> Cleanup,
	monitor_new: (world: World, matcher: ArchetypeMatcher) -> Monitor,

	hierarchy: Hierarchy,
	-- depth of every entity in the archetype through `relation`, 0 without a pair
	archetype_depth: (archetype: Archetype, relation: u53) -> number,

	-- (R, *) records of every DontFragment relation in use
	dont_fragment_records: Map<u53, PairRecord>,
	-- first (R, T) pair of the entity through the (R, *) record, from the
	-- archetype or the sparse storage. nil without a pair.
	first_pair_of: (record: EntityRecord, relation_record: PairRecord) -> u53?,

	get_archetypes_count: () -> number,

	ECS_PAIR: (first: u53, second: u53) -> u53,
	PAIR_FIRST: (id: u53) -> u24,
	PAIR_SECOND: (id: u53) -> u24,
	IS_PAIR: (id: u53) -> boolean,
	ECS_WILDCARD: u53,
	ECS_TRANSITIVE: u53,
	ECS_TRAVERSABLE: u53,
	ECS_DONT_FRAGMENT: u53,
	NULL_ARRAY: { any },
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

	exists: (entity: Entity) -> boolean,
	alive: (entity: Entity) -> boolean,
	deleting: (entity: Entity) -> boolean,

	has: (entity: Entity, id: Component) -> boolean,
	get: & (<A>(Entity, Component<A>) -> A)
		& (<A, B>(Entity, Component<A>, Component<B>) -> (A, B))
		& (<A, B, C>(Entity, Component<A>, Component<B>, Component<C>) -> (A, B, C))
		& (<A, B, C, D>(Entity, Component<A>, Component<B>, Component<C>, Component<D>) -> (A, B, C, D))
		& (<A, B, C, D, E>(
			Entity,
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>
		) -> (A, B, C, D, E))
		& (<A, B, C, D, E, F>(
			Entity,
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>
		) -> (A, B, C, D, E, F))
		& (<A, B, C, D, E, F, G>(
			Entity,
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>,
			Component<G>
		) -> (A, B, C, D, E, F, G))
		& (<A, B, C, D, E, F, G, H>(
			Entity,
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>,
			Component<G>,
			Component<H>
		) -> (A, B, C, D, E, F, G, H))
		& (<A, B, C, D, E, F, G, H>(
			Entity,
			Component<A>,
			Component<B>,
			Component<C>,
			Component<D>,
			Component<E>,
			Component<F>,
			Component<G>,
			Component<H>,
			...Component
		) -> (A, B, C, D, E, F, G, H, ...any)),

	parent: (child: Entity) -> Entity,
	children: (parent: Entity) -> () -> Entity,
	target: (entity: Entity, relation: Id, index: number?) -> Entity,
	traverse: <T>(entity: Entity, relation: Id, id: Component<T>) -> (Entity, T),
	depth: (entity: Entity, relation: Id?) -> number,
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
	query_build: () -> QueryBuilder,
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

-------------------------------------------------------------------------------
-- query engine
-------------------------------------------------------------------------------

export type QueryBuilder = {
	term: (self: QueryBuilder, id: any) -> QueryBuilder,
	with: (self: QueryBuilder, id: any) -> QueryBuilder,
	without: (self: QueryBuilder, id: any) -> QueryBuilder,

	optional: (self: QueryBuilder) -> QueryBuilder,
	bor: (self: QueryBuilder) -> QueryBuilder,
	wildcard: (self: QueryBuilder) -> QueryBuilder,
	target: (self: QueryBuilder, target: any) -> QueryBuilder,
	from: (self: QueryBuilder, source: string) -> QueryBuilder,
	up: (self: QueryBuilder, relation: any) -> QueryBuilder,
	self: (self: QueryBuilder) -> QueryBuilder,
	transitive: (self: QueryBuilder) -> QueryBuilder,
	cascade: (self: QueryBuilder, relation: any) -> QueryBuilder,

	build: (self: QueryBuilder) -> EngineQuery,
}

-- Query produced by QueryBuilder:build(). Distinct from Query<T...>, the
-- world.query() object.
export type EngineQuery = typeof(setmetatable(
	{} :: {
		iter: (self: EngineQuery) -> () -> ...any,
		archetypes: (self: EngineQuery) -> { any },
		match: (self: EngineQuery, archetype: any) -> boolean,
		rematch: (self: EngineQuery) -> { any },
		cached: (self: EngineQuery) -> EngineQuery,
		cleanup: (self: EngineQuery) -> (),
		var: (self: EngineQuery, name: string) -> any,
		monitor: (self: EngineQuery) -> Monitor,
		is_cached: boolean,
	},
	{} :: { __iter: (self: EngineQuery) -> () -> ...any }
))

return nil
