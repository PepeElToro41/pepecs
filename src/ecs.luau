--!native
--!optimize 2

type u24 = number
type u53 = number
type ArchetypeId = number
type Bitset = number
type Column = Array<any>

type Map<T, V> = { [T]: V }
type Array<T> = { T }

export type Entity<T = any> = { __T: T }
export type Component<T = any> = { __T: T }

export type Query<T...> = typeof(setmetatable(
	{} :: {
		archetypes: () -> { Archetype },
		with: (...Component) -> Query<T...>,
		without: (...Component) -> Query<T...>,
		iter: () -> () -> (Entity, T...),
	},
	{} :: {
		__iter: () -> () -> (Entity, T...),
	}
))

export type Archetype = {
	archetype_id: ArchetypeId,
	hash: string,
	
	entities: { Entity },
	colums: Array<Column>,
	components: Array<u53>,
	
    colums_map: { [u53]: Column },
	edges: Map<u53, Archetype>
}

export type EntityRecord = {
	archetype: Archetype,
	archetype_row: number,
	dense: u24,
}

type SetHook = (entity: Entity, id: Component, value: number) -> () 
type RemovedHook = (entity: Entity, id: Component) -> (() -> ())?

export type ComponentRecord = {
    column_index: Map<ArchetypeId, number>,
    id_count: Map<ArchetypeId, number>,
    
    -- only defined for pair(rel, *)
    pair_records: Map<u53, ComponentRecord>?,
    
    archetype_count: number,
    flags: Bitset,
    
    on_added: { SetHook }?,
    on_changed: { SetHook }?,
    on_removed: { RemovedHook }?
}

export type ComponentsLookup = Map<u53, ComponentRecord>

export type EntityIndex = {
	dense: Array<u53>,
	sparse: Map<u24, EntityRecord>,
	alive: number,
}

export type World = {}

local ENTITY_MASK = bit32.lshift(1, 24)
local GENERATION_MASK = bit32.lshift(1, 16)
local PAIR_OFFSET = 2 ^ 48

local HI_COMPONENT_ID = 256

local ECS_WILDCARD = HI_COMPONENT_ID + 1
local ECS_CHILDOF = HI_COMPONENT_ID + 2
local ECS_COMPONENT = HI_COMPONENT_ID + 3
local ECS_NAME = HI_COMPONENT_ID + 4
local ECS_REST = ECS_NAME + 1

local MASK_IS_TAG = bit32.lshift(1, 0)

local NULL_ARRAY = table.freeze {} :: { any }

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

local function GET_NEW_ENTITY_ID(index: EntityIndex): u53
	local dense_arr = index.dense
	local sparse_arr = index.sparse
	local alive = index.alive
	local count = #sparse_arr

	if alive >= count then
		local next_id = count + 1
		local new_record = { dense = next_id } :: EntityRecord
		table.insert(sparse_arr, new_record)
		table.insert(dense_arr, next_id)
		index.alive = next_id

		return next_id
	end

	alive += 1
	index.alive = alive
	return dense_arr[alive]
end

local function DELETE_ENTITY_ID(index: EntityIndex, id: u24)
	local dense_arr = index.dense
	local sparse_arr = index.sparse
	local alive = index.alive

	local dense_index = sparse_arr[id].dense
	if dense_index ~= alive then
		local last = dense_arr[alive]
		dense_arr[dense_index] = last
	end
	local new_generation = INCREMENT_GENERATION(dense_arr[dense_index])
	dense_arr[alive] = new_generation
	index.alive -= 1
end

local function FIRE_SET_HOOKS(hooks: { SetHook }, entity: u53, id: u53, data: any)
    for _, hook in hooks do
       hook(entity :: any, id :: any, data) 
    end
end


