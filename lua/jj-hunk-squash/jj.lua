--- jj CLI interface for jj-hunk-squash.
--- All `jj` invocations live here. No diff logic. The only UI is the immutable-revision prompt.
local M = {}

local config = require("jj-hunk-squash.config")

local _run_jj, _jj_command, _run_squash

--- Get the repository root for a file path.
---@param path string absolute path to a file inside the repo
---@return string? root absolute path to repo root, or nil on error
---@return string? err error message
function M.repo_root(path)
	local result = _run_jj({ "root" }, vim.fn.fnamemodify(path, ":h"))
	if result.code ~= 0 then
		return nil, "jj root failed: " .. (result.stderr or "unknown error")
	end
	return vim.trim(result.stdout), nil
end

--- Get file contents at a specific revision.
--- Uses `jj file show -r <rev> <path>` (current as of jj 0.28+).
---@param rev string revision specifier (e.g. "@-", "@")
---@param rel_path string repo-relative file path
---@param cwd string repo root directory
---@return string? content file contents, or nil on error
---@return string? err error message
function M.get_file_at_rev(rev, rel_path, cwd)
	local result = _run_jj({ "file", "show", "-r", rev, rel_path }, cwd)
	if result.code ~= 0 then
		return nil, "jj file show failed: " .. (result.stderr or "unknown error")
	end
	return result.stdout, nil
end

--- Squash file content into a destination revision with the fake editor tool.
--- When jj refuses an immutable destination and opts.ignore_immutable is not set,
--- ask the user, then retry with --ignore-immutable.
---@param from_rev string source revision (typically "@")
---@param to_rev string destination revision
---@param rel_path string repo-relative file path
---@param content string synthesized file content to squash
---@param cwd string repo root directory
---@param opts? { ignore_immutable?: boolean, on_done?: fun(ok: boolean, err?: string) }
function M.squash_with_tool(from_rev, to_rev, rel_path, content, cwd, opts)
	opts = opts or {}
	local on_done = opts.on_done or function() end

	_run_squash(from_rev, to_rev, rel_path, content, cwd, opts.ignore_immutable, function(ok, err)
		if ok or opts.ignore_immutable or not err:find("immutable") then
			return on_done(ok, err)
		end
		vim.ui.select({ "Yes", "No" }, {
			prompt = "Destination is immutable. Retry with --ignore-immutable?",
		}, function(choice)
			if choice == "Yes" then
				_run_squash(from_rev, to_rev, rel_path, content, cwd, true, on_done)
			else
				on_done(false, "aborted: immutable revision")
			end
		end)
	end)
end

--- Run a jj command synchronously and return the result.
---@param args string[] arguments to pass after the jj binary
---@param cwd string working directory
---@return vim.SystemCompleted
function _run_jj(args, cwd)
	return vim.system(_jj_command(args), { text = true, cwd = cwd }):wait()
end

--- Put the configured jj binary in front of the arguments.
---@param args string[]
---@return string[]
function _jj_command(args)
	return vim.list_extend({ config.options.jj_cmd }, args)
end

--- Run `jj squash --interactive` one time, with the fake editor as the diff tool.
--- Always remove the temporary directory before the callback.
---@param from_rev string
---@param to_rev string
---@param rel_path string
---@param content string
---@param cwd string
---@param ignore_immutable boolean?
---@param callback fun(ok: boolean, err?: string)
function _run_squash(from_rev, to_rev, rel_path, content, cwd, ignore_immutable, callback)
	local fake_editor = require("jj-hunk-squash.fake_editor")

	local tool, err = fake_editor.prepare(rel_path, content)
	if not tool then
		return callback(false, err)
	end

	local args = {
		"squash",
		"--from",
		from_rev,
		"--into",
		to_rev,
		"--interactive",
		"--tool",
		tool.script_path,
		"--use-destination-message",
	}
	if ignore_immutable then
		args[#args + 1] = "--ignore-immutable"
	end
	vim.list_extend(args, { "--", rel_path })

	vim.system(_jj_command(args), { text = true, cwd = cwd, env = tool.env }, function(result)
		vim.schedule(function()
			fake_editor.cleanup(tool)
			if result.code == 0 then
				callback(true)
			else
				callback(false, result.stderr or "unknown error")
			end
		end)
	end)
end

return M
