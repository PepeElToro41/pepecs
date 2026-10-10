--!strict

-- Runs every bench pair, ecs first then jecs, each in its own process of the
-- runtime this script was started with.
-- Usage: lune run tests/benches/run [topic ...]
--        zune run tests/benches/run [topic ...]

local color = require "../testlib/ansi"

-- zune exposes its std as a global instead of "@lune/*" style requires
local zune: any = (getfenv() :: any).zune

local function lune_process()
	return require "@lune/process"
end

local args: { string }
local exec: (path: string) -> boolean

if zune then
	-- zune passes the script path as the first argument
	args = table.clone(zune.process.args)
	table.remove(args, 1)

	function exec(path)
		return zune.process.run("zune", { "run", path }, { stdout = "inherit", stderr = "inherit" }).ok
	end
else
	local process = lune_process()
	args = process.args

	function exec(path)
		return process.exec("lune", { "run", path }, { stdio = "forward" }).ok
	end
end

local TOPICS = {
	"entity",
	"insertion",
	"removal",
	"get",
	"bulk",
	"deletion",
	"cascade",
	"pairs",
	"hierarchy",
	"hooks",
	"query_iter",
	"query_rematch",
	"query_dead",
	"reactive",
}

local selected = if #args > 0 then args else TOPICS

local function run(topic: string, lib: string)
	local path = `tests/benches/{topic}/{topic}_{lib}.bench.luau`
	if not exec(path) then
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
