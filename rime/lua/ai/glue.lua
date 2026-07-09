-- ai/glue.lua — AI 候选 daemon 客户端共享层（D-17 / D-18 / D-20）
-- 职责：unix socket 连接管理、非阻塞收发、结果缓存、协议编解码。
-- 热路径约束（D-19 预算制）：本模块所有对外函数除 wait() 外必须非阻塞（µs 级）。
-- 协议 v1.2（NDJSON）见 services/candidate-daemon/README.md。

local json = require("vendor.json")

local M = {
  enabled = nil,     -- 三态：nil 未初始化 / false 环境不可用（永久关） / true 可用
  sock = nil,
  rxbuf = "",
  next_retry = 0,
  cache = {},        -- key → { order = {文本…}, t = 时间 }
  cache_n = 0,
  pending = {},      -- key → 发起时间（防重复请求）
  activity = false,  -- 本会话是否发生过显式请求（供 filter 在开关关闭时判断是否仍需 drain）
  seq = 0,
}

local CACHE_MAX = 64
local PENDING_TTL = 8      -- 秒：在途请求超期后允许重发
local RETRY_COOLDOWN = 2   -- 秒：连接失败后的重试冷却

-- 环境初始化：只做一次；任何一步失败则本进程内永久禁用（输入体验回退为原生）
function M.setup()
  if M.enabled ~= nil then return M.enabled end
  M.enabled = false
  -- 关键前置：librime 以 RTLD_LOCAL 加载插件，需先把 liblua5.4 符号提升为全局
  -- （依据与约束见 docs/design/ai-daemon.md §5）
  pcall(package.loadlib, "/lib/x86_64-linux-gnu/liblua5.4.so.0", "*")
  local extra_cpath = os.getenv("RIME_AI_LUASOCKET_CPATH")  -- 测试钩子：staging 下指向本地提取副本
  if extra_cpath then package.cpath = extra_cpath .. ";" .. package.cpath end
  local ok_s, socket = pcall(require, "socket")
  if not ok_s then return false end
  local ok_u, unix = pcall(require, "socket.unix")
  if not ok_u then return false end
  M.socket, M.unix = socket, unix
  M.sock_path = os.getenv("RIME_AI_SOCKET")
    or ((os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/rime-candidate-daemon.sock")
  M.enabled = true
  return true
end

local function now()
  return M.socket.gettime()
end

local function close_sock()
  if M.sock then
    pcall(function() M.sock:close() end)
    M.sock = nil
    M.rxbuf = ""
  end
end

local function connect()
  if M.sock then return M.sock end
  local t = now()
  if t < M.next_retry then return nil end
  local mk = (type(M.unix) == "table" and M.unix.stream) or M.unix
  local ok, s = pcall(mk)
  if not ok or not s then
    M.next_retry = t + RETRY_COOLDOWN
    return nil
  end
  -- UDS connect 在内核内同步完成（实测 ~20µs）；5ms 上限仅是保险
  s:settimeout(0.005)
  local ok_c = s:connect(M.sock_path)
  if not ok_c then
    pcall(function() s:close() end)
    M.next_retry = t + RETRY_COOLDOWN
    return nil
  end
  s:settimeout(0)
  M.sock = s
  M.rxbuf = ""
  return s
end

local function send_line(line)
  if not M.setup() then return false end
  local s = connect()
  if not s then return false end
  local ok = s:send(line .. "\n")
  if not ok then
    -- 短行几乎不会部分写入；任何异常直接重置连接，等冷却后重连
    close_sock()
    M.next_retry = now() + RETRY_COOLDOWN
    return false
  end
  return true
end

local function put_cache(key, texts)
  if M.cache_n >= CACHE_MAX then
    M.cache = {}
    M.cache_n = 0
  end
  if not M.cache[key] then M.cache_n = M.cache_n + 1 end
  M.cache[key] = { texts = texts, t = now() }
  M.pending[key] = nil
end

local function handle_line(line)
  local ok, obj = pcall(json.decode, line)
  if ok and type(obj) == "table" and obj.key and type(obj.cands) == "table" then
    put_cache(obj.key, obj.cands)
  end
end

-- 非阻塞收包：把 daemon 已回的结果全部收进缓存（每次调用上限 8 条）
function M.drain()
  if not M.setup() then return end
  local s = M.sock or connect()
  if not s then return end
  for _ = 1, 8 do
    local data, err, partial = s:receive("*l")
    if data then
      handle_line(M.rxbuf .. data)
      M.rxbuf = ""
    else
      if partial and #partial > 0 then M.rxbuf = M.rxbuf .. partial end
      if err == "closed" then close_sock() end
      break
    end
  end
end

function M.get(key)
  return M.cache[key]
end

-- 当前时刻（秒，浮点）；环境不可用时恒 0（调用方的时间窗判断随之退化为直通）
function M.now()
  if not M.setup() then return 0 end
  return now()
end

-- 已选定前缀文本（选定首词后的剩余段场景）：
-- preedit = 已选文本 + 当前段原始拼音（含音节分隔），剥掉尾部 ascii 拼音串即得前缀。
-- 前缀以 ascii 词结尾（如选定英文候选）时会被一并剥掉——损失的只是提示语境，无正确性影响。
function M.selected_prefix(ctx)
  local ok, text = pcall(function()
    local pe = ctx:get_preedit()
    return pe and pe.text
  end)
  if not ok or type(text) ~= "string" then return "" end
  return (text:gsub("[%a%s']*$", ""))
end

-- 发起候补请求（非阻塞、防重复）；explicit=true 走 daemon 快车道（跳过去抖）
-- 并标记本会话已有显式活动；prefix 为已选定前缀文本（可空）。
function M.request(key, pinyin, cand_texts, explicit, prefix)
  if not M.setup() then return false end
  if M.cache[key] then return true end
  local p = M.pending[key]
  if p and now() - p < PENDING_TTL then return true end
  if #cand_texts == 0 then return false end
  M.seq = M.seq + 1
  local ok = send_line(json.encode({
    op = "suggest", id = M.seq, key = key, pinyin = pinyin, cands = cand_texts,
    explicit = explicit or nil,
    prefix = (prefix and #prefix > 0) and prefix or nil,
  }))
  if ok then
    M.pending[key] = now()
    if explicit then M.activity = true end
  end
  return ok
end

-- 上屏文本通报（会话上下文来源，fire-and-forget）
function M.commit(text)
  if not M.setup() then return end
  send_line(json.encode({ op = "commit", text = text }))
end

-- 有界等待某个 key 的结果（仅触发键路径使用；budget 单位秒）
function M.wait(key, budget)
  if M.cache[key] then return M.cache[key] end
  if not M.setup() then return nil end
  local s = M.sock or connect()
  if not s then return nil end
  local deadline = now() + budget
  s:settimeout(0.02)
  while now() < deadline do
    local data, err, partial = s:receive("*l")
    if data then
      handle_line(M.rxbuf .. data)
      M.rxbuf = ""
      if M.cache[key] then break end
    else
      if partial and #partial > 0 then M.rxbuf = M.rxbuf .. partial end
      if err == "closed" then
        close_sock()
        break
      end
      -- timeout：继续等下一片
    end
  end
  if M.sock then M.sock:settimeout(0) end
  return M.cache[key]
end

return M
