---@class SmartSplitsWeztermModifierMap
---@field wezterm string
---@field neovim string

---@class SmartSplitsWeztermModifiers
---@field move string | SmartSplitsWeztermModifierMap
---@field resize string | SmartSplitsWeztermModifierMap

---@class DirectionKeys
---@field move string[] keys to use for moving windows
---@field resize string[] keys to use for resizing windows

---Context passed to a function-valued `at_edge`. Note that `direction` uses Wezterm's
---casing ('Left'), not the Neovim plugin's ('left'), so that it can be passed directly
---to Wezterm APIs such as `window:perform_action({ ActivatePaneDirection = ctx.direction })`.
---@class SmartSplitsWeztermContext
---@field window table The Wezterm GUI window
---@field pane table The active pane, which is at the edge
---@field direction 'Left'|'Down'|'Up'|'Right' The direction of travel
---@field key string The key that was pressed
---@field split fun() Split the current pane in `direction`
---@field wrap fun() Activate the farthest pane in the opposite direction
---@field send_key fun() Pass the keystroke through to the program running in the pane

---What to do when there is no pane in the direction of travel. Note that unlike the
---Neovim plugin, 'stop' passes the keystroke through to the program running in the
---pane, since Wezterm is not the program you are typing into.
---@alias SmartSplitsWeztermAtEdgeBehavior 'stop'|'wrap'|'split'|fun(ctx:SmartSplitsWeztermContext)

---@class SmartSplitsWeztermConfig
---@field default_amount number The number of cells to resize by
---@field direction_keys string[]|DirectionKeys Keys to use for movements, not including the modifier key (such as alt or ctrl), in order of left, down, up, right
---@field modifiers SmartSplitsWeztermModifiers Modifier keys to use for movement and resize actions, these should be Wezterm's modifier key strings such as 'META', 'CTRL', etc.
---@field at_edge SmartSplitsWeztermAtEdgeBehavior What to do when moving and there is no pane in the direction of travel
---@field log_level 'info'|'warn'|'error'

if vim ~= nil then
  return -- this is a Wezterm plugin, not part of the Neovim plugin
end

local wezterm = require('wezterm')

---@type SmartSplitsWeztermConfig
local _smart_splits_wezterm_config = {
  default_amount = 3,
  direction_keys = { 'h', 'j', 'k', 'l' },
  modifiers = {
    move = 'CTRL',
    resize = 'META',
  },
  at_edge = 'stop',
  log_level = 'info',
}

local logger = {
  info = function(...)
    if _smart_splits_wezterm_config.log_level == 'info' then
      wezterm.log_info(...)
    end
  end,
  warn = function(...)
    if
      _smart_splits_wezterm_config.log_level == 'info' --
      or _smart_splits_wezterm_config.log_level == 'warn'
    then
      wezterm.log_warn(...)
    end
  end,
  error = function(...)
    if
      _smart_splits_wezterm_config.log_level == 'info'
      or _smart_splits_wezterm_config.log_level == 'warn'
      or _smart_splits_wezterm_config.log_level == 'error'
    then
      wezterm.log_error(...)
    end
  end,
}

local function is_vim(pane)
  -- if type is PaneInformation
  if pane.user_vars ~= nil then
    logger.info('[smart-splits.nvim]: PaneInformation.user_vars.IS_NVIM = ', pane.user_vars.IS_NVIM)
    return pane.user_vars.IS_NVIM == 'true'
  end

  -- this is set by the Neovim plugin on launch, and unset on ExitPre in Neovim
  logger.info('[smart-splits.nvim]: Pane:get_user_vars().IS_NVIM = ', pane:get_user_vars().IS_NVIM)
  return pane:get_user_vars().IS_NVIM == 'true'
end

local Directions = { 'Left', 'Down', 'Up', 'Right' }

local AtEdgeValues = { stop = true, wrap = true, split = true }

local LogLevels = { info = true, warn = true, error = true }

