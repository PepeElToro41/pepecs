local testkit = require "./testkit"
local ecs = require "../src/"

local it = testkit.test()
local TEST, CASE = it.TEST, it.CASE
local CHECK, FINISH = it.CHECK, it.FINISH
local FOCUS = it.FOCUS

TEST("world.query()", function()
	do
		CASE "queries should accept zero-ids provided they use :with for the leading component"
		local world = ecs.world()
		local A = world.component()
		local B = world.component()

		local e1 = world.entity()
		world.set(e1, A, "A")

		local e2 = world.entity()
		world.set(e2, A, "A")
		world.set(e2, B, "B")

		local n1 = world.entity()
		local n2 = world.entity()
		world.set(n1, B, "B")
		world.set(n2, B, "B")

		local counter = 0
		for e, a in world.query():with(A):iter() do
			CHECK(e == e1 or e == e2)
			CHECK(a == nil)
			if e == e1 then
				CHECK(world.has(e1, A))
				CHECK(not world.has(e1, B))
			elseif e == e2 then
				CHECK(world.has(e2, A, B))
			end
			counter += 1
		end
		CHECK(counter == 2)

		counter = 0
		for e, a in world.query():with(A):without(B):iter() do
			CHECK(e == e1)
			CHECK(a == nil)
			CHECK(world.has(e1, A))
			CHECK(not world.has(e1, B))
			counter += 1
		end
		CHECK(counter == 1)
	end

	do
		CASE "3 components"
		local world = ecs.world()
		local A = world.component() :: ecs.Entity<boolean>
		local B = world.component() :: ecs.Entity<boolean>
		local C = world.component() :: ecs.Entity<boolean>
		local e = world.entity()
		world.set(e, A, true)
		world.set(e, B, true)
		world.set(e, C, true)
		local q = world.query(A, B, C)
		local counter = 0
		for x, a, b, c in q:iter() do
			counter += 1
			CHECK(a)
			CHECK(b)
			CHECK(c)
		end
		CHECK(counter == 1)
	end
	do
		CASE "multiple iter"
		local world = ecs.world()
		local A = world.component() :: ecs.Entity<string>
		local B = world.component() :: ecs.Entity<string>
		local e = world.entity()
		world.add(e, A)
		world.add(e, B)
		local q = world.query(A, B)
		local counter = 0
		for x in q:iter() do
			counter += 1
		end
		for x in q:iter() do
			counter += 1
		end
		CHECK(counter == 2)
	end
	do
		CASE "tag"
		local world = ecs.world()
		local A = world.tag()
		local e = world.entity()

		world.add(e, A)
		local count = 0
		for id, a in world.query(A):iter() do
			count += 1
			CHECK(a == nil)
		end
		CHECK(count == 1)
	end
end)

return FINISH()
