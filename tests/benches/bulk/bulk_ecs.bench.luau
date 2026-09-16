--!optimize 2
--!native

local bench = require "../bench"
local ecs = require "../../../src/"

local N = 2 ^ 12
local SIZES = { 4, 16, 64 }

local world = ecs.world()
local C = {}
for i = 1, 64 do
	C[i] = world.component()
end

local function ids(k: number): { ecs.Component }
	local list = {}
	for i = 1, k do
		list[i] = C[i]
	end
	return list
end

local function values(k: number, v: any): { any }
	local list = {}
	for i = 1, k do
		list[i] = v
	end
	return list
end

local function fresh(): { ecs.Entity }
	local list = {}
	for i = 1, N do
		list[i] = world.entity()
	end
	return list
end

local function filled(k: number): { ecs.Entity }
	local list = fresh()
	local id_list = ids(k)
	for i = 1, N do
		world.bulk_set(list[i], id_list, values(k, i))
	end
	return list
end

for _, K in SIZES do
	bench.title(`bulk: insert {K} components`)

	local id_list = ids(K)
	local vals = values(K, 0)

	local seq = fresh()
	bench.run(`{K} x set (sequential)`, N, function(i)
		local e = seq[i]
		for c = 1, K do
			world.set(e, id_list[c], i)
		end
	end)

	local bulk = fresh()
	bench.run(`bulk_set {K}`, N, function(i)
		world.bulk_set(bulk[i], id_list, vals)
	end)

	local overwrite = filled(K)
	bench.run(`bulk_set {K} (all existing)`, N, function(i)
		world.bulk_set(overwrite[i], id_list, vals)
	end)

	bench.title(`bulk: remove {K} components`)

	local seq_remove = filled(K)
	bench.run(`{K} x remove (sequential)`, N, function(i)
		local e = seq_remove[i]
		for c = 1, K do
			world.remove(e, id_list[c])
		end
	end)

	local bulk_remove = filled(K)
	bench.run(`bulk_remove {K}`, N, function(i)
		world.bulk_remove(bulk_remove[i], id_list)
	end)
end
