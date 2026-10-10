--!optimize 2
--!native
--!strict

-- Query engine.
--
-- A query is described with a builder, compiled once into bytecode
-- and then executed by a small stackless backtracking interpreter.
-- The interpreter only runs per archetype (or per archetype result), never per
-- entity: everything a term needs is archetype invariant except the row, which
-- is handled by specialised emission closures.
--
-- Queries whose terms are all plain `$this` terms (Class S) never build a
-- program at all; they iterate with the same shape as `world.query`.

local types = require "./types"

type u24 = types.u24
type u53 = types.u53
type Column = types.Column
type Map<K, V> = types.Map<K, V>
type Entity = types.Entity
type Archetype = types.Archetype
type ComponentRecord = types.ComponentRecord
type PairRecord = types.PairRecord
type EntityRecord = types.EntityRecord
type HierarchyNode = types.HierarchyNode
type ReachableElement = types.ReachableElement
type World = types.World

export type QueryBuilder = types.QueryBuilder
type Query = types.EngineQuery

local MODE_TERM = 1
local MODE_WITH = 2
local MODE_WITHOUT = 3

type Term = {
	id: u53,
	mode: number,
	out: number,
	optional: boolean,
	target: (u53 | string)?,
	source: string?,
	up: u53?,
	self: boolean,
	transitive: boolean,
	or_next: Term?,
	chained: boolean,

	-- filled by compile
	rid: u53,
	src_var: number,
	tgt_var: number,
	rel_wc: u53,
	-- the id lives in DontFragment sparse storage: checked per entity
	sparse: boolean,
	-- `up` is a DontFragment relation: the first pair is resolved per entity
	up_sparse: boolean,
}

type BuilderInternal = {
	world: World,
	terms: { Term },
	pending: Term?,
	pending_or: Term?,
	n_out: number,
	-- relation the results are depth sorted by (:cascade()). Not named
	-- `cascade`: a nil field would resolve to the builder method instead.
	cascade_relation: u53?,
}

type Prematcher = {
	with_ids: { u53 },
	without_ids: { u53 },
	matcher: types.ArchetypeMatcher,
	find: (ignore_empty: boolean) -> { Archetype },
}

-- An id another entity provides to `$this`. When `id` changes on entity X the
-- archetypes holding `(relation, X)` are re-evaluated, recursively for `up`.
type DependencyWatch = {
	id: u53,
	relation: u53,
	recursive: boolean,
}

type QueryInternal = {
	world: World,
	is_static: boolean,
	n_out: number,
	prematcher: Prematcher,
	term_ids: { u53 },

	code: { number },
	n_ops: number,
	n_vars: number,
	var_names: { string },
	yield_fail_pc: number,
	cacheable_results: boolean,

	-- monitor support: true when the program binds `$this` per entity
	per_entity: boolean,
	-- any term touches DontFragment storage (monitors are archetype based)
	has_sparse: boolean,
	-- no fragmenting term selects `$this`: the program iterates the sparse
	-- set of this record instead of the prematched archetypes
	sparse_driver: u53?,
	-- `$this` ids that can change validity without leaving the prematched set
	self_watch: { u53 },
	dep_watch: { DependencyWatch },
	-- ids whose change cannot be localised to an archetype
	global_watch: { u53 },

	is_cached: boolean,
	compatible_archetypes: { Archetype }?,
	compatible_archetypes_map: Map<number, number>?,
	cache_cleanup: (() -> ())?,
	matched_generation: number,

	-- :cascade(): archetypes are iterated in depth order through `cascade`.
	-- The order is a counting sort kept in `sorted` and reused while nothing
	-- that can change it happened: no archetype created, and for a
	-- traversable relation no parent link changed (other relations re-sort
	-- on every iteration since their depth is not tracked).
	cascade: u53?,
	cascade_tracked: boolean,
	sorted: { Archetype }?,
	sorted_source: { Archetype }?,
	sorted_archetypes: number,
	sorted_links: number,
	-- scratch buffer of per archetype depths, reused between sorts
	sort_depths: { number },

	last_var_ent: { u53? }?,
}

-- opcodes, ordered by expected dispatch frequency
local OP_TERM = 1
local OP_SELECT_THIS = 2
local OP_YIELD = 3
local OP_TERM_OPT = 4
local OP_UP_TERM = 5
local OP_TARGET_VAR = 6
local OP_WITH = 7
local OP_WITHOUT = 8
local OP_UP_WITH = 9
local OP_UP_WITHOUT = 10
local OP_TARGET_BOUND = 11
local OP_TARGET_BOUND_NOT = 12
local OP_EACH_THIS = 13
local OP_FROM_SELECT = 14
local OP_FROM_SELECT_PAIR = 15
local OP_JMP = 16
local OP_NONE = 17
-- DontFragment ids: the entity of the source variable must be bound
local OP_SPARSE_CHECK = 18
local OP_SPARSE_TARGET_VAR = 19
local OP_SPARSE_FROM_SELECT = 20
local OP_SELECT_SPARSE = 21

-- OP_SPARSE_CHECK modes: MODE_TERM / MODE_WITH / MODE_WITHOUT plus optional
local SPARSE_OPTIONAL = 4

-- instruction layout: [op, fail_pc, fail_redo, A, B, C, D, E]
local STRIDE = 8
local MAX_UP_DEPTH = 64
local THIS_VAR = 1

local function NOOP() end

-------------------------------------------------------------------------------
-- builder
-------------------------------------------------------------------------------

local function builder_commit(builder: BuilderInternal)
	local pending = builder.pending
	if pending then
		if not pending.chained then
			table.insert(builder.terms, pending)
		end
		builder.pending = nil
	end
end

local function builder_new_term(builder: BuilderInternal, id: u53, mode: number): Term
	local previous_or = builder.pending_or
	builder_commit(builder)

	local term: Term = {
		id = id,
		mode = mode,
		out = 0,
		optional = false,
		target = nil,
		source = nil,
		up = nil,
		self = false,
		transitive = false,
		or_next = nil,
		chained = false,

		rid = id,
		src_var = THIS_VAR,
		tgt_var = 0,
		rel_wc = 0,
		sparse = false,
		up_sparse = false,
	}

	if previous_or then
		if mode == MODE_WITHOUT then
			error ":bor() cannot be followed by :without()"
		end
		previous_or.or_next = term
		term.chained = true
		term.out = previous_or.out
		builder.pending_or = nil
	elseif mode == MODE_TERM then
		builder.n_out += 1
		term.out = builder.n_out
	end

	builder.pending = term
	return term
end

local function builder_pending(builder: BuilderInternal, method: string): Term
	local pending = builder.pending
	if not pending then
		error(`cannot call :{method}() without a term`)
	end
	return pending
end

local function is_var(value: any): boolean
	return type(value) == "string"
end

local function validate_var(name: any, method: string)
	if type(name) ~= "string" or string.sub(name, 1, 1) ~= "$" then
		error(`:{method}() expects an entity or a "$variable" name`)
	end
end

local builder_mt = {}
builder_mt.__index = builder_mt

function builder_mt.term(builder: BuilderInternal, id: u53): BuilderInternal
	builder_new_term(builder, id, MODE_TERM)
	return builder
end

function builder_mt.with(builder: BuilderInternal, id: u53): BuilderInternal
	builder_new_term(builder, id, MODE_WITH)
	return builder
end

function builder_mt.without(builder: BuilderInternal, id: u53): BuilderInternal
	builder_new_term(builder, id, MODE_WITHOUT)
	return builder
end

function builder_mt.optional(builder: BuilderInternal): BuilderInternal
	local term = builder_pending(builder, "optional")
	if term.mode == MODE_WITHOUT then
		error ":optional() cannot be used on :without()"
	end
	term.optional = true
	return builder
end

function builder_mt.bor(builder: BuilderInternal): BuilderInternal
	local term = builder_pending(builder, "bor")
	if term.mode == MODE_WITHOUT then
		error ":bor() cannot be used after :without()"
	end
	builder.pending_or = term
	return builder
end

function builder_mt.wildcard(builder: BuilderInternal): BuilderInternal
	local term = builder_pending(builder, "wildcard")
	if builder.world.internal.IS_PAIR(term.id) then
		error ":wildcard() cannot be used on a pair id"
	end
	term.target = builder.world.internal.ECS_WILDCARD
	return builder
end

function builder_mt.target(builder: BuilderInternal, target: u53 | string): BuilderInternal
	local term = builder_pending(builder, "target")
	if builder.world.internal.IS_PAIR(term.id) then
		error ":target() cannot be used on a pair id"
	end
	if term.up then
		error ":target() cannot be combined with :up()"
	end
	if is_var(target) then
		validate_var(target, "target")
	end
	term.target = target
	return builder
end

function builder_mt.from(builder: BuilderInternal, source: string): BuilderInternal
	local term = builder_pending(builder, "from")
	validate_var(source, "from")
	if source == "$this" then
		term.source = nil
	else
		term.source = source
	end
	return builder
end

function builder_mt.up(builder: BuilderInternal, relation: u53): BuilderInternal
	local term = builder_pending(builder, "up")
	if builder.world.internal.IS_PAIR(relation) then
		error ":up() expects a relation, not a pair"
	end
	if is_var(term.target) then
		error ":up() cannot be combined with a variable :target()"
	end
	if term.transitive then
		error ":up() cannot be combined with :transitive()"
	end
	term.up = relation
	return builder
end

-- :transitive() — this is just term(pair(R, T)):up(R). No special logic for multiple pairs,
-- so this only works with exclusive relationships
function builder_mt.transitive(builder: BuilderInternal): BuilderInternal
	local term = builder_pending(builder, "transitive")
	if term.up then
		error ":transitive() cannot be combined with :up()"
	end
	term.transitive = true
	return builder
