local M = {}

local default_repository = "https://github.com/"
local repository = default_repository
local registered_global = nil

local lua_keywords = {
	["and"] = true,
	["break"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["false"] = true,
	["for"] = true,
	["function"] = true,
	["goto"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["nil"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["true"] = true,
	["until"] = true,
	["while"] = true,
}

local function fail(message)
	error("lack: " .. message, 0)
end

local function resolve_global(value)
	if value == nil or value == false then
		return nil
	end

	if value == true then
		return "lack"
	end

	if type(value) ~= "string" then
		fail("global must be a boolean, string, or nil")
	end

	if not value:match("^[A-Za-z_][A-Za-z0-9_]*$") or lua_keywords[value] then
		fail("global must be a valid Lua identifier")
	end

	return value
end

local function resolve_source(source)
	local has_scheme = source:match("^%a[%w+.-]*://") ~= nil
	local is_scp_ssh = source:match("^[^/%s@:]+@[^/%s:]+:") ~= nil

	if has_scheme or is_scp_ssh then
		return source
	end

	return repository .. source
end

local range_mt = getmetatable(vim.version.range("*"))

local function is_version_range(value)
	return type(value) == "table" and pcall(value.has, value, "1")
end

local function is_semver_pin(value)
	if type(value) ~= "string" then
		return false
	end

	local ok, parsed = pcall(vim.version.parse, value, { strict = true })
	return ok and parsed ~= nil
end

local function intersect_ranges(a, b)
	local from = b.from > a.from and b.from or a.from
	local to

	if a.to == nil then
		to = b.to
	elseif b.to == nil then
		to = a.to
	else
		to = (b.to < a.to) and b.to or a.to
	end

	if to == nil or from < to or (from == to and a:has(from) and b:has(from)) then
		return setmetatable({ from = from, to = to }, range_mt)
	end
end

local function merge_versions(name, current, incoming)
	if current == nil then
		return incoming
	end

	if incoming == nil then
		return current
	end

	if current == incoming then
		return current
	end

	local current_is_range = is_version_range(current)
	local incoming_is_range = is_version_range(incoming)

	if current_is_range and incoming_is_range then
		local merged = intersect_ranges(current, incoming)

		if merged ~= nil then
			return merged
		end
	elseif current_is_range and is_semver_pin(incoming) and current:has(incoming) then
		return incoming
	elseif incoming_is_range and is_semver_pin(current) and incoming:has(current) then
		return current
	end

	fail(("conflicting versions for %s"):format(tostring(name)))
end

local function normalize_spec(spec)
	if type(spec) == "string" then
		spec = { spec }
	elseif type(spec) ~= "table" then
		fail("plugin specifications must be strings or tables")
	end

	local source = spec.src or spec[1]
	if type(source) ~= "string" or source == "" then
		fail("plugin specification requires a non-empty source")
	end

	if spec.dependencies ~= nil and (type(spec.dependencies) ~= "table" or not vim.islist(spec.dependencies)) then
		fail("dependencies must be a list")
	end

	local package = {}

	for key, value in pairs(spec) do
		if key ~= 1 and key ~= "src" and key ~= "dependencies" then
			package[key] = value
		end
	end

	package.src = resolve_source(source)

	return package, spec.dependencies or {}
end

local function plugin_name(package)
	local name = package.name or package.src:gsub("%.git$", "")

	return (type(name) == "string" and name or ""):match("[^/]+$") or ""
end

local function fail_cycle(stack, start, repeated)
	local cycle = {}

	for index = start, #stack do
		table.insert(cycle, stack[index].package.src)
	end

	table.insert(cycle, repeated.package.src)
	fail("dependency cycle: " .. table.concat(cycle, " -> "))
end

local function assert_acyclic(groups)
	local state = {}
	local stack = {}
	local positions = {}

	local function visit(group)
		state[group] = 1
		positions[group] = #stack + 1
		table.insert(stack, group)

		for _, dependency in ipairs(group.dependencies) do
			if state[dependency] == 1 then
				fail_cycle(stack, positions[dependency], dependency)
			elseif state[dependency] == nil then
				visit(dependency)
			end
		end

		state[group] = 2
		positions[group] = nil
		table.remove(stack)
	end

	for _, group in ipairs(groups) do
		if state[group] == nil then
			visit(group)
		end
	end
end

local function collect_specs(specs)
	local groups = {}
	local groups_by_name = {}
	local visiting = {}
	local stack = {}

	local function register(package)
		local name = plugin_name(package)
		local group = groups_by_name[name]

		if group == nil then
			group = {
				package = package,
				dependencies = {},
				dependency_set = {},
				dependents = {},
			}
			groups_by_name[name] = group
			table.insert(groups, group)
			return group
		end

		if group.package.src ~= package.src then
			fail(("conflicting sources for %s: %s and %s"):format(tostring(name), group.package.src, package.src))
		end

		group.package.version = merge_versions(name, group.package.version, package.version)

		return group
	end

	local function visit(spec)
		local package, dependencies = normalize_spec(spec)
		local group = register(package)
		local cycle_start = visiting[group]

		if cycle_start ~= nil then
			fail_cycle(stack, cycle_start, group)
		end

		visiting[group] = #stack + 1
		table.insert(stack, group)

		for _, dependency_spec in ipairs(dependencies) do
			local dependency = visit(dependency_spec)

			if not group.dependency_set[dependency] then
				group.dependency_set[dependency] = true
				table.insert(group.dependencies, dependency)
				table.insert(dependency.dependents, group)
			end
		end

		visiting[group] = nil
		table.remove(stack)

		return group
	end

	for _, spec in ipairs(specs) do
		visit(spec)
	end

	assert_acyclic(groups)

	return groups
end

local function order_groups(groups)
	local indegree = {}
	local emitted = {}
	local packages = {}

	for _, group in ipairs(groups) do
		indegree[group] = #group.dependencies
	end

	while #packages < #groups do
		local next_group

		for _, group in ipairs(groups) do
			if not emitted[group] and indegree[group] == 0 then
				next_group = group
				break
			end
		end

		if next_group == nil then
			fail("dependency cycle")
		end

		emitted[next_group] = true
		table.insert(packages, next_group.package)

		for _, dependent in ipairs(next_group.dependents) do
			indegree[dependent] = indegree[dependent] - 1
		end
	end

	return packages
end

local function warn_active_conflicts(packages)
	if #packages == 0 then
		return
	end

	local ok, known = pcall(vim.pack.get, nil, { info = false })

	if not ok or type(known) ~= "table" then
		return
	end

	local active_versions = {}
	for _, entry in ipairs(known) do
		if entry.active then
			active_versions[entry.spec.name] = entry.spec.version
		end
	end

	for _, package in ipairs(packages) do
		local name = plugin_name(package)
		local active_version = active_versions[name]

		if active_version ~= nil then
			local merge_ok = pcall(merge_versions, name, active_version, package.version)

			if not merge_ok then
				vim.notify(
					("lack: %s is already active with a different version; vim.pack keeps the active plugin's version"):format(
						name
					),
					vim.log.levels.WARN
				)
			end
		end
	end
end

local function add(specs, opts)
	if type(specs) ~= "table" or not vim.islist(specs) then
		fail("plugin specifications must be a list")
	end

	local groups = collect_specs(specs)
	local packages = order_groups(groups)

	warn_active_conflicts(packages)

	return vim.pack.add(packages, opts)
end

function M.setup(opts)
	opts = opts or {}

	if type(opts) ~= "table" then
		fail("setup options must be a table")
	end

	local source = opts.repository
	if source == nil then
		source = repository
	end

	if type(source) ~= "string" or source == "" then
		fail("repository must be a non-empty string")
	end

	source = source:gsub("/+$", "")
	if source == "" then
		fail("repository must be a non-empty string")
	end

	local global = resolve_global(opts.global)
	local existing = nil

	if global ~= nil then
		existing = rawget(_G, global)
	end

	if existing ~= nil and existing ~= M then
		fail(("global %s is already defined"):format(global))
	end

	if registered_global ~= nil and rawget(_G, registered_global) == M then
		rawset(_G, registered_global, nil)
	end

	if global ~= nil then
		rawset(_G, global, M)
	end

	registered_global = global
	repository = source .. "/"
end

return setmetatable(M, {
	__call = function(_, specs, opts)
		return add(specs, opts)
	end,
})
