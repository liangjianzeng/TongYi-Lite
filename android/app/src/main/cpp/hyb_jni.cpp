/**
 * [npu-line M2 Phase C-2] JNI entries for the hybrid path:
 * NPU (QNN/HTP chain_run5) prefill -> KV bridge -> GPU decode.
 *
 * Companion of tongyilite_jni.cpp (same Java class
 * com.dgxspark.tongyilite.InferenceEngine, same libtongyilite_jni.so).
 * The GPU path in tongyilite_jni.cpp is byte-unchanged (zero-regression red
 * line); the only cross-TU surface is tongyilite_engine.h's single getter.
 *
 * Flow (two MethodChannel steps, structured JSON replies):
 *   1. nativeStartHybridPrefill
 *      - tokenizes prompt/messagesJson through the GPU path's own helpers
 *        (handle->build_prompt_ids) -> real NREAL + ids.raw (no-pad protocol,
 *        plan §6.2: eos-pad cells must be cut);
 *      - stages ids into the chain dir, resets previous chain outputs,
 *        seeds kc0/vc0 (A3b driver semantics);
 *      - launches the chain_run5 segments manifest-serially
 *        (npu-line/probe_m1/dec2/mcp5_95_run_a3b_seq.py is the frozen
 *        device-side reference: LD_LIBRARY_PATH/ADSP_LIBRARY_PATH,
 *        CHAIN_KEEP=1 CR5_ROLL_SAVE=1, wait CR5_DONE per segment, on early
 *        process death collect p{k}.log tail into the reply);
 *      - copies the terminal kc/vc x84 (+ h_l41) into kvDir for the bridge.
 *      App runtime uses the APK-private chain dir (filesDir/npu_m1, staged by
 *      NpuAssets.extract) — /data/local/tmp is noexec for the app uid.
 *   2. nativeBridgeAndResumeDecode
 *      - hyb_kv_bridge_convert (byte-exact vs frozen Python reference,
 *        gated by hyb_kv_bridge_selftest.sh) -> official state container v4;
 *      - llama_state_seq_load_file into the MAIN context (engine claimed via
 *        handle->begin_hybrid — mirrors completion()'s is_running claim);
 *      - first token: NPU head argmax when provided, else the plan §1.3
 *        fallback "GPU 侧重算一步": re-decode the LAST prompt token at its
 *        own pos (explicit batch) and argmax — costs one ~90ms decode, and
 *        that cell gets the GPU-computed row (harmless, self-consistent);
 *      - continuation: greedy argmax with the zero-init token-only batch
 *        (plan §6.2 API discipline: pos/seq auto-derived by the compat layer
 *        from memory_seq_pos_max; recipe = mcp5_95_hyb_load.cpp, but with a
 *        normal stop: eog / user stop / maxTokens, not the bench no-eog
 *        forced decode). Tokens stream through the InferenceCallback, and
 *        the full text is returned in the reply.
 *
 * Device-side layout (C-3 review rework, P0-3):
 *   - d2q feeds (emb/am/cos/sin/kc0/vc0) are generated natively per round
 *     from the loaded GGUF (hyb_feeds.c + feeds_* accessors) — always
 *     regenerated after chain_reset_outputs, never reused across prompts.
 *   - chain_run5 ships as jniLibs libchain_run5_exec.so and the QNN .so
 *     ride jniLibs too (useLegacyPackaging extracts them to
 *     nativeLibraryDir — system_file, the only app-uid-executable location
 *     under the app_data_file noexec policy). chainBin defaults there from
 *     InferenceEngine.kt; cwd stays the writable filesDir chain dir, whose
 *     lib symlink (NpuAssets.extract) resolves chain_run5's
 *     dlopen("./lib/libQnnHtp.so"). Manifests stay in assets -> filesDir.
 *
 * Threading/lifecycle: entries run on the Kotlin single engine executor (same
 * queue as completion/destroy) and additionally claim the engine through
 * handle->begin_hybrid/end_hybrid.
 */

#include <jni.h>
#include <android/log.h>
#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "llama.h"
#include "hyb_kv_bridge.h"
#include "hyb_feeds.h"
#include "tongyilite_engine.h"

/* Cross-TU accessor implemented at the bottom of tongyilite_jni.cpp. */
extern "C" const TongYiLiteEngineHandle *tongyilite_engine_handle(void);

#define LOG_TAG "TongYiLite"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* Serialize hybrid operations (mirrors the engine-executor discipline). */
static std::mutex g_hyb_mu;

/* Chain protocol defaults (chain_run5: <manifest> <steps>; A3b = 4 chunks). */
static const char *const kDefaultManifests =
    "manifest_pre2_A,manifest_pre2_B,manifest_pre2_C";
static const int kDefaultNChunks   = 4;      /* 512-token static shape / 4  */
static const int kDefaultSegMs     = 120000; /* per-segment wall bound       */

/* ===================================================================
 * JSON result assembly (no dependency; same spirit as tongyilite_jni)
 * =================================================================== */

static void json_escape_append(std::string &out, const char *s)
{
    for (; s && *s; s++) {
        unsigned char c = (unsigned char)*s;
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (c < 0x20) {
                    char b[8];
                    snprintf(b, sizeof(b), "\\u%04x", c);
                    out += b;
                } else {
                    out += (char)c;
                }
        }
    }
}

static const char *hyb_code_name(int code)
{
    switch (code) {
        case HYB_OK:              return "HYB_OK";
        case HYB_ERR_NOT_ENABLED: return "HYB_ERR_NOT_ENABLED";
        case HYB_ERR_BAD_PARAM:   return "HYB_ERR_BAD_PARAM";
        case HYB_ERR_IO:          return "HYB_ERR_IO";
        case HYB_ERR_FORMAT:      return "HYB_ERR_FORMAT";
        case HYB_ERR_BUSY:        return "HYB_ERR_BUSY";
        default:                  return "HYB_ERR_INTERNAL";
    }
}

static jstring hyb_json(JNIEnv *env, bool ok, int code,
                        const char *stage, const char *message,
                        const char *extras)
{
    std::string s = "{\"ok\":";
    s += ok ? "true" : "false";
    s += ",\"code\":\"";     s += hyb_code_name(code); s += "\"";
    s += ",\"stage\":\"";    json_escape_append(s, stage); s += "\"";
    s += ",\"message\":\"";  json_escape_append(s, message); s += "\"";
    if (extras) s += extras;
    s += "}";
    return env->NewStringUTF(s.c_str());
}

