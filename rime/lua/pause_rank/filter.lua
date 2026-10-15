-- pause_rank/filter.lua — 停顿重排（D-30）：按会话记录把打分首选提到同跨度汉字候选首位
-- 热路径：tags_match 不命中（无记录 / 段身份不符）时整个 filter 跳过，不逐候选迭代。
-- 只提升一个候选、其余相对顺序不变；非同跨度候选（英文、短词等）位置不动。

local C = require("pause_rank.common")

local M = {}

function M.tags_match(seg, env)
  local ctx = env.engine.context
  local k = ctx:get_property(C.P_KEY)
  if k == "" or k ~= C.seg_key(ctx.input, seg.start, seg._end) then return false end
  env.text, env.s, env.e = ctx:get_property(C.P_TEXT), seg.start, seg._end
  return true
end

function M.func(input, env)
  local text, s, e = env.text, env.s, env.e
  local function full(c) return c.start == s and c._end == e end
  local buf, done = {}, false
  for cand in input:iter() do
    if done then
      yield(cand)
    elseif cand.text == text and full(cand) then
      local placed = false
      for _, b in ipairs(buf) do
        if not placed and full(b) and C.is_han(b.text) then
          yield(cand)
          placed = true
        end
        yield(b)
      end
      if not placed then yield(cand) end
      done = true
    else
      buf[#buf + 1] = cand
      if #buf >= C.MAX_SCAN then
        for _, b in ipairs(buf) do yield(b) end
        done = true
      end
    end
  end
  if not done then
    for _, b in ipairs(buf) do yield(b) end
  end
end

return M
