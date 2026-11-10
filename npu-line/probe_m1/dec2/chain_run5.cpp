// [npu-line] Decode chain runner: multi-IO per segment + stepwise loop + rope table offset.
// Manifest line: <ctx> <graph> <NIN> (<name> <id> <dt> <dims> <file> [stride])xNIN
//                <NOUT> (<name> <id> <dt> <dims> <file>)xNOUT
//   stride>0 on an input = byte stride per step into a pre-loaded table (cos/sin);
//   clientBuf points at base + step*stride, no per-step file IO.
// Loop = decode step: whole chain runs once per step; output files relay to next segment's
// inputs (h -> hs, kcache_out -> kcache). CHAIN_KEEP=1 keeps ctxs resident (watch 0x3ea
// memory wall: 42x ~90MB fp16 decode ctxs ~= 3.8 GB).
// usage: chain_run5 <manifest> <steps>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <vector>
#include <string>

#include "QnnInterface.h"
#include "QnnCommon.h"
#include "QnnTypes.h"
#include "QnnBackend.h"
#include "QnnDevice.h"
#include "QnnContext.h"
#include "QnnGraph.h"

static QNN_INTERFACE_VER_TYPE g_qnn = QNN_INTERFACE_VER_TYPE_INIT;
#define STEP(call) \
  do { Qnn_ErrorHandle_t _e = (call); if (_e != QNN_SUCCESS) { \
    printf("CR5_FAIL %s -> 0x%x\n", #call, (unsigned)_e); fflush(stdout); exit(1); } } while (0)

static double now_ms() {
  struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}
static bool parse_dims(const char* s, uint32_t* out, uint32_t cap, uint32_t* rank, size_t* elems) {
  uint32_t r = 0; size_t e = 1; const char* p = s;
  while (*p && r < cap) {
    char* end; long v = strtol(p, &end, 10);
    if (end == p) return false;
    out[r++] = (uint32_t)v; e *= (size_t)v;
    p = (*end == ',') ? end + 1 : end;
  }
  *rank = r; *elems = e; return r > 0;
}
static bool read_file(const char* p, void* buf, size_t n) {
  int fd = open(p, O_RDONLY);
  if (fd < 0) { printf("CR5_FAIL open %s\n", p); return false; }
  ssize_t rd = read(fd, buf, n); close(fd);
  if (rd != (ssize_t)n) { printf("CR5_FAIL read %s got %zd want %zu\n", p, rd, n); return false; }
  return true;
}
static void write_file(const char* p, const void* buf, size_t n) {
  int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return;
  write(fd, buf, n); close(fd);
}

struct IO {
  std::string name, file;
  std::string roll_into;      // output only: host-rolls this many rows into named input
  size_t roll_row = 0;        // row stride in bytes for that roll
  bool is_roll = false;       // input marked as roll target (never re-read from file per step)
  uint32_t id;
  Qnn_DataType_t dt;
  uint32_t dims[4], rank;
  size_t elems, bytes, stride;
  uint8_t* buf = nullptr;      // full table (stride>0) or single buffer
};

struct Seg {
  std::string ctx, graph;
  std::vector<IO> ins, outs;
  Qnn_ContextHandle_t ctxH = nullptr;
  Qnn_GraphHandle_t graphH = nullptr;
};

int main(int argc, char** argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);   // BEFORE any printf: setvbuf after first output is ignored
  if (argc < 3) { printf("usage: chain_run5 <manifest> <steps>\n"); return 1; }
  FILE* mf = fopen(argv[1], "r");
  if (!mf) { printf("CR5_FAIL manifest\n"); return 1; }
  int steps = atoi(argv[2]);
  bool keep = getenv("CHAIN_KEEP") && !strcmp(getenv("CHAIN_KEEP"), "1");

  // Cross-process barrier (split-resident decode: N processes, one per ctx-pool slice):
  // process i executes step t only after counter reaches N*t+i, then writes N*t+i+1.
  // Harness initializes <dir>/counter to "0" before starting the processes.
  const char* gdir = getenv("CR5_GATE");
  int gid = getenv("CR5_ID") ? atoi(getenv("CR5_ID")) : 0;
  int gn = getenv("CR5_GATE_N") ? atoi(getenv("CR5_GATE_N")) : 0;
  std::string cpath = gdir ? (std::string(gdir) + "/counter") : "";
  auto gate_read = [&]() -> long {
    FILE* f = fopen(cpath.c_str(), "r");
    if (!f) return -1;
    long v = -1;
    if (fscanf(f, "%ld", &v) != 1) v = -1;
    fclose(f);
    return v;
  };
  auto gate_wait = [&](long target) -> double {
    double t0 = now_ms(), lastlog = t0;
    for (;;) {
      long v = gate_read();
      if (v >= target) return now_ms() - t0;
      if (now_ms() - lastlog > 2000) { printf("CR5_GATE id=%d waiting target=%ld counter=%ld\n", gid, target, v); lastlog = now_ms(); }
      usleep(100);
    }
  };
  auto gate_post = [&](long v) {
    FILE* f = fopen(cpath.c_str(), "w");
    if (!f) { printf("CR5_FAIL gate post\n"); exit(1); }
    fprintf(f, "%ld", v);
    fclose(f);
  };

  char line[4096];
  std::vector<Seg> segs;
  while (fgets(line, sizeof line, mf)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    char ctx[512], graph[128];
    int nin = 0, nout = 0;
    char* tok = strtok(line, " \t\n");
    if (!tok) continue;
    Seg s; s.ctx = tok;
    tok = strtok(nullptr, " \t\n"); s.graph = tok;
    tok = strtok(nullptr, " \t\n"); nin = atoi(tok);
    for (int i = 0; i < nin; i++) {
      IO io;
      tok = strtok(nullptr, " \t\n"); io.name = tok;
      tok = strtok(nullptr, " \t\n"); io.id = (uint32_t)atoi(tok);
      tok = strtok(nullptr, " \t\n");
      io.dt = !strcmp(tok, "u2") ? QNN_DATATYPE_UFIXED_POINT_16
            : !strcmp(tok, "i4") ? QNN_DATATYPE_INT_32 : QNN_DATATYPE_FLOAT_16;
      tok = strtok(nullptr, " \t\n");
      parse_dims(tok, io.dims, 4, &io.rank, &io.elems);
      tok = strtok(nullptr, " \t\n");
      char* at = strchr(tok, '@');
      io.stride = 0;
      if (at) { *at = 0; io.stride = (size_t)atoll(at + 1); }
      io.file = tok;
      size_t es = io.dt == QNN_DATATYPE_INT_32 ? 4 : 2;
      io.bytes = io.elems * es;
      s.ins.push_back(io);
    }
    tok = strtok(nullptr, " \t\n"); nout = atoi(tok);
    for (int i = 0; i < nout; i++) {
      IO io;
      tok = strtok(nullptr, " \t\n"); io.name = tok;
      // name may carry a host-roll marker: <name>:roll=<inputName>@<rowBytes>
      size_t cp = io.name.find(":roll=");
      if (cp != std::string::npos) {
        std::string r = io.name.substr(cp + 6);
        io.name = io.name.substr(0, cp);
        size_t ap = r.find('@');
        io.roll_into = (ap == std::string::npos) ? r : r.substr(0, ap);
        if (ap != std::string::npos) io.roll_row = (size_t)atoll(r.c_str() + ap + 1);
      }
      tok = strtok(nullptr, " \t\n"); io.id = (uint32_t)atoi(tok);
      tok = strtok(nullptr, " \t\n"); io.dt = QNN_DATATYPE_FLOAT_16;
      tok = strtok(nullptr, " \t\n");
      parse_dims(tok, io.dims, 4, &io.rank, &io.elems);
      tok = strtok(nullptr, " \t\n"); io.file = tok;
      io.bytes = io.elems * 2;
      s.outs.push_back(io);
    }
    for (auto& o : s.outs)
      if (!o.roll_into.empty())
        for (auto& in : s.ins)
          if (in.name == o.roll_into) in.is_roll = true;
    segs.push_back(s);
  }
  fclose(mf);
  printf("CR5 segs=%zu steps=%d keep=%d\n", segs.size(), steps, (int)keep);

  // load tables for stride>0 inputs (whole table once); single buffers otherwise.
  // Tolerate a missing input at startup: relay files (hs/hn/logits chains) are produced by
  // an earlier segment of THIS step or of the previous process — the per-step re-read below
  // is the strict path; zero-filling here only keeps malloc'd buffers defined pre-step-0.
  for (auto& s : segs)
    for (auto& io : s.ins) {
      size_t cap = io.stride ? io.bytes + io.stride * (steps > 0 ? steps - 1 : 0) : io.bytes;
      io.buf = (uint8_t*)malloc(cap);
      if (!read_file(io.file.c_str(), io.buf, io.stride ? io.bytes : cap)) {
        printf("CR5_INFO preload missing %s (zero-filled)\n", io.file.c_str());
        memset(io.buf, 0, cap);
      }
      // stride inputs: table file holds (steps+1) rows; read whole table
      if (io.stride && !read_file(io.file.c_str(), io.buf, io.bytes + io.stride * (steps > 0 ? steps - 1 : 0))) return 1;
    }

  void* htp = dlopen("./lib/libQnnHtp.so", RTLD_NOW | RTLD_LOCAL);
  if (!htp) { printf("CR5_FAIL dlopen: %s\n", dlerror()); return 1; }
  auto getProviders = (Qnn_ErrorHandle_t (*)(const QnnInterface_t***, uint32_t*))
      dlsym(htp, "QnnInterface_getProviders");
  if (!getProviders) { printf("CR5_FAIL dlsym\n"); return 1; }
  const QnnInterface_t** providers = nullptr; uint32_t numProviders = 0;
  if (getProviders(&providers, &numProviders) != QNN_SUCCESS || !numProviders) {
    printf("CR5_FAIL getProviders\n"); return 1;
  }
  bool found = false;
  for (uint32_t i = 0; i < numProviders; i++) {
    if (QNN_API_VERSION_MAJOR == providers[i]->apiVersion.coreApiVersion.major &&
        QNN_API_VERSION_MINOR <= providers[i]->apiVersion.coreApiVersion.minor) {
      g_qnn = providers[i]->QNN_INTERFACE_VER_NAME; found = true; break;
    }
  }
  if (!found) { printf("CR5_FAIL no api match\n"); return 1; }
  Qnn_BackendHandle_t backend = nullptr;
  Qnn_DeviceHandle_t device = nullptr;
  STEP(g_qnn.backendCreate(nullptr, nullptr, &backend));
  STEP(g_qnn.deviceCreate(nullptr, nullptr, &device));

  double wall0 = now_ms(), execTotal = 0;
  for (int t = 0; t < steps; t++) {
    double tw = now_ms(), te = 0;
    double waitms = 0;
    if (gdir && gn > 0) waitms = gate_wait((long)gn * t + gid);
    // Teacher-forcing reseed (realistic e2e): before MY turn each step, overwrite the relay
    // file with step t's reference feed <dir>/d2e_hs_t<t>.raw if present. Per-step input
    // re-reads below then pick it up. (Autoregressive protocol: next input = embedding of
    // the sampled token — NOT the previous step's hidden state.)
    {
      const char* rdir = getenv("CR5_RESEED_DIR");
      const char* rdst = getenv("CR5_RESEED_DST");
      if (rdir && rdst && gid == 0) {
        char src[768];
        snprintf(src, sizeof src, "%s/d2e_hs_t%d.raw", rdir, t);
        int sfd = open(src, O_RDONLY);
        if (sfd >= 0) {
          struct stat sb; fstat(sfd, &sb);
          uint8_t* b = (uint8_t*)malloc(sb.st_size);
          if (b && read(sfd, b, sb.st_size) == (ssize_t)sb.st_size) {
            int dfd = open(rdst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (dfd >= 0) { write(dfd, b, sb.st_size); close(dfd); }
          }
          free(b); close(sfd);
        }
      }
    }
    for (size_t i = 0; i < segs.size(); i++) {
      Seg& s = segs[i];
      if (!s.graphH) {
        printf("CR5_SEG %zu %s load...\n", i, s.graph.c_str());
        int fd = open(s.ctx.c_str(), O_RDONLY);
        if (fd < 0) { printf("CR5_FAIL open ctx\n"); return 1; }
        struct stat st; fstat(fd, &st);
        uint8_t* ctxBuf = (uint8_t*)mmap(nullptr, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        close(fd);
        STEP(g_qnn.contextCreateFromBinary(backend, device, nullptr, (const void*)ctxBuf,
                                           (Qnn_ContextBinarySize_t)st.st_size, &s.ctxH, nullptr));
        munmap(ctxBuf, st.st_size);
        STEP(g_qnn.graphRetrieve(s.ctxH, s.graph.c_str(), &s.graphH));
      }
      // per-step relay: plain inputs re-read every step (h -> hs via file),
      // stride tables not re-read, roll inputs are host-managed after each step.
      for (auto& io : s.ins)
        if (!io.stride && !io.is_roll && !read_file(io.file.c_str(), io.buf, io.bytes)) return 1;
      std::vector<Qnn_Tensor_t> tins(s.ins.size()), touts(s.outs.size());
      for (size_t j = 0; j < s.ins.size(); j++) {
        IO& io = s.ins[j];
        Qnn_Tensor_t& T = tins[j];
        memset(&T, 0, sizeof T);
        T.version = QNN_TENSOR_VERSION_2;
        T.v2.id = io.id; T.v2.name = io.name.c_str();
        T.v2.type = QNN_TENSOR_TYPE_APP_WRITE;
        T.v2.dataFormat = QNN_TENSOR_DATA_FORMAT_FLAT_BUFFER;
        T.v2.dataType = io.dt;
        T.v2.rank = io.rank; T.v2.dimensions = io.dims;
        T.v2.memType = QNN_TENSORMEMTYPE_RAW;
        T.v2.clientBuf.data = io.stride ? io.buf + (size_t)t * io.stride : io.buf;
        T.v2.clientBuf.dataSize = (uint32_t)io.bytes;
      }
      for (size_t j = 0; j < s.outs.size(); j++) {
        IO& io = s.outs[j];
        if (!io.buf) io.buf = (uint8_t*)malloc(io.bytes);
        Qnn_Tensor_t& T = touts[j];
        memset(&T, 0, sizeof T);
        T.version = QNN_TENSOR_VERSION_2;
        T.v2.id = io.id; T.v2.name = io.name.c_str();
        T.v2.type = QNN_TENSOR_TYPE_APP_READ;
        T.v2.dataFormat = QNN_TENSOR_DATA_FORMAT_FLAT_BUFFER;
        T.v2.dataType = QNN_DATATYPE_FLOAT_16;
        T.v2.rank = io.rank; T.v2.dimensions = io.dims;
        T.v2.memType = QNN_TENSORMEMTYPE_RAW;
        T.v2.clientBuf.data = io.buf; T.v2.clientBuf.dataSize = (uint32_t)io.bytes;
      }
      printf("CR5_SEG %zu %s exec...\n", i, s.graph.c_str());
      double a = now_ms();
      STEP(g_qnn.graphExecute(s.graphH, tins.data(), (uint32_t)tins.size(),
                              touts.data(), (uint32_t)touts.size(), nullptr, nullptr));
      te += now_ms() - a; execTotal += now_ms() - a;
      for (auto& io : s.outs) {
        if (!io.roll_into.empty()) {
          IO* tgt = nullptr;
          for (auto& in : s.ins) if (in.name == io.roll_into) tgt = &in;
          if (!tgt || !io.roll_row || tgt->bytes < io.roll_row * 2) {
            printf("CR5_FAIL roll cfg %s\n", io.roll_into.c_str()); return 1; }
          memmove(tgt->buf, tgt->buf + io.roll_row, tgt->bytes - io.roll_row);
          memcpy(tgt->buf + tgt->bytes - io.roll_row, io.buf, io.roll_row);
          if (!io.file.empty() && io.file != "-") write_file(io.file.c_str(), io.buf, io.bytes);
          continue;
        }
        write_file(io.file.c_str(), io.buf, io.bytes);
      }
      if (!keep && s.graphH) { STEP(g_qnn.contextFree(s.ctxH, nullptr)); s.ctxH = nullptr; s.graphH = nullptr; }
    }
    if (gdir && gn > 0) gate_post((long)gn * t + gid + 1);
    printf("CR5_STEP %d id=%d wall=%.1f exec=%.1f wait=%.1f ms\n", t, gid, now_ms() - tw, te, waitms);
  }
  for (auto& s : segs) { if (s.ctxH) g_qnn.contextFree(s.ctxH, nullptr); }
  g_qnn.contextFree(device, nullptr);
  g_qnn.backendFree(backend);
  double wall = now_ms() - wall0;
  printf("CR5_DONE steps=%d wall=%.1f ms tok_per_s=%.1f exec=%.1f\n",
         steps, wall, steps * 1000.0 / wall, execTotal);
  return 0;
}
