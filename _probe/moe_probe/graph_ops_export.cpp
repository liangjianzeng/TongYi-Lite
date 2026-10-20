// [Mesa 线 P4] 真实生产图的算子导出器。
//
// 为什么要自己写：上游 tests/test-export-graph-ops.cpp 用 common_params 走标准加载，
// 不会设 fork 私有的 `llama_model_params.moe_experts_path`（见 llama.h:325-328），
// 于是 `-les` 拆分包直接 `failed to load model`，导出的就不是我们跑的那张图。
// 本文件只做一件事：按 e2e 的方式把模型挂起来（含 experts），reserve pp/tg 两张图，
// 然后**按上游 test-backend-ops --test-file 认得的格式**逐算子落盘。
//
// 用法：OPS_OUT=<路径> ./graph_ops_export <model.gguf> <experts/manifest.json> [n_gpu_layers] [n_ctx]
//   n_gpu_layers 只影响加载，不改图形状；固定 0（CPU 设备）加载最快。
// 产出：OPS_OUT 每行一个算子 = `op type ne[4] n_params params... n_src (src_type src_ne[4] src_nb[4])* name`
// 然后：./test-backend-ops --test-file $OPS_OUT -b GPUOpenCL   ->  每个真实算子 SUPPORTED / NOT SUPPORTED
//   读法：NOT SUPPORTED 的就是**每 token 必然落 CPU** 的算子（同步与搬运的来源）。

#include "llama.h"
#include "llama-cpp.h"
#include "llama-ext.h"   // llama_graph_reserve / llama_n_expert 在这里，不在 llama.h
#include "ggml.h"
#include "ggml-backend.h"

#include <array>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <set>
#include <string>
#include <tuple>
#include <vector>

static void set_tensor_data(struct ggml_tensor * tensor, void * userdata) {
    GGML_UNUSED(tensor);
    GGML_UNUSED(userdata);
}

struct input_tensor {
    ggml_type type;
    std::array<int64_t, 4> ne;
    std::array<size_t, 4> nb;

    input_tensor(ggml_type type, int64_t * ne, size_t * nb) : type(type) {
        memcpy(this->ne.data(), ne, 4 * sizeof(int64_t));
        memcpy(this->nb.data(), nb, 4 * sizeof(size_t));
    }

    bool operator<(const input_tensor & b) const {
        return std::tie(type, ne, nb) < std::tie(b.type, b.ne, b.nb);
    }

    void serialize(std::ostream & out) const {
        out << type << ' ';
        for (size_t i = 0; i < 4; i++) { out << ne[i] << ' '; }
        for (size_t i = 0; i < 4; i++) { out << nb[i] << ' '; }
    }
};

struct test_object {
    ggml_op op;
    ggml_type type;
    std::array<int64_t, 4> ne;
    std::vector<int32_t> op_params;
    std::vector<input_tensor> sources;
    std::string name;

    void serialize(std::ostream & out) const {
        out << op << ' ' << type << ' ';
        for (size_t i = 0; i < 4; i++) { out << ne[i] << ' '; }
        out << op_params.size() << ' ';
        for (size_t i = 0; i < op_params.size(); i++) { out << op_params[i] << ' '; }
        out << sources.size() << ' ';
        for (size_t s = 0; s < sources.size(); s++) { sources[s].serialize(out); }
        out << (name.empty() ? std::string("-") : name) << '\n';
    }

    bool operator<(const test_object & b) const {
        return std::tie(op, type, ne, op_params, sources) <
               std::tie(b.op, b.type, b.ne, b.op_params, b.sources);
    }
};

