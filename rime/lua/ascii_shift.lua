-- ascii_shift.lua — 左 Shift 按下即英、右 Shift 按下即中（D-24）
-- ascii_composer 的 Shift_* 必须为 noop，否则松开时会再切一次。
-- 返回 kNoop：不吞修饰键，已在目标模式时 Shift+字母仍可打大写。
-- 热路径：非左右 Shift 立刻返回（D-19）。

local kNoop = 2
local XK_Shift_L = 0xffe1
local XK_Shift_R = 0xffe2

local M = {}

function M.func(key_event, env)
  if key_event:release() then return kNoop end
  if key_event:ctrl() or key_event:alt() or key_event:super() then return kNoop end

  local code = key_event.keycode
  if code ~= XK_Shift_L and code ~= XK_Shift_R then return kNoop end

  local ctx = env.engine.context
  if code == XK_Shift_L then
    if not ctx:get_option("ascii_mode") then
      -- 与原 Shift_L: commit_code 一致：未确认段上屏编码再切英
      if ctx:is_composing() then
        ctx:clear_non_confirmed_composition()
        ctx:commit()
      end
      ctx:set_option("ascii_mode", true)
    end
  else
    if ctx:get_option("ascii_mode") then
      if ctx:is_composing() then
        ctx:clear()
      end
      ctx:set_option("ascii_mode", false)
    end
  end
  return kNoop
end

return M
