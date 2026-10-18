--- Fake editor orchestration for jj-hunk-squash.
--- Manages the temp directory, content file, and env vars
--- for the shell script that jj invokes as its --tool.
local M = {}

local _find_script

---@class jj_hunk_squash.ToolHandle
---@field tmpdir string path to temp directory
---@field script_path string path to the fake-editor.sh script
---@field env table<string, string> environment variables for the script

--- Prepare the temp directory, content file, and environment for the fake editor.
---@param rel_path string repo-relative file path to overwrite in right/
---@param content string synthesized file content
---@return jj_hunk_squash.ToolHandle? handle tool handle, or nil on error
---@return string? err error message
function M.prepare(rel_path, content)
	-- tempname() gives a unique path for each call, inside the Neovim temp directory.
	local tmpdir = vim.fn.tempname()
	if vim.fn.mkdir(tmpdir, "p") == 0 then
		return nil, "failed to create tmpdir: " .. tmpdir
	end

	local content_file = tmpdir .. "/content"
	local f, err = io.open(content_file, "w")
	if not f then
		return nil, "failed to write content file: " .. (err or "unknown")
	end
	f:write(content)
	f:close()

	return {
		tmpdir = tmpdir,
		script_path = _find_script(),
		env = {
			JJ_HUNKSQUASH_TARGET_RELPATH = rel_path,
			JJ_HUNKSQUASH_CONTENT_FILE = content_file,
		},
	},
		nil
end

--- Clean up the temp directory.
---@param handle jj_hunk_squash.ToolHandle
function M.cleanup(handle)
	pcall(vim.fn.delete, handle.tmpdir, "rf")
end

--- Locate the shipped fake-editor.sh script.
--- This file is at lua/jj-hunk-squash/fake_editor.lua, and the script is at
--- scripts/fake-editor.sh, three levels up from this file.
---@return string path absolute path to the script
function _find_script()
	local source = debug.getinfo(1, "S").source:sub(2)
	local plugin_root = vim.fn.fnamemodify(source, ":h:h:h")
	return plugin_root .. "/scripts/fake-editor.sh"
end

return M
