local M = {}

local default_repository = "https://github.com/"
local repository = default_repository

local function fail(message)
	error("lack: " .. message, 0)
end

local function resolve_source(source)
	local has_scheme = source:match("^%a[%w+.-]*://") ~= nil
	local is_scp_ssh = source:match("^[^/%s@:]+@[^/%s:]+:") ~= nil

	if has_scheme or is_scp_ssh then
		return source
	end

	return repository .. source
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

		if group.package.version == nil then
			group.package.version = package.version
		elseif group.package.version ~= package.version then
			fail(("conflicting versions for %s"):format(tostring(name)))
		end

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

local function add(specs, opts)
	if type(specs) ~= "table" or not vim.islist(specs) then
		fail("plugin specifications must be a list")
	end

	local groups = collect_specs(specs)
	local packages = order_groups(groups)

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

	repository = source .. "/"
end

return setmetatable(M, {
	__call = function(_, specs, opts)
		return add(specs, opts)
	end,
})
