-- ai/suggest.lua — AI 智能候补 filter（D-17 / D-18 / D-21）
-- 职责：把 daemon 生成的候补（当前段转换 + 延伸预测，不受本地词库限制）注入候选栏首位，
--       本地候选原样跟随（与 AI 候补重文时由 uniquifier 消重）。
-- 纯触发式（D-21）：请求只由触发键（trigger.lua）发出，本 filter 不预取——
-- 热路径（每键执行）仅做：收包 → 查缓存 → 命中则注入，全程非阻塞。
-- 会话无显式活动（本次会话从未按过触发键）时直通透传，连 socket 都不碰。
-- 另承担上屏通报（commit_notifier → daemon 会话上下文，仅进本机内存）。

local glue = require("ai.glue")

local M = {}

local MAX_INSERT = 3   -- 注入的 AI 候补上限

function M.init(env)
  local cfg = env.engine.schema.config
  env.min_len = cfg:get_int("ai_suggest/min_length") or 1
  -- 上屏通报：作为 daemon 会话上下文（「懂我」与延伸预测的语境来源）
  env.commit_conn = env.engine.context.commit_notifier:connect(function(ctx)
    local ok, text = pcall(function() return ctx:get_commit_text() end)
    if ok and text and #text > 0 then glue.commit(text) end
  end)
end

function M.fini(env)
  if env.commit_conn then env.commit_conn:disconnect() end
end

-- 缓存键：原始输入串 + 当前翻译段起点（区分「整句」与「选定首词后的剩余段」）
-- 与 trigger.lua 的 cache_key 保持一致
local function cache_key(raw, seg_start)
  return raw .. "@" .. tostring(seg_start)
end

-- 注入 AI 候补：以首个本地候选的分段范围为准，选中即整段替换上屏
local function yield_ai(entry, base)
  local n = 0
  for _, text in ipairs(entry.texts or {}) do
    if type(text) == "string" and #text > 0 then
      n = n + 1
      if n > MAX_INSERT then break end
      yield(Candidate("ai", base.start, base._end, text, "⚡"))
    end
  end
end

function M.func(input, env)
  local ctx = env.engine.context
  local raw = ctx.input
  -- 早退：无输入 / 长度不足 / 本会话无显式活动（触发键从未按下 = 零 AI 参与）
  if not raw or #raw < env.min_len or not glue.activity then
    for cand in input:iter() do yield(cand) end
    return
  end

  glue.drain()

  -- 首个候选到达时查缓存：命中则把 AI 候补插在它前面，本地候选原样跟随
  local first = true
  for cand in input:iter() do
    if first then
      first = false
      local entry = glue.get(cache_key(raw, cand.start))
      if entry then yield_ai(entry, cand) end
    end
    yield(cand)
  end
end

return M
