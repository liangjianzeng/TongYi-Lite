// [TongYi-Lite 2026-10-27 R-061] ling_e2e：通用文本贪心解码探针（跨机型/跨代 H2′ 复验用）。
// 动机：minicpm_e2e 绑 MiniCPM 35B（设备端缺模型）；K40 存量 Ling-3.0-tiny-Q4_0 + qwen2.5-0.5b
//       可做 **非 830 设备** 的 async 乱码复现与 NDRANGE_IDLE 默认档验证 → 竞态是否跨代。
// 协议对齐 minicpm_e2e 读数面：贪心(temp=0,seed 固定)、stdout 纯 token 字节（md5 判据）、
//       stderr 打 [e2e][METRIC] leg=decode gen=N wall_ms=X tok_s=Y load_ms=Z（grep 'tok_s='）。
// 用法：ling_e2e <model.gguf> <npred> <ngl> <seed> "prompt"
#include "llama.h"
#include "ggml.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <chrono>

// [tongyi 1028 R-120 解剖刀] SIGILL/SIGSEGV 取证：backtrace 落 stderr（无缓冲），
// 崩溃不再吞进度。E2E_LOADONLY=1 只加载即退（分相定位）。零扰动：不改任何推理路径。
#include <csignal>
#if !defined(__BIONIC__)
#include <execinfo.h>   // [gemm_plan 1028] NDK android-28 无 execinfo: bionic 崩溃行走 tombstone 补栈
#endif
#include <unistd.h>
static void tyl_crash(int sig, siginfo_t * si, void * uc) {
    (void)uc;
    char b[128];
    int n = snprintf(b, sizeof(b), "\n[e2e][CRASH] sig=%d addr=%p\n", sig, (void *)si->si_addr);
    ssize_t w = write(2, b, n); (void)w;
#if !defined(__BIONIC__)
    void * frames[64];
    int f = backtrace(frames, 64);
    backtrace_symbols_fd(frames, f, 2);
#endif
    _exit(100 + sig);
}

int main(int argc, char ** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    { struct sigaction sa; memset(&sa, 0, sizeof(sa)); sa.sa_sigaction = tyl_crash;
      sa.sa_flags = SA_SIGINFO; sigaction(SIGILL, &sa, nullptr); sigaction(SIGSEGV, &sa, nullptr);
      sigaction(SIGBUS, &sa, nullptr); }
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
    fprintf(stderr, "[e2e][PHASE] model_loaded\n");
    llama_context_params cp = llama_context_default_params();
    const int nctx = (argc > 6) ? atoi(argv[6]) : 1024;
    cp.n_ctx = nctx; cp.n_batch = nctx < 512 ? nctx : 512; (void)seed; // 贪心 argmax 与 seed 无关
    // [tongyi 1027] E2E_NB: ubatch 覆盖（split-MoE in-place 的 prefill 唯一专家数控制：
    // runtime 抛 "requires more than N unique experts in one graph; reduce ubatch"——
    // 唯一专家数 ~ chunk × n_expert_used，chunk 即本值。默认不设=旧行为逐字节不变。）
    { const char * e_nb = getenv("E2E_NB"); if (e_nb && e_nb[0]) { cp.n_batch = atoi(e_nb); fprintf(stderr, "[e2e] E2E_NB ubatch=%d\n", cp.n_batch); } }
    llama_context * ctx = llama_init_from_model(model, cp);
    if (!ctx) { fprintf(stderr, "CTX_FAIL\n"); return 4; }
    fprintf(stderr, "[e2e][PHASE] ctx_ready\n");
    // [tongyi 1028 R-122] 分相点后移到 ctx 之后：opencl 核编译/装载发生在 ctx 期，
    // 停在 model_loaded 会漏测整个 kernel 面（N_DST 案教训）。
    if (const char * lo = getenv("E2E_LOADONLY"); lo && *lo) {
        llama_free(ctx); llama_model_free(model);
        fprintf(stderr, "[e2e][PHASE] loadonly_done\n");
        return 0;
    }

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
    // [gemm_plan ledger-222] prefill 计时出口 + 3K agent prompt 分块 decode:
    // 单批 n>n_batch 撞 llama-context.cpp:1944 PROBE 腿血案(830 实录 rc=134), 与 app
    // 线同款分块姿势(E2E_NB=块宽)。纯增 stderr METRIC 行, tok 零扰动。
    auto t_pf0 = std::chrono::steady_clock::now();
    int pf_rc = 0; int last_cnt = n;
    for (int i = 0; i < n && pf_rc == 0; i += cp.n_batch) {
        last_cnt = (n - i < cp.n_batch) ? (n - i) : cp.n_batch;
        llama_batch bc = llama_batch_get_one(toks.data() + i, last_cnt);
        pf_rc = llama_decode(ctx, bc);
    }
    auto t_pf1 = std::chrono::steady_clock::now();
    if (pf_rc != 0) { fprintf(stderr, "PREFILL_FAIL\n"); return 6; }
    // greedy sample via logits last-token
    float * logits = llama_get_logits_ith(ctx, last_cnt - 1);
    if (lgf) fwrite(logits, 4, lg_nv, lgf);
    int best = 0; float bv = logits[0];
    for (int i = 1; i < (int)llama_vocab_n_tokens(vocab); ++i) if (logits[i] > bv) { bv = logits[i]; best = i; }
    { // [vkh R-129] prefill argmax 无条件一行尸检: NaN 是否 prefill 期已染(分叉共享权重面 vs decode 核)
        long nz = 0; double asum = 0.0;
        const int n_t = (int)llama_vocab_n_tokens(vocab);
        for (int i = 0; i < n_t; ++i) { if (logits[i] == 0.0f) ++nz; asum += std::fabs(logits[i]); }
        fprintf(stderr, "[e2e][ARGMAX] gen=PRE id=%d val=%.5f zeros=%ld/%d absum=%.3f\n",
                best, bv, nz, n_t, asum);
    }
    llama_token next = best;
    {
        double pf_ms = std::chrono::duration<double, std::milli>(t_pf1 - t_pf0).count();
        fprintf(stderr, "[e2e][METRIC] leg=prefill device=probe n_prompt=%d pf_ms=%.0f prefill_tok_s=%.2f\n",
                n, pf_ms, pf_ms > 0 ? n * 1000.0 / pf_ms : 0.0);
    }

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
        { // [vkh R-126] 轻量 argmax 指纹：定罪 logits 全零/未写回（'!'×N 假说）——log-only 无 dump
            static const bool amdbg = getenv("E2E_ARGMAX_DEBUG") != nullptr;
            if (amdbg) {
                long nz = 0; double asum = 0.0;
                const int n_t = (int)llama_vocab_n_tokens(vocab);
                for (int i = 0; i < n_t; ++i) { if (logits[i] == 0.0f) ++nz; asum += std::fabs(logits[i]); }
                fprintf(stderr, "[e2e][ARGMAX] gen=%d id=%d val=%.5f zeros=%ld/%d absum=%.3f\n",
                        gen, best, bv, nz, n_t, asum);
            }
        }
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
