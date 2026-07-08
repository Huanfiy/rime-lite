-- ai/trigger.lua — AI 候补触发键 processor（D-17 / D-18）
-- 行为：组词状态下按触发键（默认 Tab，仅组词时拦截，其余场景 Tab 行为不变）——
--   缓存命中 → 强制刷新组句，suggest filter 注入候补，即时展示；
--   未命中   → 现场发请求并有界等待（默认 250ms），到点未回则吞键无动作，再按一次通常命中。
-- 开关关闭（ai_suggest off）时触发键仍可用 = trigger-only 隐私模式。
-- 键位取自 schema 的 ai_suggest/trigger_key；Tab 的原音节导航绑定已在 default.yaml 让位。

local glue = require("ai.glue")

local kAccepted, kNoop = 1, 2

local M = {}

function M.init(env)
  local cfg = env.engine.schema.config
  env.trigger_key = cfg:get_string("ai_suggest/trigger_key") or "Tab"
  env.wait_s = (cfg:get_int("ai_suggest/trigger_wait_ms") or 250) / 1000
  env.top_k = cfg:get_int("ai_suggest/top_k") or 8
end

-- 与 suggest.lua 的 cache_key 保持一致
local function cache_key(raw, seg_start)
  return raw .. "@" .. tostring(seg_start)
end

local function menu_snapshot(ctx, top_k)
  -- 从当前组句菜单取候选文本（触发键显式路径需要，预取路径不经过这里）
  local ok, ret = pcall(function()
    local comp = ctx.composition
    if comp:empty() then return nil end
    local seg = comp:back()
    local menu = seg.menu
    if not menu then return nil end
    menu:prepare(top_k)
    local count = math.min(menu:candidate_count(), top_k)
    local texts, start = {}, seg.start
    for i = 0, count - 1 do
      local c = menu:get_candidate_at(i)
      if c then texts[#texts + 1] = c.text end
    end
    return { texts = texts, start = start }
  end)
  if ok then return ret end
  return nil
end

function M.func(key_event, env)
  local ctx = env.engine.context
  if key_event:release() or not ctx:is_composing() then return kNoop end
  if key_event:repr() ~= env.trigger_key then return kNoop end

  local raw = ctx.input
  if not raw or #raw == 0 then return kNoop end

  glue.drain()

  local snap = menu_snapshot(ctx, env.top_k)
  local key = cache_key(raw, (snap and snap.start) or 0)
  local entry = glue.get(key)
  if not entry then
    if snap and #snap.texts > 0 then
      glue.request(key, raw, snap.texts, true)
    end
    entry = glue.wait(key, env.wait_s)
  end
  if entry then
    ctx:refresh_non_confirmed_composition()
  end
  return kAccepted
end

return M
