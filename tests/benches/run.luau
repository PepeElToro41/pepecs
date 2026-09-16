--!strict

-- Runs every bench pair, ecs first then jecs, each in its own lune process.
-- Usage: lune run tests/benches/run [topic ...]

local process = require "@lune/process"
local color = require "../testlib/ansi"

local TOPICS = {
	"entity",
	"insertion",
	"removal",
	"get",
	"bulk",
	"deletion",
	"cascade",
	"pairs",
	"hooks",
	"query_iter",
	"query_rematch",
	"reactive",
}

local selected = if #process.args > 0 then process.args else TOPICS

local function run(topic: string, lib: string)
	local path = `tests/benches/{topic}/{topic}_{lib}.bench.luau`
	local result = process.exec("lune", { "run", path }, { stdio = "forward" })
	if not result.ok then
		print(color.red(`  {path} failed`))
	end
end

for _, topic in selected do
	print()
	print(color.green_highlight(` ===== {topic}: ecs ===== `))
	run(topic, "ecs")
	if topic ~= "reactive" then
		print()
		print(color.green_highlight(` ===== {topic}: jecs ===== `))
		run(topic, "jecs")
	end
end
