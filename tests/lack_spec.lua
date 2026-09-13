--- Needed for mocking vim.pack.add() in the tests below
--- @diagnostic disable: duplicate-set-field

local lack = require("lack")

local tests = {}
local original_add = vim.pack.add

local function test(name, fn)
	table.insert(tests, { name = name, fn = fn })
end

local function equal(expected, actual)
	if not vim.deep_equal(expected, actual) then
		error(("expected:\n%s\nactual:\n%s"):format(vim.inspect(expected), vim.inspect(actual)), 2)
	end
end

local function invoke(specs, opts)
	local call = { count = 0 }

	vim.pack.add = function(packages, add_opts)
		call.count = call.count + 1
		call.packages = packages
		call.opts = add_opts
		return "native-result"
	end

	local result = lack(specs, opts)

	equal("native-result", result)
	equal(1, call.count)

	return call
end

local function expect_error(fragment, fn)
	local ok, err = pcall(fn)

	if ok then
		error(("expected error containing %q"):format(fragment), 2)
	end

	err = tostring(err)
	if not err:find(fragment, 1, true) then
		error(("expected error containing %q, got:\n%s"):format(fragment, err), 2)
	end

	return err
end

local function sources(packages)
	local result = {}

	for _, package in ipairs(packages) do
		table.insert(result, package.src)
	end

	return result
end

local function with_globals(names, fn)
	local previous = {}

	for _, name in ipairs(names) do
		previous[name] = rawget(_G, name)
		rawset(_G, name, nil)
	end

	local ok, err = xpcall(fn, debug.traceback)

	for _, name in ipairs(names) do
		rawset(_G, name, previous[name])
	end

	if not ok then
		error(err, 0)
	end
end

test("resolves string, positional, and src forms uniformly", function()
	local call = invoke({
		"owner/string",
		{ "owner/positional" },
		{ src = "owner/named" },
	})

	equal({
		"https://github.com/owner/string",
		"https://github.com/owner/positional",
		"https://github.com/owner/named",
	}, sources(call.packages))
end)

test("src takes precedence over the positional source", function()
	local call = invoke({
		{
			"owner/ignored",
			src = "owner/selected",
		},
	})

	equal({
		{ src = "https://github.com/owner/selected" },
	}, call.packages)
end)

test("passes URI and SCP-style sources through unchanged", function()
	local call = invoke({
		"https://example.com/owner/https",
		"ssh://git@example.com/owner/ssh",
		"git://example.com/owner/git",
		"file:///tmp/file-plugin",
		"git@example.com:owner/scp",
	})

	equal({
		"https://example.com/owner/https",
		"ssh://git@example.com/owner/ssh",
		"git://example.com/owner/git",
		"file:///tmp/file-plugin",
		"git@example.com:owner/scp",
	}, sources(call.packages))
end)

test("uses the configured repository with one trailing slash", function()
	lack.setup({
		repository = "https://code.example/plugins///",
	})

	local call = invoke({ "owner/plugin" })

	equal({
		{ src = "https://code.example/plugins/owner/plugin" },
	}, call.packages)
end)

test("forwards package fields and call options without mutation", function()
	local specs = {
		{
			"owner/plugin",
			name = "custom-plugin",
			version = "v1.2.3",
			data = { channel = "stable" },
		},
	}
	local opts = {
		confirm = false,
		load = false,
	}
	local original_specs = vim.deepcopy(specs)
	local call = invoke(specs, opts)

	equal({
		{
			src = "https://github.com/owner/plugin",
			name = "custom-plugin",
			version = "v1.2.3",
			data = { channel = "stable" },
		},
	}, call.packages)
	equal(original_specs, specs)
	equal(opts, call.opts)

	if call.opts ~= opts then
		error("vim.pack.add() did not receive the original options table")
	end
end)

test("orders dependencies before dependents and deduplicates them", function()
	local call = invoke({
		{
			"owner/telescope",
			dependencies = { "owner/plenary" },
		},
		{
			"owner/neogit",
			dependencies = {
				"owner/plenary",
				{
					"owner/diffview",
					dependencies = { "owner/plenary" },
				},
			},
		},
	})

	equal({
		"https://github.com/owner/plenary",
		"https://github.com/owner/telescope",
		"https://github.com/owner/diffview",
		"https://github.com/owner/neogit",
	}, sources(call.packages))
end)

