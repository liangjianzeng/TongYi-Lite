#pragma once

#include "ggml.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>

struct llama_moe_experts_entry {
    int32_t layer = -1;
    std::string tensor_name;
    std::string tensor_family;
    std::string path;
    ggml_type type = GGML_TYPE_COUNT;
    size_t offset = 0;
    size_t tensor_bytes = 0;
    size_t bytes_per_expert = 0;
    size_t expert_stride = 0;
    int32_t expert_count = 0;
};

class llama_moe_experts {
public:
    // input_path: a manifest.json / directory of packed expert bins, or a plain
    // .gguf file (in-place mode: entries address the routed expert tensors
    // inside that gguf directly, no repacking)
    explicit llama_moe_experts(const char * input_path);

    const llama_moe_experts_entry * find(const char * tensor_name) const;

    int32_t expert_count() const;
    int32_t expert_used_count() const;
    int32_t layer_count() const;
    size_t bytes_per_slot_all_layers() const;

    // true when entries were built from a gguf tensor table (family-major,
    // each entry owns one contiguous family segment)
    bool inplace() const {
        return inplace_mode;
    }

private:
    void load_from_manifest(const char * input_path);
    void load_from_gguf(const char * path);

    bool inplace_mode = false;
    int32_t n_expert = 0;
    int32_t n_expert_used = 0;
    int32_t n_layer = 0;
    size_t bytes_per_slot = 0;
    std::unordered_map<std::string, llama_moe_experts_entry> entries;
};
