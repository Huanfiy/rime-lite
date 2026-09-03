-- ascii_shift.lua — 左 Shift 点按或 Ctrl+Space 切换中英（D-28）
-- Shift 点按超时 500ms（与 librime 默认一致）；Ctrl+Space 在按下时切换。
-- 组词中切模式：ClearNonConfirmed + Commit。
-- 仅左 Shift 维持中按下其它键才打断（不切）。
-- 右 Shift / Caps 不切。ascii_composer 的 Shift_* 与 Caps_Lock 必须为 noop。
-- Shift 返回 kNoop，不吞修饰键；Ctrl+Space 返回 kAccepted，不输入空格。
-- 热路径：非左 Shift / Space 且未武装时立刻返回（D-19）。

local kAccepted, kNoop = 1, 2
local XK_space = 0x20
local XK_Shift_L = 0xffe1
local TAP_S = 0.5

local M = {}

function M.init(env)
  env.shift_pending = false
  env.shift_expired = 0
  env.ctrl_space_down = false
end

-- 墙钟：读 /proc/uptime（10ms 分辨率，仅在 Shift_L 按下 / 松开时调用）。
-- os.clock 是 CPU 时间不能测点按；不借用 luasocket，避免与 ai/ 模块的加载顺序耦合。
local function wall_now()
  local f = io.open("/proc/uptime", "r")
  if f then
    local line = f:read("*l")
    f:close()
    local n = line and tonumber(line:match("^[0-9.]+"))
    if n then return n end
  end
  return os.clock()
end

local function toggle_ascii_mode(ctx)
  local to_ascii = not ctx:get_option("ascii_mode")
  if ctx:is_composing() then
    ctx:clear_non_confirmed_composition()
    ctx:commit()
  end
  ctx:set_option("ascii_mode", to_ascii)
end

function M.func(key_event, env)
  local code = key_event.keycode

  if code == XK_space then
    if key_event:release() then
      if env.ctrl_space_down then
        env.ctrl_space_down = false
        return kAccepted
      end
    elseif key_event:ctrl() and not key_event:shift()
        and not key_event:alt() and not key_event:super() then
      env.shift_pending = false
      if not env.ctrl_space_down then
        toggle_ascii_mode(env.engine.context)
        env.ctrl_space_down = true
      end
      return kAccepted
    end
  end

  if code == XK_Shift_L then
    if key_event:release() then
      local now = wall_now()
      if env.shift_pending and now < env.shift_expired then
        toggle_ascii_mode(env.engine.context)
      end
      env.shift_pending = false
      return kNoop
    end
    if key_event:ctrl() or key_event:alt() or key_event:super() then
      env.shift_pending = false
      return kNoop
    end
    -- 首次按下武装；重复按下不刷新超时（与 librime ascii_composer 一致）
    if not env.shift_pending then
      env.shift_pending = true
      env.shift_expired = wall_now() + TAP_S
    end
    return kNoop
  end

  if not env.shift_pending then return kNoop end

  -- 按住期间其它键按下：打断本击
  if not key_event:release() then
    env.shift_pending = false
  end
  return kNoop
end

return M