local function world()
	local dense_arr = {}
	local sparse_arr = {}
	
	local archetypes_count = 1
	local archetypes: Map<ArchetypeId, Archetype> = {}
	local archetypes_lookup: Map<string, Archetype> ={}
	
	local component_count = 0
	local components_lookup: ComponentsLookup = {}
	
	local entity_index: EntityIndex = {
		dense = dense_arr,
		sparse = sparse_arr,
		alive = 0,
	}
	
	local ROOT_ARCHETYPE: Archetype = {
		archetype_id = archetypes_count,
		hash = "",
		
	    entities = {},
		colums = {},
		components = {},
		
		colums_map = {},
		edges = {},
	}
	archetypes[1] = ROOT_ARCHETYPE
	archetypes_lookup[""] = ROOT_ARCHETYPE
	
	local function get_entity_record(entity: u53): EntityRecord?
		return sparse_arr[ENTITY_ID(entity)]
	end
	
	local function get_entity_record_alive(entity: u53): EntityRecord?
	    local record = sparse_arr[ENTITY_ID(entity)]
		if record == nil then
		    return nil
		end
		if record.dense > entity_index.alive then
		    error "attempted to use a dead entity"
		end
		return record
	end
	
	local function component_record_create(id: u53)
	    local record: ComponentRecord = {
			column_index = {},
			id_count = {},
			pair_records = nil ,
					
			archetype_count = 0,
			flags = 0,
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
	
	local function archetype_append_to_record(record: ComponentRecord, archetype_id: ArchetypeId, index: number): boolean
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
	
	local function archetype_insert_entity(entity: u53, record: EntityRecord, archetype: Archetype): number
	    local entities = archetype.entities
	    local last_row = #entities
		local assign_row = last_row + 1
		
		entities[assign_row] = entity :: any
		return assign_row
	end
	
	local function archetype_move_rows(source: Archetype, destination: Archetype, source_row: number, destination_row: number, last_row: number)
	    local source_colums = source.colums

	    if source_row == destination_row then
			for index, column in source_colums do
                if column == NULL_ARRAY then continue end
                
                local destination_column = destination.colums[source.components[index]]
                if destination_column then
                    destination_column[destination_row] = column[source_row]
                end
                
                column[last_row] = nil
			end
		else
			for index, column in source_colums do
                if column == NULL_ARRAY then continue end
                
                local destination_column = destination.colums[source.components[index]]
                if destination_column then
                    destination_column[destination_row] = column[source_row]
                end
                
                column[source_row] = column[last_row]
                column[last_row] = nil
			end
		end
	end
	
	local function archetype_move_entity(entity: u53, record: EntityRecord, source: Archetype, destination: Archetype)
	    local source_entities = source.entities
		local destination_entities = destination.entities
		
		local last_source_row = #source_entities
		local last_destination_row = #destination_entities
		
		local source_row = record.archetype_row
		local destination_row = last_destination_row + 1
		
		archetype_move_rows(source, destination, source_row, destination_row, last_source_row)
		
		if source_row ~= destination_row then
		    local swapped_entity: u53 = source_entities[last_source_row] :: any
            source_entities[source_row] = swapped_entity :: any
		
		    local swapped_record = get_entity_record(swapped_entity) :: EntityRecord
			swapped_record.archetype_row = source_row
		end
		
		source_entities[last_source_row] = nil
        destination_entities[destination_row] = entity :: any
		record.archetype_row = destination_row
	end
	
	local function archetype_assign_entity(entity: u53, record: EntityRecord, archetype: Archetype)
	    local assigned_row = archetype_insert_entity(entity, record, archetype)
		record.archetype = archetype
		record.archetype_row = assigned_row
	end
	
	local function archetype_create(ids: { u53 }, hash: string): Archetype
	    local archetype_id = archetypes_count + 1
		archetypes_count = archetype_id
		
		local columns_length = #ids
		local columns: { Column } = table.create(columns_length)
		
		local columns_map: Map<u53, Column> = {}
		
		for index, id in ids do
		    local id_record = component_record_ensure(id)
			id_record.archetype_count += 1
						
			local is_tag = CHECK_FLAG(id_record.flags, MASK_IS_TAG)
			local column = if is_tag then NULL_ARRAY else {}
			columns[index] = column
			
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
                        [id] = id_record
                    }
				end
				
				local target_wildcard = ECS_PAIR(ECS_WILDCARD, target)
				local target_record = component_record_create(target_wildcard)
				target_record.archetype_count += 1
				
				local target_apended = archetype_append_to_record(target_record, archetype_id, index)
				if target_apended then
				    columns_map[relation_wildcard] = column
				end
			end
		end
		
		local archetype: Archetype = {
		    archetype_id = archetype_id,
			hash = hash,
		
			entities = {},
			colums = columns,
			components = ids,
		
			colums_map = columns_map,
			edges = {},
		}
		
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
	
	local function archetype_find_with()
	
	end
	
	local function archetype_find_without()
	
	end

	local function world_entity(): u53
		return GET_NEW_ENTITY_ID(entity_index)
	end

	local function world_set(entity: u53, id: u53, data: any)
	    local record = get_entity_record_alive(entity)
		if not record then return end
		
		local archetype_row = record.archetype_row
		local from_archetype = record.archetype
		local column = from_archetype.colums_map[id]
		
		if column then
            column[record.archetype_row] = data
            
            local component_record = components_lookup[id]
            local hooks = component_record.on_changed
            if hooks then
                FIRE_SET_HOOKS(hooks, entity, id)
            end
		else
		    if from_archetype == ROOT_ARCHETYPE then
						
				archetype_assign_entity(entity, arche)		
			else
			    --
			end
		end
		
	end

	local function world_add(entity: Entity, id: Entity)
	    
	end

	local function world_component()
		component_count += 1
		return component_count
	end

	-- query

	local function world_query()
		local function query_cached() end

		local function query_with() end

		local function query_without() end

		local function query_build() end

		local function query_archetypes() end

		return {
			query_cached = query_cached,
			query_with = query_with,
			query_without = query_without,
			query_build = query_build,
		}
	end
end

return {
	world = world,
}
