#include "models.h"
#include "../llama-memory-hybrid-iswa.h"
#include "../llama-memory-hybrid.h"

#include "ggml-backend.h"
#include "ggml-opencl.h"   // ggml_backend_opencl_svm_buft (GPU slot bank)
#include "llama-moe-experts.h"

void llama_model_lfm2moe::load_arch_hparams(llama_model_loader & ml) {
    ml.get_key(LLM_KV_SHORTCONV_L_CACHE,           hparams.n_shortconv_l_cache);
    ml.get_key(LLM_KV_ATTENTION_LAYERNORM_RMS_EPS, hparams.f_norm_rms_eps);
    ml.get_key(LLM_KV_LEADING_DENSE_BLOCK_COUNT,   hparams.n_layer_dense_lead, false);
    ml.get_key_or_arr(LLM_KV_EXPERT_FEED_FORWARD_LENGTH, hparams.n_ff_exp_arr, hparams.n_layer_all);
    ml.get_key(LLM_KV_EXPERT_GATING_FUNC,          hparams.expert_gating_func);

    for (uint32_t il = 0; il < hparams.n_layer(); ++il) {
        hparams.is_recr_impl[il] = hparams.n_head_kv(il) == 0;
    }

    switch (hparams.n_layer()) {
        case 24: type = LLM_TYPE_8B_A1B;  break;
        case 40: type = LLM_TYPE_24B_A2B; break;
        default: type = LLM_TYPE_UNKNOWN;
    }
}

