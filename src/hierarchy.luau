--!optimize 2
--!native
--!strict

-- Hierarchy: nodes for every (R, T) pair record whose relation R carries the
-- Traversable trait, plus the lazily rebuilt caches that hang off them.
--
-- A node mirrors T's position in the R hierarchy. Its parent is the node of
-- T's first R target and its children are the nodes of every entity that
-- holds (R, T). The world keeps the links hydrated on every archetype move of
-- an entity that is a target (see `moved`), so a walk never touches entities,
-- only nodes. Leaves (entities nobody targets) never get a node.
--
-- Two caches live on each node and rebuild by invalidation: a move bumps the
-- node's generation and that of every descendant, and the next consult
-- rebuilds whatever it needs.
--   depth      number of R hops from T up to a root
--   reachable  id -> nearest holder of that id, looking at T first and then
--              up the chain. This is what `:up()` and world.traverse consult.

local types = require "./types"

type u24 = types.u24
type u53 = types.u53
type Map<K, V> = types.Map<K, V>
type Archetype = types.Archetype
type EntityRecord = types.EntityRecord
type EntityIndex = types.EntityIndex
type PairRecord = types.PairRecord
type Node = types.HierarchyNode
type ReachableElement = types.ReachableElement
type Hierarchy = types.Hierarchy

export type Dependencies = {
	entity_index: EntityIndex,
	components_lookup: Map<u53, types.ComponentRecord>,
	ECS_PAIR: (first: u24, second: u24) -> u53,
	PAIR_SECOND: (id: u53) -> u24,
	ECS_WILDCARD: u53,
}