/* ===================================================================
 * file helpers
 * =================================================================== */

static bool file_exists(const char *path)
{
    struct stat st;
    return path && stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static bool copy_file(const char *from, const char *to)
{
    FILE *in = fopen(from, "rb");
    if (!in) return false;
    FILE *out = fopen(to, "wb");
    if (!out) { fclose(in); return false; }
    char buf[65536];
    size_t got;
    bool ok = true;
    while ((got = fread(buf, 1, sizeof(buf), in)) > 0) {
        if (fwrite(buf, 1, got, out) != got) { ok = false; break; }
    }
    if (ferror(in)) ok = false;
    fclose(in);
    if (fclose(out) != 0) ok = false;
    if (!ok) remove(to);
    return ok;
}

/* Last `max_bytes` of a file (log tails for the reply). */
static std::string read_tail(const char *path, size_t max_bytes)
{
    std::string out;
    FILE *f = fopen(path, "rb");
    if (!f) return out;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    if (sz > 0) {
        size_t take = ((size_t)sz < max_bytes) ? (size_t)sz : max_bytes;
        fseek(f, (long)(sz - (long)take), SEEK_SET);
        out.resize(take);
        if (fread(&out[0], 1, take, f) != take) out.clear();
    }
    fclose(f);
    return out;
}

/* Unlink every regular file in dir whose name starts with prefix. */
static void unlink_prefix(const char *dir, const char *prefix)
{
    DIR *d = opendir(dir);
    if (!d) return;
    size_t plen = strlen(prefix);
    struct dirent *de;
    while ((de = readdir(d)) != nullptr) {
        if (strncmp(de->d_name, prefix, plen) != 0) continue;
        char path[4096];
        snprintf(path, sizeof(path), "%s/%s", dir, de->d_name);
        struct stat st;
        if (stat(path, &st) == 0 && S_ISREG(st.st_mode)) remove(path);
    }
    closedir(d);
}

/* A3b cleanup set (mirror of the frozen driver's rm line).
 *
 * [P0-2 review fix] feeds 全家桶必须一并删：上一回合的 d2q_emb、d2q_am、
 * cos/sin、kc0/vc0 若在，prefill 的缺件检查会直接放行 → 旧 prompt 的 feeds
 * 喂新链，静默吐错文本且不触发 GPU 回退（最坏失效形态）。全删后缺件检查
 * 恒命中，每回合用本回合 ids 重生成。本函数必须在 feeds 检查/生成之前调
 * 用（见 prefill 流程注释）。
 * [P1-5 review fix] p<N>.log 同样 fork 前删：残留的 CR5_DONE 会让本回合
 * run_segment 首轮轮询即判 done（假段秒过）。 */
static void chain_reset_outputs(const char *chainDir)
{
    static const char *const prefixes[] = {
        "d2q_kc_", "d2q_vc_", "d2q_knew_", "d2q_vnew_", "d2q_h_l",
        "d2q_emb_", "d2q_am_",
    };
    for (size_t i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); i++) {
        unlink_prefix(chainDir, prefixes[i]);
    }
    /* 非 d2q_<prefix> 形态的定名件（cos/sin 表与 kc0/vc0 种子） */
    static const char *const exact[] = {
        "d2q_cos_table.raw", "d2q_sin_table.raw", "d2q_kc0.raw", "d2q_vc0.raw",
    };
    for (size_t i = 0; i < sizeof(exact) / sizeof(exact[0]); i++) {
        char path[4096];
        snprintf(path, sizeof(path), "%s/%s", chainDir, exact[i]);
        remove(path);
    }
    /* p<N>.log（前缀 p、中段全数字、.log 后缀） */
    {
        DIR *d = opendir(chainDir);
        if (d) {
            struct dirent *de;
            while ((de = readdir(d)) != nullptr) {
                const char *nm = de->d_name;
                if (nm[0] != 'p' || strstr(nm, ".log") == nullptr) continue;
                bool digits = (nm[1] != '\0');
                for (const char *q = nm + 1; *q && *q != '.'; q++) {
                    if (*q < '0' || *q > '9') { digits = false; break; }
                }
                if (!digits) continue;
                char path[4096];
                snprintf(path, sizeof(path), "%s/%s", chainDir, nm);
                struct stat st;
                if (stat(path, &st) == 0 && S_ISREG(st.st_mode)) remove(path);
            }
            closedir(d);
        }
    }
    /* gate dir (counter files from the 3-process protocol; serial mode
     * never uses it but the driver removes it — mirror). */
    char gate[4096];
    snprintf(gate, sizeof(gate), "%s/gate", chainDir);
    DIR *d = opendir(gate);
    if (d) {
        struct dirent *de;
        while ((de = readdir(d)) != nullptr) {
            if (de->d_name[0] == '.') continue;
            char p[4096];
            snprintf(p, sizeof(p), "%s/%s", gate, de->d_name);
            remove(p);
        }
        closedir(d);
        rmdir(gate);
    }
}

/* A3b seed: fresh per-layer cache files from the zero-filled kc0/vc0. */
static bool chain_seed_kc0(const char *chainDir, int n_layers)
{
    char src[4096], dst[4096];
    for (int i = 0; i < n_layers; i++) {
        snprintf(src, sizeof(src), "%s/d2q_kc0.raw", chainDir);
        snprintf(dst, sizeof(dst), "%s/d2q_kc_%d.raw", chainDir, i);
        if (!copy_file(src, dst)) return false;
        snprintf(src, sizeof(src), "%s/d2q_vc0.raw", chainDir);
        snprintf(dst, sizeof(dst), "%s/d2q_vc_%d.raw", chainDir, i);
        if (!copy_file(src, dst)) return false;
    }
    return true;
}

/* ===================================================================
 * chain_run5 segment launch (frozen semantics: mcp5_95_run_a3b_seq.py)
 * =================================================================== */