static void extract_graph_ops(ggml_cgraph * cgraph, const char * label, std::set<test_object> & tests) {
    const int n_nodes   = ggml_graph_n_nodes(cgraph);
    const int n_before  = (int) tests.size();
    int n_skipped = 0;
    for (int i = 0; i < n_nodes; i++) {
        ggml_tensor * node = ggml_graph_node(cgraph, i);
        if (node->op == GGML_OP_NONE || node->op == GGML_OP_VIEW || node->op == GGML_OP_RESHAPE ||
            node->op == GGML_OP_PERMUTE || node->op == GGML_OP_TRANSPOSE) {
            n_skipped++;
            continue;
        }
        test_object test;
        test.op   = node->op;
        test.type = node->type;
        memcpy(&test.ne, node->ne, 4 * sizeof(int64_t));
        test.op_params.resize(GGML_MAX_OP_PARAMS / sizeof(int32_t));
        memcpy(test.op_params.data(), node->op_params, GGML_MAX_OP_PARAMS);
        for (size_t s = 0; s < GGML_MAX_SRC; s++) {
            if (node->src[s] == nullptr) { break; }
            test.sources.emplace_back(node->src[s]->type, node->src[s]->ne, node->src[s]->nb);
        }
        test.name = node->name;
        tests.insert(test);
    }
    fprintf(stderr, "[gops] %s: +%d unique, %d nodes, %d skipped(view)\n",
            label, (int) tests.size() - n_before, n_nodes, n_skipped);
    fflush(stderr);
}

int main(int argc, char ** argv) {
    if (argc < 3) {
        fprintf(stderr, "用法: OPS_OUT=<路径> %s <model.gguf> <experts/manifest.json> [n_gpu_layers] [n_ctx]\n", argv[0]);
        return 2;
    }
    const char * model_path   = argv[1];
    const char * experts_path = argv[2];
    int n_gpu_layers          = argc > 3 ? atoi(argv[3]) : 0;
    int n_ctx                 = argc > 4 ? atoi(argv[4]) : 512;
    const char * out_path     = getenv("OPS_OUT") ? getenv("OPS_OUT") : "ops.txt";

    // 图形状与后端无关，用 CPU 设备 + no_alloc 加载（不读权重，只要 metadata 与图）
    ggml_backend_dev_t cpu_dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    if (!cpu_dev) { fprintf(stderr, "[gops] 没有 CPU 设备\n"); return 1; }
    ggml_backend_dev_t devs[2] = { cpu_dev, nullptr };

    llama_model_params mp = llama_model_default_params();
    mp.devices          = devs;
    mp.n_gpu_layers     = 0;              // 图在 sched 之前建，这里不影响算子集合
    mp.moe_experts_path = experts_path;   // fork 私有：-les 拆分包靠它，上游 exporter 缺这一句
    mp.moe_slot_bank    = getenv("OPS_BANK") ? atoi(getenv("OPS_BANK")) : 16;  // 0 = 关闭专家挂载，
                                          // 那样 check_tensor_dims 会报 ffn_*_exps.weight not found（实测踩过）

    llama_model * model = llama_model_load_from_file(model_path, mp);
    if (!model) { fprintf(stderr, "[gops] 模型加载失败（experts=%s）\n", experts_path); return 1; }
    fprintf(stderr, "[gops] 模型就绪 n_layer=%d（n_gpu_layers 仅作记录=%d）\n",
            (int) llama_n_layer(model), n_gpu_layers);

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx     = (uint32_t) n_ctx;
    cp.n_seq_max = 1;
    llama_context * ctx = llama_init_from_model(model, cp);
    if (!ctx) { fprintf(stderr, "[gops] ctx 创建失败\n"); llama_model_free(model); return 1; }

    const uint32_t n_seqs   = llama_n_seq_max(ctx);
    const uint32_t n_ubatch = llama_n_ubatch(ctx);

    std::set<test_object> tests;
    ggml_cgraph * gf_pp = llama_graph_reserve(ctx, std::min((uint32_t) n_ctx, n_ubatch), n_seqs, n_ubatch);
    if (gf_pp) { extract_graph_ops(gf_pp, "pp", tests); }
    else { fprintf(stderr, "[gops] pp 图 reserve 失败\n"); }

    ggml_cgraph * gf_tg = llama_graph_reserve(ctx, n_seqs, n_seqs, n_seqs);
    if (gf_tg) { extract_graph_ops(gf_tg, "tg", tests); }
    else { fprintf(stderr, "[gops] tg 图 reserve 失败\n"); }

    std::ofstream f(out_path);
    if (!f.is_open()) { fprintf(stderr, "[gops] 打不开 %s\n", out_path); llama_free(ctx); llama_model_free(model); return 1; }
    for (const auto & t : tests) { t.serialize(f); }
    f.close();
    fprintf(stderr, "[gops] 写出 %zu 个唯一算子 -> %s\n", tests.size(), out_path);

    llama_free(ctx);
    llama_model_free(model);
    return 0;
}
