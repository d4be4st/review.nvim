local M = {}

local store = require("review.store")
local hooks = require("review.hooks")
local popup = require("review.popup")
local marks = require("review.marks")

local function notify(msg, level)
  vim.notify(msg, level, { title = "review.nvim" })
end

---@param prompt string
---@param callback fun(comment: Comment)
local function resolve_at_cursor(prompt, callback)
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    notify("Could not determine cursor position", vim.log.levels.WARN)
    return
  end

  local matches = store.get_all_at_line(file, line, side)
  if #matches == 0 and line == 1 then
    local file_comment = store.get_file_comment(file)
    if file_comment then
      matches = { file_comment }
    end
  end

  if #matches == 0 then
    notify("No comment at cursor position", vim.log.levels.WARN)
    return
  end

  if #matches == 1 then
    callback(matches[1])
    return
  end

  local cfg = require("review.config").get()
  vim.ui.select(matches, {
    prompt = prompt,
    format_item = function(comment)
      local type_info = cfg.comment_types[comment.type]
      return string.format("%s %s", type_info and type_info.icon or "●", vim.split(comment.text, "\n")[1])
    end,
  }, function(choice)
    if choice then
      callback(choice)
    end
  end)
end

---@param initial_type? "note"|"suggestion"|"issue"|"praise"
function M.add_at_cursor(initial_type)
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    notify("Could not determine cursor position", vim.log.levels.WARN)
    return
  end

  popup.open(initial_type or "note", nil, function(comment_type, text)
    if comment_type and text then
      store.add(file, line, comment_type, text, nil, side)
      vim.schedule(function()
        marks.refresh()
      end)
      notify(string.format("Added %s comment", comment_type), vim.log.levels.INFO)
    end
  end)
end

-- Alias for backwards compatibility
function M.add_with_menu()
  M.add_at_cursor()
end

---@param initial_type? "note"|"suggestion"|"issue"|"praise"
function M.file_comment(initial_type)
  local file = hooks.get_cursor_position()
  if not file then
    notify("Could not determine file", vim.log.levels.WARN)
    return
  end

  local existing = store.get_file_comment(file)
  if existing then
    popup.open(existing.type, existing.text, function(new_type, text)
      if new_type and text then
        store.update(existing.id, text, new_type)
        vim.schedule(function()
          marks.refresh()
        end)
        notify("File comment updated", vim.log.levels.INFO)
      end
    end)
  else
    popup.open(initial_type or "note", nil, function(comment_type, text)
      if comment_type and text then
        store.add(file, 0, comment_type, text)
        vim.schedule(function()
          marks.refresh()
        end)
        notify(string.format("Added %s file comment", comment_type), vim.log.levels.INFO)
      end
    end)
  end
end

---@param initial_type? "note"|"suggestion"|"issue"|"praise"
function M.add_for_range(initial_type)
  local file, start_line, end_line, side = hooks.get_visual_range()
  if not file or not start_line or not end_line then
    notify("Could not determine visual selection", vim.log.levels.WARN)
    return
  end

  popup.open(initial_type or "note", nil, function(comment_type, text)
    if comment_type and text then
      store.add(file, start_line, comment_type, text, end_line, side)
      vim.schedule(function()
        marks.refresh()
      end)
      notify(string.format("Added %s comment", comment_type), vim.log.levels.INFO)
    end
  end)
end

function M.edit_at_cursor()
  resolve_at_cursor("Edit which comment?", function(comment)
    popup.open(comment.type, comment.text, function(new_type, text)
      if new_type and text then
        store.update(comment.id, text, new_type)
        -- Schedule refresh to run after popup is fully closed
        vim.schedule(function()
          marks.refresh()
        end)
        notify("Comment updated", vim.log.levels.INFO)
      end
    end)
  end)
end

function M.delete_at_cursor()
  resolve_at_cursor("Delete which comment?", function(comment)
    vim.ui.select({ "Yes", "No" }, {
      prompt = "Delete this comment?",
    }, function(choice)
      if choice == "Yes" then
        store.delete(comment.id)
        -- Schedule refresh to run after UI is closed
        vim.schedule(function()
          marks.refresh()
        end)
        notify("Comment deleted", vim.log.levels.INFO)
      end
    end)
  end)
