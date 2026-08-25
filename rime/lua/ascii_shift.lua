-- ascii_shift.lua — 左 Shift 点按切换中英（D-26）
-- 复原 D-24 前 ascii_composer 的 Shift_L: commit_code：翻转 ascii_mode；
-- 组词中 ClearNonConfirmed + Commit。超时 500ms（与 librime 默认一致）。
-- 仅左 Shift 维持中按下其它键才打断；松开超时不切。右 Shift / Caps 不切。
-- ascii_composer 的 Shift_* 与 Caps_Lock 必须为 noop。
-- 返回 kNoop：不吞修饰键，Shift+字母仍打大写。
-- 热路径：非左 Shift 且未武装时立刻返回（D-19）。

local kNoop = 2
local XK_Shift_L = 0xffe1
local TAP_S = 0.5

local M = {}

function M.init(env)
  env.shift_pending = false
  env.shift_expired = 0
end

-- 墙钟：优先已加载的 luasocket；否则 /proc/uptime。os.clock 是 CPU 时间，不能测点按。
local function wall_now()
  local socket = package.loaded.socket
  if type(socket) == "table" and socket.gettime then
    return socket.gettime()
  end
  local f = io.open("/proc/uptime", "r")
  if f then
    local line = f:read("*l")
    f:close()
    local n = line and tonumber(line:match("^[0-9.]+"))
    if n then return n end
  end
  return os.clock()
end

local function toggle_commit_code(ctx)
  local to_ascii = not ctx:get_option("ascii_mode")
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
      if env.shift_pending and wall_now() < env.shift_expired then
        toggle_commit_code(env.engine.context)
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

  -- 仅 Shift 按住期间的其它键按下打断；其它键松开不打断
  if env.shift_pending and not key_event:release() then
    env.shift_pending = false
  end
  return kNoop
end

return M
