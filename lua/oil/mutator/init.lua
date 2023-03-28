local cache = require("oil.cache")
local columns = require("oil.columns")
local config = require("oil.config")
local disclaimer = require("oil.mutator.disclaimer")
local oil = require("oil")
local parser = require("oil.mutator.parser")
local pathutil = require("oil.pathutil")
local preview = require("oil.mutator.preview")
local Progress = require("oil.mutator.progress")
local Trie = require("oil.mutator.trie")
local util = require("oil.util")
local view = require("oil.view")
local FIELD = require("oil.constants").FIELD
local M = {}

---@alias oil.Action oil.CreateAction|oil.DeleteAction|oil.MoveAction|oil.CopyAction|oil.ChangeAction

---@class oil.CreateAction
---@field type "create"
---@field url string
---@field entry_type oil.EntryType
---@field link nil|string

---@class oil.DeleteAction
---@field type "delete"
---@field url string
---@field entry_type oil.EntryType

---@class oil.MoveAction
---@field type "move"
---@field entry_type oil.EntryType
---@field src_url string
---@field dest_url string

---@class oil.CopyAction
---@field type "copy"
---@field entry_type oil.EntryType
---@field src_url string
---@field dest_url string

---@class oil.ChangeAction
---@field type "change"
---@field entry_type oil.EntryType
---@field url string
---@field column string
---@field value any

---@param all_diffs table<integer, oil.Diff[]>
---@return oil.Action[]
M.create_actions_from_diffs = function(all_diffs)
  ---@type oil.Action[]
  local actions = {}

  local diff_by_id = setmetatable({}, {
    __index = function(t, key)
      local list = {}
      rawset(t, key, list)
      return list
    end,
  })
  for bufnr, diffs in pairs(all_diffs) do
    local adapter = util.get_adapter(bufnr)
    if not adapter then
      error("Missing adapter")
    end
    local parent_url = vim.api.nvim_buf_get_name(bufnr)
    for _, diff in ipairs(diffs) do
      if diff.type == "new" then
        if diff.id then
          local by_id = diff_by_id[diff.id]
          -- FIXME this is kind of a hack. We shouldn't be setting undocumented fields on the diff
          diff.dest = parent_url .. diff.name
          table.insert(by_id, diff)
        else
          -- Parse nested files like foo/bar/baz
          local pieces = vim.split(diff.name, "/")
          local url = parent_url:gsub("/$", "")
          for i, v in ipairs(pieces) do
            local is_last = i == #pieces
            local entry_type = is_last and diff.entry_type or "directory"
            local alternation = v:match("{([^}]+)}")
            if is_last and alternation then
              -- Parse alternations like foo.{js,test.js}
              for _, alt in ipairs(vim.split(alternation, ",")) do
                local alt_url = url .. "/" .. v:gsub("{[^}]+}", alt)
                table.insert(actions, {
                  type = "create",
                  url = alt_url,
                  entry_type = entry_type,
                  link = diff.link,
                })
              end
            else
              url = url .. "/" .. v
              table.insert(actions, {
                type = "create",
                url = url,
                entry_type = entry_type,
                link = diff.link,
              })
            end
          end
        end
      elseif diff.type == "change" then
        table.insert(actions, {
          type = "change",
          url = parent_url .. diff.name,
          entry_type = diff.entry_type,
          column = diff.column,
          value = diff.value,
        })
      else
        local by_id = diff_by_id[diff.id]
        by_id.has_delete = true
        -- Don't insert the delete. We already know that there is a delete because of the presense
        -- in the diff_by_id map. The list will only include the 'new' diffs.
      end
    end
  end

  for id, diffs in pairs(diff_by_id) do
    local entry = cache.get_entry_by_id(id)
    if not entry then
      error(string.format("Could not find entry %d", id))
    end
    if diffs.has_delete then
      local has_create = #diffs > 0
      if has_create then
        -- MOVE (+ optional copies) when has both creates and delete
        for i, diff in ipairs(diffs) do
          table.insert(actions, {
            type = i == #diffs and "move" or "copy",
            entry_type = entry[FIELD.type],
            dest_url = diff.dest,
            src_url = cache.get_parent_url(id) .. entry[FIELD.name],
          })
        end
      else
        -- DELETE when no create
        table.insert(actions, {
          type = "delete",
          entry_type = entry[FIELD.type],
          url = cache.get_parent_url(id) .. entry[FIELD.name],
        })
      end
    else
      -- COPY when create but no delete
      for _, diff in ipairs(diffs) do
        table.insert(actions, {
          type = "copy",
          entry_type = entry[FIELD.type],
          src_url = cache.get_parent_url(id) .. entry[FIELD.name],
          dest_url = diff.dest,
        })
      end
    end
  end

  return M.enforce_action_order(actions)
