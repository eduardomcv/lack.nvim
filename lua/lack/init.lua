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

	return package
end

local function add(specs, opts)
	if type(specs) ~= "table" or not vim.islist(specs) then
		fail("plugin specifications must be a list")
	end

	local packages = {}

	for _, spec in ipairs(specs) do
		table.insert(packages, normalize_spec(spec))
	end

	return vim.pack.add(packages, opts)
end

function M.setup(opts)
	opts = opts or {}

	if type(opts) ~= "table" then
		fail("setup options must be a table")
	end

	local source = opts.repository or repository
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
