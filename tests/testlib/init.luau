--!strict

local color = require "@self/ansi"
local expect = require "@self/expect"

-- Types
export type TestResult = {
	name: string,
	status: "passed" | "failed" | "skipped",
	error: string?,
	duration: number,
}

export type SuiteResult = {
	name: string,
	status: "passed" | "failed" | "skipped",
	error: string?,
	cases: { TestResult },
	duration: number,
}

export type TestReport = {
	suites: { SuiteResult },
	passed: number,
	failed: number,
	skipped: number,
	duration: number,
}

export type TestPlan = {
	_state: PlanState,
	TEST: (name: string, fn: () -> ()) -> (),
	CASE: (name: string, fn: () -> ()) -> (),
	FOCUS: () -> (),
	SKIP: () -> (),
	BEFORE_ALL: (fn: () -> ()) -> (),
	AFTER_ALL: (fn: () -> ()) -> (),
	BEFORE_EACH: (fn: () -> ()) -> (),
	AFTER_EACH: (fn: () -> ()) -> (),
}

type Hook = () -> ()

type TestCase = {
	name: string,
	fn: () -> (),
	focused: boolean,
	skipped: boolean,
}

type TestSuite = {
	name: string,
	cases: { TestCase },
	beforeAll: { Hook },
	afterAll: { Hook },
	beforeEach: { Hook },
	afterEach: { Hook },
	focused: boolean,
	skipped: boolean,
	hasFocusedCases: boolean,
	fn: () -> (),
}

type PlanState = {
	suites: { TestSuite },
	currentSuite: TestSuite?,
	nextFocused: boolean,
	nextSkipped: boolean,
	hasFocusedSuites: boolean,
}

-- Helper to safely call a function and catch errors
local function safeCall(fn: () -> ()): (boolean, string?)
	local success, err = pcall(fn, nil :: any)
	if success then
		return true, nil
	else
		return false, tostring(err)
	end
end

-- Create a new test plan
local function createPlan(): TestPlan
	local state: PlanState = {
		suites = {},
		currentSuite = nil,
		nextFocused = false,
		nextSkipped = false,
		hasFocusedSuites = false,
	}

	local plan: TestPlan = {
		TEST = nil :: any,
		CASE = nil :: any,
		FOCUS = nil :: any,
		SKIP = nil :: any,
		BEFORE_ALL = nil :: any,
		AFTER_ALL = nil :: any,
		BEFORE_EACH = nil :: any,
		AFTER_EACH = nil :: any,
		_state = nil :: any,
	}

	-- FOCUS marks the next TEST or CASE as focused
	function plan.FOCUS()
		state.nextFocused = true
		if state.currentSuite then
			state.currentSuite.hasFocusedCases = true
		else
			state.hasFocusedSuites = true
		end
	end

	-- SKIP marks the next TEST or CASE as skipped
	function plan.SKIP()
		state.nextSkipped = true
	end

	-- TEST creates a test suite
	function plan.TEST(name: string, fn: () -> ())
		local suite: TestSuite = {
			name = name,
			cases = {},
			beforeAll = {},
			afterAll = {},
			beforeEach = {},
			afterEach = {},
			focused = state.nextFocused,
			skipped = state.nextSkipped,
			hasFocusedCases = false,
			fn = fn,
		}

		-- Reset flags after consuming them
		state.nextFocused = false
		state.nextSkipped = false

		table.insert(state.suites, suite)
	end

	-- CASE creates a test case within a suite
	function plan.CASE(name: string, fn: () -> ())
		if not state.currentSuite then
			error "CASE must be called inside a TEST block"
		end

		table.insert(state.currentSuite.cases, {
			name = name,
			fn = fn,
			focused = state.nextFocused,
			skipped = state.nextSkipped,
		})

		-- Reset flags after consuming them
		state.nextFocused = false
		state.nextSkipped = false
	end

	-- Hook registration functions
	function plan.BEFORE_ALL(fn: Hook)
		if not state.currentSuite then
			error "BEFORE_ALL must be called inside a TEST block"
		end
		table.insert(state.currentSuite.beforeAll, fn)
	end

	function plan.AFTER_ALL(fn: Hook)
		if not state.currentSuite then
			error "AFTER_ALL must be called inside a TEST block"
		end
		table.insert(state.currentSuite.afterAll, fn)
	end

	function plan.BEFORE_EACH(fn: Hook)
		if not state.currentSuite then
			error "BEFORE_EACH must be called inside a TEST block"
		end
		table.insert(state.currentSuite.beforeEach, fn)
	end

	function plan.AFTER_EACH(fn: Hook)
		if not state.currentSuite then
			error "AFTER_EACH must be called inside a TEST block"
		end
		table.insert(state.currentSuite.afterEach, fn)
	end

	-- Store state reference for access during run
	plan._state = state

	return plan
end

local function padded(str: string)
	print(`    • {str}`)
end

