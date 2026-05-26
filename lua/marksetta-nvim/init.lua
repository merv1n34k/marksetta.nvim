-- marksetta.nvim: Neovim integration for marksetta
-- Debounced real-time compilation with texpresso protocol integration
--
-- require("marksetta-nvim").setup({...})

local M = {}

local marksetta

local defaults = {
  debounce_ms = 50,
  pattern = '*.mx',
  auto_start = false,
  -- TeX distribution texpresso should use for standard package lookup
  -- ("tectonic" | "texlive" | nil to auto-detect).
  engine = nil,
  -- Before launching texpresso, run a synchronous tectonic compile of
  -- the synthesized preview.tex to populate .aux on disk. This is the
  -- only way to get \tableofcontents / cross-references in the live
  -- preview, since texpresso never persists engine-written files (its
  -- in-memory aux is rolled back on every replay).
  -- Set to false to skip the launch-time pre-compile (faster startup,
  -- empty TOC).
  seed_aux = true,
  -- Inline marksetta config override (merged on top of file-discovered
  -- config). Use this to set per-format options like packages, document
  -- class, or a full preamble override:
  --   cfg = { tex = { packages = { 'tikz', 'amsmath' } } }
  cfg = nil,
  outputs = {
    ['preview'] = { target = 'texpresso', include = { '*' } },
    ['output/out.tex'] = { format = 'tex', include = { '*' } },
    ['output/out.md'] = { format = 'md', include = { '*' } },
  },
}

local state = {
  cfg = nil,
  opts = nil,
  timer = nil,
  tex_key = nil,
  tex_dir = nil,
  tex_path = nil,
  augroup = nil,
  buffers = {},
}

local function deep_merge(base, override)
  local result = {}
  for k, v in pairs(base) do
    result[k] = v
  end
  for k, v in pairs(override) do
    if type(v) == 'table' and type(result[k]) == 'table' then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

-- Read-through overlay: user keys shadow base keys; nested tables are
-- overlaid recursively. Uses __index, so it works with marksetta's
-- frozen-config proxy on LuaJIT (which ignores __pairs and would make
-- a pairs-based deep_merge silently drop every base field).
local function overlay(base, user)
  if not user then
    return base
  end
  return setmetatable({}, {
    __index = function(_, k)
      local v = user[k]
      if v == nil then
        return base[k]
      end
      local b = base[k]
      if type(v) == 'table' and type(b) == 'table' then
        return overlay(b, v)
      end
      return v
    end,
  })
end

local function find_texpresso_target(outputs)
  local matches = {}
  for path, profile in pairs(outputs) do
    if profile.target == 'texpresso' then
      table.insert(matches, path)
    end
  end
  table.sort(matches)
  return matches[1], #matches
end

--- Convert glob pattern(s) like "*.mx" to Lua patterns like "%.mx$"
local function glob_to_lua_pattern(pat)
  local p = pat:gsub('%.', '%%.'):gsub('%*', '.*')
  return p .. '$'
end

local function find_source_buf()
  local pats = state.opts and state.opts.pattern or '*.mx'
  if type(pats) == 'string' then
    pats = { pats }
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) then
      for _, pat in ipairs(pats) do
        if name:match(glob_to_lua_pattern(pat)) then
          return buf
        end
      end
    end
  end
  return nil
end

local function tp_available()
  local ok, tp = pcall(require, 'texpresso')
  if not ok then
    return false, nil
  end
  return true, tp
end

--- Detect a usable TeX distribution. Prefer tectonic (self-contained,
--- modern). Fall back to texlive via kpsewhich. Returns nil if neither.
local function detect_engine()
  if vim.fn.executable('tectonic') == 1 then
    return 'tectonic'
  end
  if vim.fn.executable('kpsewhich') == 1 then
    return 'texlive'
  end
  return nil
end

--- Get (or lazily create) a scratch preview buffer for a "buffer" target.
--- Buffer is listed, non-modifiable, backed by no file; persists across stop().
local function get_or_create_buffer(name)
  local buf = state.buffers[name]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  state.buffers[name] = buf
  return buf