end

-- :cascade(relation) — iterate results parents first: archetypes are sorted
-- by the depth of their entities through `relation` (roots and entities
-- without the relation come first). Sorting only; combine with :up() to
-- also read the term from the parent.
function builder_mt.cascade(builder: BuilderInternal, relation: u53): BuilderInternal
	local internal = builder.world.internal
	if internal.IS_PAIR(relation) then
		error ":cascade() expects a relation, not a pair"
	end
	-- depth is per entity for such relations, archetypes cannot be sorted
	if (builder.world.has :: any)(relation, internal.ECS_DONT_FRAGMENT) then
		error ":cascade() is not supported on a DontFragment relation"
	end
	local existing = builder.cascade_relation
	if existing and existing ~= relation then
		error ":cascade() can only sort by one relation"
	end
	builder.cascade_relation = relation
	return builder
end

builder_mt["self"] = function(builder: BuilderInternal): BuilderInternal
	local term = builder_pending(builder, "self")
	if not term.up then
		error ":self() requires :up()"
	end
	term.self = true
	return builder
end

-- Sparse set and slot of a DontFragment `id` held by the entity, nil when
-- the entity does not hold it. (R, *) resolves to the first pair of R.
local function sparse_slot_of(
	components_lookup: Map<u53, ComponentRecord>,
	ECS_WILDCARD: u53,
	PAIR_SECOND: (u53) -> u24,
	entity_id: u24,
	id: u53
): (types.SparseSet?, number?)
	local record = (components_lookup[id] :: any) :: PairRecord?
	local set = if record then record.sparse else nil
	if not set then
		return nil, nil
	end
	local slot = set.index[entity_id]
	if not slot then
		return nil, nil
	end
	if PAIR_SECOND(id) == ECS_WILDCARD then
		local first_record = components_lookup[set.values[slot][1]] :: PairRecord
		local first_set = first_record.sparse :: types.SparseSet
		return first_set, first_set.index[entity_id]
	end
	return set, slot
end

-- Builds the up traversal for one world.
--
-- traverse_up walks `rel_wc` from `archetype` (the entity when given) until
-- a holder of `id` is found. Returns the holder row (0 when `include_self`
-- hit the starting archetype itself) and the column, or nil when nothing up
-- the chain has `id`. Follows the first target of the relation on every
-- level. A row other than 0 indexes the returned column directly, which
-- also covers DontFragment ids: their column is the sparse values array and
-- the row the holder's slot.
--
-- Relations with the Traversable trait resolve through the hierarchy: the
-- (R, T) record of the first pair caches the nearest holder of every id.
-- Other relations walk the chain and give up after MAX_UP_DEPTH so transient
-- relation cycles cannot hang the query. DontFragment relations and
-- `include_self` on a DontFragment id need `entity`; the planner binds
-- `$this` per entity for those terms.
local function make_traverse_up(world: World)
	local internal = world.internal
	local components_lookup = world.components_lookup
	local sparse = internal.entity_index.sparse
	local PAIR_SECOND = internal.PAIR_SECOND
	local ENTITY_ID = internal.ENTITY_ID
	local ECS_WILDCARD = internal.ECS_WILDCARD
	local reachable = internal.hierarchy.reachable
	local first_pair_of = internal.first_pair_of

	return function(archetype: Archetype, entity: u53?, rel_wc: u53, id: u53, include_self: boolean): (number?, Column?)
		local record: EntityRecord? = if entity then sparse[ENTITY_ID(entity)] else nil

		if include_self then
			local column = archetype.columns_map[id]
			if column then
				return 0, column
			end
			if record and record.sparse_count > 0 then
				local set, slot =
					sparse_slot_of(components_lookup, ECS_WILDCARD, PAIR_SECOND, ENTITY_ID(entity :: u53), id)
				if set then
					return slot, set.values
				end
			end
		end

		local relation_record = components_lookup[rel_wc] :: PairRecord
		if not relation_record then
			return nil, nil
		end

		local pair_id: u53?
		if record then
			pair_id = first_pair_of(record, relation_record)
		elseif relation_record.sparse then
			-- unreachable: the planner binds the entity for DontFragment relations
			return nil, nil
		else
			local index = relation_record.column_index[archetype.archetype_id]
			pair_id = if index then archetype.components[index] else nil
		end
		if not pair_id then
			return nil, nil
		end

		local first_record = components_lookup[pair_id] :: PairRecord
		local node = first_record and first_record.node
		if node then
			local element = reachable(node)[id]
			if element then
				local element_sparse = element.sparse
				if element_sparse then
					return element_sparse.index[ENTITY_ID(element.entity)], element.column
				end
				return element.record.archetype_row, element.column
			end
			return nil, nil
		end

		for _ = 1, MAX_UP_DEPTH do
			local target_id = PAIR_SECOND(pair_id :: u53)
			local target_record = sparse[target_id]
			if not target_record then
				return nil, nil
			end
			local column = target_record.archetype.columns_map[id]
			if column then
				return target_record.archetype_row, column
			end
			if target_record.sparse_count > 0 then
				local set, slot = sparse_slot_of(components_lookup, ECS_WILDCARD, PAIR_SECOND, target_id, id)
				if set then
					return slot, set.values
				end
			end
			pair_id = first_pair_of(target_record, relation_record)
			if not pair_id then
				return nil, nil
			end
		end

		return nil, nil
	end
end

-------------------------------------------------------------------------------
-- compiler
-------------------------------------------------------------------------------

type OpRecord = {
	op: number,
	a: number,
	b: number,
	c: number,
	d: number,
	e: number,
	iter: boolean,
	fail_pc: number?,
	fail_redo: number?,
	binds: { number }?,
}

type TermPlan = {
	priority: number,
	needs_each: boolean,
	ops: { OpRecord },
	binds: { number },
	-- relation through which `$this` binds the variables in `binds`, when the
	-- plan is an OP_TARGET_VAR on `$this`
	bind_via: u53?,
}

local function op_record(
	op: number,
	iter: boolean,
	a: number?,
	b: number?,
	c: number?,
	d: number?,
	e: number?
): OpRecord
	return {
		op = op,
		a = a or 0,
		b = b or 0,
		c = c or 0,
		d = d or 0,
		e = e or 0,
		iter = iter,
	}
end

local function term_is_required(term: Term): boolean
	return term.mode ~= MODE_WITHOUT and not term.optional and term.or_next == nil
end