local function new(deps: Dependencies): Hierarchy
	local sparse = deps.entity_index.sparse
	local dense = deps.entity_index.dense
	local components_lookup = deps.components_lookup
	local ECS_PAIR = deps.ECS_PAIR
	local ECS_WILDCARD = deps.ECS_WILDCARD

	-- stamp handed out to every walk so a relation cycle is visited once
	local epoch = 0

	-- filled below; `link_generation` is bumped on every parent link change so
	-- depth sorted queries know when their order may be stale
	local hierarchy = {} :: Hierarchy
	hierarchy.link_generation = 0

	local function next_epoch(): number
		epoch += 1
		return epoch
	end

	-- node of T's first R target as seen from `archetype`, nil at a root
	local function parent_of(node: Node, archetype: Archetype): Node?
		local index = node.relation_record.column_index[archetype.archetype_id]
		if not index then
			return nil
		end
		local parent_record = components_lookup[archetype.components[index]] :: PairRecord
		return if parent_record then parent_record.node else nil
	end

	local function link(parent: Node, child: Node)
		hierarchy.link_generation += 1
		local children = parent.children
		local slot = #children + 1
		children[slot] = child
		parent.child_slots[child.id] = slot
		child.parent = parent
	end

	local function unlink(parent: Node, child: Node)
		hierarchy.link_generation += 1
		local child_slots = parent.child_slots
		local slot = child_slots[child.id]
		if slot then
			local children = parent.children
			local last = #children
			if slot ~= last then
				local moved = children[last]
				children[slot] = moved
				child_slots[moved.id] = slot
			end
			children[last] = nil
			child_slots[child.id] = nil
		end
		child.parent = nil
	end

	local function invalidate(node: Node)
		node.generation += 1
		if #node.children == 0 then
			return
		end

		local stamp = next_epoch()
		node.visited = stamp

		local stack = { node }
		local top = 1
		while top > 0 do
			local current = stack[top]
			stack[top] = nil
			top -= 1

			for _, child in current.children do
				if child.visited ~= stamp then
					child.visited = stamp
					child.generation += 1
					top += 1
					stack[top] = child
				end
			end
		end
	end

	local function collect(node: Node, out: { Node }): { Node }
		local stamp = next_epoch()
		node.visited = stamp

		local count = #out + 1
		out[count] = node
		local cursor = count

		while cursor <= count do
			local current = out[cursor]
			cursor += 1
			for _, child in current.children do
				if child.visited ~= stamp then
					child.visited = stamp
					count += 1
					out[count] = child
				end
			end
		end
		return out
	end

	local function node_create(record: PairRecord, relation_record: PairRecord, id: u53): Node
		local target = deps.PAIR_SECOND(id)
		local node: Node = {
			id = id,
			target = target,
			record = record,
			relation_record = relation_record,

			parent = nil,
			children = {},
			child_slots = {},

			generation = 0,
			visited = 0,

			depth = { current = -1, depth = 0 },
			reachable = { current = -1, reachable = {} },
		}
		record.node = node

		local target_record = sparse[target]
		if target_record then
			target_record.targets += 1
			local parent = parent_of(node, target_record.archetype)
			if parent then
				link(parent, node)
			end
		end
		return node
	end

	local function node_release(record: PairRecord)
		local node = record.node
		if not node then
			return
		end
		record.node = nil

		local parent = node.parent
		if parent then
			unlink(parent, node)
		end

		-- children are normally gone by now (their pair to the target was
		-- removed first), but a cycle being torn down can leave some behind
		local children = node.children
		for index = #children, 1, -1 do
			local child = children[index]
			children[index] = nil
			child.parent = nil
			hierarchy.link_generation += 1
			invalidate(child)
		end
		table.clear(node.child_slots)

		local target_record = sparse[node.target]
		if target_record then
			target_record.targets -= 1
		end
	end

	-- The entity is a target of at least one traversable relation and just
	-- changed archetype: its own ids changed (reachable) and possibly its
	-- parent (depth), so every node targeting it is relinked and invalidated.
	local function moved(record: EntityRecord, destination: Archetype)
		local entity = dense[record.dense]
		local target_record = components_lookup[ECS_PAIR(ECS_WILDCARD, entity)] :: PairRecord
		if not target_record then
			return
		end

		for _, pair_record in target_record.trav_records do
			local node = pair_record.node
			if not node then
				continue
			end

			local parent = parent_of(node, destination)
			local old_parent = node.parent
			if parent ~= old_parent then
				if old_parent then
					unlink(old_parent, node)
				end
				if parent then
					link(parent, node)
				end
			end
			invalidate(node)
		end
	end

	local function depth(node: Node): number
		local cache = node.depth
		if cache.current == node.generation then
			return cache.depth
		end

		-- walk up to the first valid node (or the root), then fill downwards
		local stamp = next_epoch()
		local chain: { Node } = {}
		local count = 0
		local base = 0

		local current: Node? = node
		while current do
			local current_cache = current.depth
			if current_cache.current == current.generation then
				base = current_cache.depth
				break
			end
			if current.visited == stamp then
				error "hierarchy: relation cycle detected while computing depth"
			end
			current.visited = stamp
			count += 1
			chain[count] = current
			current = current.parent
		end

		for index = count, 1, -1 do
			local link_node = chain[index]
			local link_cache = link_node.depth
			if link_node.parent then
				base += 1
			end
			link_cache.depth = base
			link_cache.current = link_node.generation
		end
		return cache.depth
	end

	local function rebuild_reachable(node: Node)
		local cache = node.reachable
		local map = cache.reachable
		table.clear(map)

		local target_record = sparse[node.target]
		if target_record then
			local entity = dense[target_record.dense]
			for id, column in target_record.archetype.columns_map do
				map[id] = { entity = entity, record = target_record, column = column }
			end
		end

		local parent = node.parent
		if parent then
			local parent_cache = parent.reachable
			-- an invalid parent only happens inside a cycle: stop there
			if parent_cache.current == parent.generation then
				for id, element in parent_cache.reachable do
					if map[id] == nil then
						map[id] = element
					end
				end
			end
		end
		cache.current = node.generation
	end

	local function reachable(node: Node): Map<u53, ReachableElement>
		local cache = node.reachable
		if cache.current == node.generation then
			return cache.reachable
		end

		local stamp = next_epoch()
		local chain: { Node } = {}
		local count = 0

		local current: Node? = node
		while current do
			if current.reachable.current == current.generation or current.visited == stamp then
				break
			end
			current.visited = stamp
			count += 1
			chain[count] = current
			current = current.parent
		end

		for index = count, 1, -1 do
			rebuild_reachable(chain[index])
		end
		return cache.reachable
	end

	hierarchy.node_create = node_create
	hierarchy.node_release = node_release
	hierarchy.moved = moved
	hierarchy.invalidate = invalidate
	hierarchy.depth = depth
	hierarchy.reachable = reachable
	hierarchy.collect = collect
	return hierarchy
end

return {
	new = new,
}
