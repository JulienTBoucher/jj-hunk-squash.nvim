# jj-hunk-squash.nvim

Git-style hunk staging for Jujutsu, in Neovim.

> **Status: experimental**

Select lines or hunks in your buffer and squash them into any revision — typically the parent `@-`. Think `git add --patch` but for [Jujutsu (jj)](https://github.com/jj-vcs/jj).

## Installation

### lazy.nvim

```lua
{
  "JulienTBoucher/jj-hunk-squash.nvim",
  cmd = { "JJSquash", "JJSquashHunk", "JJSquashFile" },
  keys = {
    { "<leader>js", function() require("jj-hunk-squash").squash_hunk({ to_rev = "@-" }) end,
      mode = { "n", "x" }, desc = "jj: squash hunk into parent (@-)" },
    { "<leader>jf", function() require("jj-hunk-squash").squash_file({ to_rev = "@-" }) end,
      desc = "jj: squash file into parent (@-)" },
    { "<leader>jS", function() require("jj-hunk-squash").squash_hunk({ to_rev = "@+" }) end,
      mode = { "n", "x" }, desc = "jj: squash hunk into child (@+)" },
    { "<leader>jF", function() require("jj-hunk-squash").squash_file({ to_rev = "@+" }) end,
      desc = "jj: squash file into child (@+)" },
  },
  opts = {},
}
```

### Generic (any plugin manager)

Clone or add as a dependency, then call `setup()`:

```lua
require("jj-hunk-squash").setup({
  -- all options are optional, these are the defaults:
  -- jj_cmd = "jj",
  -- notify = true,
})
```

For manual install, clone the repo into your Neovim runtime path (e.g. `~/.local/share/nvim/site/pack/plugins/start/jj-hunk-squash.nvim`).

## Requirements

- Neovim 0.10+
- [jj](https://github.com/jj-vcs/jj) on `$PATH` (or configured via `jj_cmd`)

## Usage

See `:help jj-hunk-squash` for the full reference.

Three entry points, one uniform signature:

| Function | What it squashes |
|---|---|
| `squash_selection(opts)` | Only the selected lines (visual mode) or the current line (normal mode) |
| `squash_hunk(opts)` | Each complete hunk that the selection or the current line touches |
| `squash_file(opts)` | All changes to the current file |

All three accept the same `opts` table:

```lua
{
  to_rev = "@-",            -- string. Any jj revset that resolves to one revision
  ignore_immutable = false, -- squash into an immutable revision without a prompt
  on_done = nil,            -- function(ok, err)? called after squash
}
```

**From visual mode:** select lines, then invoke (via keymap or `:'<,'>JJSquash @-`).

**From normal mode:** the cursor line is used as a single-line selection.

If the destination is immutable, the plugin asks before it retries with `--ignore-immutable`. Set `ignore_immutable = true` to skip the prompt.

### User commands

- `:[range]JJSquash [rev]` — squash the selected lines (same as `squash_selection`)
- `:[range]JJSquashHunk [rev]` — squash the hunks that the range touches (same as `squash_hunk`)
- `:JJSquashFile [rev]` — squash the entire file

The revision is optional. The default is `@-`. Without a range, the commands use the cursor line.

## Recipes

```lua
-- Squash hunk under cursor / selection into parent (most common)
vim.keymap.set({'n', 'x'}, '<leader>js', function()
  require('jj-hunk-squash').squash_hunk({ to_rev = '@-' })
end, { desc = 'jj: squash hunk into parent (@-)' })

-- Squash whole file into parent
vim.keymap.set('n', '<leader>jf', function()
  require('jj-hunk-squash').squash_file({ to_rev = '@-' })
end, { desc = 'jj: squash file into parent (@-)' })

-- Squash into a bookmark named "main"
vim.keymap.set({'n', 'x'}, '<leader>jm', function()
  require('jj-hunk-squash').squash_hunk({ to_rev = 'main' })
end, { desc = 'jj: squash hunk into main' })
```

## Configuration

```lua
require("jj-hunk-squash").setup({
  jj_cmd = "jj",                     -- path to jj binary
  notify = true,                     -- show vim.notify messages
})
```

| Option | Default | Description |
|---|---|---|
| `jj_cmd` | `"jj"` | Path to the jj binary. Override if jj is not on `$PATH`. |
| `notify` | `true` | Show progress/error messages via `vim.notify`. |

## Integration with diff viewers

After every successful squash, the plugin:

1. Runs `:checktime` on the affected buffer (works with `autoread`)
2. Fires `User JJHunkSquashDone` with `data = { file, to_rev, mode }`

Wire your viewer's refresh mechanism to this autocmd.

### diffview.nvim

diffview.nvim exposes `:DiffviewRefresh` which safely no-ops when no diffview is active:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "JJHunkSquashDone",
  callback = function(ev)
    -- ev.data = { file = "...", to_rev = "...", mode = "hunk"|"selection"|"file" }
    local ok, actions = pcall(require, "diffview.actions")
    if ok then
      actions.refresh_files()
    else
      pcall(vim.cmd, "DiffviewRefresh")
    end
  end,
})
```

**Caveat (jj users):** diffview is git-centric. It works with colocated repos (`jj git init --colocate`) since it reads the git side. Pure-jj repos without `.git/` are not supported by diffview.

### codediff.nvim

codediff.nvim does not currently expose a refresh command or autocmd. After a squash, the diff view shows stale content until manually re-opened.

Workaround — re-trigger `:CodeDiff` after squash:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "JJHunkSquashDone",
  callback = function(ev)
    local pos = vim.api.nvim_win_get_cursor(0)
    vim.cmd("CodeDiff file @-")   -- re-run with whatever revset you were viewing
    pcall(vim.api.nvim_win_set_cursor, 0, pos)
  end,
})
```

