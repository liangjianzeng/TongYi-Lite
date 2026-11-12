// [npu-line] M2 KV bridge A1: golden state extractor.
// Loads a GGUF (Q4_K_M), encodes n tokens from a binary ids file (int32 LE),
// saves the kv state via llama_state_seq_save_file, then greedy-decodes ntok
// tokens and prints them (the pure-GPU reference series).
// Usage: hyb_save -m model.gguf -f ids.raw -o state.bin [-n 512] [-g 64] [-p 0]
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <vector>
#include "llama.h"

static void die(const char * m) { fprintf(stderr, "FAIL: %s\n", m); exit(1); }
static void mark(int s) { fprintf(stderr, "[MARK %d]\n", s); fflush(stderr); }
static void quiet(ggml_log_level, const char *, void *) {}

int main(int argc, char ** argv) {
    const char *model = nullptr, *idsf = nullptr, *statef = nullptr;
    int n = 512, ngreedy = 64; llama_pos p0 = 0; int ngl = 99;
    for (int i = 1; i < argc - 1; i++) {
        if (!strcmp(argv[i], "-m")) model = argv[++i];
        else if (!strcmp(argv[i], "-f")) idsf = argv[++i];
        else if (!strcmp(argv[i], "-o")) statef = argv[++i];
        else if (!strcmp(argv[i], "-n")) n = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-g")) ngreedy = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-p")) p0 = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-ngl")) ngl = atoi(argv[++i]);
    }
    if (!model || !idsf || !statef) die("-m -f -o required");
    setbuf(stdout, nullptr);  // unbuffered: crash must not eat printed lines
    std::vector<llama_token> ids(n);
    FILE * f = fopen(idsf, "rb");
    if (!f || fread(ids.data(), sizeof(llama_token), n, f) != (size_t)n) die("ids read");
    fclose(f);

    llama_log_set(quiet, nullptr);
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = ngl;
    llama_model * m = llama_model_load_from_file(model, mp);
    if (!m) die("model load");
    mark(1);
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = (uint32_t)(n + ngreedy + 64);
    cp.n_batch = (uint32_t)n;
    llama_context * ctx = llama_init_from_model(m, cp);
    if (!ctx) die("ctx init");

    // prompt = encode
    std::vector<llama_seq_id> seq0(1, 0);
    std::vector<llama_seq_id *> seqs(n, seq0.data());
    std::vector<int32_t> nseq(n, 1);
    std::vector<llama_pos> pos(n);
    std::vector<int8_t> logit(n, 0);
    for (int i = 0; i < n; i++) pos[i] = p0 + i;
    logit[n - 1] = 1;
    llama_batch b{ n, ids.data(), nullptr, pos.data(), nseq.data(), seqs.data(), logit.data() };
    mark(2);
    // NOTE: use decode (not encode) for the prompt — encode is the embedding/encoder
    // path (output_all semantics) and crashes the unified-KV graph here. cli/bench precedent.
    if (llama_decode(ctx, b) != 0) die("prefill decode");
    mark(3);
    const float * lg = llama_get_logits_ith(ctx, n - 1);
    if (!lg) die("no logits");
    int nv = (int)llama_vocab_n_tokens(llama_model_get_vocab(m));
    int best = 0;
    for (int i = 1; i < nv; i++) if (lg[i] > lg[best]) best = i;
    mark(35);
    printf("PREFILL_DONE n=%d first_tok=%d\n", n, best);
    if (!llama_state_seq_save_file(ctx, statef, 0, ids.data(), n)) die("state save");
    mark(4);
    printf("STATE_SAVED %s\n", statef);

    // greedy continuation (pure-GPU reference series)
    const char * logdir = nullptr;
    for (int i = 1; i < argc - 1; i++) if (!strcmp(argv[i], "-L")) logdir = argv[++i];
    FILE * lgf = logdir ? fopen(logdir, "wb") : nullptr;
    int nvocab = (int)llama_vocab_n_tokens(llama_model_get_vocab(m));
    std::vector<uint16_t> lbuf(nvocab);
    llama_token tk = best;
    llama_seq_id s0 = 0;
    for (int i = 0; i < ngreedy; i++) {
        // same construction as llama-simple: zero-init, token-only,
        // pos/seq auto-derived by compat layer (manual poking of the static
        // arrays inside batch_get_one is not supported by the new compat path)
        llama_batch nb = {};
        nb.token = &tk;
        nb.n_tokens = 1;
        if (llama_decode(ctx, nb) != 0) die("decode");
        if (i == 0) mark(5);
        const float * l2 = llama_get_logits_ith(ctx, 0);
        if (lgf) {
            for (int j = 0; j < nvocab; j++)
                *(__fp16 *)&lbuf[j] = (__fp16)l2[j];
            fwrite(lbuf.data(), 2, nvocab, lgf);
        }
        int best2 = 0;
        for (int j = 1; j < nv; j++) if (l2[j] > l2[best2]) best2 = j;
        tk = best2;
        printf("T %d %d\n", i, tk);
        // no eog break: forced decoding keeps the compare series full length
    }
    printf("SAVE_TOOL_DONE\n");
    llama_free(ctx); llama_model_free(m);
    return 0;
}
