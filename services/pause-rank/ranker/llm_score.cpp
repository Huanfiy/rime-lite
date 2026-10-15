// 候选打分器：对每个候选 c 计算 log P(c | prefix + ctx)。
// 与上次请求的 head 求公共前缀复用 KV；head 新增 token 与全部候选 token 合并为一次前向。
// stdin  JSONL: {"id":..,"prefix":"..","ctx":"..","cands":["..",..]}
// stdout JSONL: {"id":..,"scores":[..],"ntok":[..],"n_head":..,"n_head_dec":..,"n_tok":..,"t_ms":..}
// 用法: llm_score <model.gguf> <n_threads> [max_cands=40] [n_ctx=4096]
#include "llama.h"
#include <nlohmann/json.hpp>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <string>
#include <vector>

using json = nlohmann::json;
using clk = std::chrono::steady_clock;

static std::vector<llama_token> tokenize(const llama_vocab* vocab, const std::string& s) {
  if (s.empty()) return {};
  int n = -llama_tokenize(vocab, s.data(), (int)s.size(), nullptr, 0, false, false);
  std::vector<llama_token> out(n);
  llama_tokenize(vocab, s.data(), (int)s.size(), out.data(), n, false, false);
  return out;
}

static double ms_since(clk::time_point t0) {
  return std::chrono::duration<double, std::milli>(clk::now() - t0).count();
}

