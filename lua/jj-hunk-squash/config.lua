--- Configuration for jj-hunk-squash.
--- Single source of truth for default options and user overrides.
local M = {}

---@class jj_hunk_squash.Config
---@field jj_cmd string path to jj binary (default: "jj")
---@field notify boolean show vim.notify messages (default: true)

---@type jj_hunk_squash.Config
M.options = {
	jj_cmd = "jj",
	notify = true,
}

--- Merge user options into defaults.
---@param opts jj_hunk_squash.Config?
function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

return M