test("collects dependencies from every duplicate occurrence", function()
	local call = invoke({
		{
			"owner/plugin",
			dependencies = { "owner/first-dependency" },
		},
		{
			"owner/plugin",
			dependencies = { "owner/second-dependency" },
		},
	})

	equal({
		"https://github.com/owner/first-dependency",
		"https://github.com/owner/second-dependency",
		"https://github.com/owner/plugin",
	}, sources(call.packages))
end)

test("retains independent declaration order", function()
	local call = invoke({
		"owner/first",
		"owner/second",
		"owner/third",
	})

	equal({
		"https://github.com/owner/first",
		"https://github.com/owner/second",
		"https://github.com/owner/third",
	}, sources(call.packages))
end)

test("retains stable order when dependencies constrain declarations", function()
	local call = invoke({
		{
			"owner/first",
			dependencies = { "owner/dependency" },
		},
		"owner/second",
		"owner/third",
	})

	equal({
		"https://github.com/owner/dependency",
		"https://github.com/owner/first",
		"https://github.com/owner/second",
		"https://github.com/owner/third",
	}, sources(call.packages))
end)

test("fills a missing canonical version from a duplicate", function()
	local call = invoke({
		{
			"owner/plugin",
			data = { canonical = true },
		},
		{
			"owner/plugin",
			version = "v2.0.0",
			data = { canonical = false },
		},
	})

	equal({
		{
			src = "https://github.com/owner/plugin",
			version = "v2.0.0",
			data = { canonical = true },
		},
	}, call.packages)
end)

test("deduplicates explicit names by their native final component", function()
	local call = invoke({
		{
			"owner/plugin",
			name = "scope/plugin",
			dependencies = { "owner/first-dependency" },
		},
		{
			"owner/plugin",
			name = "plugin",
			dependencies = { "owner/second-dependency" },
		},
	})

	equal({
		"https://github.com/owner/first-dependency",
		"https://github.com/owner/second-dependency",
		"https://github.com/owner/plugin",
	}, sources(call.packages))
	equal("scope/plugin", call.packages[3].name)
end)

test("rejects duplicate identities with conflicting sources", function()
	local called = false
	vim.pack.add = function()
		called = true
	end

	expect_error("conflicting sources", function()
		lack({
			{ "owner/first", name = "plugin" },
			{ "owner/second", name = "plugin" },
		})
	end)
	equal(false, called)
end)

test("rejects duplicate identities with conflicting versions", function()
	local called = false
	vim.pack.add = function()
		called = true
	end

	expect_error("conflicting versions", function()
		lack({
			{ "owner/plugin", version = "v1.0.0" },
			{ "owner/plugin", version = "v2.0.0" },
		})
	end)
	equal(false, called)
end)

test("preserves native version conflict ordering", function()
	expect_error("conflicting versions", function()
		lack({
			{ "owner/plugin", version = "v1.0.0" },
			"owner/plugin",
		})
	end)
end)

test("reports dependency cycles before calling vim.pack.add", function()
	local called = false
	vim.pack.add = function()
		called = true
	end

	local first = { "owner/first" }
	local second = {
		"owner/second",
		dependencies = { first },
	}
	first.dependencies = { second }

	local err = expect_error("lack:", function()
		lack({ first })
	end)

	equal(false, called)

	if not err:find("owner/first", 1, true) or not err:find("owner/second", 1, true) then
		error("cycle error does not identify the complete plugin chain")
	end
end)

local invalid_specs = {
	{
		name = "rejects a non-list top-level specification",
		specs = { plugin = "owner/plugin" },
	},
	{
		name = "rejects a non-string and non-table plugin specification",
		specs = { 42 },
	},
	{
		name = "rejects a missing plugin source",
		specs = { { version = "v1.0.0" } },
	},
	{
		name = "rejects an empty plugin source",
		specs = { "" },
	},
	{
		name = "rejects a non-list dependencies value",
		specs = {
			{
				"owner/plugin",
				dependencies = { plugin = "owner/dependency" },
			},
		},
	},
}