// 对一行 logits 做 log-softmax 后取 tok 的值
static float logprob(const float* logits, int n_vocab, llama_token tok) {
  float mx = logits[0];
  for (int i = 1; i < n_vocab; i++) mx = std::max(mx, logits[i]);
  double sum = 0;
  for (int i = 0; i < n_vocab; i++) sum += std::exp(logits[i] - mx);
  return logits[tok] - mx - (float)std::log(sum);
}

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <model.gguf> <n_threads> [max_cands] [n_ctx]\n", argv[0]);
    return 2;
  }
  int n_threads = atoi(argv[2]);
  int max_cands = argc > 3 ? atoi(argv[3]) : 40;

  llama_log_set([](ggml_log_level lvl, const char* txt, void*) {
    if (lvl >= GGML_LOG_LEVEL_ERROR) fputs(txt, stderr);
  }, nullptr);
  llama_backend_init();
  llama_model* model = llama_model_load_from_file(argv[1], llama_model_default_params());
  if (!model) return 1;
  const llama_vocab* vocab = llama_model_get_vocab(model);
  const int n_vocab = llama_vocab_n_tokens(vocab);

  llama_context_params cp = llama_context_default_params();
  cp.n_ctx = argc > 4 ? atoi(argv[4]) : 4096;
  cp.n_batch = 1024;
  cp.n_ubatch = 512;
  cp.n_seq_max = max_cands + 1;
  cp.n_threads = n_threads;
  cp.n_threads_batch = n_threads;
  cp.kv_unified = true;
  cp.no_perf = true;
  llama_context* ctx = llama_init_from_model(model, cp);
  if (!ctx) return 1;
  llama_memory_t mem = llama_get_memory(ctx);
  llama_batch batch = llama_batch_init(cp.n_batch, 0, cp.n_seq_max);

  std::vector<llama_token> cached;  // seq 0 当前已解码的 head
  const size_t JOINT_MAX = 256;     // 与候选同批解码的 head 新增 token 上限，超出部分先单独解码

  auto add = [&](llama_token t, llama_pos p, const std::vector<llama_seq_id>& sids, bool out) {
    int k = batch.n_tokens++;
    batch.token[k] = t;
    batch.pos[k] = p;
    batch.n_seq_id[k] = (int)sids.size();
    for (size_t s = 0; s < sids.size(); s++) batch.seq_id[k][s] = sids[s];
    batch.logits[k] = out;
    return k;
  };

  std::string line;
  while (std::getline(std::cin, line)) {
    if (line.empty()) continue;
    json req = json::parse(line);
    std::string prefix = req.value("prefix", "");
    std::string ctxs = req.value("ctx", "");
    std::vector<std::string> cands = req["cands"].get<std::vector<std::string>>();
    if ((int)cands.size() > max_cands) cands.resize(max_cands);

    // head = tok(prefix) + tok(ctx)，分开分词以保证 prefix 段 token 稳定、可复用 KV
    std::vector<llama_token> head = tokenize(vocab, prefix);
    auto ct = tokenize(vocab, ctxs);
    head.insert(head.end(), ct.begin(), ct.end());
    if (head.empty()) head = tokenize(vocab, "\n");

    auto t0 = clk::now();
    // 1) 与缓存求最长公共前缀；至少重解码最后一个 token 以取得其 logits
    size_t common = 0;
    while (common < cached.size() && common < head.size() && cached[common] == head[common]) common++;
    if (common == head.size()) common--;
    llama_memory_seq_rm(mem, 0, (llama_pos)common, -1);
    const int n_dec = (int)(head.size() - common);
    while (head.size() - common > JOINT_MAX) {  // 超长 head 的前段：仅 seq 0，不出 logits
      batch.n_tokens = 0;
      for (; head.size() - common > JOINT_MAX && batch.n_tokens < (int)cp.n_batch; common++)
        add(head[common], (llama_pos)common, {0}, false);
      if (llama_decode(ctx, batch) != 0) { fprintf(stderr, "decode head failed\n"); return 1; }
    }

    // 2) 单次前向：head 新增 token 同属 seq 0 与所有多 token 候选的 seq；候选 token 各占一个 seq
    const llama_pos H = (llama_pos)head.size();
    std::vector<std::vector<llama_token>> ctoks(cands.size());
    std::vector<double> scores(cands.size(), 0.0);
    std::vector<std::vector<int>> out_idx(cands.size());
    std::vector<llama_seq_id> sids = {0};
    for (size_t c = 0; c < cands.size(); c++) {
      ctoks[c] = tokenize(vocab, cands[c]);
      if (ctoks[c].size() < 2) continue;
      llama_seq_id sid = (llama_seq_id)(c + 1);
      llama_memory_seq_rm(mem, sid, -1, -1);
      llama_memory_seq_cp(mem, 0, sid, -1, -1);  // 复用 [0, common) 的前缀 KV
      sids.push_back(sid);
    }
    batch.n_tokens = 0;
    int head_out = -1;
    for (size_t i = common; i < head.size(); i++)
      head_out = add(head[i], (llama_pos)i, sids, i == head.size() - 1);
    for (size_t c = 0; c < cands.size(); c++)
      for (size_t j = 0; j + 1 < ctoks[c].size(); j++)  // 末 token 无需输出 logits
        out_idx[c].push_back(add(ctoks[c][j], H + (llama_pos)j, {(llama_seq_id)(c + 1)}, true));
    if (llama_decode(ctx, batch) != 0) { fprintf(stderr, "decode failed\n"); return 1; }
    const float* hl = llama_get_logits_ith(ctx, head_out);
    for (size_t c = 0; c < cands.size(); c++) {
      if (ctoks[c].empty()) { scores[c] = -INFINITY; continue; }
      scores[c] = logprob(hl, n_vocab, ctoks[c][0]);
      for (size_t j = 0; j < out_idx[c].size(); j++)
        scores[c] += logprob(llama_get_logits_ith(ctx, out_idx[c][j]), n_vocab, ctoks[c][j + 1]);
    }
    for (size_t s = 1; s < sids.size(); s++) llama_memory_seq_rm(mem, sids[s], -1, -1);
    cached = head;
    const double t_ms = ms_since(t0);

    json resp;
    resp["id"] = req.value("id", json());
    resp["scores"] = scores;
    std::vector<int> ntok;
    for (auto& v : ctoks) ntok.push_back((int)v.size());
    resp["ntok"] = ntok;
    resp["n_head"] = head.size();
    resp["n_head_dec"] = n_dec;
    resp["n_tok"] = batch.n_tokens;
    resp["t_ms"] = t_ms;
    std::cout << resp.dump() << std::endl;
  }
  llama_batch_free(batch);
  llama_free(ctx);
  llama_model_free(model);
  return 0;
}
