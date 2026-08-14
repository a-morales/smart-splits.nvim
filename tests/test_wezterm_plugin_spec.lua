-- Tests for the Wezterm plugin half of smart-splits (plugin/init.lua).
--
-- That file guards itself with `if vim ~= nil then return end`, and these tests run
-- under nlua where `vim` is always present. So rather than `require`ing it, we load
-- the chunk with a custom environment that masks `vim`, and stub out the `wezterm`
-- module it requires. No globals are mutated.

local logged_errors = {}

local wezterm_stub = {
  -- the real one wraps the callback in a KeyAssignment; we just need the function back
  action_callback = function(fn)
    return fn
  end,
  log_info = function() end,
  log_warn = function() end,
  log_error = function(msg)
    table.insert(logged_errors, msg)
  end,
}

-- resolved relative to this spec file so the suite does not depend on the cwd
local plugin_path = debug.getinfo(1, 'S').source:sub(2):gsub('[^/\\]+$', '') .. '../plugin/init.lua'

local function load_plugin()
  package.loaded.wezterm = wezterm_stub
  local chunk = assert(loadfile(plugin_path))
  local env = setmetatable({}, {
    __index = function(_, key)
      if key == 'vim' then
        return nil
      end
      return _G[key]
    end,
  })
  setfenv(chunk, env)
  return chunk()
end

---Build a fake Pane. `is_nvim` drives the IS_NVIM user var that `is_vim()` reads.
local function make_pane(id, is_nvim)
  return {
    activated = false,
    get_user_vars = function()
      return { IS_NVIM = is_nvim and 'true' or 'false' }
    end,
    pane_id = function()
      return id
    end,
    activate = function(self)
      self.activated = true
    end,
  }
end

---Build a fake Window.
---@param opts table
---  panes: list of pane info (left/top/width/height/is_active/pane)
---  neighbors: map of direction -> pane, for get_pane_direction
local function make_window(opts)
  local panes = opts.panes or {}
  local neighbors = opts.neighbors or {}

  local tab = {
    panes = function()
      local list = {}
      for _, pane_info in ipairs(panes) do
        table.insert(list, pane_info.pane)
      end
      return list
    end,
    panes_with_info = function()
      return panes
    end,
    get_pane_direction = function(_, direction)
      return neighbors[direction]
    end,
  }

  local window = { actions = {} }
  window.active_tab = function()
    return tab
  end
  window.perform_action = function(_, action, _pane)
    table.insert(window.actions, action)
  end
  return window
end

---A tab holding a single pane, which is therefore at the edge in every direction.
local function single_pane_layout(is_nvim)
  local pane = make_pane(1, is_nvim)
  return pane,
    {
      panes = { { left = 0, top = 0, width = 80, height = 24, is_active = true, pane = pane } },
      neighbors = {},
    }
end

--   +----+----+
--   | A  | B  |
--   +----+----+
--   | C  | D  |
--   +----+----+
-- A is active. Wrapping left must land on B (same row), not D.
---@param active string|nil which pane is focused, defaults to 'a'
local function quad_layout(active)
  active = active or 'a'
  local panes = { a = make_pane('a'), b = make_pane('b'), c = make_pane('c'), d = make_pane('d') }
  local geometry = {
    { name = 'a', left = 0, top = 0, width = 40, height = 12 },
    { name = 'b', left = 41, top = 0, width = 40, height = 12 },
    { name = 'c', left = 0, top = 13, width = 40, height = 12 },
    { name = 'd', left = 41, top = 13, width = 40, height = 12 },
  }
  local panes_with_info = {}
  for _, geo in ipairs(geometry) do
    table.insert(panes_with_info, {
      left = geo.left,
      top = geo.top,
      width = geo.width,
      height = geo.height,
      is_active = geo.name == active,
      pane = panes[geo.name],
    })
  end
  return panes, { panes = panes_with_info, neighbors = {} }
end

---Find the keymap the plugin registered for `key` + `mods`.
local function keymap_for(config_builder, key, mods)
  for _, keymap in ipairs(config_builder.keys) do
    if keymap.key == key and keymap.mods == mods then
      return keymap
    end
  end
  return nil
end

---Configure the plugin and return the action callback for the given movement key.
local function move_action(plugin_config, key)
  local plugin = load_plugin()
  local config_builder = {}
  plugin.apply_to_config(config_builder, plugin_config)
  return keymap_for(config_builder, key, 'CTRL').action
end

