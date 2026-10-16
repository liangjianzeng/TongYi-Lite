#include "llama-moe-experts.h"

#include "gguf.h"
#include "llama-impl.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <unordered_set>

namespace {

ggml_type parse_type(std::string name) {
    std::transform(name.begin(), name.end(), name.begin(), [](unsigned char value) {
        return (char) std::tolower(value);
    });

    for (int value = 0; value < GGML_TYPE_COUNT; ++value) {
        const auto type = (ggml_type) value;
        const char * type_name = ggml_type_name(type);
        if (!type_name) {
            continue;
        }
        std::string candidate(type_name);
        std::transform(candidate.begin(), candidate.end(), candidate.begin(), [](unsigned char item) {
            return (char) std::tolower(item);
        });
        if (candidate == name) {
            return type;
        }
    }

    throw std::runtime_error(format("unknown MoE experts quant type '%s'", name.c_str()));
}

bool routed_family(const std::string & family) {
    return family == "ffn_gate_exps" ||
           family == "ffn_up_exps" ||
           family == "ffn_down_exps" ||
           family == "ffn_gate_up_exps";
}

// "blk.<N>.<family>.weight" -> family name for routed expert tensors, empty string otherwise
std::string routed_family_name(const std::string & name, int32_t & layer) {
    if (name.compare(0, 4, "blk.") != 0) {
        return {};
    }
    const size_t d1 = name.find('.', 4);
    if (d1 == std::string::npos) {
        return {};
    }
    const std::string lstr = name.substr(4, d1 - 4);
    if (lstr.empty() || lstr.find_first_not_of("0123456789") != std::string::npos) {
        return {};
    }
    static const std::string suffix = ".weight";
    if (name.size() <= d1 + 1 + suffix.size() ||
        name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0) {
        return {};
    }
    const std::string family = name.substr(d1 + 1, name.size() - suffix.size() - (d1 + 1));
    if (!routed_family(family)) {
        return {};
    }
    layer = (int32_t) std::strtol(lstr.c_str(), nullptr, 10);
    return family;
}

// Minimal GGUF header walker. Captures the scalar KVs the in-place experts
// mode needs plus every tensor record (name, dims, type, data offset). parse()
// returns false when the buffer ends mid-header; the caller grows the read.
struct gguf_header_scan {
    struct rec {
        std::string name;
        uint64_t dims[4] = { 0, 0, 0, 0 };
        uint32_t n_dims  = 0;
        uint32_t type    = 0;
        uint64_t off     = 0;
    };

    const uint8_t * p   = nullptr;
    const uint8_t * end = nullptr;
    bool more = false;

    uint32_t n_expert     = 0;
    uint32_t n_expert_used = 0;
    uint32_t alignment    = 32;
    bool saw_expert_count = false;
    bool saw_expert_used  = false;

    bool raw(void * dst, size_t n) {
        if ((size_t) (end - p) < n) {
            more = true;
            return false;
        }
        memcpy(dst, p, n);
        p += n;
        return true;
    }
    template <typename T>
    bool val(T & v) {
        return raw(&v, sizeof(v));
    }
    bool str(std::string & s) {
        uint64_t n;
        if (!val(n) || n > (uint64_t) (end - p)) {
            more = true;
            return false;
        }
        s.assign((const char *) p, (size_t) n);
        p += n;
        return true;
    }

    bool kv_value(uint32_t type, int depth, const std::string & key) {
        if (depth > 4) {
            throw std::runtime_error("MoE experts gguf: kv array nesting too deep");
        }
        switch (type) {
            case GGUF_TYPE_UINT8: case GGUF_TYPE_INT8: case GGUF_TYPE_BOOL: {
                uint8_t v; return val(v);
            }
            case GGUF_TYPE_UINT16: case GGUF_TYPE_INT16: {
                uint16_t v; return val(v);
            }
            case GGUF_TYPE_UINT32: case GGUF_TYPE_INT32: case GGUF_TYPE_FLOAT32: {
                uint32_t v;
                if (!val(v)) {
                    return false;
                }
                if (type == GGUF_TYPE_UINT32) {
                    // arch-prefixed: llama.expert_count, lfm2moe.expert_count, ...
                    static const std::string ec = ".expert_count";
                    static const std::string eu = ".expert_used_count";
                    if (key.size() >= ec.size() &&
                        key.compare(key.size() - ec.size(), ec.size(), ec) == 0) {
                        n_expert = v; saw_expert_count = true;
                    } else if (key.size() >= eu.size() &&
                               key.compare(key.size() - eu.size(), eu.size(), eu) == 0) {
                        n_expert_used = v; saw_expert_used = true;
                    } else if (key == "general.alignment" && v) {
                        alignment = v;
                    }
                }
                return true;
            }
            case GGUF_TYPE_UINT64: case GGUF_TYPE_INT64: case GGUF_TYPE_FLOAT64: {
                uint64_t v; return val(v);
            }
            case GGUF_TYPE_STRING: {
                std::string s; return str(s);
            }
            case GGUF_TYPE_ARRAY: {
                uint32_t elem;
                uint64_t n;
                if (!val(elem) || !val(n)) {
                    return false;
                }
                if (n > 10000000) {
                    throw std::runtime_error("MoE experts gguf: kv array too large");
                }
                for (uint64_t i = 0; i < n; ++i) {
                    if (!kv_value(elem, depth + 1, key)) {
                        return false;
                    }
                }
                return true;
            }
            default:
                throw std::runtime_error(format("MoE experts gguf: bad kv type %u", type));
        }
    }