struct SegResult {
    bool  done      = false;   /* CR5_DONE seen                       */
    bool  failed    = false;   /* CR5_FAIL seen                       */
    bool  timed_out = false;   /* wall bound hit -> SIGKILL'd           */
    int   exit_code = -1;      /* WEXITSTATUS when exited               */
    bool  exited    = false;   /* process exited (voluntarily or not)  */
    std::string tail;          /* p{k}.log tail                          */
};

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static SegResult run_segment(const char *chainDir, const char *chainBin,
                             const char *qnnLibDir, const char *manifest,
                             int n_chunks, int seg_idx, int timeout_ms)
{
    SegResult r;
    char logPath[4096];
    snprintf(logPath, sizeof(logPath), "%s/p%d.log", chainDir, seg_idx);

    pid_t pid = fork();
    if (pid < 0) {
        r.failed = true;
        r.tail = "fork failed";
        return r;
    }
    if (pid == 0) {
        /* child: cwd = chain dir (chain_run5 dlopens ./lib/libQnnHtp.so and
         * reads manifest/feeds relative to cwd), stdio -> p{k}.log. */
        if (chdir(chainDir) != 0) _exit(127);
        int fd = open(logPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) _exit(126);
        dup2(fd, STDIN_FILENO);
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        if (fd > 2) close(fd);
        char steps[16];
        snprintf(steps, sizeof(steps), "%d", n_chunks);
        std::string ld = std::string("LD_LIBRARY_PATH=") + qnnLibDir;
        // [MC 设备窗口判例 2026-11-12 + 坑 47 复核] ADSP_LIBRARY_PATH 缺失即
        // HTP deviceCreate 0x36b1。两设备配方不同：830 用 '//<dir>;native'
        // （make_fullchain_probe/mcp5_18），**740 用裸绝对路径**（mcp5_93 坑 47
        // 冻结、mcp5_95_run_a3b_seq 同款全绿）。R11 的 '//' 形态在 740 上仍
        // 0x36b1（p0.log 尾行），按本机判例回裸路径。
        std::string ad = std::string("ADSP_LIBRARY_PATH=") + qnnLibDir;
        char *envp[] = {
            (char *)"PATH=/system/bin:/system/xbin",
            (char *)ld.c_str(),
            (char *)ad.c_str(),
            (char *)"CHAIN_KEEP=1",
            (char *)"CR5_ROLL_SAVE=1",
            nullptr,
        };
        char *argv[] = { (char *)chainBin, (char *)manifest, steps, nullptr };
        execve(chainBin, argv, envp);
        _exit(125); /* execve failed (missing binary / not executable) */
    }

    /* parent: poll child + log markers, wall-bound the segment. */
    const double t0 = now_ms();
    bool reaped = false;
    while (!reaped) {
        int status = 0;
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) {
            r.exited = true;
            r.exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
            reaped = true;
        } else if (w < 0) {
            r.failed = true;
            r.tail = "waitpid error";
            reaped = true;
        }

        /* Log markers checked each round even after exit (stdout flushed
         * before exit; tail collected once below). */
        std::string log = read_tail(logPath, 8192);
        if (log.find("CR5_DONE") != std::string::npos) r.done = true;
        if (log.find("CR5_FAIL") != std::string::npos) r.failed = true;

        if (r.done || r.failed) break;
        if (r.exited) {
            /* Process vanished without a marker (crash / SIGKILL).
             * A3b treated "alive==0 && t>8" as gone-failure — mirror. */
            r.failed = true;
            break;
        }
        if (now_ms() - t0 > (double)timeout_ms) {
            kill(pid, SIGKILL);
            waitpid(pid, &status, 0);
            r.timed_out = true;
            r.failed = true;
            break;
        }
        usleep(200 * 1000);
    }
    if (!reaped) { /* marker hit while still resident — reap politely */
        int status = 0;
        kill(pid, SIGTERM);
        for (int i = 0; i < 50; i++) {
            pid_t w = waitpid(pid, &status, WNOHANG);
            if (w == pid) { reaped = true; break; }
            usleep(100 * 1000);
        }
        if (!reaped) { kill(pid, SIGKILL); waitpid(pid, &status, 0); }
        r.exited = true;
        r.exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
    r.tail = read_tail(logPath, 4096);
    return r;
}

/* ===================================================================
 * JNI entry 1/2: NPU prefill (chain_run5) + token staging
 * =================================================================== */