---Configure the plugin and return the action callback for moving left (CTRL+h).
local function move_left_action(plugin_config)
  return move_action(plugin_config, 'h')
end

describe('smart-splits wezterm plugin', function()
  before_each(function()
    logged_errors = {}
  end)

  after_each(function()
    package.loaded.wezterm = nil
  end)

  describe('movement', function()
    it('activates the pane in the direction of travel when one exists', function()
      local pane = make_pane(1)
      local window = make_window({
        panes = {
          { left = 41, top = 0, width = 40, height = 24, is_active = true, pane = pane },
          { left = 0, top = 0, width = 40, height = 24, is_active = false, pane = make_pane(2) },
        },
        neighbors = { Left = make_pane(2) },
      })

      move_left_action({})(window, pane)

      assert.same({ { ActivatePaneDirection = 'Left' } }, window.actions)
    end)

    it('passes the key through to the program when the pane is neovim', function()
      local pane, layout = single_pane_layout(true)
      local window = make_window(layout)

      -- even with a non-default at_edge, neovim panes are left entirely alone
      move_left_action({ at_edge = 'split' })(window, pane)

      assert.same({ { SendKey = { key = 'h', mods = 'CTRL' } } }, window.actions)
    end)
  end)

  describe('at_edge = stop', function()
    it('is the default', function()
      local pane, layout = single_pane_layout()
      local window = make_window(layout)

      move_left_action(nil)(window, pane)

      assert.same({ { SendKey = { key = 'h', mods = 'CTRL' } } }, window.actions)
    end)

    it('passes the key through when at the edge of a multi-pane tab', function()
      local panes, layout = quad_layout()
      local window = make_window(layout)

      move_left_action({ at_edge = 'stop' })(window, panes.a)

      assert.same({ { SendKey = { key = 'h', mods = 'CTRL' } } }, window.actions)
    end)

    it('falls back to the wezterm modifier when the map omits neovim', function()
      local pane, layout = single_pane_layout()
      local window = make_window(layout)

      move_left_action({ modifiers = { move = { wezterm = 'CTRL' } } })(window, pane)

      -- the map itself must never leak through as `mods`
      assert.same({ { SendKey = { key = 'h', mods = 'CTRL' } } }, window.actions)
    end)

    it('sends the neovim modifier when modifiers are a wezterm/neovim map', function()
      local pane, layout = single_pane_layout()
      local window = make_window(layout)

      move_left_action({ modifiers = { move = { wezterm = 'CTRL', neovim = 'ALT' } } })(window, pane)

      assert.same({ { SendKey = { key = 'h', mods = 'ALT' } } }, window.actions)
    end)
  end)

  describe('at_edge = wrap', function()
    it('wraps to the farthest pane in the same row', function()
      local panes, layout = quad_layout()
      local window = make_window(layout)

      move_left_action({ at_edge = 'wrap' })(window, panes.a)

      assert.is_true(panes.b.activated)
      assert.is_false(panes.d.activated) -- would be a diagonal jump
      assert.same({}, window.actions)
    end)

    it('wraps right to the leftmost pane in the same row', function()
      local panes, layout = quad_layout('b')
      local window = make_window(layout)

      move_action({ at_edge = 'wrap' }, 'l')(window, panes.b)

      assert.is_true(panes.a.activated)
      assert.is_false(panes.c.activated) -- would be a diagonal jump
    end)

    it('wraps up to the bottom pane in the same column', function()
      local panes, layout = quad_layout('a')
      local window = make_window(layout)

      move_action({ at_edge = 'wrap' }, 'k')(window, panes.a)

      assert.is_true(panes.c.activated)
      assert.is_false(panes.d.activated) -- would be a diagonal jump
    end)

    it('wraps down to the top pane in the same column', function()
      local panes, layout = quad_layout('c')
      local window = make_window(layout)

      move_action({ at_edge = 'wrap' }, 'j')(window, panes.c)

      assert.is_true(panes.a.activated)
      assert.is_false(panes.b.activated) -- would be a diagonal jump
    end)

    it('passes the key through when there is nowhere to wrap to', function()
      local pane, layout = single_pane_layout()
      local window = make_window(layout)

      move_left_action({ at_edge = 'wrap' })(window, pane)

      -- falls back to 'stop' rather than swallowing the keystroke
      assert.is_false(pane.activated)
      assert.same({ { SendKey = { key = 'h', mods = 'CTRL' } } }, window.actions)
    end)
  end)

  describe('at_edge = split', function()
    it('splits in the direction of travel', function()
      local pane, layout = single_pane_layout()
      local window = make_window(layout)

      move_left_action({ at_edge = 'split' })(window, pane)

      assert.same({ { SplitPane = { direction = 'Left' } } }, window.actions)
    end)
  end)

  describe('at_edge as a function', function()
    it('receives the context', function()
      local pane, layout = single_pane_layout()
      local window = make_window(layout)
      local ctx

      move_left_action({
        at_edge = function(context)
          ctx = context
        end,
      })(window, pane)

      assert.equals(window, ctx.window)
      assert.equals(pane, ctx.pane)
      assert.equals('Left', ctx.direction) -- wezterm casing, not the neovim plugin's 'left'
      assert.equals('h', ctx.key)
      assert.same({}, window.actions) -- nothing happens unless the callback asks for it
    end)

    it('exposes a working send_key', function()
      local pane, layout = single_pane_layout()
      local window = make_window(layout)

      move_left_action({
        at_edge = function(context)
          context.send_key()
        end,
      })(window, pane)

      assert.same({ { SendKey = { key = 'h', mods = 'CTRL' } } }, window.actions)
    end)

    it('exposes a working split', function()
      local pane, layout = single_pane_layout()
      local window = make_window(layout)

      move_left_action({
        at_edge = function(context)
          context.split()
        end,
      })(window, pane)

      assert.same({ { SplitPane = { direction = 'Left' } } }, window.actions)
    end)

    it('exposes a working wrap', function()
      local panes, layout = quad_layout()
      local window = make_window(layout)

      move_left_action({
        at_edge = function(context)
          context.wrap()
        end,
      })(window, panes.a)

      assert.is_true(panes.b.activated)
    end)

    it('is not called when a pane exists in the direction of travel', function()
      local pane = make_pane(1)
      local window = make_window({
        panes = { { left = 41, top = 0, width = 40, height = 24, is_active = true, pane = pane } },
        neighbors = { Left = make_pane(2) },
      })
      local called = false

      move_left_action({
        at_edge = function()
          called = true
        end,
      })(window, pane)

      assert.is_false(called)
      assert.same({ { ActivatePaneDirection = 'Left' } }, window.actions)
    end)
  end)

  describe('resize', function()
    local function resize_left_action(plugin_config)
      local plugin = load_plugin()
      local config_builder = {}
      plugin.apply_to_config(config_builder, plugin_config)
      return keymap_for(config_builder, 'h', 'META').action
    end

    it('does not consult at_edge', function()
      local panes, layout = quad_layout()
      local window = make_window(layout)

      -- pane A has no pane to its left, but resizing against its right-hand
      -- boundary is still meaningful, so at_edge must not fire
      resize_left_action({ at_edge = 'split' })(window, panes.a)

      assert.same({ { AdjustPaneSize = { 'Left', 3 } } }, window.actions)
    end)

    it('passes the key through in a single-pane tab', function()
      local pane, layout = single_pane_layout()
      local window = make_window(layout)

      resize_left_action({ at_edge = 'wrap' })(window, pane)

      assert.same({ { SendKey = { key = 'h', mods = 'META' } } }, window.actions)
    end)
  end)

  describe('config validation', function()
    it('falls back to stop and logs an error for an invalid at_edge', function()
      local pane, layout = single_pane_layout()
      local window = make_window(layout)

      move_left_action({ at_edge = 'wrapped', log_level = 'error' })(window, pane)

      assert.equals(1, #logged_errors)
      assert.is_truthy(logged_errors[1]:match('wrapped'))
      assert.same({ { SendKey = { key = 'h', mods = 'CTRL' } } }, window.actions)
    end)

    it('falls back to info and logs an error for an invalid log_level', function()
      local pane, layout = single_pane_layout()
      local window = make_window(layout)

      move_left_action({ log_level = 'debug', at_edge = 'wrapped' })(window, pane)

      -- the bad log_level must not suppress the at_edge error that follows it
      assert.equals(2, #logged_errors)
      assert.is_truthy(logged_errors[1]:match('debug'))
      assert.is_truthy(logged_errors[2]:match('wrapped'))
    end)

    it('accepts every valid string value', function()
      for _, value in ipairs({ 'stop', 'wrap', 'split' }) do
        local pane, layout = single_pane_layout()
        move_left_action({ at_edge = value })(make_window(layout), pane)
        assert.same({}, logged_errors)
      end
    end)
  end)
end)
