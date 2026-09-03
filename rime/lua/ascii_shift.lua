-- ascii_shift.lua — 左 Shift 单击切 ASCII、快速双击切中（D-27）
-- 点按超时 500ms（与 librime 默认一致）；双击窗口 400ms（首击松开 → 次击松开）。
-- 组词中切模式：ClearNonConfirmed + Commit。已在目标模式则保持。
-- 仅左 Shift 维持中按下其它键才打断（不切）；单击后其它键取消双击窗口。
-- 右 Shift / Caps 不切。ascii_composer 的 Shift_* 与 Caps_Lock 必须为 noop。
-- 返回 kNoop：不吞修饰键，Shift+字母仍打大写。
-- 热路径：非左 Shift 且未武装、无双击窗口时立刻返回（D-19）。

local kNoop = 2
local XK_Shift_L = 0xffe1
local TAP_S = 0.5
local DOUBLE_S = 0.4

local M = {}

function M.init(env)
  env.shift_pending = false
  env.shift_expired = 0
  env.double_armed = false
  env.double_expired = 0
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

local function set_ascii_mode(ctx, to_ascii)
  if ctx:get_option("ascii_mode") == to_ascii then return end
  if ctx:is_composing() then
    ctx:clear_non_confirmed_composition()
    ctx:commit()
  end
  ctx:set_option("ascii_mode", to_ascii)
end

function M.func(key_event, env)
  local code = key_event.keycode

  if code == XK_Shift_L then
    if key_event:release() then
      local now = wall_now()
      if env.shift_pending and now < env.shift_expired then
        if env.double_armed and now < env.double_expired then
          set_ascii_mode(env.engine.context, false)
          env.double_armed = false
        else
          set_ascii_mode(env.engine.context, true)
          env.double_armed = true
          env.double_expired = now + DOUBLE_S
        end
      else
        env.double_armed = false
      end
      env.shift_pending = false
      return kNoop
    end
    if key_event:ctrl() or key_event:alt() or key_event:super() then
      env.shift_pending = false
      env.double_armed = false
      return kNoop
    end
    -- 首次按下武装；重复按下不刷新超时（与 librime ascii_composer 一致）
    if not env.shift_pending then
      env.shift_pending = true
      env.shift_expired = wall_now() + TAP_S
    end
    return kNoop
  end

  if not env.shift_pending and not env.double_armed then return kNoop end

  -- 按住期间其它键按下：打断本击；单击后其它键：取消双击窗口
  if not key_event:release() then
    env.shift_pending = false
    env.double_armed = false
  end
  return kNoop
end

return M