end

local function update_buffer(name, content)
  local buf = get_or_create_buffer(name)
  local lines = vim.split(content, '\n', { plain = true })
  if #lines > 0 and lines[#lines] == '' then
    table.remove(lines)
  end
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
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

    for path, result in pairs(results) do
      local content = type(result) == 'table' and result.output or result
      local profile = state.opts.outputs[path]
      local target = (profile and profile.target) or 'file'

      if target == 'texpresso' then
        -- Push only the elected texpresso target; extras are ignored
        -- (warned at setup time).
        if path == state.tex_key and state.tex_path then
          local has_tp, tp = tp_available()
          if has_tp and tp.is_running() then
            tp.push(state.tex_path, content)
          end
        end
      elseif target == 'buffer' then
        -- Render into a scratch buffer named after the path key.
        update_buffer(path, content)
      else
        -- target == "file" (default): write to disk at the configured path.
        local f = io.open(path, 'w')
        if f then
          f:write(content)
          f:close()
        end
      end
    end
  end)
  if not ok then
    vim.notify('[marksetta] ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local function start(buf)
  buf = buf or find_source_buf()
  if not buf then
    vim.notify('[marksetta] no matching buffer found', vim.log.levels.ERROR)
    return
  end

  if not state.tex_key then
    vim.notify('[marksetta] no texpresso target configured', vim.log.levels.WARN)
    return
  end

  local has_tp, tp = tp_available()
  if not has_tp then
    vim.notify(
      '[marksetta] texpresso.vim not available; texpresso target ignored',
      vim.log.levels.WARN
    )
    return
  end

  if tp.is_running() then
    vim.notify('[marksetta] texpresso already running', vim.log.levels.WARN)
    return
  end

  -- Preview file + TeX intermediates live in <src_dir>/.marksetta/.
  -- The output_name in the user's texpresso target is ignored.
  local src = vim.api.nvim_buf_get_name(buf)
  local src_dir = vim.fn.fnamemodify(src, ':p:h')
  state.tex_dir = src_dir .. '/.marksetta'
  vim.fn.mkdir(state.tex_dir, 'p')
  state.tex_path = state.tex_dir .. '/preview.tex'

  -- Backward synctex (PDF click) would drop the user into the
  -- synthesized .marksetta/preview.tex — useless for a marksetta
  -- workflow whose source is the .mx file. Disable it.
  if tp.synctex_backward_enabled ~= nil then
    tp.synctex_backward_enabled = false
  end

  local engine = state.opts.engine or detect_engine()

  -- Seed .aux on disk so texpresso's first run can render \tableofcontents
  -- and resolve cross-references. Texpresso never persists engine-written
  -- files, so without this the live TOC is always empty. Only tectonic is
  -- supported for the seed (it auto-reruns until .aux stabilizes); texlive
  -- users get a notice and a stale-TOC preview.
  if state.opts.seed_aux and engine == 'tectonic' then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local results = marksetta.compile(lines, {
      cfg = state.cfg,
      outputs = state.opts.outputs,
    })
    local r = results[state.tex_key]
    local seed_content = type(r) == 'table' and r.output or r
    if seed_content then
      local fh = io.open(state.tex_path, 'w')
      if fh then
        fh:write(seed_content)
        fh:close()
        vim.notify('[marksetta] seeding .aux with tectonic...')
        local out = vim.fn.system({
          'tectonic',
          '--keep-intermediates',
          '--outdir',
          state.tex_dir,
          state.tex_path,
        })
        if vim.v.shell_error ~= 0 then
          vim.notify(
            '[marksetta] tectonic seed failed (TOC may be empty): ' .. out,
            vim.log.levels.WARN
          )
        end
      end
    end
  elseif state.opts.seed_aux and engine ~= 'tectonic' then
    vim.notify(
      '[marksetta] seed_aux requires tectonic; skipping. TOC and cross-refs '
        .. 'will be empty in the preview.',
      vim.log.levels.WARN
    )
  end

  -- -I <src_dir> lets the TeX engine resolve relative includes
  -- (images, .bib, .sty) directly from the source directory.
  -- -tectonic/-texlive tells texpresso where to find standard packages.
  local launch_args = { state.tex_path, '-I', src_dir }
  if engine == 'tectonic' then
    table.insert(launch_args, '-tectonic')
  elseif engine == 'texlive' then
    table.insert(launch_args, '-texlive')
  else
    vim.notify(
      '[marksetta] no TeX engine detected (install tectonic or texlive); '
        .. 'texpresso will not find standard packages',
      vim.log.levels.WARN
    )
  end
  tp.stream_mode = true
  tp.launch(launch_args)
  rebuild(buf)

  vim.notify('[marksetta] texpresso started: ' .. state.tex_path)
end

local function stop()
  local has_tp, tp = tp_available()
  if has_tp and tp.is_running() then
    tp.stop()
    vim.notify('[marksetta] texpresso stopped')
  end
  state.tex_path = nil
  state.tex_dir = nil
end

function M.setup(opts)
  marksetta = require('marksetta')
  opts = opts or {}
  state.opts = deep_merge(defaults, opts)
  -- Load defaults + auto-discovered .marksetta.json (cwd) or
  -- ~/.config/marksetta/config.json, then layer the inline `cfg`
  -- override from setup() on top so editor-only tweaks win.
  local base = marksetta.config.load({})
  state.cfg = overlay(base, state.opts.cfg)
  state.timer = vim.uv.new_timer()

  -- Normalize texpresso targets: format and output_name are ignored for
  -- the user, but marksetta.compile still needs `format = "tex"` to know
  -- how to render the chunk.
  for _, profile in pairs(state.opts.outputs) do
    if profile.target == 'texpresso' then
      profile.format = 'tex'
    end
  end

  -- Elect a single texpresso target; warn if multiple are configured.
  local tex_count
  state.tex_key, tex_count = find_texpresso_target(state.opts.outputs)
  if tex_count and tex_count > 1 then
    vim.notify(
      string.format(
        '[marksetta] %d texpresso targets configured; using %s (others ignored)',
        tex_count,
        state.tex_key
      ),
      vim.log.levels.WARN
    )
  end

  -- Ensure parent directories exist for file-target outputs.
  for path, profile in pairs(state.opts.outputs) do
    if (profile.target or 'file') == 'file' then
      local dir = path:match('(.+)/')
      if dir then
        vim.fn.mkdir(dir, 'p')
      end
    end
  end

  local pat = state.opts.pattern

  state.augroup = vim.api.nvim_create_augroup('marksetta-nvim', { clear = true })

  -- Initial build when file is opened
  vim.api.nvim_create_autocmd('BufReadPost', {
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
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
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
  vim.api.nvim_create_autocmd('BufDelete', {
    group = state.augroup,
    pattern = pat,
    callback = function()
      vim.schedule(function()
        if not find_source_buf() then
          stop()
        end
      end)
    end,
  })

  -- User commands
  vim.api.nvim_create_user_command('MarksettaStart', function()
    start()
  end, { desc = 'Start texpresso for .mx output' })

  vim.api.nvim_create_user_command('MarksettaStop', function()
    stop()
  end, { desc = 'Stop texpresso' })

  vim.api.nvim_create_user_command('MarksettaToggle', function()
    local has_tp, tp = tp_available()
    if has_tp and tp.is_running() then
      stop()
    else
      start()
    end
  end, { desc = 'Toggle texpresso' })

  -- Rebuild any matching buffers already open when setup() is called
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      local pats = type(pat) == 'table' and pat or { pat }
      for _, p in ipairs(pats) do
        if name:match(glob_to_lua_pattern(p)) then
          rebuild(buf)
          break
        end
      end
    end
  end
end

return M
