--!optimize 2
--!native

local bench = require "../bench"
local jecs = require "../jecs"

local N = 2 ^ 15

local world = jecs.world()
local C1 = world:component()
local C2 = world:component()
local C3 = world:component()
local C4 = world:component()
local T1 = world:entity()
local T2 = world:entity()
local T3 = world:entity()
local T4 = world:entity()

bench.title "entity: creation"

bench.run("entity()", N, function()
	world:entity()
end)

-- create then delete N so the next N creations hit the free list
local pool = {}
for i = 1, N do
	pool[i] = world:entity()
end
for i = 1, N do
	world:delete(pool[i])
end
bench.run("entity() recycled id", N, function()
	world:entity()
end)

bench.run("entity() + 4 set", N, function(i)
	local e = world:entity()
	world:set(e, C1, i)
	world:set(e, C2, i)
	world:set(e, C3, i)
	world:set(e, C4, i)
end)

local ids = { C1, C2, C3, C4 }
bench.run("entity() + bulk_set 4", N, function(i)
	local e = world:entity()
	jecs.bulk_insert(world, e, ids, { i, i, i, i })
end)

bench.run("entity() + 4 add (tags)", N, function()
	local e = world:entity()
	world:add(e, T1)
	world:add(e, T2)
	world:add(e, T3)
	world:add(e, T4)
end)

bench.title "entity: create + delete churn"

bench.run("entity() + delete", N, function()
	world:delete(world:entity())
end)

bench.run("entity() + 4 set + delete", N, function(i)
	local e = world:entity()
	world:set(e, C1, i)
	world:set(e, C2, i)
	world:set(e, C3, i)
	world:set(e, C4, i)
	world:delete(e)
end)
