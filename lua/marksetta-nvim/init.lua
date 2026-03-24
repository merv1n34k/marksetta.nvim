-- marksetta.nvim: Neovim integration for marksetta
-- Debounced real-time compilation with texpresso protocol integration
--
-- require("marksetta-nvim").setup({...})

local M = {}

local marksetta

local defaults = {
  debounce_ms = 50,
  pattern = "*.mx",
  auto_start = false,
  outputs = {
    ["output/out.tex"] = { format = "tex", include = { "*" } },
    ["output/out.md"] = { format = "md", include = { "*" } },
  },
}

local state = {
  cfg = nil,
  opts = nil,
  timer = nil,
  last_lines = nil,
  last_map = nil,
  tex_path = nil,
  augroup = nil,
}

local function deep_merge(base, override)
  local result = {}
  for k, v in pairs(base) do
    result[k] = v
  end
  for k, v in pairs(override) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

local function find_tex_output(outputs)
  for path, profile in pairs(outputs) do
    if profile.format == "tex" then
      return path
    end
  end
  return nil
end

local function find_mx_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and name:match("%.mx$") then
      return buf
    end
  end
  return nil
end

local function split_lines(text)
  if not text or text == "" then
    return {}
  end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  -- Remove trailing empty line from the split if text didn't end with newline
  if text:sub(-1) ~= "\n" and #lines > 0 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

--- Build a lookup of source map entries keyed by (flavor, chunk_id)
local function map_by_chunk(source_map)
  local lookup = {}
  for _, entry in ipairs(source_map or {}) do
    local key = entry.flavor .. ":" .. tostring(entry.chunk_id)
    lookup[key] = entry
  end
  return lookup
end