void llama_model_lfm2moe::load_arch_tensors(llama_model_loader & ml) {
    LLAMA_LOAD_LOCALS;

    // ---- split-moe: routed experts synthesized as slot tensors -------------
    // With an experts manifest, the stripped (-les) gguf has no ffn_*_exps
    // tensors; synthesize them from the manifest so llama-moe-slot's runtime
    // preadv can feed them (same scheme as qwen35moe, three families only).
    const bool moe_slot = moe_slot_bank_enabled();
    ggml_backend_buffer_type_t moe_slot_buft = nullptr;
    if (moe_slot) {
        // LLAMA_MOE_BANK_GPU=1: slot bank in OpenCL FGSVM (GPU-addressable,
        // still CPU-writable). Fall back to CPU on any miss.
        static const bool bank_gpu = [] {
            const char * e = getenv("LLAMA_MOE_BANK_GPU");
            return e && e[0] == '1';
        }();
        if (bank_gpu) {
            ggml_backend_dev_t gpu_dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
            if (gpu_dev) {
                moe_slot_buft = ggml_backend_opencl_svm_buft(gpu_dev);
            }
            if (moe_slot_buft) {
                LLAMA_LOG_INFO("%s: split-moe slot bank on GPU FGSVM (LLAMA_MOE_BANK_GPU=1)\n", __func__);
            } else {
                LLAMA_LOG_WARN("%s: LLAMA_MOE_BANK_GPU=1 but no FGSVM-capable OpenCL device - falling back to CPU bank\n", __func__);
            }
        }
        if (!moe_slot_buft) {
            ggml_backend_dev_t cpu_dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
            GGML_ASSERT(cpu_dev && "split-moe requires a CPU device");
            moe_slot_buft = ggml_backend_dev_buffer_type(cpu_dev);
        }
    }

    // per-group layout: base = prefill capacity + sum(per-layer decode widths).
    // layer_c is indexed by MoE-relative layer (0 = first MoE layer); the loops
    // below run over absolute layers, so subtract the dense lead to index it.
    const int64_t dec_c = moe_slot ? moe_decode_window() : 0;
    const int64_t k_pf  = moe_slot ? moe_prefetch_slots() : 0;
    const int64_t moe_base = (int64_t) hparams.n_layer_dense_lead;
    const std::vector<int32_t> layer_c = moe_slot ? moe_layer_windows() : std::vector<int32_t>();
    const bool dec_enabled = dec_c > 0 && !layer_c.empty();
    auto width_of = [&](int il) -> int64_t {
        const int64_t mi = (int64_t) il - moe_base;
        if (!dec_enabled || mi < 0 || mi >= (int64_t) layer_c.size()) {
            return 0;
        }
        return (int64_t) layer_c[(size_t) mi] + k_pf;
    };
    const int64_t prefill_cap = moe_slot ? moe_slot_bank_size() : 0;

    const llm_tensor fam_ids[3] = {
        LLM_TENSOR_FFN_GATE_EXPS, LLM_TENSOR_FFN_UP_EXPS, LLM_TENSOR_FFN_DOWN_EXPS,
    };
    // family -> (bytes_per_expert -> layer indices, ascending)
    std::map<size_t, std::vector<int>> moe_groups[3];
    if (moe_slot) {
        for (int il = 0; il < n_layer; ++il) {
            for (int fi = 0; fi < 3; ++fi) {
                const auto * e = moe_experts_entry(tn(fam_ids[fi], "weight", il).str().c_str());
                if (e) {
                    moe_groups[fi][e->bytes_per_expert].push_back(il);
                }
            }
        }
    }
    // group leader (allocates prefill_cap + decode widths); others are views.
    std::map<std::string, int64_t> group_slots;
    if (moe_slot) {
        for (int fi = 0; fi < 3; ++fi) {
            for (const auto & kv : moe_groups[fi]) {
                int64_t group_total = 0;
                for (int il : kv.second) {
                    group_total += width_of(il);
                }
                group_slots[tn(fam_ids[fi], "weight", kv.second.front()).str()] =
                    dec_enabled ? (prefill_cap + group_total) : prefill_cap;
            }
        }
    }
    auto slots_for = [&](const std::string & name) -> int64_t {
        const auto it = group_slots.find(name);
        return it == group_slots.end() ? prefill_cap : it->second;
    };
    auto create_routed_exps = [&](llm_tensor fam, int il, const std::initializer_list<int64_t> & dims, int flags) -> ggml_tensor * {
        const std::string name = tn(fam, "weight", il).str();
        if (!moe_slot) {
            return create_tensor(tn(fam, "weight", il), dims, flags);
        }
        const auto * entry = moe_experts_entry(name.c_str());
        ggml_tensor * tensor = nullptr;
        if (entry) {
            tensor = ml.create_tensor_expert_alloc(hparams, moe_slot_buft, name, dims, entry->type);
            if (ggml_nbytes(tensor) != entry->bytes_per_expert * (size_t) hparams.n_expert) {
                throw std::runtime_error(format(
                    "split-moe: expert tensor '%s' byte size mismatch: tensor=%zu manifest=%zu (check dims ordering)",
                    name.c_str(), ggml_nbytes(tensor),
                    entry->bytes_per_expert * (size_t) hparams.n_expert));
            }
            ml.virtualize_expert_tensor(tensor, hparams.n_expert, slots_for(name), entry->type, entry->bytes_per_expert);
        } else if (!(flags & TENSOR_NOT_REQUIRED)) {
            throw std::runtime_error(format(
                "split-moe: routed tensor '%s' in neither the gguf nor the experts manifest", name.c_str()));
        }
        return tensor;
    };

    tok_embd = create_tensor(tn(LLM_TENSOR_TOKEN_EMBD, "weight"), {n_embd, n_vocab}, 0);

    output_norm = create_tensor(tn(LLM_TENSOR_OUTPUT_NORM_LFM2, "weight"), {n_embd}, 0);
    output      = create_tensor(tn(LLM_TENSOR_OUTPUT,           "weight"), {n_embd, n_vocab}, TENSOR_NOT_REQUIRED);

    if (output == NULL) {
        output = create_tensor(tn(LLM_TENSOR_TOKEN_EMBD, "weight"), {n_embd, n_vocab}, TENSOR_DUPLICATED);
    }

    for (int i = 0; i < n_layer; ++i) {
        auto & layer = layers[i];

        const bool is_moe_layer = i >= static_cast<int>(hparams.n_layer_dense_lead);

        // ffn/moe is same for transformer and conv layers
        layer.ffn_norm = create_tensor(tn(LLM_TENSOR_FFN_NORM, "weight", i), {n_embd}, 0);
        if (is_moe_layer) {
            GGML_ASSERT(n_expert && n_expert_used);
            layer.ffn_gate_inp    = create_tensor(tn(LLM_TENSOR_FFN_GATE_INP, "weight", i),  {n_embd, n_expert}, 0);
            layer.ffn_gate_exps   = create_routed_exps(LLM_TENSOR_FFN_GATE_EXPS, i, {n_embd, hparams.n_ff_exp(), n_expert}, 0);
            layer.ffn_down_exps   = create_routed_exps(LLM_TENSOR_FFN_DOWN_EXPS, i, {hparams.n_ff_exp(),   n_embd, n_expert}, 0);
            layer.ffn_up_exps     = create_routed_exps(LLM_TENSOR_FFN_UP_EXPS, i, {n_embd, hparams.n_ff_exp(), n_expert}, 0);
            layer.ffn_exp_probs_b = create_tensor(tn(LLM_TENSOR_FFN_EXP_PROBS_B, "bias", i), {n_expert}, 0);
        } else {  // dense
            layer.ffn_gate = create_tensor(tn(LLM_TENSOR_FFN_GATE, "weight", i), {n_embd,   n_ff}, 0);
            layer.ffn_down = create_tensor(tn(LLM_TENSOR_FFN_DOWN, "weight", i), {  n_ff, n_embd}, 0);
            layer.ffn_up   = create_tensor(tn(LLM_TENSOR_FFN_UP,   "weight", i), {n_embd,   n_ff}, 0);
        }

        // for operator_norm
        layer.attn_norm = create_tensor(tn(LLM_TENSOR_ATTN_NORM, "weight", i), {n_embd}, 0);

        if (!hparams.is_recr(i)) {
            layer.attn_q_norm = create_tensor(tn(LLM_TENSOR_ATTN_Q_NORM, "weight", i), {n_embd_head_k}, 0);
            layer.attn_k_norm = create_tensor(tn(LLM_TENSOR_ATTN_K_NORM, "weight", i), {n_embd_head_k}, 0);
            GGML_ASSERT(n_embd_v_gqa == n_embd_k_gqa);

            create_tensor_qkv(layer, i, n_embd, n_embd, hparams.n_embd_k_gqa(i), hparams.n_embd_v_gqa(i), 0);

            layer.wo = create_tensor(tn(LLM_TENSOR_ATTN_OUT, "weight", i), {n_embd, n_embd}, 0);
        } else {
            layer.shortconv.conv     = create_tensor(tn(LLM_TENSOR_SHORTCONV_CONV,    "weight", i), {hparams.n_shortconv_l_cache, n_embd}, 0);
            layer.shortconv.in_proj  = create_tensor(tn(LLM_TENSOR_SHORTCONV_INPROJ,  "weight", i), {n_embd, 3 * n_embd}, 0);
            layer.shortconv.out_proj = create_tensor(tn(LLM_TENSOR_SHORTCONV_OUTPROJ, "weight", i), {n_embd, n_embd}, 0);
        }
    }

    // for LFM2-ColBert-350M
    dense_2_out_layers   = create_tensor(tn(LLM_TENSOR_DENSE_2_OUT, "weight"), {n_embd, hparams.n_embd_out()}, TENSOR_NOT_REQUIRED);
    dense_2_out_layers_b = create_tensor(tn(LLM_TENSOR_DENSE_2_OUT, "bias"),   {hparams.n_embd_out()        }, TENSOR_NOT_REQUIRED);

    // split-moe grouping: one base per family, layers become windows on it
    if (moe_slot) {
        struct fam_t {
            ggml_tensor * llama_layer::* pf;
            ggml_tensor * llama_layer::* pf_dec;
        };
        const fam_t fams[3] = {
            { &llama_layer::ffn_gate_exps, &llama_layer::ffn_gate_exps_dec },
            { &llama_layer::ffn_up_exps,   &llama_layer::ffn_up_exps_dec   },
            { &llama_layer::ffn_down_exps, &llama_layer::ffn_down_exps_dec },
        };

        size_t resident = 0;
        int n_win = 0;
        int n_grp = 0;

        for (int fi = 0; fi < 3; ++fi) {
            for (const auto & kv : moe_groups[fi]) {
                const std::vector<int> & members = kv.second;
                if (members.empty()) {
                    continue;
                }
                const int first = members.front();
                ggml_tensor * base = layers[first].*fams[fi].pf;
                if (!base) {
                    continue;
                }
                const auto * e = moe_experts_entry(ggml_get_name(base));
                if (!e || e->bytes_per_expert == 0) {
                    throw std::runtime_error(format(
                        "MoE base '%s' has no usable experts entry", ggml_get_name(base)));
                }
                if (e->bytes_per_expert != kv.first) {
                    throw std::runtime_error(format(
                        "MoE group for '%s' has inconsistent expert bytes", ggml_get_name(base)));
                }
                resident += ggml_nbytes(base);
                n_grp++;

                // non-leaders are plain views of the base, else each would
                // really allocate its own slot memory
                for (size_t j = 1; j < members.size(); ++j) {
                    ggml_tensor * t = layers[members[j]].*fams[fi].pf;
                    if (t) {
                        ml.alias_expert_slot_tensor(t, base);
                    }
                }

                // the leader IS the base: rename to `.base`, layer gets a
                // prefill window view; decode windows stack after prefill_cap
                for (size_t j = 0; j < members.size(); ++j) {
                    auto & L = layers[members[j]];
                    if (j == 0) {
                        const std::string orig = ggml_get_name(base);
                        ggml_set_name(base, (orig + ".base").c_str());
                        L.*fams[fi].pf = ml.window_expert_slot_tensor(
                            ml.expert_ctx_for_buft(hparams, moe_slot_buft),
                            orig.c_str(), base, 0, prefill_cap, e->bytes_per_expert);
                    }
                    n_win++;
                    if (dec_enabled) {
                        int64_t off = prefill_cap;
                        for (size_t k2 = 0; k2 < j; ++k2) {
                            off += width_of(members[k2]);
                        }
                        const int64_t wj = width_of(members[j]);
                        if (wj > 0) {
                            const std::string n2 = format("%s.dec", ggml_get_name(L.*fams[fi].pf));
                            L.*fams[fi].pf_dec = ml.window_expert_slot_tensor(
                                ml.expert_ctx_for_buft(hparams, moe_slot_buft),
                                n2.c_str(), base, off, wj, e->bytes_per_expert);
                        }
                    }
                }
            }
        }

        LLAMA_LOG_INFO(
            "%s: split-moe MoE bank %d groups, %.2f MiB resident; %d prefill windows%s\n",
            __func__, n_grp, resident / 1024.0 / 1024.0, n_win,
            dec_enabled ? " + decode windows" : "");
    }
}

std::unique_ptr<llm_graph_context> llama_model_lfm2moe::build_arch_graph(const llm_graph_params & params) const {
    if (hparams.swa_type == LLAMA_SWA_TYPE_STANDARD) {
        return std::make_unique<graph<true>>(*this, params);
    } else {
        return std::make_unique<graph<false>>(*this, params);
    }
}

