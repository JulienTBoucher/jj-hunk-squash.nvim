# AGENTS.md

Neovim plugin: git-style hunk staging for Jujutsu (`jj`). Pure Lua + one POSIX shell script. No build, no tests, no lint config, no CI.

## Repo VCS

This repo is colocated `jj` + `git` (note `.jj/` and `.git/`). Prefer `jj` commands when inspecting history. Do not run `jj`/`git` mutations unless asked.

## Layout

- `lua/jj-hunk-squash/init.lua` — public API, user commands, and the `_run(mode, opts, range)` orchestrator. All entry points (`squash_selection`, `squash_hunk`, `squash_file`, and the `:JJSquash*` commands) delegate here.
- `lua/jj-hunk-squash/jj.lua` — every `jj` CLI invocation, and the immutable-revision prompt. No diff logic.
- `lua/jj-hunk-squash/diff.lua` — pure functions over line tables. No I/O, no `vim.ui`, no `jj`. Wraps `vim.diff(..., result_type="indices")`.
- `lua/jj-hunk-squash/selection.lua` — converts a command range, a visual selection, or the cursor line to line ranges.
- `lua/jj-hunk-squash/fake_editor.lua` — prepares the tmpdir, the content file, and the env vars for the shell script.
- `scripts/fake-editor.sh` — POSIX `/bin/sh`. Located by walking up from `fake_editor.lua` via `debug.getinfo`. Do not move it without updating `_find_script()`.
- `lua/jj-hunk-squash/config.lua` — single source of truth for defaults.
- `doc/jj-hunk-squash.txt` — vim help file. Keep it in sync with the README.

Layer rule: `init.lua` → (`jj.lua`, `diff.lua`, `selection.lua`, `fake_editor.lua`). `diff.lua` and `config.lua` must stay dependency-free of Neovim UI / subprocess code.

## Architecture quirks an agent will get wrong

- **Two-phase squash.** Phase 1 synthesizes the desired file content in pure Lua (diff `@-` vs buffer, select lines or hunks, apply them). Phase 2 hands that content to `jj squash --interactive --tool <script>`. Do not try to parse `jj`'s hunk format — that is intentionally avoided.
- **Fake editor.** jj calls the script with `<left> <right>`. The script copies the content file into `right/<rel_path>` and exits. jj waits for the script to exit, so no handshake is necessary. The env vars (`JJ_HUNKSQUASH_TARGET_RELPATH`, `JJ_HUNKSQUASH_CONTENT_FILE`) are the contract: if you change one side, change both.
- **Three modes.** `selection` squashes only the selected lines (`diff.clip_hunks_to_ranges`). `hunk` squashes each complete hunk that the selection touches (`diff.select_whole_hunks`). `file` squashes the full buffer. All produce `PartialHunk`s for `diff.apply_partial_hunks`, except `file`.
- **`vim.diff` indices semantics.** When `count == 0` (pure insertion or pure deletion), `start` is an anchor (the line before the change, `0` at the top of the file), not a 1-based line. Preserve that handling in `diff.lua`.
- **Selection source.** Do not read the `'<` / `'>` marks: they keep the last visual selection in normal mode. Use the command range, `line("v")` in visual mode, or the cursor line.
- **Buffer, not disk.** Phase 1 diffs `@-` against buffer content (including unsaved changes), not the on-disk file. Intentional.
- **Immutable-rev retry.** `jj.squash_with_tool` detects `immutable` in stderr and prompts to retry with `--ignore-immutable`, unless `opts.ignore_immutable` is set. Both attempts go through `_run_squash`, which builds a new tmpdir each time.
- **`jj file show` is jj 0.28+.** Older jj used `jj show` / `jj cat`. Do not downgrade.

## Integration surface

External integrations hook the `User JJHunkSquashDone` autocmd with `data = { file, to_rev, mode }`. The plugin must never directly call into diff viewers (diffview, codediff, etc.). One-way dependency only.

## Dev workflow

- No test suite, linter, or formatter is configured. If asked to add tests, ask which framework (none is established).
- Manual test loop: open Neovim in a `jj` repo, edit a file, `:JJSquash`, inspect with `jj log`. Plugin loads from this dir via your plugin manager.
- Lua style: tabs for indent (see existing files). LuaCATS annotations on public functions — keep them when editing.
- Module layout: public functions first, then private helpers. Private helpers are forward-declared as `local _name` at the top of the module.
- Requires Neovim 0.10+ (`vim.system`, `vim.diff` indices). Do not introduce 0.11-only APIs.
- No external Lua deps.