--- Compute chunk-aware diffs between old and new TeX output.
--- Returns a list of {first, old_count, new_text} change-lines operations,
--- or nil if a full reload is needed.
local function diff_maps(old_lines, old_map, new_lines, new_map)
  if not old_map or not new_map then
    return nil
  end

  local old_lookup = map_by_chunk(old_map)
  local new_lookup = map_by_chunk(new_map)

  -- If chunk count differs significantly, full reload
  local old_count = 0
  for _ in pairs(old_lookup) do
    old_count = old_count + 1
  end
  local new_count = 0
  for _ in pairs(new_lookup) do
    new_count = new_count + 1
  end
  if math.abs(old_count - new_count) > old_count * 0.5 + 1 then
    return nil
  end

  local changes = {}

  for key, new_entry in pairs(new_lookup) do
    local old_entry = old_lookup[key]
    if not old_entry then
      -- New chunk appeared — full reload
      return nil
    end

    -- Extract output line ranges (1-based from source map)
    local old_start = old_entry.out_start
    local old_end = old_entry.out_end
    local new_start = new_entry.out_start
    local new_end = new_entry.out_end

    -- Compare lines in this chunk region
    local changed = false
    if (old_end - old_start) ~= (new_end - new_start) then
      changed = true
    else
      for i = 0, new_end - new_start do
        if old_lines[old_start + i] ~= new_lines[new_start + i] then
          changed = true
          break
        end
      end
    end

    if changed then
      -- Collect new lines for this chunk
      local chunk_lines = {}
      for i = new_start, new_end do
        chunk_lines[#chunk_lines + 1] = new_lines[i]
      end
      changes[#changes + 1] = {
        first = old_start - 1, -- texpresso uses 0-based
        old_count = old_end - old_start + 1,
        new_text = table.concat(chunk_lines, "\n") .. "\n",
      }
    end
  end

  -- Check for removed chunks
  for key, _ in pairs(old_lookup) do
    if not new_lookup[key] then
      return nil
    end
  end

  return changes
end

local function tp_available()
  local ok, tp = pcall(require, "texpresso")
  if not ok then
    return false, nil
  end
  return true, tp
end

local function compile(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local results = marksetta.compile(lines, {
    cfg = state.cfg,
    outputs = state.opts.outputs,
    source_map = true,
  })
  return results
end

local function rebuild(buf)
  local ok, err = pcall(function()
    local results = compile(buf)
    local tex_key = find_tex_output(state.opts.outputs)
    local has_tp, tp = tp_available()
    local tp_running = has_tp and tp.is_running()

    for path, result in pairs(results) do
      local content, source_map
      if type(result) == "table" then
        content = result.output
        source_map = result.source_map
      else
        content = result
        source_map = nil
      end

      if path == tex_key and tp_running then
        -- Send to texpresso via protocol
        local new_lines = split_lines(content)
        local abs_path = state.tex_path or vim.fn.fnamemodify(path, ":p")
        -- texpresso expects trailing \n on all content
        local tp_content = content:sub(-1) == "\n" and content or content .. "\n"

        if not state.last_lines then
          -- First compile or no previous state — full open
          tp.send("open", abs_path, tp_content)
        else
          local changes = diff_maps(state.last_lines, state.last_map, new_lines, source_map)
          if changes and #changes > 0 then
            -- Sort changes in reverse order so line offsets don't shift
            table.sort(changes, function(a, b)
              return a.first > b.first
            end)
            for _, change in ipairs(changes) do
              tp.send("change-lines", abs_path, change.first, change.old_count, change.new_text)
            end
          elseif not changes then
            -- Structural change — full reload
            tp.send("open", abs_path, tp_content)
          end
          -- else: no changes, nothing to send
        end

        state.last_lines = new_lines
        state.last_map = source_map

        -- Also write to disk so file stays in sync
        local f = io.open(path, "w")
        if f then
          f:write(content)
          f:close()
        end
      else
        -- Non-tex outputs or texpresso not running: write to disk
        local f = io.open(path, "w")
        if f then
          f:write(content)
          f:close()
        end

        -- Track tex state even when texpresso isn't running
        if path == tex_key then
          state.last_lines = split_lines(content)
          state.last_map = source_map
        end
      end
    end
  end)
  if not ok then
    vim.notify("[marksetta] " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function start(buf)
  buf = buf or find_mx_buf()
  if not buf then
    vim.notify("[marksetta] no .mx buffer found", vim.log.levels.ERROR)
    return
  end

  local tex_key = find_tex_output(state.opts.outputs)
  if not tex_key then
    vim.notify("[marksetta] no tex output configured", vim.log.levels.ERROR)
    return
  end

  local has_tp, tp = tp_available()
  if not has_tp then
    vim.notify("[marksetta] texpresso.vim not available", vim.log.levels.ERROR)
    return
  end

  if tp.is_running() then
    vim.notify("[marksetta] texpresso already running", vim.log.levels.WARN)
    return
  end

  -- Ensure output directory exists
  local dir = tex_key:match("(.+)/")
  if dir then
    vim.fn.mkdir(dir, "p")
  end

  -- Initial compile and write to disk (texpresso needs the file)
  state.last_lines = nil
  state.last_map = nil
  rebuild(buf)

  -- Resolve absolute path for texpresso
  state.tex_path = vim.fn.fnamemodify(tex_key, ":p")

  -- Launch texpresso watching the file
  tp.launch({ state.tex_path })

  vim.notify("[marksetta] texpresso started: " .. state.tex_path)
end

local function stop()
  local has_tp, tp = tp_available()
  if has_tp and tp.is_running() then
    tp.stop()
    vim.notify("[marksetta] texpresso stopped")
  end

  state.last_lines = nil
  state.last_map = nil
  state.tex_path = nil
end

function M.setup(opts)
  marksetta = require("marksetta")
  opts = opts or {}
  state.opts = deep_merge(defaults, opts)
  state.cfg = marksetta.config.load({ no_file = true })
  state.timer = vim.uv.new_timer()

  -- Ensure parent directories exist for all output paths
  for path, _ in pairs(state.opts.outputs) do
    local dir = path:match("(.+)/")
    if dir then
      vim.fn.mkdir(dir, "p")
    end
  end

  local pat = state.opts.pattern

  state.augroup = vim.api.nvim_create_augroup("marksetta-nvim", { clear = true })

  -- Initial build when file is opened
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = state.augroup,
    pattern = pat,
    callback = function(ev)
      rebuild(ev.buf)
      if state.opts.auto_start then
        local has_tp, tp = tp_available()
        if has_tp and not tp.is_running() then
          start(ev.buf)
        end
      end
    end,
  })

  -- Debounced rebuild on edits
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = state.augroup,
    pattern = pat,
    callback = function(ev)
      state.timer:stop()
      state.timer:start(
        state.opts.debounce_ms,
        0,
        vim.schedule_wrap(function()
          rebuild(ev.buf)
        end)
      )
    end,
  })

  -- Stop texpresso when last .mx buffer is closed
  vim.api.nvim_create_autocmd("BufDelete", {
    group = state.augroup,
    pattern = pat,
    callback = function()
      vim.schedule(function()
        if not find_mx_buf() then
          stop()
        end
      end)
    end,
  })

  -- User commands
  vim.api.nvim_create_user_command("MarksettaStart", function()
    start()
  end, { desc = "Start texpresso for .mx output" })

  vim.api.nvim_create_user_command("MarksettaStop", function()
    stop()
  end, { desc = "Stop texpresso" })

  vim.api.nvim_create_user_command("MarksettaToggle", function()
    local has_tp, tp = tp_available()
    if has_tp and tp.is_running() then
      stop()
    else
      start()
    end
  end, { desc = "Toggle texpresso" })

  -- Rebuild any .mx buffers already open when setup() is called
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and name:match("%.mx$") then
      rebuild(buf)
    end
  end
end

return M