local function compile(builder: BuilderInternal): QueryInternal
	local world = builder.world
	local internal = world.internal
	-- ids are plain numbers inside the engine
	local has: (u53, u53) -> boolean = world.has :: any
	local ECS_PAIR = internal.ECS_PAIR
	local ECS_WILDCARD = internal.ECS_WILDCARD

	builder_commit(builder)
	if builder.pending_or then
		error ":bor() must be followed by a term"
	end

	local terms = builder.terms

	-- 1. variables ----------------------------------------------------------
	local var_names: { string } = { "$this" }
	local var_indices: Map<string, number> = { ["$this"] = THIS_VAR }

	local function var_index(name: string): number
		local existing = var_indices[name]
		if existing then
			return existing
		end
		local index = #var_names + 1
		var_names[index] = name
		var_indices[name] = index
		return index
	end

	-- 2. normalise ----------------------------------------------------------
	local IS_PAIR = internal.IS_PAIR
	local PAIR_FIRST = internal.PAIR_FIRST
	local PAIR_SECOND = internal.PAIR_SECOND
	local ECS_TRANSITIVE = internal.ECS_TRANSITIVE
	local ECS_DONT_FRAGMENT = internal.ECS_DONT_FRAGMENT
	local get_entity_alive = internal.get_entity_alive

	local function normalise(term: Term)
		local target = term.target
		-- relation of a (R, T) term with a concrete target, used for transitivity
		local relation: u53? = nil

		if type(target) == "string" then
			term.tgt_var = var_index(target)
			term.rid = ECS_PAIR(term.id, ECS_WILDCARD)
			if term.transitive or has(term.id, ECS_TRANSITIVE) then
				error "transitive terms with a variable target are not supported yet"
			end
		elseif type(target) == "number" then
			term.rid = ECS_PAIR(term.id, target)
			if target ~= ECS_WILDCARD then
				relation = term.id
			end
		else
			term.rid = term.id
			if IS_PAIR(term.id) then
				local first, second = PAIR_FIRST(term.id), PAIR_SECOND(term.id)
				if first ~= ECS_WILDCARD and second ~= ECS_WILDCARD then
					relation = get_entity_alive(first)
				end
			end
		end

		-- transitive (R, T): (R, T) on self, or on anything reached through R
		if relation and not term.up then
			if term.transitive or has(relation, ECS_TRANSITIVE) then
				term.transitive = true
				term.up = relation
				term.self = true
			end
		elseif term.transitive then
			error ":transitive() needs a pair term with a target"
		end

		local source = term.source
		term.src_var = if source then var_index(source) else THIS_VAR

		local up = term.up
		if up then
			term.rel_wc = ECS_PAIR(up, ECS_WILDCARD)
			term.up_sparse = has(up, ECS_DONT_FRAGMENT)
		end

		-- DontFragment pairs are checked per entity against sparse storage.
		-- (*, T) has no storage of its own and stays an archetype check.
		local rid = term.rid
		if IS_PAIR(rid) and PAIR_FIRST(rid) ~= ECS_WILDCARD then
			local relation_entity = get_entity_alive(PAIR_FIRST(rid))
			term.sparse = relation_entity ~= nil and has(relation_entity, ECS_DONT_FRAGMENT)
		end
	end

	for _, head in terms do
		normalise(head)
		local alternative = head.or_next
		while alternative do
			normalise(alternative)
			if alternative.src_var ~= head.src_var then
				error "all alternatives of a :bor() chain must share the same source"
			end
			-- :optional() on any alternative makes the whole chain optional
			if alternative.optional then
				head.optional = true
			end
			alternative = alternative.or_next
		end
	end

	-- 3. prematcher ---------------------------------------------------------
	local with_ids: { u53 } = {}
	local without_ids: { u53 } = {}
	local with_set: Map<u53, boolean> = {}
	local without_set: Map<u53, boolean> = {}

	-- DontFragment terms are not part of any archetype, so they never enter
	-- the prematcher. They are checked per entity by the program.
	local has_sparse = false
	local sparse_driver: u53? = nil

	for _, term in terms do
		if term.sparse or term.up_sparse then
			has_sparse = true
		end
		if term.src_var ~= THIS_VAR or term.or_next then
			continue
		end
		if term.mode == MODE_WITHOUT then
			if term.up == nil and term.tgt_var == 0 and not term.sparse and not without_set[term.rid] then
				without_set[term.rid] = true
				table.insert(without_ids, term.rid)
			end
		elseif not term.optional then
			local id: u53
			if term.up then
				if term.up_sparse then
					sparse_driver = sparse_driver or term.rel_wc
					continue
				end
				id = term.rel_wc
			else
				if term.sparse then
					sparse_driver = sparse_driver or term.rid
					continue
				end
				id = term.rid
			end
			if not with_set[id] then
				with_set[id] = true
				table.insert(with_ids, id)
			end
		end
	end

	-- a fragmenting term drives the iteration whenever there is one; only a
	-- query made of DontFragment terms iterates a sparse set directly
	if #with_ids > 0 then
		sparse_driver = nil
	elseif not sparse_driver then
		error "query needs at least one required term on $this"
	end

	local FIND_MATCHED_ARCHETYPES = internal.FIND_MATCHED_ARCHETYPES
	local matcher = internal.ARCHETYPE_MATCHER_NEW(with_ids, if #without_ids > 0 then without_ids else nil)

	local prematcher: Prematcher = {
		with_ids = with_ids,
		without_ids = without_ids,
		matcher = matcher,
		find = function(ignore_empty: boolean): { Archetype }
			return FIND_MATCHED_ARCHETYPES(world, matcher, ignore_empty)
		end,
	}

	-- 4. classify -----------------------------------------------------------
	local is_static = true
	local term_ids: { u53 } = table.create(builder.n_out)

	for _, term in terms do
		if term.src_var ~= THIS_VAR or term.up or term.tgt_var ~= 0 or term.or_next or term.sparse then
			is_static = false
			break
		end
	end

	if is_static then
		for _, term in terms do
			if term.out ~= 0 then
				term_ids[term.out] = term.rid
			end
		end
	end

	local query: QueryInternal = {
		world = world,
		is_static = is_static,
		n_out = builder.n_out,
		prematcher = prematcher,
		term_ids = term_ids,

		code = {},
		n_ops = 0,
		n_vars = #var_names,
		var_names = var_names,
		yield_fail_pc = 0,
		cacheable_results = true,

		per_entity = false,
		has_sparse = has_sparse,
		sparse_driver = sparse_driver,
		self_watch = {},
		dep_watch = {},
		global_watch = {},

		is_cached = false,
		compatible_archetypes = nil,
		compatible_archetypes_map = nil,
		cache_cleanup = nil,
		matched_generation = -1,

		cascade = builder.cascade_relation,
		cascade_tracked = builder.cascade_relation ~= nil
			and has(builder.cascade_relation :: u53, internal.ECS_TRAVERSABLE),
		sorted = nil,
		sorted_source = nil,
		sorted_archetypes = -1,
		sorted_links = -1,
		sort_depths = {},

		last_var_ent = nil,
	}

	if is_static then
		return query
	end

	-- 5. plan ops -----------------------------------------------------------
	local bound: Map<number, boolean> = { [THIS_VAR] = true }
	local bind_relation: Map<number, u53?> = {}
	-- a sparse driver binds `$this` per entity from the start
	local this_each = sparse_driver ~= nil

	-- Row multiplier of an output read from `var`: `$this` results span the
	-- rows of an archetype (m = 1) unless the program selects entities one by
	-- one from a sparse set, where the result row is a slot of that set.
	local function m_of(var: number): number
		return if var == THIS_VAR and not sparse_driver then 1 else 0
	end

	-- Builds the single check op for a term whose source is bound and whose
	-- target (if any) is bound. Returns nil when the term is not a check.
	local function check_op(term: Term): (OpRecord?, boolean)
		local src = term.src_var
		local m = m_of(src)
		-- DontFragment checks need the entity of `$this`
		local on_this = src == THIS_VAR and not this_each

		if term.up then
			local op = if term.mode == MODE_WITHOUT
				then OP_UP_WITHOUT
				elseif term.mode == MODE_WITH then OP_UP_WITH
				else OP_UP_TERM
			local self_flag = if term.self then 1 else 0
			local needs_each = on_this and (term.up_sparse or (term.self and term.sparse))
			if op == OP_UP_TERM then
				return op_record(op, false, src, term.rel_wc, term.rid, term.out, self_flag), needs_each
			end
			return op_record(op, false, src, term.rel_wc, term.rid, self_flag), needs_each
		end

		local tgt = term.tgt_var
		if tgt ~= 0 then
			if not bound[tgt] then
				return nil, false
			end
			if term.sparse then
				return op_record(OP_SPARSE_CHECK, false, src, term.id, term.out, term.mode, tgt), on_this
			end
			local needs_each = tgt == THIS_VAR and not this_each
			local op = if term.mode == MODE_WITHOUT then OP_TARGET_BOUND_NOT else OP_TARGET_BOUND
			return op_record(op, false, src, term.id, tgt, term.out, m), needs_each
		end

		if term.sparse then
			return op_record(OP_SPARSE_CHECK, false, src, term.rid, term.out, term.mode, 0), on_this
		end

		if term.mode == MODE_WITHOUT then
			return op_record(OP_WITHOUT, false, src, term.rid), false
		elseif term.mode == MODE_WITH then
			return op_record(OP_WITH, false, src, term.rid), false
		end
		return op_record(OP_TERM, false, src, term.rid, term.out, m), false
	end

	local function plan_term(term: Term): TermPlan?
		local src = term.src_var
		local priority = if src == THIS_VAR then 0 else 1

		-- or chain: every alternative must be a ready check op
		if term.or_next then
			if not bound[src] then
				return nil
			end
			local ops: { OpRecord } = {}
			local needs_each = false
			local alternative: Term? = term
			while alternative do
				local op, each = check_op(alternative)
				if not op then
					return nil
				end
				needs_each = needs_each or each
				table.insert(ops, op)
				alternative = alternative.or_next
			end
			if term.optional then
				table.insert(ops, op_record(OP_NONE, false, term.out))
			end
			return { priority = priority, needs_each = needs_each, ops = ops, binds = {} }
		end

		-- unbound source: this term must bind it by scanning
		if not bound[src] then
			if not term_is_required(term) or term.up then
				return nil
			end
			local tgt = term.tgt_var
			local sparse = term.sparse
			if tgt == 0 then
				return {
					priority = 3,
					needs_each = false,
					ops = {
						if sparse
							then op_record(OP_SPARSE_FROM_SELECT, true, src, term.rid, term.out, 0)
							else op_record(OP_FROM_SELECT, true, src, term.rid, term.out),
					},
					binds = { src },
				}
			elseif bound[tgt] then
				return {
					priority = 3,
					needs_each = tgt == THIS_VAR and not this_each,
					ops = {
						if sparse
							then op_record(OP_SPARSE_FROM_SELECT, true, src, term.id, term.out, tgt)
							else op_record(OP_FROM_SELECT_PAIR, true, src, term.id, tgt, term.out),
					},
					binds = { src },
				}
			end
			-- both source and target unbound: scan (rel, *) then enumerate targets
			if sparse then
				return {
					priority = 3,
					needs_each = false,
					ops = {
						op_record(OP_SPARSE_FROM_SELECT, true, src, term.rid, 0, 0),
						op_record(OP_SPARSE_TARGET_VAR, true, src, term.rid, tgt, term.out),
					},
					binds = { src, tgt },
				}
			end
			return {
				priority = 3,
				needs_each = false,
				ops = {
					op_record(OP_FROM_SELECT, true, src, term.rid, 0),
					op_record(OP_TARGET_VAR, true, src, term.rid, tgt, term.out, 0),
				},
				binds = { src, tgt },
			}
		end

		-- bound source, unbound target: bind it by enumerating pairs
		local tgt = term.tgt_var
		if tgt ~= 0 and not bound[tgt] then
			if not term_is_required(term) then
				return nil
			end
			if term.sparse then
				return {
					priority = 2,
					needs_each = src == THIS_VAR and not this_each,
					ops = { op_record(OP_SPARSE_TARGET_VAR, true, src, term.rid, tgt, term.out) },
					binds = { tgt },
					bind_via = if src == THIS_VAR then term.id else nil,
				}
			end
			return {
				priority = 2,
				needs_each = false,
				ops = { op_record(OP_TARGET_VAR, true, src, term.rid, tgt, term.out, m_of(src)) },
				binds = { tgt },
				bind_via = if src == THIS_VAR then term.id else nil,
			}
		end

		local op, needs_each = check_op(term)
		if not op then
			return nil
		end
		local ops = { op }
		if term.optional then
			if op.op == OP_TERM then
				op.op = OP_TERM_OPT
			elseif op.op == OP_SPARSE_CHECK and op.d == MODE_TERM then
				op.d = SPARSE_OPTIONAL
			else
				table.insert(ops, op_record(OP_NONE, false, term.out))
			end
		end
		return { priority = priority, needs_each = needs_each, ops = ops, binds = {} }
	end

	local ops: { OpRecord } = {}

	local function emit(record: OpRecord): number
		table.insert(ops, record)
		return #ops
	end

	local function emit_plan(plan: TermPlan)
		local plan_ops = plan.ops
		local count = #plan_ops
		local is_chain = count > 1 and not plan_ops[1].iter

		if not is_chain then
			for _, record in plan_ops do
				emit(record)
			end
		else
			-- alternatives: fail falls through to the next alternative without
			-- redo, success jumps past the chain
			local jumps: { OpRecord } = {}
			for index, record in plan_ops do
				local pc = emit(record)
				if index < count then
					record.fail_pc = pc + 2
					record.fail_redo = 0
					local jump = op_record(OP_JMP, false, 0)
					emit(jump)
					table.insert(jumps, jump)
				end
			end
			local after = #ops + 1
			for _, jump in jumps do
				jump.a = after
			end
		end

		for _, var in plan.binds do
			bound[var] = true
			bind_relation[var] = plan.bind_via
		end
	end

	local placed: Map<Term, boolean> = {}
	local remaining = #terms

	if sparse_driver then
		-- Every entity of the driving set holds the driver's id, so a plain
		-- required term on that id needs no check: the select op also writes
		-- its output when the driver is a concrete (R, T) pair.
		local driver_out = 0
		for _, term in terms do
			if
				term.rid == sparse_driver
				and term.src_var == THIS_VAR
				and term.tgt_var == 0
				and term.up == nil
				and term.or_next == nil
				and not term.optional
				and term.mode ~= MODE_WITHOUT
				and (term.out == 0 or PAIR_SECOND(term.rid) ~= ECS_WILDCARD)
			then
				driver_out = term.out
				placed[term] = true
				remaining -= 1
				break
			end
		end
		emit(op_record(OP_SELECT_SPARSE, true, sparse_driver, driver_out))
	else
		emit(op_record(OP_SELECT_THIS, true))
	end

	while remaining > 0 do
		local best: TermPlan? = nil
		local best_term: Term? = nil
		local blocked_on_each = false

		for _, term in terms do
			if placed[term] then
				continue
			end
			local plan = plan_term(term)
			if not plan then
				continue
			end
			if plan.needs_each then
				blocked_on_each = true
				continue
			end
			if not best or plan.priority < best.priority then
				best = plan
				best_term = term
			end
		end

		if best and best_term then
			emit_plan(best)
			placed[best_term] = true
			remaining -= 1
		elseif blocked_on_each then
			emit(op_record(OP_EACH_THIS, true))
			this_each = true
		else
			for _, term in terms do
				if placed[term] then
					continue
				end
				local unbound_var = if not bound[term.src_var]
					then term.src_var
					elseif term.tgt_var ~= 0 and not bound[term.tgt_var] then term.tgt_var
					else 0
				if unbound_var ~= 0 then
					error(`variable {var_names[unbound_var]} is never bound`)
				end
			end
			error "query could not be planned"
		end
	end

	local yield = op_record(OP_YIELD, false)
	emit(yield)

	-- 5b. monitor dependencies ----------------------------------------------
	-- Ids whose change on some entity can flip the validity of a `$this`
	-- archetype without moving `$this` in or out of the prematched set.
	local self_watch: { u53 } = {}
	local dep_watch: { DependencyWatch } = {}
	local global_watch: { u53 } = {}
	local self_set: Map<u53, boolean> = {}
	local dep_set: Map<u53, DependencyWatch> = {}
	local global_set: Map<u53, boolean> = {}

	local function add_dep(id: u53, relation: u53, recursive: boolean)
		local existing = dep_set[id]
		if existing then
			existing.recursive = existing.recursive or recursive
			return
		end
		local watch: DependencyWatch = { id = id, relation = relation, recursive = recursive }
		dep_set[id] = watch
		table.insert(dep_watch, watch)
	end

	local function add_global(id: u53)
		if not global_set[id] then
			global_set[id] = true
			table.insert(global_watch, id)
		end
	end

	for _, head in terms do
		if head.optional then
			continue
		end
		local alternative: Term? = head
		while alternative do
			local term = alternative
			if term.src_var == THIS_VAR then
				if term.up then
					local up: u53 = term.up
					add_dep(term.rid, up, true)
					add_dep(term.rel_wc, up, true)
				elseif term.tgt_var ~= 0 or head.or_next then
					-- (R, *) swaps keep the entity in the set; bor alternatives are
					-- not part of the prematcher
					self_set[term.rid] = true
				end
			elseif term.up then
				add_global(term.rid)
				add_global(term.rel_wc)
			else
				local relation = bind_relation[term.src_var]
				if relation then
					add_dep(term.rid, relation, false)
				else
					add_global(term.rid)
				end
			end
			alternative = term.or_next
		end
	end

	for id in self_set do
		if not dep_set[id] and not global_set[id] then
			table.insert(self_watch, id)
		end
	end

	query.per_entity = this_each
	query.self_watch = self_watch
	query.dep_watch = dep_watch
	query.global_watch = global_watch

	-- 6. encode -------------------------------------------------------------
	local code: { number } = table.create(#ops * STRIDE, 0)
	local last_iter = 0
	local cacheable_results = true

	for pc, record in ops do
		local fail_pc = record.fail_pc
		local fail_redo = record.fail_redo
		if fail_pc == nil then
			fail_pc = last_iter
			fail_redo = 1
		end
		if record.op == OP_SELECT_THIS or record.op == OP_SELECT_SPARSE then
			fail_pc = 0
			fail_redo = 0
		end

		local off = (pc - 1) * STRIDE
		code[off + 1] = record.op
		code[off + 2] = fail_pc :: number
		code[off + 3] = fail_redo :: number
		code[off + 4] = record.a
		code[off + 5] = record.b
		code[off + 6] = record.c
		code[off + 7] = record.d
		code[off + 8] = record.e

		if record.iter then
			last_iter = pc
			if record.op ~= OP_SELECT_THIS and record.op ~= OP_TARGET_VAR and record.op ~= OP_SELECT_SPARSE then
				cacheable_results = false
			end
		end
	end

	query.code = table.freeze(code)
	query.n_ops = #ops
	query.yield_fail_pc = last_iter
	query.cacheable_results = cacheable_results

	return query
end

-------------------------------------------------------------------------------
-- iteration: static class
-------------------------------------------------------------------------------

local function iter_static(query: QueryInternal, list: { Archetype }): () -> ...any
	local EMPTY = query.world.internal.NULL_ARRAY
	local n_out = query.n_out
	local A, B, C, D, E, F, G, H = unpack(query.term_ids)

	local index = 0
	local entities: { Entity } = EMPTY
	local row = 0
	local a: Column, b: Column, c: Column, d: Column
	local e: Column, f: Column, g: Column, h: Column

	if n_out == 0 then
		return function(): ...any
			local entity = entities[row]
			while entity == nil do
				index += 1
				local archetype = list[index]
				if not archetype then
					return nil
				end
				if not archetype.alive then
					continue
				end
				entities = archetype.entities
				row = #entities
				entity = entities[row]
			end
			row -= 1
			return entity
		end
	elseif n_out == 1 then
		return function(): ...any
			local entity = entities[row]
			while entity == nil do
				index += 1
				local archetype = list[index]
				if not archetype then
					return nil
				end
				if not archetype.alive then
					continue
				end
				entities = archetype.entities
				row = #entities
				local columns_map = archetype.columns_map
				a = columns_map[A] or EMPTY
				entity = entities[row]
			end
			local r = row
			row -= 1
			return entity, a[r]
		end
	elseif n_out == 2 then
		return function(): ...any
			local entity = entities[row]
			while entity == nil do
				index += 1
				local archetype = list[index]
				if not archetype then
					return nil
				end
				if not archetype.alive then
					continue
				end
				entities = archetype.entities
				row = #entities
				local columns_map = archetype.columns_map
				a = columns_map[A] or EMPTY
				b = columns_map[B] or EMPTY
				entity = entities[row]
			end
			local r = row
			row -= 1
			return entity, a[r], b[r]
		end
	elseif n_out == 3 then
		return function(): ...any
			local entity = entities[row]
			while entity == nil do
				index += 1
				local archetype = list[index]
				if not archetype then
					return nil
				end
				if not archetype.alive then
					continue
				end
				entities = archetype.entities
				row = #entities
				local columns_map = archetype.columns_map
				a = columns_map[A] or EMPTY
				b = columns_map[B] or EMPTY
				c = columns_map[C] or EMPTY
				entity = entities[row]
			end
			local r = row
			row -= 1
			return entity, a[r], b[r], c[r]
		end
	elseif n_out == 4 then
		return function(): ...any
			local entity = entities[row]
			while entity == nil do
				index += 1
				local archetype = list[index]
				if not archetype then
					return nil
				end
				if not archetype.alive then
					continue
				end
				entities = archetype.entities
				row = #entities
				local columns_map = archetype.columns_map
				a = columns_map[A] or EMPTY
				b = columns_map[B] or EMPTY
				c = columns_map[C] or EMPTY
				d = columns_map[D] or EMPTY
				entity = entities[row]
			end
			local r = row
			row -= 1
			return entity, a[r], b[r], c[r], d[r]
		end
	elseif n_out == 5 then
		return function(): ...any
			local entity = entities[row]
			while entity == nil do
				index += 1
				local archetype = list[index]
				if not archetype then
					return nil
				end
				if not archetype.alive then
					continue
				end
				entities = archetype.entities
				row = #entities
				local columns_map = archetype.columns_map
				a = columns_map[A] or EMPTY
				b = columns_map[B] or EMPTY
				c = columns_map[C] or EMPTY
				d = columns_map[D] or EMPTY
				e = columns_map[E] or EMPTY
				entity = entities[row]
			end
			local r = row
			row -= 1
			return entity, a[r], b[r], c[r], d[r], e[r]
		end
	elseif n_out == 6 then
		return function(): ...any
			local entity = entities[row]
			while entity == nil do
				index += 1
				local archetype = list[index]
				if not archetype then
					return nil
				end
				if not archetype.alive then
					continue
				end
				entities = archetype.entities
				row = #entities
				local columns_map = archetype.columns_map
				a = columns_map[A] or EMPTY
				b = columns_map[B] or EMPTY
				c = columns_map[C] or EMPTY
				d = columns_map[D] or EMPTY
				e = columns_map[E] or EMPTY
				f = columns_map[F] or EMPTY
				entity = entities[row]
			end
			local r = row
			row -= 1
			return entity, a[r], b[r], c[r], d[r], e[r], f[r]
		end
	elseif n_out == 7 then
		return function(): ...any
			local entity = entities[row]
			while entity == nil do
				index += 1
				local archetype = list[index]
				if not archetype then
					return nil
				end
				if not archetype.alive then
					continue
				end
				entities = archetype.entities
				row = #entities
				local columns_map = archetype.columns_map
				a = columns_map[A] or EMPTY
				b = columns_map[B] or EMPTY
				c = columns_map[C] or EMPTY
				d = columns_map[D] or EMPTY
				e = columns_map[E] or EMPTY
				f = columns_map[F] or EMPTY
				g = columns_map[G] or EMPTY
				entity = entities[row]
			end
			local r = row
			row -= 1
			return entity, a[r], b[r], c[r], d[r], e[r], f[r], g[r]
		end
	elseif n_out == 8 then
		return function(): ...any
			local entity = entities[row]
			while entity == nil do
				index += 1
				local archetype = list[index]
				if not archetype then
					return nil
				end
				if not archetype.alive then
					continue
				end
				entities = archetype.entities
				row = #entities
				local columns_map = archetype.columns_map
				a = columns_map[A] or EMPTY
				b = columns_map[B] or EMPTY
				c = columns_map[C] or EMPTY
				d = columns_map[D] or EMPTY
				e = columns_map[E] or EMPTY
				f = columns_map[F] or EMPTY
				g = columns_map[G] or EMPTY
				h = columns_map[H] or EMPTY
				entity = entities[row]
			end
			local r = row
			row -= 1
			return entity, a[r], b[r], c[r], d[r], e[r], f[r], g[r], h[r]
		end
	end

	local term_ids = query.term_ids
	local rest_count = n_out - 8
	local rest_columns: { Column } = table.create(rest_count)
	local rest: { any } = table.create(rest_count)

	return function(): ...any
		local entity = entities[row]
		while entity == nil do
			index += 1
			local archetype = list[index]
			if not archetype then
				return nil
			end
			if not archetype.alive then
				continue
			end
			entities = archetype.entities
			row = #entities
			local columns_map = archetype.columns_map
			a = columns_map[A] or EMPTY
			b = columns_map[B] or EMPTY
			c = columns_map[C] or EMPTY
			d = columns_map[D] or EMPTY
			e = columns_map[E] or EMPTY
			f = columns_map[F] or EMPTY
			g = columns_map[G] or EMPTY
			h = columns_map[H] or EMPTY
			for i = 1, rest_count do
				rest_columns[i] = columns_map[term_ids[i + 8]] or EMPTY
			end
			entity = entities[row]
		end
		local r = row
		row -= 1
		for i = 1, rest_count do
			rest[i] = rest_columns[i][r]
		end
		return entity, a[r], b[r], c[r], d[r], e[r], f[r], g[r], h[r], unpack(rest, 1, rest_count)
	end
end

-- With `probe`, returns `(archetype) -> boolean` instead of an iterator: runs
-- the program for that single archetype until its first yield. `list` must
-- then be a private one-slot table.
local function iter_program(query: QueryInternal, list: { Archetype }, probe: boolean?): () -> ...any
	local world = query.world
	local internal = world.internal
	local components_lookup = world.components_lookup
	local archetypes = world.archetypes
	local entity_index = internal.entity_index
	local sparse = entity_index.sparse
	local dense = entity_index.dense
	local ECS_PAIR = internal.ECS_PAIR
	local PAIR_SECOND = internal.PAIR_SECOND
	local ENTITY_ID = internal.ENTITY_ID
	local ECS_WILDCARD = internal.ECS_WILDCARD
	local EMPTY = internal.NULL_ARRAY
	local traverse_up = make_traverse_up(world)

	local code = query.code
	local n_out = query.n_out
	local n_vars = query.n_vars
	local yield_fail_pc = query.yield_fail_pc

	local ctx: { number } = table.create(query.n_ops * 2, 0)
	local var_ent: { u53? } = table.create(n_vars)
	local var_arch: { Archetype } = table.create(n_vars)
	local var_row: { number } = table.create(n_vars, 0)
	local rc: { Column } = table.create(n_out, EMPTY)
	local rm: { number } = table.create(n_out, 0)
	local rb: { number } = table.create(n_out, 1)

	local res_entities: { Entity } = EMPTY
	local res_lo = 1
	local res_hi = 0

	-- Runs the program until the next OP_YIELD. `redo` resumes the last
	-- iterating op instead of starting from the beginning.
	local function run(redo: boolean): boolean
		local pc = if redo then yield_fail_pc else 1

		while true do
			local off = (pc - 1) * STRIDE
			local op = code[off + 1]
			local ok: boolean

			if op == OP_TERM then
				local src = code[off + 4]
				local column = var_arch[src].columns_map[code[off + 5]]
				if column then
					local out, m = code[off + 6], code[off + 7]
					rc[out], rm[out], rb[out] = column, m, (1 - m) * var_row[src]
					ok = true
				else
					ok = false
				end
			elseif op == OP_SELECT_THIS then
				local index = if redo then ctx[pc * 2 - 1] + 1 else 1
				local archetype = list[index]
				while archetype and not archetype.alive do
					index += 1
					archetype = list[index]
				end
				if not archetype then
					return false
				end

				ctx[pc * 2 - 1] = index
				var_arch[THIS_VAR], var_row[THIS_VAR], var_ent[THIS_VAR] = archetype, 0, nil
				res_entities = archetype.entities
				res_lo, res_hi = 1, #res_entities
				ok = true
			elseif op == OP_YIELD then
				return true
			elseif op == OP_EACH_THIS then
				local entities = var_arch[THIS_VAR].entities
				local count = #entities
				local row = if redo then ctx[pc * 2 - 1] - 1 else count
				if row > count then
					row = count
				end
				if row < 1 then
					ok = false
				else
					ctx[pc * 2 - 1] = row
					var_ent[THIS_VAR], var_row[THIS_VAR] = entities[row] :: any, row
					res_lo, res_hi = row, row
					ok = true
				end
			elseif op == OP_SPARSE_CHECK then
				-- A src var, B id (relation when E ~= 0), C out, D mode, E target var
				local entity = var_ent[code[off + 4]]
				local id = code[off + 5]
				local tgt = code[off + 8]
				if tgt ~= 0 then
					local target = var_ent[tgt]
					id = if target then ECS_PAIR(id, target) else 0
				end

				local mode = code[off + 7]
				local out = code[off + 6]
				local set: types.SparseSet? = nil
				local slot: number? = nil
				if entity then
					if mode == MODE_TERM or mode == SPARSE_OPTIONAL then
						-- the value of (R, *) is the one of the first pair
						set, slot = sparse_slot_of(components_lookup, ECS_WILDCARD, PAIR_SECOND, ENTITY_ID(entity), id)
					else
						-- existence only: the (R, *) set answers directly
						local record = (components_lookup[id] :: any) :: PairRecord?
						set = if record then record.sparse else nil
						slot = if set then set.index[ENTITY_ID(entity)] else nil
					end
				end

				if mode == MODE_WITHOUT then
					ok = slot == nil
				elseif slot then
					if out ~= 0 then
						rc[out], rm[out], rb[out] = (set :: types.SparseSet).values, 0, slot
					end
					ok = true
				elseif mode == SPARSE_OPTIONAL then
					rc[out], rm[out], rb[out] = EMPTY, 0, 1
					ok = true
				else
					ok = false
				end
			elseif op == OP_SELECT_SPARSE or op == OP_SPARSE_FROM_SELECT then
				-- A var, B record id (relation when D ~= 0), C out, D target var.
				-- Walks the sparse set backwards with clamping like OP_EACH_THIS,
				-- so deleting the yielded entity is safe.
				local var: number
				local id: u53
				local out = 0
				if op == OP_SELECT_SPARSE then
					var = THIS_VAR
					id = code[off + 4]
					out = code[off + 5]
				else
					var = code[off + 4]
					id = code[off + 5]
					out = code[off + 6]
					local tgt = code[off + 7]
					if tgt ~= 0 then
						local target = var_ent[tgt]
						id = if target then ECS_PAIR(id, target) else 0
					end
				end

				local record = (components_lookup[id] :: any) :: PairRecord?
				local set = if record then record.sparse else nil
				ok = false
				if set then
					local set_dense = set.dense
					local slot = if redo then ctx[pc * 2 - 1] - 1 else #set_dense
					if slot > #set_dense then
						slot = #set_dense
					end
					while slot >= 1 do
						local entity = set_dense[slot]
						local entity_record = sparse[ENTITY_ID(entity)]
						if entity_record then
							var_arch[var], var_row[var], var_ent[var] =
								entity_record.archetype, entity_record.archetype_row, entity
							if out ~= 0 then
								rc[out], rm[out], rb[out] = set.values, 0, slot
							end
							if var == THIS_VAR then
								res_entities = set_dense :: any
								res_lo, res_hi = slot, slot
							end
							ctx[pc * 2 - 1] = slot
							ok = true
							break
						end
						slot -= 1
					end
				end
			elseif op == OP_SPARSE_TARGET_VAR then
				-- A src var, B (R, *) id, C target var, D out. Enumerates the
				-- entity's list of (R, T) pairs.
				local entity = var_ent[code[off + 4]]
				local relation_record = (components_lookup[code[off + 5]] :: any) :: PairRecord?
				local relation_set = if relation_record then relation_record.sparse else nil
				local list: { u53 }? = nil
				if relation_set and entity then
					local slot = relation_set.index[ENTITY_ID(entity)]
					list = if slot then relation_set.values[slot] else nil
				end

				local k = if redo then ctx[pc * 2 - 1] + 1 else 1
				ok = false
				if list then
					while k <= #list do
						local pair_id = list[k]
						local target_record = sparse[PAIR_SECOND(pair_id)]
						if target_record then
							local var = code[off + 6]
							var_arch[var], var_row[var], var_ent[var] =
								target_record.archetype, target_record.archetype_row, dense[target_record.dense]
							local out = code[off + 7]
							if out ~= 0 then
								local pair_set = (components_lookup[pair_id] :: PairRecord).sparse :: types.SparseSet
								rc[out], rm[out], rb[out] = pair_set.values, 0, pair_set.index[ENTITY_ID(entity :: u53)]
							end
							ctx[pc * 2 - 1] = k
							ok = true
							break
						end
						k += 1
					end
				end
			elseif op == OP_TERM_OPT then
				local src = code[off + 4]
				local term = code[off + 5]
				local output = code[off + 6]

				local column = var_arch[src].columns_map[term]
				if column then
					local m = code[off + 7]
					rc[output], rm[output], rb[output] = column, m, (1 - m) * var_row[src]
				else
					rc[output], rm[output], rb[output] = EMPTY, 0, 1
				end
				ok = true
			elseif op == OP_UP_TERM then
				local src = code[off + 4]
				local row, column =
					traverse_up(var_arch[src], var_ent[src], code[off + 5], code[off + 6], code[off + 8] == 1)
				if column then
					local out = code[off + 7]
					if row == 0 then
						local m = if src == THIS_VAR then 1 else 0
						rc[out], rm[out], rb[out] = column, m, (1 - m) * var_row[src]
					else
						rc[out], rm[out], rb[out] = column, 0, row :: number
					end
					ok = true
				else
					ok = false
				end
			elseif op == OP_TARGET_VAR then
				local src = code[off + 4]
				local archetype = var_arch[src]
				local archetype_id = archetype.archetype_id
				local k: number
				local count: number
				local start = 0

				local pair_record = (components_lookup[code[off + 5]] :: any) :: PairRecord?
				if redo then
					k = ctx[pc * 2 - 1] + 1
					count = ctx[pc * 2]
				else
					k = 0
					count = if pair_record then pair_record.pairs_count[archetype_id] or 0 else 0
					ctx[pc * 2] = count
				end
				if count > 0 and pair_record then
					start = pair_record.column_index[archetype_id]
				end

				ok = false
				local components, columns = archetype.components, archetype.columns
				while k < count do
					local record = sparse[PAIR_SECOND(components[start + k])]
					if record then
						local var = code[off + 6]
						var_arch[var], var_row[var], var_ent[var] =
							record.archetype, record.archetype_row, dense[record.dense]
						local out = code[off + 7]
						if out ~= 0 then
							local m = code[off + 8]
							rc[out], rm[out], rb[out] = columns[start + k], m, (1 - m) * var_row[src]
						end
						ctx[pc * 2 - 1] = k
						ok = true
						break
					end
					k += 1
				end
			elseif op == OP_WITH then
				ok = var_arch[code[off + 4]].columns_map[code[off + 5]] ~= nil
			elseif op == OP_WITHOUT then
				ok = var_arch[code[off + 4]].columns_map[code[off + 5]] == nil
			elseif op == OP_UP_WITH or op == OP_UP_WITHOUT then
				local src = code[off + 4]
				local _, column =
					traverse_up(var_arch[src], var_ent[src], code[off + 5], code[off + 6], code[off + 7] == 1)
				ok = if op == OP_UP_WITH then column ~= nil else column == nil
			elseif op == OP_TARGET_BOUND or op == OP_TARGET_BOUND_NOT then
				local src = code[off + 4]
				local target = var_ent[code[off + 6]]
				local column = if target then var_arch[src].columns_map[ECS_PAIR(code[off + 5], target)] else nil
				if op == OP_TARGET_BOUND_NOT then
					ok = column == nil
				elseif column then
					local out = code[off + 7]
					if out ~= 0 then
						local m = code[off + 8]
						rc[out], rm[out], rb[out] = column, m, (1 - m) * var_row[src]
					end
					ok = true
				else
					ok = false
				end
			elseif op == OP_FROM_SELECT or op == OP_FROM_SELECT_PAIR then
				local var = code[off + 4]
				local id: u53
				local index: number
				local row: number
				local record: ComponentRecord?

				if op == OP_FROM_SELECT then
					id = code[off + 5]
				else
					local target = var_ent[code[off + 6]]
					id = if target then ECS_PAIR(code[off + 5], target) else 0
				end
				record = components_lookup[id]

				if redo then
					index = ctx[pc * 2 - 1]
					row = ctx[pc * 2] - 1
				else
					index = if record then #record.archetype_ids + 1 else 0
					row = 0
				end

				ok = false
				if record then
					local archetype_ids = record.archetype_ids
					local column_index = record.column_index
					while true do
						local archetype: Archetype? = if index >= 1 then archetypes[archetype_ids[index]] else nil
						if archetype then
							local entities = archetype.entities
							local count = #entities
							if row > count then
								row = count
							end
							if row >= 1 then
								var_arch[var], var_row[var], var_ent[var] = archetype, row, entities[row] :: any
								local out = if op == OP_FROM_SELECT then code[off + 6] else code[off + 7]
								if out ~= 0 then
									rc[out], rm[out], rb[out] =
										archetype.columns[column_index[archetype.archetype_id]], 0, row
								end
								ctx[pc * 2 - 1], ctx[pc * 2] = index, row
								ok = true
								break
							end
						end
						index -= 1
						if index < 1 then
							break
						end
						local next_archetype = archetypes[archetype_ids[index]]
						row = if next_archetype then #next_archetype.entities else 0
					end
				end
			elseif op == OP_JMP then
				pc = code[off + 4]
				redo = false
				continue
			elseif op == OP_NONE then
				local out = code[off + 4]
				if out ~= 0 then
					rc[out], rm[out], rb[out] = EMPTY, 0, 1
				end
				ok = true
			else
				error(`query engine: unknown opcode {op}`)
			end

			if ok then
				pc += 1
				redo = false
			else
				pc = code[off + 2]
				if pc == 0 then
					return false
				end
				redo = code[off + 3] == 1
			end
		end
	end

	if probe then
		return (function(archetype: Archetype): boolean
			list[1] = archetype
			return run(false)
		end) :: any
	end

	query.last_var_ent = var_ent

	local cur_row = 0
	local row_lo = 1
	local redo = false
	local entities: { Entity } = EMPTY

	local a: Column, b: Column, c: Column, d: Column
	local e: Column, f: Column, g: Column, h: Column
	local ma, mb, mc, md, me, mf, mg, mh = 0, 0, 0, 0, 0, 0, 0, 0
	local ba, bb, bc, bd, be, bf, bg, bh = 1, 1, 1, 1, 1, 1, 1, 1

	if n_out == 0 then
		return function(): ...any
			local row = cur_row
			if row < row_lo then
				if not run(redo) then
					return nil
				end
				redo = true
				entities, row_lo, row = res_entities, res_lo, res_hi
			end
			cur_row = row - 1
			return entities[row]
		end
	elseif n_out == 1 then
		return function(): ...any
			local row = cur_row
			if row < row_lo then
				if not run(redo) then
					return nil
				end
				redo = true
				entities, row_lo, row = res_entities, res_lo, res_hi
				a, ma, ba = rc[1], rm[1], rb[1]
			end
			cur_row = row - 1
			return entities[row], a[row * ma + ba]
		end
	elseif n_out == 2 then
		return function(): ...any
			local row = cur_row
			if row < row_lo then
				if not run(redo) then
					return nil
				end
				redo = true
				entities, row_lo, row = res_entities, res_lo, res_hi
				a, ma, ba = rc[1], rm[1], rb[1]
				b, mb, bb = rc[2], rm[2], rb[2]
			end
			cur_row = row - 1
			return entities[row], a[row * ma + ba], b[row * mb + bb]
		end
	elseif n_out == 3 then
		return function(): ...any
			local row = cur_row
			if row < row_lo then
				if not run(redo) then
					return nil
				end
				redo = true
				entities, row_lo, row = res_entities, res_lo, res_hi
				a, ma, ba = rc[1], rm[1], rb[1]
				b, mb, bb = rc[2], rm[2], rb[2]
				c, mc, bc = rc[3], rm[3], rb[3]
			end
			cur_row = row - 1
			return entities[row], a[row * ma + ba], b[row * mb + bb], c[row * mc + bc]
		end
	elseif n_out == 4 then
		return function(): ...any
			local row = cur_row
			if row < row_lo then
				if not run(redo) then
					return nil
				end
				redo = true
				entities, row_lo, row = res_entities, res_lo, res_hi
				a, ma, ba = rc[1], rm[1], rb[1]
				b, mb, bb = rc[2], rm[2], rb[2]
				c, mc, bc = rc[3], rm[3], rb[3]
				d, md, bd = rc[4], rm[4], rb[4]
			end
			cur_row = row - 1
			return entities[row], a[row * ma + ba], b[row * mb + bb], c[row * mc + bc], d[row * md + bd]
		end
	elseif n_out == 5 then
		return function(): ...any
			local row = cur_row
			if row < row_lo then
				if not run(redo) then
					return nil
				end
				redo = true
				entities, row_lo, row = res_entities, res_lo, res_hi
				a, ma, ba = rc[1], rm[1], rb[1]
				b, mb, bb = rc[2], rm[2], rb[2]
				c, mc, bc = rc[3], rm[3], rb[3]
				d, md, bd = rc[4], rm[4], rb[4]
				e, me, be = rc[5], rm[5], rb[5]
			end
			cur_row = row - 1
			return entities[row],
				a[row * ma + ba],
				b[row * mb + bb],
				c[row * mc + bc],
				d[row * md + bd],
				e[row * me + be]
		end
	elseif n_out == 6 then
		return function(): ...any
			local row = cur_row
			if row < row_lo then
				if not run(redo) then
					return nil
				end
				redo = true
				entities, row_lo, row = res_entities, res_lo, res_hi
				a, ma, ba = rc[1], rm[1], rb[1]
				b, mb, bb = rc[2], rm[2], rb[2]
				c, mc, bc = rc[3], rm[3], rb[3]
				d, md, bd = rc[4], rm[4], rb[4]
				e, me, be = rc[5], rm[5], rb[5]
				f, mf, bf = rc[6], rm[6], rb[6]
			end
			cur_row = row - 1
			return entities[row],
				a[row * ma + ba],
				b[row * mb + bb],
				c[row * mc + bc],
				d[row * md + bd],
				e[row * me + be],
				f[row * mf + bf]
		end
	elseif n_out == 7 then
		return function(): ...any
			local row = cur_row
			if row < row_lo then
				if not run(redo) then
					return nil
				end
				redo = true
				entities, row_lo, row = res_entities, res_lo, res_hi
				a, ma, ba = rc[1], rm[1], rb[1]
				b, mb, bb = rc[2], rm[2], rb[2]
				c, mc, bc = rc[3], rm[3], rb[3]
				d, md, bd = rc[4], rm[4], rb[4]
				e, me, be = rc[5], rm[5], rb[5]
				f, mf, bf = rc[6], rm[6], rb[6]
				g, mg, bg = rc[7], rm[7], rb[7]
			end
			cur_row = row - 1
			return entities[row],
				a[row * ma + ba],
				b[row * mb + bb],
				c[row * mc + bc],
				d[row * md + bd],
				e[row * me + be],
				f[row * mf + bf],
				g[row * mg + bg]
		end
	elseif n_out == 8 then
		return function(): ...any
			local row = cur_row
			if row < row_lo then
				if not run(redo) then
					return nil
				end
				redo = true
				entities, row_lo, row = res_entities, res_lo, res_hi
				a, ma, ba = rc[1], rm[1], rb[1]
				b, mb, bb = rc[2], rm[2], rb[2]
				c, mc, bc = rc[3], rm[3], rb[3]
				d, md, bd = rc[4], rm[4], rb[4]
				e, me, be = rc[5], rm[5], rb[5]
				f, mf, bf = rc[6], rm[6], rb[6]
				g, mg, bg = rc[7], rm[7], rb[7]
				h, mh, bh = rc[8], rm[8], rb[8]
			end
			cur_row = row - 1
			return entities[row],
				a[row * ma + ba],
				b[row * mb + bb],
				c[row * mc + bc],
				d[row * md + bd],
				e[row * me + be],
				f[row * mf + bf],
				g[row * mg + bg],
				h[row * mh + bh]
		end
	end

	local rest_count = n_out - 8
	local rest: { any } = table.create(rest_count)

	return function(): ...any
		local row = cur_row
		if row < row_lo then
			if not run(redo) then
				return nil
			end
			redo = true
			entities, row_lo, row = res_entities, res_lo, res_hi
			a, ma, ba = rc[1], rm[1], rb[1]
			b, mb, bb = rc[2], rm[2], rb[2]
			c, mc, bc = rc[3], rm[3], rb[3]
			d, md, bd = rc[4], rm[4], rb[4]
			e, me, be = rc[5], rm[5], rb[5]
			f, mf, bf = rc[6], rm[6], rb[6]
			g, mg, bg = rc[7], rm[7], rb[7]
			h, mh, bh = rc[8], rm[8], rb[8]
		end
		cur_row = row - 1
		for i = 1, rest_count do
			local slot = i + 8
			rest[i] = rc[slot][row * rm[slot] + rb[slot]]
		end
		return entities[row],
			a[row * ma + ba],
			b[row * mb + bb],
			c[row * mc + bc],
			d[row * md + bd],
			e[row * me + be],
			f[row * mf + bf],
			g[row * mg + bg],
			h[row * mh + bh],
			unpack(rest, 1, rest_count)
	end
end

local query_mt = {}
query_mt.__index = query_mt

local function assert_archetype_driven(query: QueryInternal, method: string)
	if query.sparse_driver then
		error(`:{method}() is not available on a query driven by a DontFragment term`)
	end
end

local function query_rematch(query: QueryInternal): { Archetype }
	assert_archetype_driven(query, "rematch")
	if query.is_cached then
		return query.compatible_archetypes :: { Archetype }
	end
	-- empty archetypes are kept: entities may move into them before the next
	-- archetype creation, which is the only event that refreshes this list
	local list = query.prematcher.find(false)
	query.compatible_archetypes = list
	query.matched_generation = query.world.internal.get_archetypes_count()
	return list
end

-- Non cached queries keep their prematched list while no archetype has been
-- created since the last match; destroyed archetypes are skipped while
-- iterating, so only creations can change the result.
local function query_archetypes(query: QueryInternal): { Archetype }
	local list = query.compatible_archetypes
	if list and (query.is_cached or query.matched_generation == query.world.internal.get_archetypes_count()) then
		return list
	end
	return query_rematch(query)
end

-- Depth ordering of `list` for :cascade(). Counting sort on the archetype
-- depth: stable, so archetypes of one depth keep their creation order.
-- Traversable relations read the depth off the hierarchy node of the first
-- pair; other relations walk the chain of archetypes, memoised per sort so
-- shared ancestors are walked once.
local function cascade_sort(query: QueryInternal, list: { Archetype }): { Archetype }
	local world = query.world
	local internal = world.internal
	local archetypes_count = internal.get_archetypes_count()
	local hierarchy = internal.hierarchy
	local links = hierarchy.link_generation
	local sorted = query.sorted

	if
		sorted
		and query.sorted_source == list
		and query.sorted_archetypes == archetypes_count
		and (query.cascade_tracked and query.sorted_links == links)
	then
		return sorted
	end

	local relation = query.cascade :: u53
	local components_lookup = world.components_lookup
	local relation_record = components_lookup[internal.ECS_PAIR(relation, internal.ECS_WILDCARD)]

	query.sorted_source = list
	query.sorted_archetypes = archetypes_count
	query.sorted_links = links

	-- nobody holds the relation: every depth is 0 and the list is in order
	if not relation_record then
		query.sorted = list
		return list
	end

	local column_index = relation_record.column_index
	local count = #list
	local depths = query.sort_depths
	local max_depth = 0

	if query.cascade_tracked then
		local hierarchy_depth = hierarchy.depth
		for index, archetype in list do
			local depth = 0
			local pair_index = column_index[archetype.archetype_id]
			if pair_index then
				local node = (components_lookup[archetype.components[pair_index]] :: PairRecord).node
				if node then
					local cache = node.depth
					depth = (if cache.current == node.generation then cache.depth else hierarchy_depth(node)) + 1
				else
					depth = internal.archetype_depth(archetype, relation)
				end
			end
			depths[index] = depth
			if depth > max_depth then
				max_depth = depth
			end
		end
	else
		local sparse = internal.entity_index.sparse
		local PAIR_SECOND = internal.PAIR_SECOND
		-- archetype id -> depth; -1 marks an archetype on the chain being walked
		local memo: Map<number, number> = {}
		local chain: { Archetype } = {}

		for index, archetype in list do
			local depth = memo[archetype.archetype_id]
			if not depth then
				local chain_count = 0
				local base = 0
				local current = archetype
				while true do
					local pair_index = column_index[current.archetype_id]
					if not pair_index then
						break
					end
					memo[current.archetype_id] = -1
					chain_count += 1
					chain[chain_count] = current

					local target_record = sparse[PAIR_SECOND(current.components[pair_index])]
					local holder = target_record.archetype
					local known = memo[holder.archetype_id]
					if known == -1 then
						error "relation cycle detected while sorting by depth"
					elseif known then
						base = known
						break
					end
					current = holder
				end
				for link = chain_count, 1, -1 do
					base += 1
					memo[chain[link].archetype_id] = base
				end
				memo[archetype.archetype_id] = base
				depth = base
			end
			depths[index] = depth
			if depth > max_depth then
				max_depth = depth
			end
		end
	end

	-- bucket starts, index depth + 1
	local starts: { number } = table.create(max_depth + 1, 0)
	for index = 1, count do
		local bucket = depths[index] + 1
		starts[bucket] += 1
	end
	local position = 1
	for bucket = 1, max_depth + 1 do
		local size = starts[bucket]
		starts[bucket] = position
		position += size
	end

	local output: { Archetype }
	if sorted and sorted ~= list then
		output = sorted
		table.clear(output)
	else
		output = table.create(count)
		query.sorted = output
	end
	for index = 1, count do
		local bucket = depths[index] + 1
		local slot = starts[bucket]
		starts[bucket] = slot + 1
		output[slot] = list[index]
	end
	return output
end

local function query_archetypes_ordered(query: QueryInternal): { Archetype }
	assert_archetype_driven(query, "archetypes")
	local list = query_archetypes(query)
	if query.cascade and #list > 1 then
		return cascade_sort(query, list)
	end
	return list
end

local function query_match(query: QueryInternal, archetype: Archetype): boolean
	assert_archetype_driven(query, "match")
	local map = query.compatible_archetypes_map
	if map then
		return map[archetype.archetype_id] ~= nil
	end
	return query.world.internal.ARCHETYPE_MATCHER_MATCH(query.prematcher.matcher)(archetype)
end

-- a sparse driven program never reads the archetype list
local SPARSE_DRIVER_LIST: { Archetype } = table.freeze {} :: any

local function query_iter(query: QueryInternal): () -> ...any
	if query.sparse_driver then
		return iter_program(query, SPARSE_DRIVER_LIST)
	end
	local list = query_archetypes_ordered(query)
	if #list == 0 then
		return NOOP
	end
	if query.is_static then
		return iter_static(query, list)
	end
	return iter_program(query, list)
end

local function query_cached(query: QueryInternal): QueryInternal
	-- nothing to cache: the sparse set is the live result list
	if query.is_cached or query.sparse_driver then
		return query
	end
	local list, map, cleanup = query.world.internal.OBSERVE_MATCHED_ARCHETYPES(query.world, query.prematcher.matcher)
	query.is_cached = true
	query.compatible_archetypes = list
	query.compatible_archetypes_map = map
	query.cache_cleanup = cleanup
	return query
end

local function query_cleanup(query: QueryInternal)
	local cleanup = query.cache_cleanup
	if cleanup then
		cleanup()
	end
	query.is_cached = false
	query.cache_cleanup = nil
	query.compatible_archetypes = nil
	query.compatible_archetypes_map = nil
end

local function query_var(query: QueryInternal, name: string): u53?
	local var_ent = query.last_var_ent
	if not var_ent then
		return nil
	end
	local index = table.find(query.var_names, name)
	if not index then
		error(`unknown query variable {name}`)
	end
	return var_ent[index]
end

-- Monitors are event driven: every id the query depends on is hooked and the
-- affected archetypes are re-probed from inside those hooks. A `reported` set
-- keeps every `added` balanced by exactly one `removed`, so hooks firing twice
-- for one operation or callbacks mutating the world are harmless.
local function query_monitor(query: QueryInternal): types.Monitor
	local world = query.world
	local internal = world.internal
	local prematcher = query.prematcher
	local without_ids: { u53 }? = if #prematcher.without_ids > 0 then prematcher.without_ids else nil

	if query.is_static then
		return internal.monitor_new(world, prematcher.matcher)
	end
	-- monitors compare archetypes, which DontFragment pairs are not part of
	if query.has_sparse then
		error "monitor() is not supported on queries with DontFragment terms"
	end
	if query.per_entity then
		error "monitor() is not supported on queries that bind $this per entity"
	end

	local components_lookup = world.components_lookup
	local archetypes = world.archetypes
	local ECS_PAIR = internal.ECS_PAIR
	local get_entity_record = internal.get_entity_record
	local hierarchy_collect = internal.hierarchy.collect

	local list, map, observe_cleanup = internal.OBSERVE_MATCHED_ARCHETYPES(world, prematcher.matcher)
	local probe: (Archetype) -> boolean = iter_program(query, {}, true) :: any

	local reported: Map<u53, boolean> = {}
	local added_callback: ((entity: u53) -> ())? = nil
	local removed_callback: ((entity: u53) -> ())? = nil

	local function report_added(entity: u53)
		reported[entity] = true
		if added_callback then
			added_callback(entity)
		end
	end

	local function report_removed(entity: u53)
		reported[entity] = nil
		if removed_callback then
			removed_callback(entity)
		end
	end

	local function reconcile_entity(entity: u53, archetype: Archetype?)
		if not archetype then
			local record = get_entity_record(entity)
			archetype = if record then record.archetype else nil
		end
		local valid = archetype ~= nil and map[archetype.archetype_id] ~= nil and probe(archetype)
		if valid then
			if not reported[entity] then
				report_added(entity)
			end
		elseif reported[entity] then
			report_removed(entity)
		end
	end

	-- every entity of an archetype shares its validity
	local function reconcile_archetype(archetype: Archetype)
		local entities = archetype.entities
		if probe(archetype) then
			for row = #entities, 1, -1 do
				local entity: u53 = entities[row] :: any
				if entity ~= nil and not reported[entity] then
					report_added(entity)
				end
			end
		else
			for row = #entities, 1, -1 do
				local entity: u53 = entities[row] :: any
				if entity ~= nil and reported[entity] then
					report_removed(entity)
				end
			end
		end
	end

	local function reconcile_all()
		for index = #list, 1, -1 do
			local archetype = list[index]
			if archetype and archetype.alive then
				reconcile_archetype(archetype)
			end
		end
	end

	-- every archetype holding (relation, source) is re-evaluated: all of its
	-- entities depend on `source`
	local function reconcile_record(record: ComponentRecord)
		local archetype_ids = record.archetype_ids
		for index = #archetype_ids, 1, -1 do
			local archetype_id = archetype_ids[index]
			local archetype = if archetype_id then archetypes[archetype_id] else nil
			if archetype and archetype.alive and map[archetype_id] then
				reconcile_archetype(archetype)
			end
		end
	end

	-- re-evaluates everything that depends on `source` through `relation`,
	-- following the chain downwards when `recursive`. Traversable relations
	-- walk hierarchy nodes (targets only); other relations walk entities.
	local function propagate_down(relation: u53, source: u53, recursive: boolean, depth: number)
		local record = components_lookup[ECS_PAIR(relation, source)] :: PairRecord
		if not record then
			return
		end

		local node = record.node
		if node then
			if not recursive then
				reconcile_record(record)
				return
			end
			-- snapshot first: callbacks may reshape the hierarchy while walking
			local nodes = hierarchy_collect(node, {})
			for _, descendant in nodes do
				reconcile_record(descendant.record)
			end
			return
		end

		local archetype_ids = record.archetype_ids
		for index = #archetype_ids, 1, -1 do
			local archetype_id = archetype_ids[index]
			local archetype = if archetype_id then archetypes[archetype_id] else nil
			if not archetype or not archetype.alive then
				continue
			end
			if map[archetype_id] then
				reconcile_archetype(archetype)
			end
			if recursive and depth < MAX_UP_DEPTH then
				local entities = archetype.entities
				for row = #entities, 1, -1 do
					local entity: u53 = entities[row] :: any
					if entity ~= nil then
						propagate_down(relation, entity, true, depth + 1)
					end
				end
			end
		end
	end

	local detaches: { () -> () } = {}

	-- membership: entering or leaving the prematched set, entity deletion
	local membership: types.QueryIdMonitor = {
		match = function(archetype: Archetype): boolean
			return map[archetype.archetype_id] ~= nil
		end,
		added = function(entity: u53, _: number?, destination: Archetype?)
			reconcile_entity(entity, destination)
		end,
		removed = function(entity: u53)
			reconcile_entity(entity, nil)
		end,
	}
	table.insert(detaches, internal.MONITOR_ATTACH(world, prematcher.with_ids, membership))
	if without_ids then
		table.insert(detaches, internal.MONITOR_ATTACH(world, without_ids, membership))
	end

	local function always(): boolean
		return true
	end

	-- self watch: `$this` changes that keep it inside the prematched set
	if #query.self_watch > 0 then
		table.insert(
			detaches,
			internal.OBSERVER_ATTACH(world, query.self_watch, {
				match = always,
				callback = function(entity: u53)
					reconcile_entity(entity, nil)
				end,
			})
		)
	end

	-- dependency watch: ids other entities provide through a relation
	for _, watch in query.dep_watch do
		local relation, recursive = watch.relation, watch.recursive
		table.insert(
			detaches,
			internal.OBSERVER_ATTACH(world, { watch.id }, {
				match = always,
				callback = function(entity: u53)
					reconcile_entity(entity, nil)
					propagate_down(relation, entity, recursive, 1)
				end,
			})
		)
	end

	if #query.global_watch > 0 then
		table.insert(
			detaches,
			internal.OBSERVER_ATTACH(world, query.global_watch, {
				match = always,
				callback = function()
					reconcile_all()
				end,
			})
		)
	end

	local function cleanup()
		for _, detach in detaches do
			detach()
		end
		table.clear(detaches)
		observe_cleanup()
		table.clear(reported)
	end

	-- entities matching at creation are tracked silently (no callbacks are set
	-- yet) so that they get `removed` when they stop matching
	reconcile_all()

	return {
		added = function(callback: (entity: u53) -> ())
			added_callback = callback
		end,
		removed = function(callback: (entity: u53) -> ())
			removed_callback = callback
		end,
		cleanup = cleanup,
	} :: any
end

query_mt.iter = query_iter
query_mt.__iter = query_iter
query_mt.monitor = query_monitor
query_mt.archetypes = query_archetypes_ordered
query_mt.match = query_match
query_mt.rematch = query_rematch
query_mt.cached = query_cached
query_mt.cleanup = query_cleanup
query_mt.var = query_var

function builder_mt.build(builder: BuilderInternal): Query
	local query = compile(builder)
	return setmetatable(query, query_mt) :: any
end

local function build(world: any): QueryBuilder
	local builder: BuilderInternal = {
		world = world,
		terms = {},
		pending = nil,
		pending_or = nil,
		n_out = 0,
		cascade_relation = nil,
	}
	return setmetatable(builder, builder_mt) :: any
end

return {
	build = build,
}