-- For each direction of travel, describes how to find the pane to wrap to.
-- `axis`/`pick` select the farthest pane in the opposite direction, while
-- `band`/`band_size` describe the perpendicular extent used to keep the wrap
-- within the current pane's row or column.
local WrapSpec = {
  Left = { axis = 'left', pick = 'max', band = 'top', band_size = 'height' },
  Right = { axis = 'left', pick = 'min', band = 'top', band_size = 'height' },
  Up = { axis = 'top', pick = 'max', band = 'left', band_size = 'width' },
  Down = { axis = 'top', pick = 'min', band = 'left', band_size = 'width' },
}

---Find the pane to wrap to when at the edge, or nil if that would be the current pane.
---Wezterm has no wrap primitive, and `get_pane_direction` is relative to the tab's
---active pane, so walking the layout would mean activating each pane in turn. Instead
---this is computed geometrically from a single, side-effect-free call.
---@param window table
---@param direction 'Left'|'Down'|'Up'|'Right'
---@return table|nil pane the pane to activate, or nil to stay put
local function find_wrap_target(window, direction)
  local spec = WrapSpec[direction]
  local panes = window:active_tab():panes_with_info()

  local current
  for _, pane_info in ipairs(panes) do
    if pane_info.is_active then
      current = pane_info
      break
    end
  end

  if current == nil then
    return nil
  end

  local target = current
  for _, pane_info in ipairs(panes) do
    -- only consider panes sharing a row (or column) with the current pane,
    -- so that wrapping never jumps diagonally across the tab
    local overlaps = pane_info[spec.band] < current[spec.band] + current[spec.band_size]
      and current[spec.band] < pane_info[spec.band] + pane_info[spec.band_size]
    if overlaps then
      if spec.pick == 'max' and pane_info[spec.axis] > target[spec.axis] then
        target = pane_info
      elseif spec.pick == 'min' and pane_info[spec.axis] < target[spec.axis] then
        target = pane_info
      end
    end
  end

  -- panes tile, so the current pane always overlaps itself; a single-pane tab, or a
  -- pane that is already the farthest one, wraps to itself, meaning stay put
  if target == current then
    return nil
  end

  return target.pane
end

---Apply the configured `at_edge` behavior. Only called for movement, and only once
---we know there is no pane in the direction of travel.
---@param window table
---@param pane table
---@param key string
---@param direction 'Left'|'Down'|'Up'|'Right'
---@param send_key fun() pass the keystroke through to the program running in the pane
local function handle_at_edge(window, pane, key, direction, send_key)
  local split = function()
    window:perform_action({ SplitPane = { direction = direction } }, pane)
  end
  local wrap = function()
    local target = find_wrap_target(window, direction)
    if target == nil then
      -- nothing to wrap to: a single-pane tab, or no other pane sharing this row or
      -- column. Fall back to 'stop' so the keystroke still reaches the program running
      -- in the pane instead of being silently swallowed by Wezterm.
      send_key()
      return
    end
    target:activate()
  end

  local at_edge = _smart_splits_wezterm_config.at_edge
  if type(at_edge) == 'function' then
    at_edge({ ---@type SmartSplitsWeztermContext
      window = window,
      pane = pane,
      direction = direction,
      key = key,
      split = split,
      wrap = wrap,
      send_key = send_key,
    })
  elseif at_edge == 'wrap' then
    wrap()
  elseif at_edge == 'split' then
    split()
  else -- 'stop'
    send_key()
  end
end

---@param resize_or_move 'resize'|'move'
---@param key string
---@param direction 'Left'|'Down'|'Up'|'Right'
---@return table
local function split_nav(resize_or_move, key, direction)
  local modifier = resize_or_move == 'resize' and _smart_splits_wezterm_config.modifiers.resize
    or _smart_splits_wezterm_config.modifiers.move
  -- a modifier is either a single string, or a { wezterm = ..., neovim = ... } map. When
  -- the map omits one side, fall back to the other; passing the table itself through as
  -- `mods` is not a valid Wezterm modifier string.
  local wezterm_modifier = modifier --[[@as string]]
  local neovim_modifier = modifier --[[@as string]]
  if type(modifier) == 'table' then
    wezterm_modifier = modifier.wezterm or modifier.neovim
    neovim_modifier = modifier.neovim or modifier.wezterm
  end
  return {
    key = key,
    mods = wezterm_modifier,
    action = wezterm.action_callback(function(win, pane)
      local send_key = function()
        win:perform_action({ SendKey = { key = key, mods = neovim_modifier } }, pane)
      end

      -- pass the keys through to vim/nvim; it applies its own `at_edge` behavior
      if is_vim(pane) then
        send_key()
        return
      end

      if resize_or_move == 'resize' then
        -- resize does not consult `at_edge`; with a single pane there is no boundary
        -- to move, so the key belongs to the program running in the pane
        if #win:active_tab():panes() == 1 then
          send_key()
        else
          win:perform_action({ AdjustPaneSize = { direction, _smart_splits_wezterm_config.default_amount } }, pane)
        end
        return
      end

      if win:active_tab():get_pane_direction(direction) ~= nil then
        win:perform_action({ ActivatePaneDirection = direction }, pane)
        return
      end

      handle_at_edge(win, pane, key, direction, send_key)
    end),
  }
