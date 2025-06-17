local M = {}

local default_config = {
	setup_adapter = true,
	netcoredbg = {
		path = "netcoredbg",
	},
}

local maxConcurrentProcs = 5
---@class Semaphore
local concurrentProcsSemaphore = require("plenary.async.control").Semaphore.new(maxConcurrentProcs)

---@class dap-cs.projectInfo
---@field IsExe boolean
---@field TargetPath string
---@field OutputType string

---@class dap-cs.projectInfoPromise
---@field info? dap-cs.projectInfo
---@field running boolean
---@field await fun()

---@class dap-cs.projectInfoCache
---@field _next? function
---@field iter function
---@field resolved dap-cs.projectInfo[]
---@field deferred { [string]: dap-cs.projectInfoPromise }
---@field queued { [string]: dap-cs.projectInfoPromise }
M.projectInfoCache = {
	resolved = {},
	deferred = {},
	queued = {},
	---@param self dap-cs.projectInfoCache
	iter = function(self)
		if vim.tbl_count(self.queued) == 0 and vim.tbl_count(self.deferred) == 0 then
			return pairs(self.resolved)
		end
		local _next = nil
		local this
		this = function(_, idx)
			if _next == nil then
				_next = pairs(self.queued)
			end

			local _idx, value = _next(self.queued, idx)

			if _idx == nil then
				if vim.tbl_count(self.deferred) > 0 then
					self.queued = self.deferred
					self.deferred = {}
					_next = nil
					return this(_idx)
				else
					self.queued = {}
					self.deferred = {}
					return nil
				end
			end
			local _name = vim.fn.fnamemodify(_idx, ":t")

			---@cast value dap-cs.projectInfoPromise
			---@cast _idx string
			if not value.running then
				vim.wait(1)
				self.deferred[_idx] = value
				return this(nil, _idx)
			else
				if value.info == nil then
					value:await()
				end
				self.resolved[_idx] = value.info

				return _idx, value.info
			end
		end
		return this, self, nil
	end,
}

local load_module = function(module_name)
	local ok, module = pcall(require, module_name)
	assert(ok, string.format("dap-cs dependency error: %s not installed", module_name))
	return module
end

local file_selection = function(files, opts)
	if #files == 0 then
		vim.notify(opts.empty_message)
		return
	end

	if opts.allow_multiple then
		return files
	end

	local result
	if #files > 1 then
		result = require("dap.ui").pick_one(files, opts.multiple_title_message, function(fname)
			return vim.fn.fnamemodify(fname, ":t")
		end)
	else
		result = files[1]
	end

	return result
end

---Uses dotnet and msbuild to ensure relevant info is cached
local cache_project_info = function(file, force)
	---@module "plenary.async"
	local a = load_module("plenary.async")

	if (not M.projectInfoCache.resolved[file]) or force then
		local info = { running = false, info = nil }

		function info:await()
			vim.wait(30000, function() -- MsBuild can take long, but probably not longer than 30 seconds. Probably
				return self.info ~= nil
			end)

			if self.info == nil then
				-- At this point we already timed out, but as the async job might still be running there is a chance it completes in time.
				-- However that might also not be the case, so we emit a warning
				vim.notify(
					"dap-cs: Warning: MsBuild didnt respond within the timeout! Subsequent errors may occur!",
					vim.log.levels.WARN
				)
			end
		end

		M.projectInfoCache.queued[file] = info
		local tx, rx = a.control.channel.oneshot()

		a.run(rx, function(_)
			info.running = true
		end)
		-- Asyncronously fetch the Project Information
		a.run(
			function()
				local cmd = {
					"dotnet",
					"msbuild",
					"-GetProperty:TargetPath",
					"-GetProperty:OutputType",
					file,
				}

				local handle = concurrentProcsSemaphore:acquire()
				tx(true)
				local _out = a.wrap(vim.system, 3)(cmd, { text = true })
				handle:forget()

				---@type dap-cs.projectInfo
				local project_info = vim.json.decode(_out.stdout).Properties
				project_info.IsExe = project_info.OutputType:match("[Ee]xe") and true or false
				return project_info
			end,
			-- Update the Cache
			function(Info)
				info.info = Info
			end
		)
	end
end

