--!optimize 2
--!native

-- ecs only: jecs core has no monitors / observers / changed queries

local bench = require "../bench"
local ecs = require "../../../src/"

local N = 2 ^ 15

local function noop() end

local function setup()
	local world = ecs.world()
	local A = world.component()
	local B = world.component()
	local entities = {}
	for i = 1, N do
		local e = world.entity()
		world.set(e, A, i)
		entities[i] = e
	end
	return world, A, B, entities
end

bench.title "reactive: baseline (no listeners)"

do
	local world, A, B, entities = setup()
	bench.run("add B", N, function(i)
		world.add(entities[i], B)
	end)
	bench.run("remove B", N, function(i)
		world.remove(entities[i], B)
	end)
	bench.run("set A existing", N, function(i)
		world.set(entities[i], A, i)
	end)
end

bench.title "reactive: monitor on query(A, B)"

do
	local world, A, B, entities = setup()
	local monitor = world.query(A, B):monitor()
	monitor.added(noop)
	monitor.removed(noop)
	bench.run("add B (enters query)", N, function(i)
		world.add(entities[i], B)
	end)
	bench.run("remove B (leaves query)", N, function(i)
		world.remove(entities[i], B)
	end)
end

bench.title "reactive: observe on query(A, B)"

do
	local world, A, B, entities = setup()
	world.query(A, B):observe(noop)
	bench.run("add B (enters query)", N, function(i)
		world.add(entities[i], B)
	end)
	for i = 1, N do
		world.remove(entities[i], B)
	end
	bench.run("set A existing (in query, after add)", N, function(i)
		world.add(entities[i], B)
		world.set(entities[i], A, i)
	end)
end

bench.title "reactive: changed on query(A)"

do
	local world, A, B, entities = setup()
	local changed = world.query(A):changed()
	-- drain the initial queue
	for _ in changed:iter() do
	end

	bench.run("set A existing (tracked)", N, function(i)
		world.set(entities[i], A, i)
	end)

	bench.run("changed:iter(), 100% modified", 1, function()
		for _, a in changed:iter() do
		end
	end)

	for i = 1, N, 10 do
		world.set(entities[i], A, i)
	end
	bench.run("changed:iter(), 10% modified", 1, function()
		for _, a in changed:iter() do
		end
	end)

	bench.run("changed:iter(), 0% modified", 1000, function()
		for _, a in changed:iter() do
		end
	end)
end
