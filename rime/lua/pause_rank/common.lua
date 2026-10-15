-- pause_rank/common.lua — 停顿重排（D-30）共享常量与工具；结构见 docs/design/pause-rank.md

local M = {}

-- 私有键：由 fcitx5 插件 pauserank 在主循环里直接注入当前 IC（不经应用，未消费也不会外泄）
M.K_SNAP = 0xFFDE    -- F33：停顿时注入 → processor 写候选快照 req
M.K_APPLY = 0xFFDF   -- F34：打分回包且需改首选时注入 → processor 读 res、刷新组句

M.DIR = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/rime-pause-rank"

-- 会话内已生效的提升（processor 写、filter 读；上屏时清空）
M.P_KEY = "pause_rank_key"     -- 段身份：输入串@段起点-段终点
M.P_TEXT = "pause_rank_text"   -- 提升到同跨度首位的候选文本

M.MAX_SCAN = 60    -- 快照 / 重排扫描的菜单深度
M.MAX_CANDS = 16   -- 送打分的同跨度汉字候选上限（与 P0 测评口径一致）

function M.seg_key(input, s, e)
  return input .. "@" .. s .. "-" .. e
end

-- 全汉字（基本区，与 P0 测评口径一致）
function M.is_han(s)
  local ok, r = pcall(function()
    local n = 0
    for _, cp in utf8.codes(s) do
      if cp < 0x4E00 or cp > 0x9FFF then return false end
      n = n + 1
    end
    return n > 0
  end)
  return ok and r
end

return M
