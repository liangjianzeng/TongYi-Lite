// [npu-line] M2 KV bridge A5: hybrid decode executor.
// Loads the same GGUF, injects a (possibly bridged) kv state file via
// llama_state_seq_load_file, then greedy-decodes from a given first token
// (the NPU head argmax in the hybrid path; the golden first_tok in controls).
// Usage: hyb_load -m model.gguf -s state.bin -t <first_tok> [-g 64] [-n 512] [-p 0]
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <vector>
#include "llama.h"

static void die(const char * m) { fprintf(stderr, "FAIL: %s\n", m); exit(1); }

int main(int argc, char ** argv) {
    const char *model = nullptr, *statef = nullptr;
    int n = 512, ngreedy = 64, ngl = 99; llama_pos p0 = 0;
    llama_token first = -1;
    for (int i = 1; i < argc - 1; i++) {
        if (!strcmp(argv[i], "-m")) model = argv[++i];
        else if (!strcmp(argv[i], "-s")) statef = argv[++i];
        else if (!strcmp(argv[i], "-t")) first = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-n")) n = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-g")) ngreedy = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-p")) p0 = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-ngl")) ngl = atoi(argv[++i]);
    }
    if (!model || !statef || first < 0) die("-m -s -t required");
    setbuf(stdout, nullptr);

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = ngl;
    llama_model * m = llama_model_load_from_file(model, mp);
    if (!m) die("model load");
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = (uint32_t)(n + ngreedy + 64);
    cp.n_batch = (uint32_t)n;
    llama_context * ctx = llama_init_from_model(m, cp);
    if (!ctx) die("ctx init");

    std::vector<llama_token> tk(n);
    size_t loaded = 0;
    // [decode-tps 口径判例 2026-11-13] 计时一律 wall（ggml_time_ms）：clock()=
    // 进程 CPU 时间总和，OpenCL 驱动 spin 线程的 CPU 会被计入 → tps 被低估
    // ~40%（6.26 vs 真值 10+，三臂对照 vkl simple 10.27 / fork 库+simple 10.23
    // / fork hyb_load 6.26 定罪）。llama_perf 同为 wall 口径。
    double tload0 = (double)ggml_time_ms();
    size_t r = llama_state_seq_load_file(ctx, statef, 0, tk.data(), n, &loaded);
    if (r == 0) die("state load");
    double tload = (double)ggml_time_ms() - tload0;
    llama_pos nextpos = llama_memory_seq_pos_max(llama_get_memory(ctx), 0) + 1;
    printf("STATE_LOADED tokens=%zu next_pos=%lld load_ms=%.0f\n", loaded, (long long)nextpos, tload);

    const llama_vocab * vocab = llama_model_get_vocab(m);
    int nv = (int)llama_vocab_n_tokens(vocab);
    const char * logdir = nullptr;
    for (int i = 1; i < argc - 1; i++) if (!strcmp(argv[i], "-L")) logdir = argv[++i];
    FILE * lgf = logdir ? fopen(logdir, "wb") : nullptr;
    std::vector<uint16_t> lbuf(nv);
    llama_token t = first;
    llama_seq_id s0 = 0;
    double t0 = (double)ggml_time_ms(); // wall, 同 tload0 口径（clock() 判例见上）
    double tfirst = -1;
    for (int i = 0; i < ngreedy; i++) {
        // zero-init token-only batch: compat layer auto-derives pos from
        // memory_seq_pos_max (already correct after state load) and seq 0
        llama_batch nb = {};
        nb.token = &t;
        nb.n_tokens = 1;
        if (llama_decode(ctx, nb) != 0) die("decode");
        const float * l = llama_get_logits_ith(ctx, 0);
        if (lgf) {
            for (int j = 0; j < nv; j++) *(__fp16 *)&lbuf[j] = (__fp16)l[j];
            fwrite(lbuf.data(), 2, nv, lgf);
        }
        int best = 0;
        for (int j = 1; j < nv; j++) if (l[j] > l[best]) best = j;
        t = best;
        if (i == 0) {
            double tf = (double)ggml_time_ms() - t0;
            printf("FIRST_TOK_MS %.0f (state+step0 decode)\n", tf);
        }
        printf("T %d %d\n", i, t);
        // no eog break: forced decoding keeps the compare series full length
    }
    double dt = ((double)ggml_time_ms() - t0) / 1e3;
    printf("HYB_DECODE tps=%.2f secs=%.2f\n", ngreedy / (dt > 0 ? dt : 1), dt);
    printf("LOAD_TOOL_DONE\n");
    llama_free(ctx); llama_model_free(m);
    return 0;
}