for _, case in ipairs(invalid_specs) do
	test(case.name, function()
		expect_error("lack:", function()
			lack(case.specs)
		end)
	end)
end

test("rejects an empty configured repository", function()
	expect_error("lack:", function()
		lack.setup({ repository = "" })
	end)
end)

test("rejects a non-string configured repository", function()
	expect_error("repository must be a non-empty string", function()
		lack.setup({ repository = false })
	end)
end)

test("registers, renames, and disables the global alias", function()
	with_globals({ "use", "plug" }, function()
		lack.setup({ global = true })
		equal(lack, rawget(_G, "use"))

		lack.setup({ global = "plug" })
		equal(nil, rawget(_G, "use"))
		equal(lack, rawget(_G, "plug"))

		lack.setup({})
		equal(nil, rawget(_G, "plug"))
	end)
end)

test("forwards calls through the global alias", function()
	with_globals({ "use" }, function()
		lack.setup({ global = true })

		local opts = { confirm = false }
		local call = { count = 0 }

		vim.pack.add = function(packages, add_opts)
			call.count = call.count + 1
			call.packages = packages
			call.opts = add_opts
			return "global-result"
		end

		local result = rawget(_G, "use")({ "owner/plugin" }, opts)

		equal("global-result", result)
		equal(1, call.count)
		equal({ { src = "https://github.com/owner/plugin" } }, call.packages)
		equal(opts, call.opts)
	end)
end)

test("disables only an alias still owned by lack", function()
	with_globals({ "use" }, function()
		lack.setup({ global = true })
		equal(lack, rawget(_G, "use"))

		local replacement = {}
		rawset(_G, "use", replacement)
		lack.setup({ global = false })

		equal(replacement, rawget(_G, "use"))
	end)
end)

test("re-registering the same owned global succeeds silently", function()
	with_globals({ "use" }, function()
		lack.setup({ global = true })
		equal(lack, rawget(_G, "use"))

		lack.setup({ global = true })
		equal(lack, rawget(_G, "use"))
	end)
end)

test("rejects re-registering an owned global after it is hijacked", function()
	with_globals({ "use" }, function()
		lack.setup({ global = true })
		equal(lack, rawget(_G, "use"))

		local hijacker = {}
		rawset(_G, "use", hijacker)

		expect_error("global use is already defined", function()
			lack.setup({ global = true })
		end)

		equal(hijacker, rawget(_G, "use"))
	end)
end)

test("rejects invalid global names", function()
	for _, value in ipairs({ "", "not-valid", "local", 42 }) do
		expect_error("global", function()
			lack.setup({ global = value })
		end)
	end
end)

test("rejects occupied globals without changing existing setup", function()
	with_globals({ "plug", "occupied" }, function()
		lack.setup({
			repository = "https://gitlab.com/",
			global = "plug",
		})
		rawset(_G, "occupied", false)

		expect_error("global occupied is already defined", function()
			lack.setup({
				repository = "https://code.example/",
				global = "occupied",
			})
		end)

		equal(lack, rawget(_G, "plug"))
		equal(false, rawget(_G, "occupied"))

		local packages
		vim.pack.add = function(resolved)
			packages = resolved
			return "global-result"
		end

		local result = rawget(_G, "plug")({ "owner/plugin" })

		equal("global-result", result)
		equal({ { src = "https://gitlab.com/owner/plugin" } }, packages)
	end)
end)

local failures = {}

for _, case in ipairs(tests) do
	lack.setup({
		repository = "https://github.com/",
	})

	local ok, err = xpcall(case.fn, debug.traceback)

	if ok then
		print("ok - " .. case.name)
	else
		table.insert(failures, {
			name = case.name,
			error = err,
		})
		print("not ok - " .. case.name)
	end
end

vim.pack.add = original_add

if #failures > 0 then
	for _, failure in ipairs(failures) do
		io.stderr:write(("\n%s\n%s\n"):format(failure.name, failure.error))
	end

	vim.cmd("cquit 1")
end

print(("%d tests passed"):format(#tests))
vim.cmd("qa!")