    bool parse(std::vector<rec> & out) {
        out.clear();
        char magic[4];
        uint32_t version;
        uint64_t n_tensors, n_kv;
        if (!raw(magic, 4)) {
            return false;
        }
        if (memcmp(magic, "GGUF", 4) != 0) {
            throw std::runtime_error("MoE experts gguf: bad magic");
        }
        if (!val(version)) {
            return false;
        }
        if (version < 2 || version > 3) {
            throw std::runtime_error(format("MoE experts gguf: unsupported version %u", version));
        }
        if (version == 2) {
            uint32_t a, b;
            if (!val(a) || !val(b)) {
                return false;
            }
            n_tensors = a;
            n_kv      = b;
        } else {
            if (!val(n_tensors) || !val(n_kv)) {
                return false;
            }
        }
        if (n_tensors > 1000000 || n_kv > 100000) {
            throw std::runtime_error("MoE experts gguf: absurd header counts");
        }
        for (uint64_t i = 0; i < n_kv; ++i) {
            std::string key;
            if (!str(key)) {
                return false;
            }
            uint32_t type;
            if (!val(type)) {
                return false;
            }
            if (!kv_value(type, 0, key)) {
                return false;
            }
        }
        for (uint64_t i = 0; i < n_tensors; ++i) {
            rec r;
            if (!str(r.name) || !val(r.n_dims)) {
                return false;
            }
            if (r.n_dims > 4) {
                throw std::runtime_error(format("MoE experts gguf: tensor '%s' has %u dims",
                                                r.name.c_str(), r.n_dims));
            }
            for (uint32_t d = 0; d < r.n_dims; ++d) {
                if (!val(r.dims[d])) {
                    return false;
                }
            }
            if (!val(r.type) || !val(r.off)) {
                return false;
            }
            out.push_back(std::move(r));
        }
        return true;
    }
};

}

llama_moe_experts::llama_moe_experts(const char * input_path) {
    namespace fs = std::filesystem;

    if (!input_path || input_path[0] == '\0') {
        throw std::invalid_argument("MoE experts path is empty");
    }

    const fs::path input(input_path);
    std::string ext = input.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) {
        return (char) std::tolower(c);
    });
    if (ext == ".gguf") {
        inplace_mode = true;
        load_from_gguf(input_path);
        return;
    }
    load_from_manifest(input_path);
}

