-- ascii_shift.lua — 左 Shift 按下即英、Caps 点按即中（D-24 / D-25）
-- 右 Shift 不再切中英（D-25）。本机 XKB caps:ctrl_modifier 下 Caps 仍发
-- Caps_Lock keysym，同时叠 Control：点按切中，按住作 Ctrl 不切。
-- ascii_composer 的 Shift_* 与 Caps_Lock 必须为 noop。
-- 返回 kNoop：不吞修饰键；已在英文时左 Shift+字母仍打大写；
-- 拼音下右 Shift+字母打大写。
-- 热路径：非 Caps / 非左 Shift 立刻返回（D-19）；仅 Caps 点按武装期内看后续键。

local kNoop = 2
local XK_Shift_L = 0xffe1
local XK_Caps_Lock = 0xffe5

local M = {}

function M.init(env)
  env.caps_pending = false
  env.caps_chord = false
end

local function to_chinese(ctx)
  if not ctx:get_option("ascii_mode") then return end
  if ctx:is_composing() then
    ctx:clear()
  end
  ctx:set_option("ascii_mode", false)
end

function M.func(key_event, env)
  local code = key_event.keycode

  if code == XK_Caps_Lock then
    if key_event:release() then
      if env.caps_pending then
        to_chinese(env.engine.context)
      end
      env.caps_pending = false
      env.caps_chord = false
      return kNoop
    end
    -- down / repeat：和弦后的 Caps 重复不得重新武装点按
    if not env.caps_chord then
      env.caps_pending = true
    end
    return kNoop
  end

  if env.caps_pending and not key_event:release() then
    env.caps_pending = false
    env.caps_chord = true
  end

  if key_event:release() then return kNoop end
  if key_event:ctrl() or key_event:alt() or key_event:super() then return kNoop end
  if code ~= XK_Shift_L then return kNoop end

  local ctx = env.engine.context
  if not ctx:get_option("ascii_mode") then
    -- 与原 Shift_L: commit_code 一致：未确认段上屏编码再切英
    if ctx:is_composing() then
      ctx:clear_non_confirmed_composition()
      ctx:commit()
    end
    ctx:set_option("ascii_mode", true)
  end
  return kNoop
end

return M
