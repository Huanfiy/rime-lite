-- ai/suggest.lua — AI 智能候补 filter（D-17 / D-18 / D-20）
-- 职责：把 daemon 生成的候补（当前段转换 + 延伸预测，不受本地词库限制）注入候选栏首位，
--       本地候选原样跟随（与 AI 候补重文时由 uniquifier 消重）。
-- 热路径（每键执行）：收包 → 查缓存 → 注入候补 → 发预取，全程非阻塞。
-- 阈值分离（D-20）：注入 / 触发键下限 = min_length（默认 4）；
--                   自动预取下限 = auto_min_length（默认 6，短词本地词库已足够快）。
-- 开关语义：ai_suggest 开 = 自动预取；关 = 仅触发键显式请求（trigger.lua），
--           但缓存一旦存在（显式请求产生）仍会被应用。

local glue = require("ai.glue")

local M = {}

local MAX_INSERT = 3   -- 注入的 AI 候补上限

function M.init(env)
  local cfg = env.engine.schema.config
  env.top_k = cfg:get_int("ai_suggest/top_k") or 8
  env.min_len = cfg:get_int("ai_suggest/min_length") or 4
  env.auto_min_len = cfg:get_int("ai_suggest/auto_min_length") or 6
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
  local auto = ctx:get_option("ai_suggest")
  -- 早退：无输入 / 长度不足，或「自动预取关闭且本会话无显式活动」
  if not raw or #raw < env.min_len or (not auto and not glue.activity) then
    for cand in input:iter() do yield(cand) end
    return
  end

  glue.drain()

  local prefetch = auto and #raw >= env.auto_min_len

  -- 注意执行模型：本函数是惰性候选流的一环，前端每页只拉 5 个候选，
  -- 流通常不会耗尽——预取与注入必须在首个 yield 之前完成决策，
  -- 循环结束后的代码只在候选不足 top_k（流耗尽）时才会运行。
  local head, texts, key, rem = {}, {}, nil, raw
  local n, emitted = 0, false
  for cand in input:iter() do
    if not emitted then
      n = n + 1
      head[n] = cand
      texts[n] = cand.text
      if n == 1 then
        key = cache_key(raw, cand.start)
        rem = raw:sub(cand.start + 1)   -- 当前翻译段拼音（选定首词后为剩余段）
      end
      if n >= env.top_k then
        -- 头部收齐（发生在首个候选被拉取时）：先发预取，再注入 AI 候补并吐出头部
        if prefetch then
          glue.request(key, rem, texts, false,
                       head[1].start > 0 and glue.selected_prefix(ctx) or "")
        end
        local entry = glue.get(key)
        if entry then yield_ai(entry, head[1]) end
        for _, c in ipairs(head) do yield(c) end
        emitted = true
      end
    else
      yield(cand)
    end
  end
  if not emitted and key then
    -- 候选不足 top_k：流已尽，此处统一预取、注入并吐出
    if prefetch then
      glue.request(key, rem, texts, false,
                   head[1].start > 0 and glue.selected_prefix(ctx) or "")
    end
    local entry = glue.get(key)
    if entry then yield_ai(entry, head[1]) end
    for _, c in ipairs(head) do yield(c) end
  end
end

return M