local function printReport(report: TestReport)
	print(("-"):rep(10))
	print(color.white_underline "Test Summary")

	local totalCases = 0
	local totalPassed = 0
	local totalFailed = 0
	local totalSkipped = 0

	for _, suite in report.suites do
		local totalCasesPassed = 0
		local totalCasesFailed = 0
		local totalCasesSkipped = 0

		for _, case in suite.cases do
			if case.status == "passed" then
				totalCasesPassed += 1
			elseif case.status == "failed" then
				totalCasesFailed += 1
			elseif case.status == "skipped" then
				totalCasesSkipped += 1
			end
			totalCases += 1
		end

		if suite.status == "failed" then
			print(`{color.red_highlight "FAIL"}| {suite.name}`)
			print(`error: {suite.error}`)
		elseif suite.status == "skipped" then
			print(`{color.yellow "SKIP"}| {suite.name}`)
		elseif suite.status == "passed" then
			if totalCasesFailed == 0 then
				print(
					`{color.green_highlight "PASS"}| {suite.name} {(" "):rep(6)} {color.green(
						`{totalCasesPassed} passed`
					)}`
				)
			else
				print(
					`{color.red_highlight "FAIL"}| {suite.name} {(" "):rep(6)} {color.red(`{totalCasesFailed} failed`)}`
				)
			end
		end

		for _, case in suite.cases do
			if case.status == "failed" then
				padded(`{color.red_highlight "FAIL"}| {suite.name}`)
				padded(`   error: {suite.error}`)
			elseif case.status == "skipped" then
				padded(`{color.yellow "SKIP"}| {suite.name}`)
			elseif case.status == "passed" then
				padded(`{color.green_highlight "PASS"}| {suite.name}`)
			end
		end

		totalPassed += totalCasesPassed
		totalSkipped += totalCasesSkipped
		totalFailed += totalCasesFailed
	end

	if totalFailed == 0 then
		print(color.green_highlight(` --- PASS --- `))
	else
		print(color.red_highlight(` --- FAIL --- `))
	end

	print(
		color.gray(string.format(`{totalPassed}/{totalCases} cases passed in %.3f ms.` :: any, report.duration * 1e3))
	)
	print ""
	print(`{totalPassed} {color.green "passed"}`)
	print(`{totalFailed} {color.green "failed"}`)
	print(`{totalSkipped} {color.green "skipped"}`)
end

local function runCase(suite: TestSuite, case: TestCase)
	local hasFocusedCases = suite.hasFocusedCases
	local shouldSkip = case.skipped or (hasFocusedCases and not case.focused)
	local result: TestResult = {
		name = case.name,
		status = nil :: any,
		error = nil,
		duration = 0,
	}

	if shouldSkip then
		result.status = "skipped"
		return result
	end

	for _, hook in ipairs(suite.beforeEach) do
		local success, err = safeCall(hook)
		if not success then
			result.error = "BEFORE_EACH hook failed: " .. (err or "(unknown error)")
			result.status = "failed"
		end
		return result
	end
	local success, err = safeCall(case.fn)

	if not success then
		result.status = "passed"
	else
		result.status = "failed"
		result.error = err
	end

	-- Run AFTER_EACH hooks
	for _, hook in ipairs(suite.afterEach) do
		local success, err = safeCall(hook)
		if not success then
			print(color.orange("  ⚠ AFTER_EACH hook failed: " .. (err or "unknown error")))
		end
	end

	return result
end

local function runSuite(state: PlanState, suite: TestSuite): SuiteResult
	local suiteResult: SuiteResult = {
		name = suite.name,
		status = nil :: any,
		cases = {},
		duration = 0,
	}

	local hasFocusedSuites = state.hasFocusedSuites
	local suiteShouldSkip = suite.skipped or (hasFocusedSuites and not suite.focused)
	if suiteShouldSkip then
		suiteResult.status = "skipped"
		return suiteResult
	end

	state.currentSuite = suite
	local success, err = safeCall(suite.fn)
	state.currentSuite = nil

	if success then
		for _, hook in ipairs(suite.beforeAll) do
			local success, err = safeCall(hook)
			if not success then
				-- Skip all tests in this suite if BEFORE_ALL fails
				suiteResult.status = "failed"
				suiteResult.error = "BEFORE_ALL hook failed: " .. (err or "unknown error")

				for _, case in ipairs(suite.cases) do
					local result: TestResult = {
						name = case.name,
						status = "skipped",
						error = suiteResult.error,
						duration = 0,
					}
					table.insert(suiteResult.cases, result)
				end

				return suiteResult
			end
		end

		-- Run test cases
		for _, case in ipairs(suite.cases) do
			local caseStartTime = os.clock()
			local caseResult = runCase(suite, case)

			caseResult.duration = os.clock() - caseStartTime
			table.insert(suiteResult.cases, caseResult)
		end
	else
		suiteResult.status = "failed"
		suiteResult.error = err
	end

	-- Run AFTER_ALL hooks
	for _, hook in ipairs(suite.afterAll) do
		local success, err = safeCall(hook)
		if not success then
			print(color.orange("  ⚠ AFTER_ALL hook failed: " .. (err or "(unknown error)")))
		end
	end

	return suiteResult
end

-- Test runner
local function runTests(...: TestPlan): TestReport
	local plans = { ... }

	if #plans == 0 then
		error "run() requires at least one test plan. Use testlib.plan() to create a plan."
	end

	local startTime = os.clock()
	local report: TestReport = {
		suites = {},
		passed = 0,
		failed = 0,
		skipped = 0,
		duration = 0,
	}

	print(color.white_underline "Running Tests")

	-- Process all plans
	for _, plan in ipairs(plans) do
		local state: PlanState = plan._state
		local suites = state.suites

		for _, suite in ipairs(suites) do
			local suiteStartTime = os.clock()
			local suiteResult = runSuite(state, suite)
			suiteResult.duration = os.clock() - suiteStartTime

			table.insert(report.suites, suiteResult)
		end
	end

	report.duration = os.clock() - startTime
	return report
end

-- Export
return {
	report = printReport,
	plan = createPlan,
	expect = expect,
	run = runTests,
}