end

---@return string[]
local function get_move_direction_keys()
  -- check if table format or list format
  if _smart_splits_wezterm_config.direction_keys.move ~= nil then
    return _smart_splits_wezterm_config.direction_keys.move
  end

  return _smart_splits_wezterm_config.direction_keys --[[@as string[] ]]
end

---@return string[]
local function get_resize_direction_keys()
  -- check if table format or list format
  if _smart_splits_wezterm_config.direction_keys.resize ~= nil then
    return _smart_splits_wezterm_config.direction_keys.resize
  end

  return _smart_splits_wezterm_config.direction_keys --[[@as string[] ]]
end

---Apply plugin to Wezterm config.
---@param config_builder table
---@param plugin_config SmartSplitsWeztermConfig|nil
---@return table config_builder the updated config
local function apply_to_config(config_builder, plugin_config)
  -- apply plugin config
  if plugin_config then
    -- applied first so that anything logged below respects the user's log level
    if plugin_config.log_level ~= nil then
      if LogLevels[plugin_config.log_level] then
        _smart_splits_wezterm_config.log_level = plugin_config.log_level
      else
        -- logged before the fallback is applied, while the default level still allows it
        logger.error(
          string.format(
            "[smart-splits.nvim]: invalid log_level '%s', expected 'info', 'warn', or 'error'; "
              .. "falling back to 'info'",
            tostring(plugin_config.log_level)
          )
        )
        _smart_splits_wezterm_config.log_level = 'info'
      end
    end
    _smart_splits_wezterm_config.direction_keys = plugin_config.direction_keys
      or _smart_splits_wezterm_config.direction_keys
    if plugin_config.modifiers then
      _smart_splits_wezterm_config.modifiers.move = plugin_config.modifiers.move
        or _smart_splits_wezterm_config.modifiers.move
      _smart_splits_wezterm_config.modifiers.resize = plugin_config.modifiers.resize
        or _smart_splits_wezterm_config.modifiers.resize
    end
    if plugin_config.default_amount then
      _smart_splits_wezterm_config.default_amount = plugin_config.default_amount
    end
    if plugin_config.at_edge ~= nil then
      if type(plugin_config.at_edge) == 'function' or AtEdgeValues[plugin_config.at_edge] then
        _smart_splits_wezterm_config.at_edge = plugin_config.at_edge
      else
        logger.error(
          string.format(
            "[smart-splits.nvim]: invalid at_edge value '%s', expected 'stop', 'wrap', 'split', "
              .. "or a function; falling back to 'stop'",
            tostring(plugin_config.at_edge)
          )
        )
        _smart_splits_wezterm_config.at_edge = 'stop'
      end
    end
  end

  local keymaps = {}
  for idx, key in ipairs(get_move_direction_keys()) do
    table.insert(keymaps, split_nav('move', key, Directions[idx]))
  end
  for idx, key in ipairs(get_resize_direction_keys()) do
    table.insert(keymaps, split_nav('resize', key, Directions[idx]))
  end

  if config_builder.keys == nil then
    config_builder.keys = keymaps
  else
    for _, keymap in ipairs(keymaps) do
      table.insert(config_builder.keys, keymap)
    end
  end
  return config_builder
end

return {
  apply_to_config = apply_to_config,
  is_vim = is_vim,
}