Caveats:
- Works well for single-file diff views; explorer view cursor is more fragile.
- Cursor preservation is best-effort (clamps if file shrank above cursor).
- A clean long-term fix would be an upstream `:CodeDiffRefresh` command.

### What the plugin does *not* do

The plugin does not detect or call into any specific diff viewer. The dependency direction is one-way: the `User JJHunkSquashDone` autocmd is the only integration surface.

## How it works

The design is inspired by the `squashSelectedRanges` command of [keanemind/jjk](https://github.com/keanemind/jjk), a Jujutsu extension for VS Code.

**Phase 1 — Compute desired content (pure Lua):**
The file's content at `@-` (the parent) is diffed against the current buffer using `vim.diff()`. In hunk mode, each hunk that touches the selection is kept complete. In selection mode, each hunk is clipped to the user's visual selection at the individual line level: for pure additions only the selected `+` lines are staged; for replacements all original lines in the hunk are removed but only the selected new lines are inserted; for pure deletions the whole hunk is staged if a line next to the deletion is selected. The result is a synthesized file — "what the file would look like if only these lines were staged."

**Phase 2 — Hand content to jj via a fake merge tool:**
The plugin invokes `jj squash --from @ --into <dest> --interactive --tool <script> --use-destination-message`. jj creates temp `left/` and `right/` directories and calls the script. The script overwrites the target file in `right/` with the synthesized content from Phase 1 and exits. jj sees the delta between `left/` and the modified `right/` — exactly the selected hunks — and squashes it into the destination.

This avoids parsing jj's hunk format and avoids racing the working-copy snapshotter.

## Limitations

- **Renames not handled specially.** If a file was renamed in `@`, the plugin doesn't track the rename — use the current file path.
- **Unsaved buffer changes are included.** The plugin diffs `@-` against the buffer content, not the on-disk snapshot. Save first if you want to squash only committed changes.
- **Replacement hunks stage all deletions.** When you partially select a replacement hunk (new lines replacing old lines), all original lines in that hunk are removed and only your selected new lines are inserted. Pure additions support truly independent per-line selection.

## Acknowledgments

- [keanemind/jjk](https://github.com/keanemind/jjk) — VS Code extension whose `squashSelectedRanges` command inspired the design of this plugin (synthesized content plus a fake diff editor).
- [VS Code git extension](https://github.com/microsoft/vscode/tree/main/extensions/git) — its "stage selected ranges" feature (`staging.ts`) inspired the line-level selection.

## License

[MIT](LICENSE)
