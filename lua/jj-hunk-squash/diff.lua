--- Pure diff functions for jj-hunk-squash.
--- No I/O, no jj, no vim.ui. Functions take strings/tables and return strings/tables.
local M = {}

local _overlaps, _partial_hunk, _mod_lines, _in_ranges

---@class jj_hunk_squash.Hunk
---@field orig_start integer start line in original (1-indexed when orig_count > 0; anchor when orig_count == 0)
---@field orig_count integer number of lines affected in original (0 = pure insertion)
---@field mod_start integer start line in modified (1-indexed when mod_count > 0; anchor when mod_count == 0)
---@field mod_count integer number of lines affected in modified (0 = pure deletion)

---@class jj_hunk_squash.PartialHunk
---@field orig_start integer start line in original (1-indexed when orig_count > 0; anchor when orig_count == 0)
---@field orig_count integer number of original lines to remove (0 for pure insertions)
---@field selected_mod_lines integer[] sorted 1-indexed mod-file line numbers to insert

--- Compute line-level hunks between two sets of lines.
--- Wraps vim.diff() with result_type='indices'.
---@param original_lines string[] lines of the original file
---@param modified_lines string[] lines of the modified file
---@return jj_hunk_squash.Hunk[]
function M.compute_hunks(original_lines, modified_lines)
	local orig_text = table.concat(original_lines, "\n")
	local mod_text = table.concat(modified_lines, "\n")

	-- vim.diff returns {start_a, count_a, start_b, count_b}[] (1-indexed).
	-- When count is 0, start is an anchor (line after which the change occurs)
	-- and is NOT incremented to 1-based by vim.diff's internal logic.
	local indices = vim.diff(orig_text, mod_text, { result_type = "indices" })
	if not indices then
		return {}
	end

	local hunks = {}
	for _, entry in ipairs(indices) do
		hunks[#hunks + 1] = {
			orig_start = entry[1],
			orig_count = entry[2],
			mod_start = entry[3],
			mod_count = entry[4],
		}
	end
	return hunks
end

--- Select each hunk that overlaps one of the ranges, with all of its lines.
---@param hunks jj_hunk_squash.Hunk[]
---@param ranges jj_hunk_squash.LineRange[]
---@return jj_hunk_squash.PartialHunk[]
function M.select_whole_hunks(hunks, ranges)
	local result = {}
	for _, hunk in ipairs(hunks) do
		if _overlaps(hunk, ranges) then
			result[#result + 1] = _partial_hunk(hunk, _mod_lines(hunk))
		end
	end
	return result
end

--- Clip hunks to the ranges for line-level squashing.
--- Pure additions: only the added lines inside a range are kept.
--- Pure deletions: the whole hunk is kept when it overlaps a range.
--- Replacements: all original lines are removed, and only the new lines inside a range are inserted.
---@param hunks jj_hunk_squash.Hunk[]
---@param ranges jj_hunk_squash.LineRange[]
---@return jj_hunk_squash.PartialHunk[]
function M.clip_hunks_to_ranges(hunks, ranges)
	local result = {}
	for _, hunk in ipairs(hunks) do
		if hunk.mod_count == 0 then
			if _overlaps(hunk, ranges) then
				result[#result + 1] = _partial_hunk(hunk, {})
			end
		else
			local selected = vim.tbl_filter(function(n)
				return _in_ranges(n, ranges)
			end, _mod_lines(hunk))
			if #selected > 0 then
				result[#result + 1] = _partial_hunk(hunk, selected)
			end
		end
	end
	return result
end

--- Apply partial hunks to the original lines to produce the synthesized content.
--- Processes hunks in reverse orig_start order to keep earlier indices stable.
---@param original_lines string[]
---@param modified_lines string[]
---@param partial_hunks jj_hunk_squash.PartialHunk[] sorted by orig_start ascending
---@return string
function M.apply_partial_hunks(original_lines, modified_lines, partial_hunks)
	local result = {}
	for _, line in ipairs(original_lines) do
		result[#result + 1] = line
	end

	for i = #partial_hunks, 1, -1 do
		local ph = partial_hunks[i]

		-- Determine insertion point before any removal alters indices.
		-- For pure insertions (orig_count == 0), orig_start is an anchor; insert after it.
		local insert_pos = ph.orig_count > 0 and ph.orig_start or ph.orig_start + 1

		-- Remove original lines (for deletions and replacements).
		if ph.orig_count > 0 then
			for j = ph.orig_start + ph.orig_count - 1, ph.orig_start, -1 do
				table.remove(result, j)
			end
		end

		-- Insert selected modified lines in order (iterate in reverse so table.insert preserves order).
		for j = #ph.selected_mod_lines, 1, -1 do
			table.insert(result, insert_pos, modified_lines[ph.selected_mod_lines[j]])
		end
	end

	return table.concat(result, "\n")
end

--- Check whether the modified side of a hunk overlaps one of the ranges.
--- A pure deletion has no modified lines. It overlaps a range when one of the
--- two lines next to the deletion is in the range. The anchor is 0 for a
--- deletion at the top of the file, so line 1 then selects it.
---@param hunk jj_hunk_squash.Hunk
---@param ranges jj_hunk_squash.LineRange[]
---@return boolean
function _overlaps(hunk, ranges)
	local first, last
	if hunk.mod_count == 0 then
		first, last = hunk.mod_start, hunk.mod_start + 1
	else
		first, last = hunk.mod_start, hunk.mod_start + hunk.mod_count - 1
	end
	for _, range in ipairs(ranges) do
		if first <= range[2] and last >= range[1] then
			return true
		end
	end
	return false
end

--- Make a partial hunk that removes all original lines of the hunk and inserts the given modified lines.
---@param hunk jj_hunk_squash.Hunk
---@param selected_mod_lines integer[]
---@return jj_hunk_squash.PartialHunk
function _partial_hunk(hunk, selected_mod_lines)
	return {
		orig_start = hunk.orig_start,
		orig_count = hunk.orig_count,
		selected_mod_lines = selected_mod_lines,
	}
end

--- Return the modified-side line numbers of a hunk.
---@param hunk jj_hunk_squash.Hunk
---@return integer[]
function _mod_lines(hunk)
	local lines = {}
	for n = hunk.mod_start, hunk.mod_start + hunk.mod_count - 1 do
		lines[#lines + 1] = n
	end
	return lines
end

--- Check whether a line number is inside one of the ranges.
---@param n integer
---@param ranges jj_hunk_squash.LineRange[]
---@return boolean
function _in_ranges(n, ranges)
	for _, range in ipairs(ranges) do
		if n >= range[1] and n <= range[2] then
			return true
		end
	end
	return false
end

return M
