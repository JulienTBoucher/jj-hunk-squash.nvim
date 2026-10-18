--- Selection translation for jj-hunk-squash.
--- Converts visual/normal mode selections to 1-indexed line ranges.
local M = {}

---@class jj_hunk_squash.LineRange
---@field [1] integer start line (1-indexed, inclusive)
---@field [2] integer end line (1-indexed, inclusive)

--- Get the line ranges to squash, in this order of precedence:
--- 1. The explicit range, for example from a user command with a range.
--- 2. The visual selection, when visual mode is active. This exits visual mode.
--- 3. The cursor line.
--- Do not read the '< and '> marks: they keep the last visual selection after
--- visual mode ends, so normal mode would use an old selection.
---@param range? jj_hunk_squash.LineRange explicit range
---@return jj_hunk_squash.LineRange[]
function M.get_current_ranges(range)
	if range then
		return { range }
	end

	local mode = vim.fn.mode()
	if mode == "v" or mode == "V" or mode == "\22" then
		local first = vim.fn.line("v")
		local last = vim.fn.line(".")
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
		return { { math.min(first, last), math.max(first, last) } }
	end

	local line = vim.api.nvim_win_get_cursor(0)[1]
	return { { line, line } }
end

return M