void llama_moe_experts::load_from_manifest(const char * input_path) {
    namespace fs = std::filesystem;

    const fs::path input(input_path);
    const fs::path manifest_path = fs::is_directory(input) ? input / "manifest.json" : input;
    const fs::path manifest_dir = manifest_path.parent_path();

    std::ifstream stream(manifest_path);
    if (!stream.is_open()) {
        throw std::runtime_error(format("failed to open MoE experts manifest '%s'", manifest_path.string().c_str()));
    }

    nlohmann::json manifest;
    stream >> manifest;

    if (manifest.value("schema_version", 0) != 1) {
        throw std::runtime_error("unsupported MoE experts schema version");
    }
    // 兼容旧 manifest：早期写的是 `sidecar_kind`。数据格式改名不该让已生成的
    // 13 GiB 产物作废，所以这里两个 key 都收。
    const std::string kind = manifest.contains("experts_kind")
        ? manifest.value("experts_kind", std::string())
        : manifest.value("sidecar_kind", std::string());
    if (kind != "omni_moe_gguf" && kind != "flashmoe_gguf") {
        throw std::runtime_error(format("unsupported MoE experts kind '%s'", kind.c_str()));
    }
    const std::string layout = manifest.value("layout", std::string());
    if (layout != "layer_major_expert" && layout != "expert_major") {
        throw std::runtime_error(format("MoE experts layout '%s' is not expert-major", layout.c_str()));
    }

    const auto & model = manifest.at("model");
    n_expert = model.at("expert_count").get<int32_t>();
    n_expert_used = model.at("expert_used_count").get<int32_t>();
    if (n_expert <= 0 || n_expert_used <= 0 || n_expert_used > n_expert) {
        throw std::runtime_error("invalid expert counts in MoE experts manifest");
    }

    std::unordered_set<int32_t> layers;
    for (const auto & item : manifest.at("entries")) {
        const std::string family = item.at("tensor_family").get<std::string>();
        if (!routed_family(family)) {
            continue;
        }

        llama_moe_experts_entry entry;
        entry.layer = item.at("layer").get<int32_t>();
        entry.tensor_name = item.at("tensor_name").get<std::string>();
        entry.tensor_family = family;
        entry.path = (manifest_dir / item.at("repacked_file").get<std::string>()).string();
        entry.type = parse_type(item.at("quant_type").get<std::string>());
        entry.offset = item.at("repacked_offset").get<size_t>();
        entry.tensor_bytes = item.at("exact_byte_length").get<size_t>();
        entry.bytes_per_expert = item.at("bytes_per_expert").get<size_t>();
        entry.expert_stride = item.at("expert_stride").get<size_t>();
        entry.expert_count = item.value(
            "expert_count",
            entry.bytes_per_expert == 0 ? 0 : (int32_t) (entry.tensor_bytes / entry.bytes_per_expert));

        if (entry.layer < 0 || entry.bytes_per_expert == 0 || entry.expert_count != n_expert) {
            throw std::runtime_error(format("invalid MoE experts entry '%s'", entry.tensor_name.c_str()));
        }
        if (entry.offset > std::numeric_limits<size_t>::max() - entry.bytes_per_expert) {
            throw std::runtime_error(format("MoE experts entry '%s' overflows family extent", entry.tensor_name.c_str()));
        }
        const size_t family_end = entry.offset + entry.bytes_per_expert;
        if (entry.expert_stride < family_end) {
            throw std::runtime_error(format("invalid expert stride for MoE experts entry '%s'", entry.tensor_name.c_str()));
        }
        if ((size_t) (entry.expert_count - 1) >
            (std::numeric_limits<size_t>::max() - family_end) / entry.expert_stride) {
            throw std::runtime_error(format("MoE experts entry '%s' overflows file extent", entry.tensor_name.c_str()));
        }

        const size_t required = (size_t) (entry.expert_count - 1) * entry.expert_stride +
                                family_end;
        std::error_code error;
        const size_t file_size = (size_t) fs::file_size(entry.path, error);
        if (error || file_size < required) {
            throw std::runtime_error(format(
                "MoE experts file '%s' is too small for tensor '%s'",
                entry.path.c_str(), entry.tensor_name.c_str()));
        }

        bytes_per_slot += entry.bytes_per_expert;
        layers.insert(entry.layer);
        if (!entries.emplace(entry.tensor_name, std::move(entry)).second) {
            throw std::runtime_error("duplicate tensor in MoE experts manifest");
        }
    }

    if (entries.empty()) {
        throw std::runtime_error("MoE experts manifest has no routed expert tensors");
    }
    n_layer = (int32_t) layers.size();
}

