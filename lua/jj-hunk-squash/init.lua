--- jj-hunk-squash.nvim — git-style hunk staging for Jujutsu, in Neovim.
--- Public API: setup(), squash_selection(), squash_hunk(), squash_file().
local M = {}

local config = require("jj-hunk-squash.config")

local _command_range, _finish, _buffer_text, _notify

---@class jj_hunk_squash.Opts
---@field to_rev? string any jj revset resolving to a single rev (default: "@-")
---@field ignore_immutable? boolean squash into an immutable revision without a confirmation prompt
---@field on_done? fun(ok: boolean, err?: string) callback after squash completes

---@alias jj_hunk_squash.Mode "selection"|"hunk"|"file"

--- Merge user config and set up the plugin.
---@param opts jj_hunk_squash.Config?
function M.setup(opts)
	config.setup(opts)

	vim.api.nvim_create_user_command("JJSquash", function(cmd)
		M._run("selection", { to_rev = cmd.fargs[1] }, _command_range(cmd))
	end, { nargs = "?", range = true, desc = "Squash the selected lines into a destination revision" })

	vim.api.nvim_create_user_command("JJSquashHunk", function(cmd)
		M._run("hunk", { to_rev = cmd.fargs[1] }, _command_range(cmd))
	end, { nargs = "?", range = true, desc = "Squash the hunks under the cursor or selection into a destination revision" })

	vim.api.nvim_create_user_command("JJSquashFile", function(cmd)
		M._run("file", { to_rev = cmd.fargs[1] })
	end, { nargs = "?", desc = "Squash all changes of the file into a destination revision" })
end

--- Squash the selected lines (visual mode) or the current line (normal mode).
--- Only the selected lines are squashed. See the README for the rules on replacements and deletions.
---@param opts jj_hunk_squash.Opts?
function M.squash_selection(opts)
	M._run("selection", opts or {})
end

--- Squash each complete hunk that the selection (visual mode) or the current line (normal mode) touches.
---@param opts jj_hunk_squash.Opts?
function M.squash_hunk(opts)
	M._run("hunk", opts or {})
end

--- Squash ALL changes to the current file from @ into the destination.
--- Ignores selection entirely.
---@param opts jj_hunk_squash.Opts?
function M.squash_file(opts)
	M._run("file", opts or {})
end

--- Internal runner. All public entry points and user commands delegate here.
---@param mode jj_hunk_squash.Mode
---@param opts jj_hunk_squash.Opts
---@param range? jj_hunk_squash.LineRange explicit range from a user command
function M._run(mode, opts, range)
	local jj = require("jj-hunk-squash.jj")
	local diff = require("jj-hunk-squash.diff")
	local selection = require("jj-hunk-squash.selection")

	local bufnr = vim.api.nvim_get_current_buf()
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local to_rev = opts.to_rev or "@-"

	-- Read the selection first, while visual mode is still active.
	local ranges = mode ~= "file" and selection.get_current_ranges(range) or nil

	if file_path == "" then
		return _finish(opts, false, "buffer has no file name")
	end

	-- Resolve repo root
	local root, root_err = jj.repo_root(file_path)
	if not root then
		return _finish(opts, false, root_err or "not in a jj repo")
	end

	-- Compute repo-relative path
	local rel_path = vim.fn.fnamemodify(file_path, ":.")
	-- Make it relative to root
	if file_path:sub(1, #root) == root then
		rel_path = file_path:sub(#root + 2) -- +2 to skip the trailing /
	end

	-- Phase 1: compute the synthesized content
	local content
	if mode == "file" then
		content = _buffer_text(bufnr)
	else
		local original, orig_err = jj.get_file_at_rev("@-", rel_path, root)
		if not original then
			return _finish(opts, false, orig_err or "failed to get file at @-")
		end

		local orig_lines = vim.split(original, "\n", { plain = true })
		local mod_lines = vim.split(_buffer_text(bufnr), "\n", { plain = true })

		local hunks = diff.compute_hunks(orig_lines, mod_lines)
		if #hunks == 0 then
			return _finish(opts, true, "no changes to squash")
		end

		local partial_hunks
		if mode == "hunk" then
			partial_hunks = diff.select_whole_hunks(hunks, ranges)
		else
			partial_hunks = diff.clip_hunks_to_ranges(hunks, ranges)
		end
		if #partial_hunks == 0 then
			return _finish(opts, true, "no changes overlap the selection")
		end

		content = diff.apply_partial_hunks(orig_lines, mod_lines, partial_hunks)
	end

	-- Phase 2: squash. jj validates the destination.
	jj.squash_with_tool("@", to_rev, rel_path, content, root, {
		ignore_immutable = opts.ignore_immutable,
		on_done = function(ok, err)
			if not ok then
				return _finish(opts, false, err or "squash failed")
			end
			-- Refresh the buffer to reflect changes
			vim.api.nvim_buf_call(bufnr, function()
				vim.cmd("checktime")
			end)
			-- Fire autocmd for integrations
			vim.api.nvim_exec_autocmds("User", {
				pattern = "JJHunkSquashDone",
				data = { file = rel_path, to_rev = to_rev, mode = mode },
			})
			_finish(opts, true, "squashed " .. mode .. " into " .. to_rev)
		end,
	})
end

--- Get the explicit line range of a user command, or nil when the command has no range.
---@param cmd table argument of a user command callback
---@return jj_hunk_squash.LineRange?
function _command_range(cmd)
	if cmd.range > 0 then
		return { cmd.line1, cmd.line2 }
	end
	return nil
end

--- Show the message and call opts.on_done.
--- The message is an error when ok is false, and information when ok is true.
---@param opts jj_hunk_squash.Opts
---@param ok boolean
---@param msg string
function _finish(opts, ok, msg)
	_notify(msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
	if opts.on_done then
		opts.on_done(ok, not ok and msg or nil)
	end
end

--- Get the buffer content as one string, with a final newline when the buffer has one.
---@param bufnr integer
---@return string
function _buffer_text(bufnr)
	local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	if vim.bo[bufnr].eol then
		text = text .. "\n"
	end
	return text
end

--- Notify helper that respects config.notify.
---@param msg string
---@param level integer vim.log.levels.*
function _notify(msg, level)
	if config.options.notify then
		vim.notify("jj-hunk-squash: " .. msg, level)
	end
end

return M
