--!optimize 2
--!native

local bench = require "../bench"
local jecs = require "../jecs"

local N = 2 ^ 15
local PASSES = 20

-- same seed as the ecs bench so both worlds get identical layouts
math.randomseed(1)
local function flip()
	return math.random() >= 0.3
end

-- dense: every entity has all 8 components (single archetype)
local dense = jecs.world()
local D = {}
for i = 1, 8 do
	D[i] = dense:component()
end
for _ = 1, N do
	local e = dense:entity()
	for i = 1, 8 do
		dense:set(e, D[i], i)
	end
end

-- fragmented: each entity gets a random subset of 8 components (up to 256 archetypes)
local frag = jecs.world()
local F = {}
for i = 1, 8 do
	F[i] = frag:component()
end
for _ = 1, N do
	local e = frag:entity()
	for i = 1, 8 do
		if flip() then
			frag:set(e, F[i], i)
		end
	end
end

local function count(query): number
	local n = 0
	for _ in query:iter() do
		n += 1
	end
	return n
end

bench.title "query iter: dense (1 archetype)"

bench.run("1 term", PASSES, function()
	for _, a in dense:query(D[1]):iter() do
	end
end)
bench.run("2 terms", PASSES, function()
	for _, a, b in dense:query(D[1], D[2]):iter() do
	end
end)
bench.run("4 terms", PASSES, function()
	for _, a, b, c, d in dense:query(D[1], D[2], D[3], D[4]):iter() do
	end
end)
bench.run("8 terms", PASSES, function()
	for _, a, b, c, d, e, f, g, h in dense:query(D[1], D[2], D[3], D[4], D[5], D[6], D[7], D[8]):iter() do
	end
end)

bench.title(`query iter: fragmented ({count(frag:query(F[2], F[4]))} / {count(frag:query(F[2], F[4], F[6], F[8]))} matched)`)

bench.run("2 terms", PASSES, function()
	for _, a, b in frag:query(F[2], F[4]):iter() do
	end
end)
bench.run("4 terms", PASSES, function()
	for _, a, b, c, d in frag:query(F[2], F[4], F[6], F[8]):iter() do
	end
end)
bench.run("2 terms, without 1", PASSES, function()
	for _, a, b in frag:query(F[2], F[4]):without(F[1]):iter() do
	end
end)
bench.run("2 terms, without 3", PASSES, function()
	for _, a, b in frag:query(F[2], F[4]):without(F[1], F[3], F[5]):iter() do
	end
end)

local reused = frag:query(F[2], F[4], F[6], F[8])
bench.run("4 terms, reused query", PASSES, function()
	for _, a, b, c, d in reused:iter() do
	end
end)

local cached = frag:query(F[2], F[4], F[6], F[8]):cached()
bench.run("4 terms, cached query", PASSES, function()
	for _, a, b, c, d in cached:iter() do
	end
end)

bench.run("each(F1)", PASSES, function()
	for _ in frag:each(F[1]) do
	end
end)

bench.title "query iter: archetypes()"

bench.run("archetypes(), 4 terms", 1000, function()
	frag:query(F[2], F[4], F[6], F[8]):archetypes()
end)
