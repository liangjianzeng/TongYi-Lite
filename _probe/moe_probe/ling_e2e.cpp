// [TongYi-Lite 2026-10-27 R-061] ling_e2e：通用文本贪心解码探针（跨机型/跨代 H2′ 复验用）。
// 动机：minicpm_e2e 绑 MiniCPM 35B（设备端缺模型）；K40 存量 Ling-3.0-tiny-Q4_0 + qwen2.5-0.5b
//       可做 **非 830 设备** 的 async 乱码复现与 NDRANGE_IDLE 默认档验证 → 竞态是否跨代。
// 协议对齐 minicpm_e2e 读数面：贪心(temp=0,seed 固定)、stdout 纯 token 字节（md5 判据）、
//       stderr 打 [e2e][METRIC] leg=decode gen=N wall_ms=X tok_s=Y load_ms=Z（grep 'tok_s='）。
// 用法：ling_e2e <model.gguf> <npred> <ngl> <seed> "prompt"
#include "llama.h"
#include "ggml.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <chrono>

int main(int argc, char ** argv) {
    if (argc < 5) { fprintf(stderr, "usage: ling_e2e model npred ngl seed [prompt]\n"); return 2; }
    const char * model_path = argv[1];
    const int npred = atoi(argv[2]);
    const int ngl   = atoi(argv[3]);
    const int seed  = atoi(argv[4]);
    std::string prompt = (argc > 5) ? argv[5]
        : "请详细介绍一下中国的四大发明，分别说明历史背景与技术要点，分四段展开。";

    ggml_backend_load_all();
    auto t0 = std::chrono::steady_clock::now();
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = ngl;
    llama_model * model = llama_model_load_from_file(model_path, mp);
    if (!model) { fprintf(stderr, "LOAD_FAIL\n"); return 3; }
    auto t1 = std::chrono::steady_clock::now();

    llama_context_params cp = llama_context_default_params();
    const int nctx = (argc > 6) ? atoi(argv[6]) : 1024;
    cp.n_ctx = nctx; cp.n_batch = nctx < 512 ? nctx : 512; (void)seed; // 贪心 argmax 与 seed 无关
    llama_context * ctx = llama_init_from_model(model, cp);
    if (!ctx) { fprintf(stderr, "CTX_FAIL\n"); return 4; }

    // X4 logit 面（R-072）：E2E_LOGITDUMP=<path> 时逐 argmax 站点 dump 全量 fp32 logits。
    // 铁律：探针=放大器——tok 输出必须零扰动；dump 只做只读 fwrite。
    FILE * lgf = nullptr;
    { const char * lgpath = getenv("E2E_LOGITDUMP"); if (lgpath && *lgpath) lgf = fopen(lgpath, "wb"); }
    const size_t lg_nv = (size_t)llama_vocab_n_tokens(llama_model_get_vocab(model));

    auto vocab = llama_model_get_vocab(model);
    std::vector<llama_token> toks(8 + prompt.size());
    int n = llama_tokenize(vocab, prompt.c_str(), (int)prompt.size(), toks.data(), (int)toks.size(), true, false);
    if (n < 1) { fprintf(stderr, "TOK_FAIL\n"); return 5; }
    toks.resize(n);

    // prefill
    llama_batch b = llama_batch_get_one(toks.data(), n);
    if (llama_decode(ctx, b) != 0) { fprintf(stderr, "PREFILL_FAIL\n"); return 6; }
    // greedy sample via logits last-token
    float * logits = llama_get_logits_ith(ctx, n - 1);
    if (lgf) fwrite(logits, 4, lg_nv, lgf);
    int best = 0; float bv = logits[0];
    for (int i = 1; i < (int)llama_vocab_n_tokens(vocab); ++i) if (logits[i] > bv) { bv = logits[i]; best = i; }
    llama_token next = best;

    auto t2 = std::chrono::steady_clock::now();
    std::string text;
    char buf[256];
    int gen = 0;
    for (; gen < npred; ++gen) {
        if (llama_vocab_is_eog(vocab, next)) break;
        int len = llama_token_to_piece(vocab, next, buf, sizeof(buf), 0, true);
        if (len > 0) text.append(buf, len);
        std::vector<llama_token> one = { next };
        llama_batch b1 = llama_batch_get_one(one.data(), 1);
        if (llama_decode(ctx, b1) != 0) { fprintf(stderr, "DECODE_FAIL@%d\n", gen); break; }
        logits = llama_get_logits_ith(ctx, 0);
        if (lgf) fwrite(logits, 4, lg_nv, lgf);
        best = 0; bv = logits[0];
        for (int i = 1; i < (int)llama_vocab_n_tokens(vocab); ++i) if (logits[i] > bv) { bv = logits[i]; best = i; }
        next = best;
    }
    if (lgf) { fclose(lgf); lgf = nullptr; }
    auto t3 = std::chrono::steady_clock::now();
    double load_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    double wall_ms = std::chrono::duration<double, std::milli>(t3 - t2).count();
    fwrite(text.data(), 1, text.size(), stdout);
    fflush(stdout);
    fprintf(stderr, "[e2e][METRIC] leg=decode gen=%d wall_ms=%.0f tok_s=%.2f load_ms=%.0f\n",
            gen, wall_ms, gen * 1000.0 / (wall_ms > 0 ? wall_ms : 1), load_ms);
    llama_free(ctx); llama_model_free(model);
    return 0;
}
