-- Minimal vim mock for busted tests
_G.vim = {
  api = {
    nvim_list_bufs = function()
      return {}
    end,
    nvim_buf_get_name = function()
      return ""
    end,
    nvim_buf_is_loaded = function()
      return false
    end,
    nvim_buf_get_lines = function()
      return {}
    end,
    nvim_create_augroup = function(name, _)
      return name
    end,
    nvim_create_autocmd = function() end,
    nvim_create_user_command = function() end,
  },
  fn = {
    mkdir = function() end,
    fnamemodify = function(path, _)
      return path
    end,
  },
  uv = {
    new_timer = function()
      return { stop = function() end, start = function() end }
    end,
  },
  log = { levels = { ERROR = 4, WARN = 3, INFO = 2 } },
  notify = function() end,
  schedule_wrap = function(fn)
    return fn
  end,
}

-- Mock marksetta
package.preload["marksetta"] = function()
  return {
    config = {
      load = function()
        return {}
      end,
    },
    compile = function(_, opts)
      local results = {}
      for path, profile in pairs(opts.outputs or {}) do
        if opts.source_map then
          results[path] = { output = "", source_map = {} }
        else
          results[path] = ""
        end
      end
      return results
    end,
  }
end

-- Mock texpresso (optional dependency)
package.preload["texpresso"] = function()
  return {
    launch = function() end,
    stop = function() end,
    send = function() end,
    is_running = function()
      return false
    end,
    theme = function() end,
  }
end

describe("marksetta-nvim", function()
  local plugin

  before_each(function()
    package.loaded["marksetta-nvim"] = nil
    plugin = require("marksetta-nvim")
  end)

  it("exports setup function", function()
    assert.is_function(plugin.setup)
  end)

  it("setup runs without error with defaults", function()
    assert.has_no.errors(function()
      plugin.setup()
    end)
  end)

  it("setup accepts custom options", function()
    assert.has_no.errors(function()
      plugin.setup({
        debounce_ms = 100,
        auto_start = true,
        outputs = {
          ["out.tex"] = { format = "tex", include = { "*" } },
        },
      })
    end)
  end)
end)