end

---@param actions oil.Action[]
---@return oil.Action[]
M.enforce_action_order = function(actions)
  local src_trie = Trie.new()
  local dest_trie = Trie.new()
  for _, action in ipairs(actions) do
    if action.type == "delete" or action.type == "change" then
      src_trie:insert_action(action.url, action)
    elseif action.type == "create" then
      dest_trie:insert_action(action.url, action)
    else
      dest_trie:insert_action(action.dest_url, action)
      src_trie:insert_action(action.src_url, action)
    end
  end

  -- 1. create a graph, each node points to all of its dependencies
  -- 2. for each action, if not added, find it in the graph
  -- 3. traverse through the graph until you reach a node that has no dependencies (leaf)
  -- 4. append that action to the return value, and remove it from the graph
  --   a. TODO optimization: check immediate parents to see if they have no dependencies now
  -- 5. repeat

  -- Gets the dependencies of a particular action. Effectively dynamically calculates the dependency
  -- "edges" of the graph.
  local function get_deps(action)
    local ret = {}
    if action.type == "delete" then
      return ret
    elseif action.type == "create" then
      -- Finish operating on parents first
      -- e.g. NEW /a BEFORE NEW /a/b
      dest_trie:accum_first_parents_of(action.url, ret)
      -- Process remove path before creating new path
      -- e.g. DELETE /a BEFORE NEW /a
      src_trie:accum_actions_at(action.url, ret, function(a)
        return a.type == "move" or a.type == "delete"
      end)
    elseif action.type == "change" then
      -- Finish operating on parents first
      -- e.g. NEW /a BEFORE CHANGE /a/b
      dest_trie:accum_first_parents_of(action.url, ret)
      -- Finish operations on this path first
      -- e.g. NEW /a BEFORE CHANGE /a
      dest_trie:accum_actions_at(action.url, ret)
      -- Finish copy from operations first
      -- e.g. COPY /a -> /b BEFORE CHANGE /a
      src_trie:accum_actions_at(action.url, ret, function(entry)
        return entry.type == "copy"
      end)
    elseif action.type == "move" then
      -- Finish operating on parents first
      -- e.g. NEW /a BEFORE MOVE /z -> /a/b
      dest_trie:accum_first_parents_of(action.dest_url, ret)
      -- Process children before moving
      -- e.g. NEW /a/b BEFORE MOVE /a -> /b
      dest_trie:accum_children_of(action.src_url, ret)
      -- Copy children before moving parent dir
      -- e.g. COPY /a/b -> /b BEFORE MOVE /a -> /d
      src_trie:accum_children_of(action.src_url, ret, function(a)
        return a.type == "copy"
      end)
      -- Process remove path before moving to new path
      -- e.g. MOVE /a -> /b BEFORE MOVE /c -> /a
      src_trie:accum_actions_at(action.dest_url, ret, function(a)
        return a.type == "move" or a.type == "delete"
      end)
    elseif action.type == "copy" then
      -- Finish operating on parents first
      -- e.g. NEW /a BEFORE COPY /z -> /a/b
      dest_trie:accum_first_parents_of(action.dest_url, ret)
      -- Process children before copying
      -- e.g. NEW /a/b BEFORE COPY /a -> /b
      dest_trie:accum_children_of(action.src_url, ret)
      -- Process remove path before copying to new path
      -- e.g. MOVE /a -> /b BEFORE COPY /c -> /a
      src_trie:accum_actions_at(action.dest_url, ret, function(a)
        return a.type == "move" or a.type == "delete"
      end)
    end
    return ret
  end

  ---@return nil|oil.Action The leaf action
  ---@return nil|oil.Action When no leaves found, this is the last action in the loop
  local function find_leaf(action, seen)
    if not seen then
      seen = {}
    elseif seen[action] then
      return nil, action
    end
    seen[action] = true
    local deps = get_deps(action)
    if vim.tbl_isempty(deps) then
      return action
    end
    local action_in_loop
    for _, dep in ipairs(deps) do
      local leaf, loop_action = find_leaf(dep, seen)
      if leaf then
        return leaf
      elseif not action_in_loop and loop_action then
        action_in_loop = loop_action
      end
    end
    return nil, action_in_loop
  end

  local ret = {}
  local after = {}
  while not vim.tbl_isempty(actions) do
    local action = actions[1]
    local selected, loop_action = find_leaf(action)
    local to_remove
    if selected then
      to_remove = selected
    else
      if loop_action and loop_action.type == "move" then
        -- If this is moving a parent into itself, that's an error
        if vim.startswith(loop_action.dest_url, loop_action.src_url) then
          error("Detected cycle in desired paths")
        end

        -- We've detected a move cycle (e.g. MOVE /a -> /b + MOVE /b -> /a)
        -- Split one of the moves and retry
        local intermediate_url =
          string.format("%s__oil_tmp_%05d", loop_action.src_url, math.random(999999))
        local move_1 = {
          type = "move",
          entry_type = loop_action.entry_type,
          src_url = loop_action.src_url,
          dest_url = intermediate_url,
        }
        local move_2 = {
          type = "move",
          entry_type = loop_action.entry_type,
          src_url = intermediate_url,
          dest_url = loop_action.dest_url,
        }
        to_remove = loop_action
        table.insert(actions, move_1)
        table.insert(after, move_2)
        dest_trie:insert_action(move_1.dest_url, move_1)
        src_trie:insert_action(move_1.src_url, move_1)
      else
        error("Detected cycle in desired paths")
      end
    end

    if selected then
      if selected.type == "move" or selected.type == "copy" then
        if vim.startswith(selected.dest_url, selected.src_url .. "/") then
          error(
            string.format(
              "Cannot move or copy parent into itself: %s -> %s",
              selected.src_url,
              selected.dest_url
            )
          )
        end
      end
      table.insert(ret, selected)
    end

    if to_remove then
      if to_remove.type == "delete" or to_remove.type == "change" then
        src_trie:remove_action(to_remove.url, to_remove)
      elseif to_remove.type == "create" then
        dest_trie:remove_action(to_remove.url, to_remove)
      else
        dest_trie:remove_action(to_remove.dest_url, to_remove)
        src_trie:remove_action(to_remove.src_url, to_remove)
      end
      for i, a in ipairs(actions) do
        if a == to_remove then
          table.remove(actions, i)
          break
        end
      end
    end
  end

  vim.list_extend(ret, after)
  return ret
