-- ai/trigger.lua — AI 候补触发键 processor（D-17 / D-18 / D-21）
-- 纯触发式（D-21）下这里是 AI 候补的唯一请求入口：不按触发键，零上云。
-- 两拍契约：组词状态下按触发键（默认 Tab，仅组词时拦截，其余场景 Tab 行为不变）——
--   缓存命中 → 强制刷新组句，suggest filter 注入候补，即时展示；
--   未命中   → 发请求（daemon 直达并发槽）并有界等待（默认 250ms），
--              到点未回则在预编辑区亮「⚡…」提示，约一个 API 周期后再按即命中。
--   长按触发键 = 轮询收割：自动重复的键事件逐次收包查缓存，结果落地即展示；
--   有界等待带 1s 冷却，重复事件只做 µs 级查表，不会积压事件队列。
-- 键位取自 schema 的 ai_suggest/trigger_key；Tab 的原音节导航绑定已在 default.yaml 让位。

local glue = require("ai.glue")

local kAccepted, kNoop = 1, 2

local WAIT_COOLDOWN = 1.0  -- 秒：两次有界等待的最小间隔（长按轮询时退化为纯查表）

local M = {}

function M.init(env)
  local cfg = env.engine.schema.config
  env.trigger_key = cfg:get_string("ai_suggest/trigger_key") or "Tab"
  env.wait_s = (cfg:get_int("ai_suggest/trigger_wait_ms") or 250) / 1000
  env.top_k = cfg:get_int("ai_suggest/top_k") or 8
  env.min_len = cfg:get_int("ai_suggest/min_length") or 1
  env.next_wait_ok = 0
end

-- 与 suggest.lua 的 cache_key 保持一致
local function cache_key(raw, seg_start)
  return raw .. "@" .. tostring(seg_start)
end

local function menu_snapshot(ctx, top_k)
  -- 从当前组句菜单取候选文本（作为请求的本地机械转换参考）
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

-- 未命中反馈：在当前段亮提示，让「生成中」可见（下一次按键 / 刷新自然清除）。
-- 仅改 Segment.prompt，不动候选与输入串；fcitx5 每键后重绘预编辑区即可带出。
local function show_pending_prompt(ctx)
  pcall(function()
    local comp = ctx.composition
    if not comp:empty() then comp:back().prompt = " ⚡…" end
  end)
end

function M.func(key_event, env)
  local ctx = env.engine.context
  if key_event:release() or not ctx:is_composing() then return kNoop end
  if key_event:repr() ~= env.trigger_key then return kNoop end

  local raw = ctx.input
  if not raw or #raw == 0 then return kNoop end
  -- 低于注入下限：保持吞键（组词中 Tab 不外泄），但不发请求
  if #raw < env.min_len then return kAccepted end

  glue.drain()

  local snap = menu_snapshot(ctx, env.top_k)
  local seg_start = (snap and snap.start) or 0
  local key = cache_key(raw, seg_start)
  local entry = glue.get(key)
  if not entry then
    if snap and #snap.texts > 0 then
      glue.request(key, raw:sub(seg_start + 1), snap.texts,
                   seg_start > 0 and glue.selected_prefix(ctx) or "")
    end
    -- 有界等待只兜「即将落地」的结果；长按重复触发时受冷却限制，退化为纯轮询
    local t = glue.now()
    if t >= env.next_wait_ok then
      env.next_wait_ok = t + WAIT_COOLDOWN
      entry = glue.wait(key, env.wait_s)
    end
  end
  if entry then
    ctx:refresh_non_confirmed_composition()
  else
    show_pending_prompt(ctx)
  end
  return kAccepted
end

return M