---@async
M.project_selection = function(project_path, allow_multiple)
	local files = {}
	if
		vim.iter(vim.fs.dir(project_path)):any(function(name, type)
			return type == "file" and vim.fn.fnamemodify(name, ":e") == "sln"
		end) and vim.fn.executable("dotnet") == 1
	then
		local solution_members =
			vim.trim(vim.system({ "dotnet", "sln", "list" }, { text = true, cwd = project_path }):wait().stdout)

		for i, file in ipairs(vim.split(solution_members, "\n")) do
			if i < 3 then
				goto continue
			end
			cache_project_info(file)
			::continue::
		end

		files = vim.iter(M.projectInfoCache:iter())
			:filter(function(_, info)
				return info and info.IsExe or false
			end)
			:fold({}, function(acc, k, v)
				acc[k] = v
				return acc
			end)
		files = vim.tbl_keys(files)
	else
		files = vim.fs.find(function(name, _)
			return name:match("('.*%.csproj$')")
		end, {
			type = "file",
		})
	end

	local project_file = file_selection(files, {
		empty_message = "No csproj files found in " .. project_path,
		multiple_title_message = "Select project:",
		allow_multiple = allow_multiple,
	})
	return project_file
end

---@async
---@param project_path string
---@return string?
local select_dll = function(project_path)
	local project_file = M.project_selection(project_path)
	if project_file == nil then
		return
	end
	cache_project_info(project_file)
	local cache = M.projectInfoCache.queued[project_file]
	local info
	if cache then
		cache:await()
		info = assert(cache.info)
	else
		info = assert(M.projectInfoCache.resolved[project_file])
	end

	local dll_path = info.TargetPath
	return dll_path
end

--- Attempts to pick a process smartly.
---
--- Does the following:
--- 1. Gets all project files
--- 2. Build filter
--- 2a. If a single project is found then will filter for processes ending with project name.
--- 2b. If multiple projects found then will filter for processes ending with any of the project file names.
--- 2c. If no project files found then will filter for processes starting with "dotnet"
--- 3. If a single process matches then auto selects it. If multiple found then displays it user for selection.
local smart_pick_process = function(dap_utils, project_path)
	local project_file = M.project_selection(project_path, true)
	if project_file == nil then
		return
	end

	local filter = function(proc)
		if type(project_file) == "table" then
			for _, file in pairs(project_file) do
				local project_name = vim.fn.fnamemodify(file, ":t:r")
				if vim.endswith(proc.name, project_name) then
					return true
				end
			end
			return false
		elseif type(project_file) == "string" then
			local project_name = vim.fn.fnamemodify(project_file, ":t:r")
			return vim.startswith(proc.name, project_name or "dotnet")
		end
	end

	local processes = dap_utils.get_processes()
	processes = vim.tbl_filter(filter, processes)

	if #processes == 0 then
		print("No dotnet processes could be found automatically. Try 'Attach' instead")
		return
	end

	if #processes > 1 then
		return dap_utils.pick_process({
			filter = filter,
		})
	end

	return processes[1].pid
end

---@param fn async fun(): any
---@return fun(): thread
local function dap_async(fn)
	return function()
		return coroutine.create(function(dap_co)
			coroutine.resume(dap_co, fn())
		end)
	end
end

local setup_configuration = function(dap, dap_utils, config)
	dap.configurations.cs = {
		{
			type = "coreclr",
			name = "Launch",
			request = "launch",
			program = dap_async(function()
				local current_working_dir = vim.fn.getcwd()

				return select_dll(current_working_dir) or dap.ABORT
			end),
		},
		{
			type = "coreclr",
			name = "Attach",
			request = "attach",
			processId = dap_utils.pick_process,
		},

		{
			type = "coreclr",
			name = "Attach (Smart)",
			request = "attach",
			processId = dap_async(function()
				local current_working_dir = vim.fn.getcwd()
				return smart_pick_process(dap_utils, current_working_dir) or dap.ABORT
			end),
		},
	}

	if config == nil or config.dap_configurations == nil then
		return
	end

	for _, dap_config in ipairs(config.dap_configurations) do
		if dap_config.type == "coreclr" then
			table.insert(dap.configurations.cs, dap_config)
		end
	end
end

local setup_adapter = function(dap, config)
	dap.adapters.coreclr = {
		type = "executable",
		command = config.netcoredbg.path,
		args = { "--interpreter=vscode" },
	}
end

function M.setup(opts)
	local config = vim.tbl_deep_extend("force", default_config, opts or {})
	local dap = load_module("dap")
	local dap_utils = load_module("dap.utils")
	if config.setup_adapter then
		setup_adapter(dap, config)
	end
	setup_configuration(dap, dap_utils, config)
end

return M