// [MC 设备窗口判例] extern "C" 不可省：本文件是 .cpp，裸 JNIEXPORT 会走 Itanium
// C++ mangling（导出成 ...P7_JNIEnvP8_jobject... 长名）→ Java 侧
// UnsatisfiedLinkError "No implementation found"，且 so 里 grep 符号名还能命中
// （假在场），只有对比 Kotlin 尝试名才见差异。
extern "C" JNIEXPORT jstring JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeStartHybridPrefill(
    JNIEnv *env, jobject /*thiz*/,
    jstring kvDir, jstring idsPath, jstring chainDir, jstring chainBin,
    jstring qnnLibDir, jstring manifestsCsv, jint nChunks,
    jstring prompt, jstring messagesJson, jint nRealCap, jint timeoutMs,
    jboolean feedsOnly)
{
    std::lock_guard<std::mutex> lk(g_hyb_mu);

    auto get = [&](jstring js, char *buf, size_t len) -> const char * {
        if (!js) { buf[0] = '\0'; return nullptr; }
        const char *c = env->GetStringUTFChars(js, NULL);
        if (!c) { buf[0] = '\0'; return nullptr; }
        snprintf(buf, len, "%s", c);
        env->ReleaseStringUTFChars(js, c);
        return buf;
    };
    char kv[4096], ids[4096], cdir[4096], cbin[4096], qlib[4096], mans[4096];
    const char *kvp   = get(kvDir, kv, sizeof(kv));
    const char *idp   = get(idsPath, ids, sizeof(ids));
    const char *cdp   = get(chainDir, cdir, sizeof(cdir));
    const char *cbp   = get(chainBin, cbin, sizeof(cbin));
    const char *qlp   = get(qnnLibDir, qlib, sizeof(qlib));
    const char *mnp   = get(manifestsCsv, mans, sizeof(mans));
    const char *promptC = nullptr;
    char promptBuf[16384];
    if (prompt) {
        const char *pc = env->GetStringUTFChars(prompt, NULL);
        if (pc) { snprintf(promptBuf, sizeof(promptBuf), "%s", pc);
                  env->ReleaseStringUTFChars(prompt, pc); promptC = promptBuf; }
    }

    if (!kvp || !kvp[0] || !idp || !idp[0] || !cdp || !cdp[0]) {
        return hyb_json(env, false, HYB_ERR_BAD_PARAM, "prefill_param",
                        "kvDir/idsPath/chainDir required", NULL);
    }
    const char *chainBinPath = (cbp && cbp[0]) ? cbp : nullptr;
    std::string chainBinStr;
    if (!chainBinPath) {
        chainBinStr = std::string(cdir) + "/chain_run5";
        chainBinPath = chainBinStr.c_str();
    }
    std::string qlibStr;
    if (!qlp || !qlp[0]) {
        qlibStr = std::string(cdir) + "/lib";
        qlp = qlibStr.c_str();
    }
    if (nChunks <= 0) nChunks = kDefaultNChunks;
    const int segMs = (timeoutMs > 0) ? (int)timeoutMs : kDefaultSegMs;
    const int cap = (nRealCap > 0 && nRealCap <= HYB_NC_DEFAULT)
                    ? (int)nRealCap : HYB_NC_DEFAULT;

    const TongYiLiteEngineHandle *h = tongyilite_engine_handle();
    if (!h || !h->is_loaded()) {
        return hyb_json(env, false, HYB_ERR_BAD_PARAM, "prefill_engine",
                        "model not loaded — hybrid prefill needs the GGUF "
                        "resident (tokenizer + later state load)", NULL);
    }

    /* [P0-4 review fix] fail-closed before the chain: the frozen state
     * container is written F16 and llama_state_seq_load_file hard-validates
     * the context cache type — a q4_0/q8_0 context (the App default is
     * q4_0) can never load it. Bail with HYB_ERR_NOT_ENABLED now instead of
     * burning ~40s x 3 segments and only then failing state_load. */
    if (!h->kv_cache_type || h->kv_cache_type() != TONGYI_KV_CACHE_F16) {
        char msg[192];
        snprintf(msg, sizeof(msg),
                 "engine KV cache selector=%d (need %d=f16) — the hybrid "
                 "state container is F16; switch kv cache type to f16",
                 h->kv_cache_type ? h->kv_cache_type() : -1,
                 TONGYI_KV_CACHE_F16);
        return hyb_json(env, false, HYB_ERR_NOT_ENABLED, "prefill_kvtype",
                        msg, NULL);
    }

    /* ---- ④ tokenize through the GPU path's own helpers ---- */
    std::vector<int32_t> idsBuf((size_t)cap);
    const int n = h->build_prompt_ids((void *)env, messagesJson, promptC,
                                      idsBuf.data(), cap);
    if (n == -2) {
        return hyb_json(env, false, HYB_ERR_NOT_ENABLED, "prefill_template_gate",
                        "chatml-route only (clover/bailing/nanbeige gate) — "
                        "C-3 parity item; falling back to GPU path", NULL);
    }
    if (n <= 0) {
        char msg[96];
        snprintf(msg, sizeof(msg), "build_prompt_ids failed (%d)", n);
        return hyb_json(env, false, HYB_ERR_BAD_PARAM, "prefill_tokenize",
                        msg, NULL);
    }
    const int n_real = n; /* protocol-level REAL token count (no-pad, §6.2) */

    /* ---- stage ids: dart-owned work file (no-pad, bridge authority) +
     * chain cwd copy. [P2-8 review fix] the chain copy follows the A3b
     * frozen protocol: full NC=512 entries, eos-padded (the batch judge
     * validated the whole line with 512-entry ids.raw). The pad id comes
     * from the model GGUF's own tokenizer.ggml.eos_token_id — absent is a
     * structured failure, never a guessed 1. The bridge keeps reading the
     * dart work file (real no-pad tokens, §6.2 cell-cut protocol). ---- */
    int32_t eos_pad = -1;
    if (!h->feeds_eos_id || h->feeds_eos_id(&eos_pad) != 0 || eos_pad < 0) {
        return hyb_json(env, false, HYB_ERR_FORMAT, "prefill_ids",
                        "tokenizer.ggml.eos_token_id absent in model GGUF — "
                        "chain ids pad (A3b 512-entry protocol) cannot be "
                        "derived; refusing to guess", NULL);
    }
    {
        FILE *f = fopen(ids, "wb");
        if (!f || fwrite(idsBuf.data(), 4, (size_t)n_real, f) != (size_t)n_real) {
            if (f) { fclose(f); remove(ids); }
            return hyb_json(env, false, HYB_ERR_IO, "prefill_ids",
                            "cannot write ids.raw", NULL);
        }
        fclose(f);
        char cids[4096];
        snprintf(cids, sizeof(cids), "%s/ids.raw", cdir);
        std::vector<int32_t> padded((size_t)HYB_NC_DEFAULT, eos_pad);
        memcpy(padded.data(), idsBuf.data(),
               sizeof(int32_t) * (size_t)n_real);
        FILE *cf = fopen(cids, "wb");
        if (!cf || fwrite(padded.data(), 4, (size_t)HYB_NC_DEFAULT, cf) !=
                   (size_t)HYB_NC_DEFAULT) {
            if (cf) { fclose(cf); remove(cids); }
            return hyb_json(env, false, HYB_ERR_IO, "prefill_ids",
                            "cannot stage padded ids.raw into chain dir", NULL);
        }
        fclose(cf);
    }

    /* ---- chain dir sanity (assets extraction + staged feeds) ----
     * [m3shell] feedsOnly（App 自带 adb 通道派 shell 域跑链）时本进程不碰
     * chain/QNN —— App 域 exec/dlopen 判死（§7.6bis 域墙），这些检查无意义。 */
    if (!feedsOnly && !file_exists(chainBinPath)) {
        return hyb_json(env, false, HYB_ERR_IO, "prefill_bin",
                        "chain_run5 binary missing (expect "
                        "nativeLibraryDir/libchain_run5_exec.so from jniLibs "
                        "install; chainBin override honored)", NULL);
    }
    char htp[4096];
    snprintf(htp, sizeof(htp), "%s/libQnnHtp.so", qlp);
    if (!feedsOnly && !file_exists(htp)) {
        return hyb_json(env, false, HYB_ERR_IO, "prefill_qnn_lib",
                        "QNN libQnnHtp.so missing under qnnLibDir — "
                        "jniLibs install/extract failed?", NULL);
    }
    /* [P0-2 review fix] reset 前移到 feeds 检查之前：d2q feeds 与 p*.log
     * 现在也在删除集里，若还留在生成之后会把刚生成的本回合 feeds 删掉、
     * 并让 seed 找不到 d2q_kc0.raw。删除集不含 ids.raw / manifest，前移
     * 对它们无影响；同时天然满足 P1-5「fork 前删日志」。 */
    chain_reset_outputs(cdir);
    {
        char missing[512] = "";
        static const char *const feeds[] = {
            "d2q_emb_0.raw", "d2q_emb_1.raw", "d2q_emb_2.raw", "d2q_emb_3.raw",
            "d2q_am_0.raw",  "d2q_am_1.raw",  "d2q_am_2.raw",  "d2q_am_3.raw",
            "d2q_cos_table.raw", "d2q_sin_table.raw",
            "d2q_kc0.raw", "d2q_vc0.raw",
        };
        for (size_t i = 0; i < sizeof(feeds) / sizeof(feeds[0]); i++) {
            char p[4096];
            snprintf(p, sizeof(p), "%s/%s", cdir, feeds[i]);
            if (!file_exists(p)) {
                if (missing[0]) strncat(missing, ",", sizeof(missing) - strlen(missing) - 1);
                strncat(missing, feeds[i], sizeof(missing) - strlen(missing) - 1);
            }
        }
        if (missing[0]) {
            /* [Phase C-3] 缺件 → 端侧按 prep77b 协议生成（hyb_feeds.c）：
             * emb = 已载 GGUF token_embd 逐行读（eos-pad 补满 NC，链侧恒
             * 满窗、桥处才剪 cell）；cos/sin = 模型 rope 参数现算（theta/
             * hd 由 feeds_model_info 从 GGUF 直读）；am/kc0/vc0 纯协议。
             * 生成失败保留 stage=prefill_feeds 结构化回包（Dart 自动回退
             * GPU）——绝不让半成品进链。 */
            double theta = 0.0;
            int hd = 0, hid = 0, n_vocab = 0;
            const int chunks = (nChunks > 0) ? (int)nChunks : HYB_FEEDS_CHUNKS_DEFAULT;
            const int s = (chunks > 0 && (HYB_FEEDS_NC_DEFAULT % chunks) == 0)
                          ? (HYB_FEEDS_NC_DEFAULT / chunks) : 0;
            bool gen_ok = h->feeds_model_info &&
                          h->feeds_model_info(&theta, &hd, &hid, &n_vocab) == 0 &&
                          hid > 0 && hd > 0 && theta > 0.0 && s > 0 &&
                          n_real <= HYB_FEEDS_NC_DEFAULT &&
                          n_real <= (int)idsBuf.size();
            std::vector<uint16_t> rows;
            if (gen_ok) {
                /* eos-pad 补齐到 NC：pad 值与链 ids 同源（GGUF
                 * tokenizer.ggml.eos_token_id，prefill_ids 处已 fail-closed） */
                std::vector<int32_t> padded((size_t)HYB_FEEDS_NC_DEFAULT,
                                            (uint32_t)eos_pad);
                memcpy(padded.data(), idsBuf.data(),
                       sizeof(int32_t) * (size_t)n_real);
                rows.assign((size_t)HYB_FEEDS_NC_DEFAULT * (size_t)hid, (uint16_t)0);
                if (!h->feeds_read_embd ||
                    h->feeds_read_embd(padded.data(), HYB_FEEDS_NC_DEFAULT,
                                       rows.data()) != 0) {
                    gen_ok = false;
                }
            }
            char ferr[128] = "";
            if (gen_ok &&
                (hyb_feeds_gen_emb(cdir, rows.data(), HYB_FEEDS_NC_DEFAULT,
                                   s, hid, ferr, sizeof(ferr)) != 0 ||
                 hyb_feeds_gen_am(cdir, chunks, s, HYB_FEEDS_NC_DEFAULT,
                                  ferr, sizeof(ferr)) != 0 ||
                 hyb_feeds_gen_rope(cdir, HYB_FEEDS_P0_DEFAULT, chunks, s,
                                    hd, theta, ferr, sizeof(ferr)) != 0 ||
                 hyb_feeds_gen_kc0(cdir, HYB_FEEDS_NC_DEFAULT, hd,
                                   HYB_FEEDS_NKV_DEFAULT,
                                   ferr, sizeof(ferr)) != 0)) {
                gen_ok = false;
            }
            if (!gen_ok) {
                char extras[768];
                snprintf(extras, sizeof(extras),
                         ",\"missing\":\"%s\",\"gen_err\":\"%s\"",
                         missing, ferr);
                return hyb_json(env, false, HYB_ERR_IO, "prefill_feeds",
                                "prompt feeds absent and native generation "
                                "failed (rope/embd params unavailable?)",
                                extras);
            }
            LOGI("hyb prefill: feeds generated natively (chunks=%d s=%d "
                 "hid=%d hd=%d theta=%.1f pos_base=%d)",
                 chunks, s, hid, hd, theta, HYB_FEEDS_P0_DEFAULT);
        }
    }

    /* [m3shell] feedsOnly：ids.raw + d2q feeds 已落本地 chainDir，到此为止
     * （manifest/seed/三段 spawn/收集全由 Dart 经 App 自带 adb 通道在
     * shell 域完成——App 域 NPU 判死 §7.6bis，shell 域同二进制全绿）。 */
    if (feedsOnly) {
        char extras[512];
        snprintf(extras, sizeof(extras),
                 ",\"n_real\":%d,\"ids_path\":\"%s\",\"feeds_dir\":\"%s\","
                 "\"first_tok\":-1,\"pos_base\":%d,\"n_chunks\":%d",
                 n_real, ids, cdir, HYB_P0_DEFAULT, nChunks);
        LOGI("hyb prefill(feedsOnly): n_real=%d dir=%s", n_real, cdir);
        return hyb_json(env, true, HYB_OK, "feeds_done",
                        "ids+feeds staged locally for shell-domain chain",
                        extras);
    }

    /* ---- manifests ---- */
    std::vector<std::string> segments;
    {
        const char *m = (mnp && mnp[0]) ? mnp : kDefaultManifests;
        std::string s = m;
        size_t pos = 0;
        while (pos < s.size()) {
            size_t comma = s.find(',', pos);
            std::string tok = s.substr(pos, comma == std::string::npos
                                              ? std::string::npos : comma - pos);
            /* trim spaces */
            size_t a = tok.find_first_not_of(" \t");
            size_t b = tok.find_last_not_of(" \t");
            if (a != std::string::npos) segments.push_back(tok.substr(a, b - a + 1));
            if (comma == std::string::npos) break;
            pos = comma + 1;
        }
    }
    if (segments.empty()) {
        return hyb_json(env, false, HYB_ERR_BAD_PARAM, "prefill_manifest",
                        "empty manifest list", NULL);
    }
    for (size_t i = 0; i < segments.size(); i++) {
        char p[4096];
        snprintf(p, sizeof(p), "%s/%s", cdir, segments[i].c_str());
        if (!file_exists(p)) {
            char msg[512], extras[600];
            snprintf(msg, sizeof(msg), "manifest missing: %s", segments[i].c_str());
            snprintf(extras, sizeof(extras), ",\"manifest\":\"%s\"", segments[i].c_str());
            return hyb_json(env, false, HYB_ERR_IO, "prefill_manifest", msg, extras);
        }
    }

    /* ---- seed (A3b driver semantics; reset already ran pre-feeds, P0-2) ---- */
    if (!chain_seed_kc0(cdir, HYB_NL_DEFAULT)) {
        return hyb_json(env, false, HYB_ERR_IO, "prefill_seed",
                        "kc0/vc0 seeding failed (stage d2q_kc0/vc0)", NULL);
    }

    /* ---- serial segment launches (one resident at a time) ---- */
    double walls[16] = {0};
    int nseg = (int)segments.size();
    if (nseg > (int)(sizeof(walls) / sizeof(walls[0]))) nseg = (int)(sizeof(walls) / sizeof(walls[0]));
    for (int i = 0; i < (int)segments.size(); i++) {
        const double t0 = now_ms();
        SegResult sr = run_segment(cdir, chainBinPath, qlp,
                                   segments[i].c_str(), nChunks, i, segMs);
        walls[i < nseg ? i : nseg - 1] = now_ms() - t0;
        LOGI("hyb prefill seg %d (%s): done=%d failed=%d exit=%d timeout=%d",
             i, segments[i].c_str(), (int)sr.done, (int)sr.failed,
             sr.exit_code, (int)sr.timed_out);
        if (!sr.done) {
            char msg[512];
            snprintf(msg, sizeof(msg), "segment %d (%s) %s (exit=%d)",
                     i, segments[i].c_str(),
                     sr.timed_out ? "TIMED OUT" : "failed", sr.exit_code);
            std::string extras = std::string(",\"manifest\":\"") + segments[i] + "\"";
            extras += ",\"log_tail\":\"";
            json_escape_append(extras, sr.tail.c_str());
            extras += "\"";
            return hyb_json(env, false, HYB_ERR_IO, "prefill_seg", msg,
                            extras.c_str());
        }
    }

    /* ---- collect the 84 KV raws (+ final hidden) into kvDir ---- */
    for (int i = 0; i < HYB_NL_DEFAULT; i++) {
        char src[4096], dst[4096];
        snprintf(src, sizeof(src), "%s/d2q_kc_%d.raw", cdir, i);
        snprintf(dst, sizeof(dst), "%s/d2q_kc_%d.raw", kv, i);
        if (!copy_file(src, dst)) {
            return hyb_json(env, false, HYB_ERR_IO, "prefill_collect",
                            "kc collection failed — chain wrote no d2q_kc_*?",
                            NULL);
        }
        snprintf(src, sizeof(src), "%s/d2q_vc_%d.raw", cdir, i);
        snprintf(dst, sizeof(dst), "%s/d2q_vc_%d.raw", kv, i);
        if (!copy_file(src, dst)) {
            return hyb_json(env, false, HYB_ERR_IO, "prefill_collect",
                            "vc collection failed", NULL);
        }
    }
    {
        char src[4096], dst[4096];
        snprintf(src, sizeof(src), "%s/d2q_h_l41_3.raw", cdir);
        snprintf(dst, sizeof(dst), "%s/d2q_h_l41_3.raw", kv);
        if (file_exists(src)) copy_file(src, dst); /* optional diagnostic */
    }

    char extras[512];
    snprintf(extras, sizeof(extras),
             ",\"n_real\":%d,\"ids_path\":\"%s\",\"first_tok\":-1,"
             "\"pos_base\":%d,"
             "\"n_chunks\":%d,\"segments\":%d,\"wall_ms_0\":%.0f",
             n_real, ids, HYB_P0_DEFAULT, nChunks, (int)segments.size(),
             walls[0]);
    LOGI("hyb prefill done: n_real=%d segs=%zu", n_real, segments.size());
    return hyb_json(env, true, HYB_OK, "prefill_done",
                    "NPU prefill complete; KV staged for bridge", extras);
}

