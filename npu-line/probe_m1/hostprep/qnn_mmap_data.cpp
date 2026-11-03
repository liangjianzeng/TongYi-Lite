// [C32] Runtime file-backed tensor data for model libs (bypasses the 4GiB ELF/objcopy wall).
// With the patched QnnWrapperUtils.hpp, BINVARSTART/BINLEN resolve through this registry:
// each tensor's bytes are mmap'd from $QNN_MODEL_DATA_DIR/<tensor_member_name>.raw on demand.
// The compose process reads each tensor exactly once; net-run --retrieve_context never calls in.
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <unistd.h>

namespace {
struct Ent { char name[224]; void* ptr; uint64_t len; };
const int kMax = 512;
Ent g_tbl[kMax];
int g_n = 0;

const char* data_dir() {
    const char* d = getenv("QNN_MODEL_DATA_DIR");
    return (d && *d) ? d : ".";
}

Ent* find_or_load(const char* name) {
    for (int i = 0; i < g_n; ++i)
        if (strcmp(g_tbl[i].name, name) == 0) return &g_tbl[i];
    if (g_n >= kMax) { fprintf(stderr, "qnn_mmap_data: table full\n"); return nullptr; }
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.raw", data_dir(), name);
    int fd = ::open(path, O_RDONLY);
    if (fd < 0) { fprintf(stderr, "qnn_mmap_data: cannot open %s\n", path); return nullptr; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) { ::close(fd); fprintf(stderr, "qnn_mmap_data: bad size %s\n", path); return nullptr; }
    void* p = mmap(nullptr, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    ::close(fd);
    if (p == MAP_FAILED) { fprintf(stderr, "qnn_mmap_data: mmap failed %s\n", path); return nullptr; }
    Ent& e = g_tbl[g_n++];
    snprintf(e.name, sizeof(e.name), "%s", name);
    e.ptr = p;
    e.len = (uint64_t)st.st_size;
    return &e;
}
} // namespace

extern "C" void* qnn_mmap_get(const char* name) {
    Ent* e = find_or_load(name);
    return e ? e->ptr : nullptr;
}
extern "C" uint64_t qnn_mmap_len(const char* name) {
    Ent* e = find_or_load(name);
    return e ? e->len : 0;
}