end

function M.goto_next()
  local file, line, side = hooks.get_cursor_position()
  if not file then
    return
  end

  local comments = store.get_for_file(file, side)
  for _, comment in ipairs(comments) do
    if comment.line > line then
      vim.api.nvim_win_set_cursor(0, { comment.line, 0 })
      return
    end
  end

  notify("No more comments in this file", vim.log.levels.INFO)
end

function M.goto_prev()
  local file, line, side = hooks.get_cursor_position()
  if not file then
    return
  end

  local comments = store.get_for_file(file, side)
  for i = #comments, 1, -1 do
    local comment = comments[i]
    if comment.line < line then
      vim.api.nvim_win_set_cursor(0, { comment.line, 0 })
      return
    end
  end

  notify("No previous comments in this file", vim.log.levels.INFO)
end

---@param comment Comment
local function goto_comment(comment)
  local tabpage = hooks.get_current_tabpage()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok or not tabpage then
    return
  end

  local explorer = lifecycle.get_explorer(tabpage)
  if explorer then
    for _, file in ipairs(require("codediff.ui.explorer.refresh").get_all_files(explorer.tree)) do
      if file.data.path == comment.file then
        if explorer.current_file_path ~= comment.file then
          explorer.on_file_select(file.data, { no_jump = true })
        end
        break
      end
    end
  end

  local attempts = 0
  local function jump()
    attempts = attempts + 1
    local orig_path, mod_path = hooks.get_paths()
    if mod_path ~= comment.file and orig_path ~= comment.file then
      if attempts < 40 then
        vim.defer_fn(jump, 50)
      end
      return
    end
    local orig_win, mod_win = lifecycle.get_windows(tabpage)
    local win = mod_win
    if comment.side == "old" and orig_win ~= mod_win and orig_win and vim.api.nvim_win_is_valid(orig_win) then
      win = orig_win
    end
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      pcall(vim.api.nvim_win_set_cursor, win, { comment.line == 0 and 1 or comment.line, 0 })
    end
  end
  jump()
end

function M.list()
  local config = require("review.config").get()
  local all_comments = store.get_all()

  if #all_comments == 0 then
    notify("No comments yet", vim.log.levels.INFO)
    return
  end

  -- Build display items
  local items = {}
  for _, comment in ipairs(all_comments) do
    local type_info = config.comment_types[comment.type]
    local icon = type_info and type_info.icon or "●"
    local name = type_info and type_info.name or comment.type
    local location
    local is_old = (comment.side or "new") == "old"
    if comment.line == 0 then
      location = comment.file
    elseif is_old then
      if comment.line_end and comment.line_end ~= comment.line then
        location = string.format("%s:~%d-~%d", comment.file, comment.line, comment.line_end)
      else
        location = string.format("%s:~%d", comment.file, comment.line)
      end
    elseif comment.line_end and comment.line_end ~= comment.line then
      location = string.format("%s:%d-%d", comment.file, comment.line, comment.line_end)
    else
      location = string.format("%s:%d", comment.file, comment.line)
    end
    local display = string.format("%s %s [%s] %s", icon, location, name, comment.text)
    local header = string.format("**%s** · %s · `%s`", name, comment.author or "me", location)
    table.insert(items, {
      display = display,
      text = display,
      comment = comment,
      preview = { text = header .. "\n\n" .. comment.text, ft = "markdown" },
    })
  end

  local snacks_ok, Snacks = pcall(require, "snacks")
  if snacks_ok and Snacks.picker then
    Snacks.picker.pick({
      title = "Review comments",
      items = items,
      format = "text",
      preview = "preview",
      confirm = function(picker, item)
        picker:close()
        if item then
          goto_comment(item.comment)
        end
      end,
    })
    return
  end

  vim.ui.select(items, {
    prompt = "Comments:",
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if choice then
      goto_comment(choice.comment)
    end
  end)
end

return M