void llama_moe_experts::load_from_gguf(const char * path) {
    namespace fs = std::filesystem;

    std::error_code ec;
    const uint64_t fsize = (uint64_t) fs::file_size(path, ec);
    if (ec || fsize < 1024) {
        throw std::runtime_error(format("MoE experts gguf: cannot read '%s'", path));
    }

    // grow the header buffer until the whole header parsed (4 MB steps)
    std::vector<uint8_t> buf;
    std::vector<gguf_header_scan::rec> recs;
    gguf_header_scan scan;
    uint64_t data_start = 0;
    bool parsed = false;
    {
        std::ifstream f(path, std::ios::binary | std::ios::ate);
        if (!f) {
            throw std::runtime_error(format("MoE experts gguf: failed to open '%s'", path));
        }
        const uint64_t file_size = (uint64_t) f.tellg();
        f.seekg(0);
        for (int attempt = 0; attempt < 16; ++attempt) {
            const uint64_t want = std::min<uint64_t>(file_size, buf.size() + (uint64_t) 4 * 1024 * 1024);
            const size_t old = buf.size();
            buf.resize((size_t) want);
            f.read((char *) buf.data() + old, (std::streamsize) (want - old));
            if (!f) {
                throw std::runtime_error(format("MoE experts gguf: failed reading header of '%s'", path));
            }
            scan = gguf_header_scan{};
            scan.p   = buf.data();
            scan.end = buf.data() + buf.size();
            if (scan.parse(recs)) {
                parsed = true;
                const uint64_t hdr_end = (uint64_t) (scan.p - buf.data());
                data_start = (hdr_end + scan.alignment - 1) / scan.alignment * scan.alignment;
                break;
            }
            if (buf.size() >= file_size) {
                throw std::runtime_error(format("MoE experts gguf: truncated header in '%s'", path));
            }
        }
    }

    if (!parsed) {
        throw std::runtime_error(format("MoE experts gguf: header of '%s' exceeds 64 MB", path));
    }
    if (!scan.saw_expert_count || !scan.saw_expert_used) {
        throw std::runtime_error("MoE experts gguf: .expert_count/.expert_used_count kv missing");
    }
    n_expert      = (int32_t) scan.n_expert;
    n_expert_used = (int32_t) scan.n_expert_used;
    if (n_expert <= 0 || n_expert_used <= 0 || n_expert_used > n_expert) {
        throw std::runtime_error("MoE experts gguf: invalid expert counts");
    }

    std::unordered_set<int32_t> layers;
    for (const auto & r : recs) {
        int32_t layer = -1;
        const std::string family = routed_family_name(r.name, layer);
        if (family.empty()) {
            continue;
        }
        if (r.n_dims != 3 || !r.dims[1] || !r.dims[2] || r.type >= GGML_TYPE_COUNT) {
            throw std::runtime_error(format("MoE experts gguf: routed tensor '%s' has invalid shape/type",
                                            r.name.c_str()));
        }
        llama_moe_experts_entry entry;
        entry.layer         = layer;
        entry.tensor_name   = r.name;
        entry.tensor_family = family;
        entry.path          = path;
        entry.type          = (ggml_type) r.type;
        const size_t row    = ggml_row_size(entry.type, (int64_t) r.dims[0]);
        if (row == 0) {
            throw std::runtime_error(format("MoE experts gguf: routed tensor '%s' has unsupported type",
                                            r.name.c_str()));
        }
        entry.tensor_bytes     = row * (size_t) r.dims[1] * (size_t) r.dims[2];
        entry.bytes_per_expert = entry.tensor_bytes / (size_t) r.dims[2];
        if (entry.bytes_per_expert == 0 ||
            entry.bytes_per_expert * (size_t) r.dims[2] != entry.tensor_bytes) {
            throw std::runtime_error(format("MoE experts gguf: tensor '%s' does not split into whole expert slices",
                                            r.name.c_str()));
        }
        // family-major in-place: experts are contiguous inside one segment
        entry.expert_stride = entry.bytes_per_expert;
        entry.expert_count  = (int32_t) r.dims[2];
        if (r.off > (uint64_t) (std::numeric_limits<size_t>::max)() - data_start) {
            throw std::runtime_error(format("MoE experts gguf: tensor '%s' offset overflow", r.name.c_str()));
        }
        entry.offset = (size_t) (data_start + r.off);
        if (entry.expert_count != n_expert) {
            throw std::runtime_error(format("MoE experts gguf: tensor '%s' has %d experts, expected %d",
                                            r.name.c_str(), entry.expert_count, n_expert));
        }
        if (entry.offset > (size_t) fsize || entry.offset + entry.tensor_bytes > (size_t) fsize) {
            throw std::runtime_error(format("MoE experts gguf: tensor '%s' does not fit in file", r.name.c_str()));
        }
        bytes_per_slot += entry.bytes_per_expert;
        layers.insert(entry.layer);
        if (!entries.emplace(entry.tensor_name, std::move(entry)).second) {
            throw std::runtime_error("MoE experts gguf: duplicate routed tensor");
        }
    }

    if (entries.empty()) {
        throw std::runtime_error(format("MoE experts gguf: '%s' has no routed expert tensors", path));
    }
    n_layer = (int32_t) layers.size();
}

const llama_moe_experts_entry * llama_moe_experts::find(const char * tensor_name) const {
    const auto found = entries.find(tensor_name);
    return found == entries.end() ? nullptr : &found->second;
}

int32_t llama_moe_experts::expert_count() const {
    return n_expert;
}

int32_t llama_moe_experts::expert_used_count() const {
    return n_expert_used;
}

int32_t llama_moe_experts::layer_count() const {
    return n_layer;
}

size_t llama_moe_experts::bytes_per_slot_all_layers() const {
    return bytes_per_slot;
}