end

---@param actions oil.Action[]
---@param cb fun(err: nil|string)
M.process_actions = function(actions, cb)
  -- convert delete actions to move-to-trash
  local trash_url = config.get_trash_url()
  if trash_url then
    for i, v in ipairs(actions) do
      if v.type == "delete" then
        local scheme, path = util.parse_url(v.url)
        if config.adapters[scheme] == "files" then
          actions[i] = {
            type = "move",
            src_url = v.url,
            entry_type = v.entry_type,
            dest_url = trash_url .. "/" .. pathutil.basename(path) .. string.format(
              "_%06d",
              math.random(999999)
            ),
          }
        end
      end
    end
  end

  -- Convert cross-adapter moves to a copy + delete
  for _, action in ipairs(actions) do
    if action.type == "move" then
      local src_scheme = util.parse_url(action.src_url)
      local dest_scheme = util.parse_url(action.dest_url)
      if src_scheme ~= dest_scheme then
        action.type = "copy"
        table.insert(actions, {
          type = "delete",
          url = action.src_url,
          entry_type = action.entry_type,
        })
      end
    end
  end

  local finished = false
  local progress = Progress.new()
  -- Defer showing the progress to avoid flicker for fast operations
  vim.defer_fn(function()
    if not finished then
      progress:show()
    end
  end, 100)

  local function finish(...)
    finished = true
    progress:close()
    cb(...)
  end

  local idx = 1
  local next_action
  next_action = function()
    if idx > #actions then
      finish()
      return
    end
    local action = actions[idx]
    progress:set_action(action, idx, #actions)
    idx = idx + 1
    local ok, adapter = pcall(util.get_adapter_for_action, action)
    if not ok then
      return finish(adapter)
    end
    local callback = vim.schedule_wrap(function(err)
      if err then
        finish(err)
      else
        cache.perform_action(action)
        next_action()
      end
    end)
    if action.type == "change" then
      columns.perform_change_action(adapter, action, callback)
    else
      adapter.perform_action(action, callback)
    end
  end
  next_action()
end

local mutation_in_progress = false

---@param confirm nil|boolean
M.try_write_changes = function(confirm)
  if mutation_in_progress then
    error("Cannot perform mutation when already in progress")
    return
  end
  local current_buf = vim.api.nvim_get_current_buf()
  local was_modified = vim.bo.modified
  local buffers = view.get_all_buffers()
  local all_diffs = {}
  local all_errors = {}

  mutation_in_progress = true
  -- Lock the buffer to prevent race conditions from the user modifying them during parsing
  view.lock_buffers()
  for _, bufnr in ipairs(buffers) do
    if vim.bo[bufnr].modified then
      local diffs, errors = parser.parse(bufnr)
      all_diffs[bufnr] = diffs
      if not vim.tbl_isempty(errors) then
        all_errors[bufnr] = errors
      end
    end
  end
  local function unlock()
    view.unlock_buffers()
    -- The ":write" will set nomodified even if we cancel here, so we need to restore it
    if was_modified then
      vim.bo[current_buf].modified = true
    end
    mutation_in_progress = false
  end

  local ns = vim.api.nvim_create_namespace("Oil")
  vim.diagnostic.reset(ns)
  if not vim.tbl_isempty(all_errors) then
    vim.notify("Error parsing oil buffers", vim.log.levels.ERROR)
    for bufnr, errors in pairs(all_errors) do
      vim.diagnostic.set(ns, bufnr, errors)
    end

    -- Jump to an error
    local curbuf = vim.api.nvim_get_current_buf()
    if all_errors[curbuf] then
      pcall(
        vim.api.nvim_win_set_cursor,
        0,
        { all_errors[curbuf][1].lnum + 1, all_errors[curbuf][1].col }
      )
    else
      local bufnr, errs = next(pairs(all_errors))
      vim.api.nvim_win_set_buf(0, bufnr)
      pcall(vim.api.nvim_win_set_cursor, 0, { errs[1].lnum + 1, errs[1].col })
    end
    return unlock()
  end

  local actions = M.create_actions_from_diffs(all_diffs)
  -- TODO(2023-06-01) If no one has reported data loss by this time, we can remove the disclaimer
  disclaimer.show(function(disclaimed)
    if not disclaimed then
      return unlock()
    end
    preview.show(actions, confirm, function(proceed)
      if not proceed then
        return unlock()
      end

      M.process_actions(
        actions,
        vim.schedule_wrap(function(err)
          view.unlock_buffers()
          if err then
            vim.notify(string.format("[oil] Error applying actions: %s", err), vim.log.levels.ERROR)
            view.rerender_all_oil_buffers({ preserve_undo = false })
          else
            local current_entry = oil.get_cursor_entry()
            if current_entry then
              -- get the entry under the cursor and make sure the cursor stays on it
              view.set_last_cursor(
                vim.api.nvim_buf_get_name(0),
                vim.split(current_entry.name, "/")[1]
              )
            end
            view.rerender_all_oil_buffers({ preserve_undo = M.trash })
          end
          mutation_in_progress = false
        end)
      )
    end)
  end)
end

return M
