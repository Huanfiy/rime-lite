-- pause_rank/processor.lua — 停顿重排（D-30）：私有键处理
-- 热路径：非私有键只做一次 keycode 比较即返回 kNoop。
-- F33（停顿）：取当前段同跨度汉字候选 + 上屏历史窗口，写 req（插件读走转发给打分服务）。
-- F34（回包）：读 res，校验版本 / 段身份 / 高亮未动，记录提升并刷新组句，filter 按记录重排。

local C = require("pause_rank.common")
local json = require("vendor.json")

local kAccepted, kNoop = 1, 2
local WIN = 80   -- 上文窗口步长：长度保持 [WIN, 2·WIN)，起点每 WIN 字前移，打分端 KV 前缀可复用

local M = {}

local function push_hist(env, text)
  pcall(function()
    for _, cp in utf8.codes(text) do env.hist[#env.hist + 1] = utf8.char(cp) end
  end)
  local n = #env.hist
  if n > 4 * WIN then
    local drop = (n - 2 * WIN) // WIN * WIN
    table.move(env.hist, drop + 1, n, 1)
    for i = n - drop + 1, n do env.hist[i] = nil end
    env.base = env.base + drop
  end
end

local function window(env)
  local total = env.base + #env.hist
  local start = total < 2 * WIN and 0 or (total - WIN) // WIN * WIN
  return table.concat(env.hist, "", math.max(start - env.base, 0) + 1, #env.hist)
end

-- 已选定前缀（选定首词后的剩余段）：preedit 剥掉尾部拼音
local function selected_prefix(ctx)
  local ok, text = pcall(function() return ctx:get_preedit().text end)
  if not ok or type(text) ~= "string" then return "" end
  return (text:gsub("[%a%s']*$", ""))
end

local function write_file(path, data)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(data)
  f:close()
  return os.rename(tmp, path)
end

local function snap(ctx, env)
  if not ctx:is_composing() then return end
  local comp = ctx.composition
  if comp:empty() then return end
  local seg = comp:back()
  if seg.selected_index ~= 0 or not seg.menu then return end
  local s, e = seg.start, seg._end
  local key = C.seg_key(ctx.input, s, e)
  if ctx:get_property(C.P_KEY) == key then return end   -- 本段已按当前上文重排过
  local menu = seg.menu
  menu:prepare(C.MAX_SCAN)
  local cands = {}
  for i = 0, math.min(menu:candidate_count(), C.MAX_SCAN) - 1 do
    local c = menu:get_candidate_at(i)
    if c and c.start == s and c._end == e and c.type ~= "ai" and C.is_han(c.text) then
      cands[#cands + 1] = c.text
      if #cands >= C.MAX_CANDS then break end
    end
  end
  if #cands < 2 then return end
  env.ver = env.ver + 1
  env.pending = { ver = env.ver, key = key, cands = cands }
  local text = window(env) .. (s > 0 and selected_prefix(ctx) or "")
  write_file(C.DIR .. "/req", json.encode({ ver = env.ver, ctx = text, cands = cands }))
end

local function apply(ctx, env)
  local p = env.pending
  env.pending = nil
  local path = C.DIR .. "/res"
  local f = io.open(path, "r")
  if not f then return end
  local line = f:read("l") or ""
  f:close()
  os.remove(path)
  local ver, best = line:match("^(%d+)\t(%d+)")
  ver, best = tonumber(ver), tonumber(best)
  if not p or ver ~= p.ver or not best or best < 1 then return end
  local text = p.cands[best + 1]
  if not text then return end
  local comp = ctx.composition
  if comp:empty() then return end
  local seg = comp:back()
  if seg.selected_index ~= 0 or C.seg_key(ctx.input, seg.start, seg._end) ~= p.key then return end
  ctx:set_property(C.P_TEXT, text)
  ctx:set_property(C.P_KEY, p.key)
  ctx:refresh_non_confirmed_composition()
end

function M.init(env)
  env.hist, env.base, env.ver = {}, 0, 0
  env.conn = env.engine.context.commit_notifier:connect(function(ctx)
    if ctx:get_property(C.P_KEY) ~= "" then ctx:set_property(C.P_KEY, "") end
    local ok, text = pcall(function() return ctx:get_commit_text() end)
    if ok and text and #text > 0 then push_hist(env, text) end
  end)
end

function M.fini(env)
  if env.conn then env.conn:disconnect() end
end

function M.func(key, env)
  local kc = key.keycode
  if kc ~= C.K_SNAP and kc ~= C.K_APPLY then return kNoop end
  if not key:release() then
    local ok, err = pcall(kc == C.K_SNAP and snap or apply, env.engine.context, env)
    if not ok then log.error("pause_rank: " .. tostring(err)) end
  end
  return kAccepted
end

return M