/* ===================================================================
 * JNI entry 2/2: bridge -> state load -> greedy continuation decode
 * =================================================================== */

static bool hyb_emit(JNIEnv *env, jobject cb, jmethodID mid, const char *text)
{
    if (!cb || !mid || !text || !text[0]) return true;
    jstring js = env->NewStringUTF(text);
    if (!js) return true;
    jboolean keep = env->CallBooleanMethod(cb, mid, js);
    env->DeleteLocalRef(js);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        return false;
    }
    return keep == JNI_TRUE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeBridgeAndResumeDecode(
    JNIEnv *env, jobject /*thiz*/, jstring kvDir, jstring idsPath,
    jstring outPath, jint nReal, jlong posBase, jint firstTok,
    jint maxTokens, jfloat /*temperature*/, jfloat /*topP*/,
    jobject callback)
{
    std::lock_guard<std::mutex> lk(g_hyb_mu);

    char kv[4096], ids[4096], out[4096];
    auto get = [&](jstring js, char *buf, size_t len) -> const char * {
        if (!js) { buf[0] = '\0'; return nullptr; }
        const char *c = env->GetStringUTFChars(js, NULL);
        if (!c) { buf[0] = '\0'; return nullptr; }
        snprintf(buf, len, "%s", c);
        env->ReleaseStringUTFChars(js, c);
        return buf;
    };
    const char *kvp   = get(kvDir, kv, sizeof(kv));
    const char *idp   = get(idsPath, ids, sizeof(ids));
    const char *outp  = get(outPath, out, sizeof(out));

    if (!kvp || !kvp[0] || !idp || !idp[0] || !outp || !outp[0]) {
        return hyb_json(env, false, HYB_ERR_BAD_PARAM, "bridge_param",
                        "kvDir/idsPath/outPath required", NULL);
    }
    if (nReal < 1 || nReal > HYB_NC_DEFAULT) {
        return hyb_json(env, false, HYB_ERR_BAD_PARAM, "bridge_param",
                        "nReal must be in [1, NC]", NULL);
    }
    if (maxTokens < 1) {
        return hyb_json(env, false, HYB_ERR_BAD_PARAM, "bridge_param",
                        "maxTokens invalid", NULL);
    }
    /* [P0-4] same fail-closed as prefill (defense in depth: direct callers
     * skipping prefill would otherwise burn the 7.4MB bridge conversion
     * before state_load rejects an F16 container against q4_0/q8_0 KV). */
    {
        const TongYiLiteEngineHandle *hh = tongyilite_engine_handle();
        if (!hh || !hh->kv_cache_type ||
            hh->kv_cache_type() != TONGYI_KV_CACHE_F16) {
            return hyb_json(env, false, HYB_ERR_NOT_ENABLED, "bridge_kvtype",
                            "engine KV cache is not f16 — state container "
                            "replay requires an F16 cache context", NULL);
        }
    }

    /* ids (i32 LE) — needed for the recompute-step first token */
    std::vector<int32_t> idsBuf((size_t)nReal);
    {
        FILE *f = fopen(ids, "rb");
        if (!f || fread(idsBuf.data(), 4, (size_t)nReal, f) != (size_t)nReal) {
            if (f) fclose(f);
            return hyb_json(env, false, HYB_ERR_IO, "bridge_ids",
                            "ids file missing/short", NULL);
        }
        fclose(f);
    }

    /* ---- stage 1: bridge conversion (byte-frozen contract) ---- */
    hyb_kv_params p;
    memset(&p, 0, sizeof(p));
    p.kv_dir    = kv;
    p.ids_path  = ids;
    p.out_path  = out;
    p.n_real    = (int)nReal;
    p.pos_base  = (long long)posBase;
    p.nc        = HYB_NC_DEFAULT; /* [P0-1 review fix] bridge validates
                                   * 1<=n_real<=nc; leaving it 0 made every
                                   * convert fail BAD_PARAM (silent GPU
                                   * fallback after full chain burn) */
    p.state_ver = 0; /* => HYB_BRIDGE_DEFAULT_VER (4 = App/fork lineage) */
    char err[256] = "";
    const int rc = hyb_kv_bridge_convert(&p, err, sizeof(err));
    if (rc != HYB_OK) {
        LOGE("hyb bridge: convert failed rc=%d %s", rc, err);
        char extras[512];
        snprintf(extras, sizeof(extras), ",\"rc\":%d", rc);
        return hyb_json(env, false, rc, "bridge_convert", err, extras);
    }

    /* ---- stage 2: claim engine + load state ---- */
    const TongYiLiteEngineHandle *h = tongyilite_engine_handle();
    if (!h || !h->begin_hybrid()) {
        return hyb_json(env, false, HYB_ERR_BUSY, "engine_claim",
                        "engine busy (generation in flight?) or model not loaded",
                        NULL);
    }

    llama_model *m = (llama_model *)h->model;
    const llama_vocab *vocab = m ? llama_model_get_vocab(m) : nullptr;
    if (!m || !h->context || !vocab) {
        h->end_hybrid();
        return hyb_json(env, false, HYB_ERR_INTERNAL, "engine_handles",
                        "engine handles null after claim", NULL);
    }

    /* [m3shell 定罪修复 2026-11-13] 引擎主 ctx 是 kv_unified=true（unified KV，
     * 2026-10-16 大批次正确性定案的产物）→ state 载入走 llama_memory_hybrid::
     * state_read：kv 段之后还要读 mem_recr 尾块；而桥容器是冻结契约（工具判卷
     * 50/50 同源），只到 kv。取证链：同一容器（md5 与主机 Python 重桥逐字节
     * 一致）在工具 runner 上双库组都 STATE_LOADED，App unified 拒载——差量唯一
     * 在 unified。修复 = 混合回合临时建 classic ctx（llama_context_default_
     * params 的 kv_unified=false，与工具 mcp5_95_hyb_load 同参形：n_ctx =
     * pos_base+n_real+maxTokens+64、n_batch=n_real），共享 model 权重零重载；
     * 引擎 unified 主 ctx 不碰 = 普通聊天现路径逐字节不变（零回归红线）。 */
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = (uint32_t)(posBase + (long long)nReal + maxTokens + 64);
    cp.n_batch = (uint32_t)nReal;
    llama_context *ctx = llama_init_from_model(m, cp);
    if (!ctx) {
        h->end_hybrid();
        return hyb_json(env, false, HYB_ERR_INTERNAL, "decode_ctx_init",
                        "classic decode ctx alloc failed (OOM?)", NULL);
    }

    const int n_ctx = (int)llama_n_ctx(ctx);
    if (posBase + (long long)nReal + maxTokens + 2 > (long long)n_ctx) {
        llama_free(ctx);
        h->end_hybrid();
        char msg[192];
        snprintf(msg, sizeof(msg),
                 "pos_base(%lld)+nReal(%d)+maxTokens(%d) exceeds n_ctx(%d)",
                 (long long)posBase, (int)nReal, (int)maxTokens, n_ctx);
        return hyb_json(env, false, HYB_ERR_BAD_PARAM, "decode_ctx", msg, NULL);
    }

    struct timespec ts0, ts1;
    clock_gettime(CLOCK_MONOTONIC, &ts0);
    std::vector<llama_token> tk((size_t)nReal);
    size_t loaded = 0;
    const size_t r = llama_state_seq_load_file(ctx, out, 0, tk.data(),
                                               (int)nReal, &loaded);
    clock_gettime(CLOCK_MONOTONIC, &ts1);
    const double load_ms = (ts1.tv_sec - ts0.tv_sec) * 1e3 +
                           (ts1.tv_nsec - ts0.tv_nsec) / 1e6;
    if (r == 0) {
        llama_free(ctx);
        h->end_hybrid();
        return hyb_json(env, false, HYB_ERR_IO, "state_load",
                        "llama_state_seq_load_file rejected the container "
                        "(version/layout mismatch?)", NULL);
    }
    LOGI("hyb decode: state loaded (%zu cells, %.0f ms)", loaded, load_ms);

    /* ---- first token ---- */
    int next_tok = (int)firstTok;
    if (next_tok < 0) {
        /* plan §1.3 fallback "GPU 侧重算一步": re-decode the LAST prompt
         * token at its own pos and argmax. The cell gets the GPU row
         * (overwrites the NPU row for that one token — self-consistent).
         * [m3shell 2026-11-13] batch 形态对齐工具 runner 已证路径：显式
         * pos/seq/logits 数组在临时 classic ctx 上 decode 即败（无内部日志，
         * 9ms 入口级拒绝），token-only 零初始化 batch 是工具 STATE_LOADED+贪心
         * 全绿的唯一形态——先 seq_rm 掉尾 cell，token-only 的自动 pos 派生
         * (seq_pos_max+1) 恰好落回 p_last（尾 cell 删除后 max=p_last-1）。 */
        const int last = idsBuf[(size_t)nReal - 1];
        const llama_pos p_last = (llama_pos)(posBase + nReal - 1);
        llama_memory_seq_rm(llama_get_memory(ctx), 0, p_last, p_last + 1);
        llama_token t1 = (llama_token)last;
        llama_batch b = {};
        b.n_tokens = 1;
        b.token = &t1;
        /* [m3shell 审讯灯] decode 入口级失败无 logcat（tag "llama" 通道在
         * 本进程被 App log bridge 占用且冒烟过滤吞过），本窗口临时捕获
         * llama 内部日志拼进 error message，让真凶开口。 */
        static std::mutex g_cap_mtx;
        static std::string g_cap;
        llama_log_set(
            [](ggml_log_level, const char *text, void *) {
                if (!text) return;
                std::lock_guard<std::mutex> lk(g_cap_mtx);
                if (g_cap.size() < 2048) g_cap += text;
            },
            nullptr);
        const int drc = llama_decode(ctx, b);
        llama_log_set(nullptr, nullptr);
        std::string cap;
        {
            std::lock_guard<std::mutex> lk(g_cap_mtx);
            cap = g_cap;
            g_cap.clear();
        }
        LOGI("hyb decode: recompute rc=%d llama_log=[%s]", drc, cap.c_str());
        if (drc != 0) {
            llama_free(ctx);
            h->end_hybrid();
            std::string msg = "recompute-step decode failed: " + cap;
            return hyb_json(env, false, HYB_ERR_INTERNAL, "first_tok_recompute",
                            msg.c_str(), NULL);
        }
        const float *lg = llama_get_logits_ith(ctx, 0);
        if (!lg) {
            llama_free(ctx);
            h->end_hybrid();
            return hyb_json(env, false, HYB_ERR_INTERNAL, "first_tok_recompute",
                            "no logits after recompute-step", NULL);
        }
        const int nv = (int)llama_vocab_n_tokens(vocab);
        int best = 0;
        for (int i = 1; i < nv; i++) if (lg[i] > lg[best]) best = i;
        next_tok = best;
        LOGI("hyb decode: first_tok via recompute-step = %d", next_tok);
    }

    /* ---- callback wiring (InferenceCallback.onToken) ---- */
    jmethodID mid = nullptr;
    if (callback) {
        jclass cls = env->GetObjectClass(callback);
        mid = env->GetMethodID(cls, "onToken", "(Ljava/lang/String;)Z");
        env->DeleteLocalRef(cls);
    }

    /* ---- greedy continuation (zero-init token-only batch, §6.2) ---- */
    std::string text;
    int gen = 0;
    bool stopped_by_user = false;
    bool stopped_eog = false;
    int decode_fail = 0;
    llama_token t = (llama_token)next_tok;
    const int nv = (int)llama_vocab_n_tokens(vocab);

    for (int i = 0; i < (int)maxTokens; i++) {
        if (h->should_stop()) { stopped_by_user = true; break; }
        if (llama_vocab_is_eog(vocab, t)) { stopped_eog = true; break; }

        llama_batch nb = {};
        nb.token = &t;
        nb.n_tokens = 1;
        if (llama_decode(ctx, nb) != 0) { decode_fail = i + 1; break; }

        char piece[256];
        const int32_t pn = llama_token_to_piece(vocab, t, piece,
                                                (int32_t)sizeof(piece) - 1,
                                                0, false);
        if (pn > 0) {
            piece[pn] = '\0';
            text += piece;
            if (!hyb_emit(env, callback, mid, piece)) { stopped_by_user = true; break; }
        }
        gen++;

        const float *lg = llama_get_logits_ith(ctx, 0);
        if (!lg) { decode_fail = i + 1; break; }
        int best = 0;
        for (int j = 1; j < nv; j++) if (lg[j] > lg[best]) best = j;
        t = (llama_token)best;
    }
    llama_free(ctx);
    h->end_hybrid();

    if (decode_fail) {
        std::string ex = ",\"n_gen\":" + std::to_string(gen) +
                         ",\"decode_fail_at\":" + std::to_string(decode_fail) +
                         ",\"state_path\":\"";
        json_escape_append(ex, out);
        ex += "\",\"text\":\"";
        json_escape_append(ex, text.c_str());
        ex += "\"";
        return hyb_json(env, false, HYB_ERR_INTERNAL, "decode",
                        "llama_decode failed mid-continuation", ex.c_str());
    }

    std::string ex = ",\"n_gen\":" + std::to_string(gen) +
                     ",\"first_tok\":" + std::to_string(next_tok) +
                     ",\"load_ms\":" + std::to_string((long)load_ms) +
                     ",\"state_path\":\"";
    json_escape_append(ex, out);
    ex += "\",\"stopped\":" +
        (stopped_by_user ? std::string("\"user\"")
                         : (stopped_eog ? std::string("\"eog\"")
                                        : std::string("\"max\""))) +
        ",\"text\":\"";
    json_escape_append(ex, text.c_str());
    ex += "\"";
    LOGI("hyb decode done: n_gen=%d stopped=%s text=%zu chars",
         gen, stopped_by_user ? "user" : (stopped_eog ? "eog" : "max"),
         text.size());
    return hyb_json(env, true, HYB_OK, "decode_done", "hybrid decode complete",
                    ex.c_str());
}
