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
  tex_path = nil,
  tex_buf = nil,
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
  if text:sub(-1) ~= "\n" and #lines > 0 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

local function tp_available()
  local ok, tp = pcall(require, "texpresso")
  if not ok then
    return false, nil
  end
  return true, tp
end

--- Get or create the hidden TeX buffer for texpresso sync
local function get_tex_buf()
  if state.tex_buf and vim.api.nvim_buf_is_valid(state.tex_buf) then
    return state.tex_buf
  end
  state.tex_buf = nil
  return nil
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
    local tex_buf = get_tex_buf()

    for path, result in pairs(results) do
      local content
      if type(result) == "table" then
        content = result.output
      else
        content = result
      end

      if path == tex_key and tex_buf then
        -- Update the hidden TeX buffer — texpresso.nvim's on_lines hook
        -- automatically sends change-lines to the texpresso process
        local new_lines = split_lines(content)
        vim.api.nvim_buf_set_lines(tex_buf, 0, -1, false, new_lines)
      end

      -- Always write to disk
      local f = io.open(path, "w")
      if f then
        f:write(content)
        f:close()
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

  -- Resolve absolute path
  state.tex_path = vim.fn.fnamemodify(tex_key, ":p")

  -- Reuse existing buffer for the TeX file, or create a hidden one
  local existing = vim.fn.bufnr(state.tex_path)
  if existing ~= -1 then
    state.tex_buf = existing
  else
    state.tex_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.tex_buf, state.tex_path)
  end

  -- Initial compile — writes to disk and populates the buffer
  rebuild(buf)

  -- Launch texpresso
  tp.launch({ state.tex_path })

  -- Attach the TeX buffer so texpresso.nvim syncs it via on_lines
  tp.attach(state.tex_buf)

  vim.notify("[marksetta] texpresso started: " .. state.tex_path)
end

local function stop()
  local has_tp, tp = tp_available()
  if has_tp and tp.is_running() then
    tp.stop()
    vim.notify("[marksetta] texpresso stopped")
  end

  if state.tex_buf and vim.api.nvim_buf_is_valid(state.tex_buf) then
    vim.api.nvim_buf_delete(state.tex_buf, { force = true })
  end
  state.tex_buf = nil
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
