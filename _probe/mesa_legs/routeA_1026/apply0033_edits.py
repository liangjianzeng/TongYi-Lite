#!/usr/bin/env python3
# [TongYi-Lite 0033 E4 round-3] R10 probes, dangling-free redesign (e4d crashed
# rc=139 reading a munmap'd cached ring):
#  - e4_save entries store handle+iova+gpuaddr+size+crc (NO raw map pointer).
#  - E4VERIFY looks up the *current* live mapping via handle_table (new helper
#    fd_bo_e4_lookup in freedreno_bo.c); dead -> SKIPPED(nolive), handle reused
#    with different iova -> SKIPPED(iova). Never dereferences stale pointers.
#  - E4REUSE uses the live bo passed at acquire time (heap path too, the path
#    softpin actually takes; the 0032 cache-only hook never fired: E4REUSE=0).
#  - NO bo references are held anywhere: holding refs would block the very
#    slot reuse we are trying to observe (self-neutering probe).
import sys, os

TREE = os.environ.get("E4TREE", "/root/mesa-26.2.4")

def edit(path, pairs):
    with open(path) as f: s = f.read()
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            print(f"ANCHOR FAIL count={n} in {path} :: {old[:70]!r}")
            sys.exit(1)
        s = s.replace(old, new, 1)
    with open(path, "w") as f: f.write(s)
    print("OK", path)

KRB = TREE + "/src/freedreno/drm/kgsl/kgsl_ringbuffer_sp.c"

RB_PAIRS = [
    # struct: no map pointer, add iova
    ("""    uint64_t gpuaddr;
    uint32_t size;
    uint32_t crc;
    const uint32_t *map;
    uint32_t queue_id;
    int valid;
};""",
     """    uint64_t gpuaddr;
    uint32_t size;
    uint32_t crc;
    uint64_t iova;   /* [0033] for live-mapping re-derivation */
    uint32_t queue_id;
    int valid;
};"""),
    # save: no ptr stored
    ("""    const uint32_t *ptr = (const uint32_t *)((const uint8_t *)bo->map + off);
    uint32_t crc = e4_crc32(ptr, size);""",
     """    const uint32_t *ptr = (const uint32_t *)((const uint8_t *)bo->map + off);
    uint32_t crc = e4_crc32(ptr, size);
    (void)0; /* [0033] ptr not stored; verified via live mapping later */"""),
    # probe-slot fill: map -> iova
    ("""            e->crc = crc;
            e->map = ptr;
            e->queue_id = queue_id;""",
     """            e->crc = crc;
            e->iova = bo->iova;   /* [0033] */
            e->queue_id = queue_id;"""),
    # fallback fill: map -> iova
    ("""    e->crc = crc;
    e->map = ptr;
    e->queue_id = queue_id;""",
     """    e->crc = crc;
    e->iova = bo->iova;   /* [0033] */
    e->queue_id = queue_id;"""),
    # verify: live lookup instead of saved pointer
    ("""void
kgsl_e4_verify(struct fd_device *dev, uint32_t queue_id, uint32_t ts)
{
    (void)dev;
    if (!e4_enabled() || ts == 0)
        return;
    for (unsigned i = 0; i < E4_TABLE_SZ; i++) {
        struct e4_save *e = &e4_table[i];
        if (!e->valid || e->ts != ts || e->queue_id != queue_id)
            continue;
        if (!e->map)
            continue;
        uint32_t now = e4_crc32(e->map, e->size);
        fprintf(stderr,
            "E4VERIFY ts=%u handle=%u gpuaddr=0x%llx size=%u crc_then=%08x crc_now=%08x %s rt=%llu\\n",
            ts, e->handle, (unsigned long long)e->gpuaddr, e->size,
            e->crc, now, (now == e->crc) ? "OK" : "MISMATCH", e4_now_ns());
    }
}""",
     """extern struct fd_bo *fd_bo_e4_lookup(struct fd_device *dev, uint32_t handle);

void
kgsl_e4_verify(struct fd_device *dev, uint32_t queue_id, uint32_t ts)
{
    if (!e4_enabled() || ts == 0)
        return;
    for (unsigned i = 0; i < E4_TABLE_SZ; i++) {
        struct e4_save *e = &e4_table[i];
        if (!e->valid || e->ts != ts || e->queue_id != queue_id)
            continue;
        /* [0033] resolve the LIVE mapping by handle; never touch stale ptrs. */
        struct fd_bo *bo = fd_bo_e4_lookup(dev, e->handle);
        if (!bo || !bo->map) {
            fprintf(stderr,
                "E4VERIFY ts=%u handle=%u gpuaddr=0x%llx size=%u crc_then=%08x SKIPPED(nolive) rt=%llu\\n",
                ts, e->handle, (unsigned long long)e->gpuaddr, e->size,
                e->crc, e4_now_ns());
            continue;
        }
        if (bo->iova != e->iova) {
            fprintf(stderr,
                "E4VERIFY ts=%u handle=%u gpuaddr=0x%llx size=%u crc_then=%08x SKIPPED(iova old=0x%llx new=0x%llx) rt=%llu\\n",
                ts, e->handle, (unsigned long long)e->gpuaddr, e->size,
                e->crc, (unsigned long long)e->iova,
                (unsigned long long)bo->iova, e4_now_ns());
            continue;
        }
        uint64_t off = e->gpuaddr - e->iova;
        if (off + e->size > bo->size) {
            fprintf(stderr,
                "E4VERIFY ts=%u handle=%u SKIPPED(bounds) rt=%llu\\n",
                ts, e->handle, e4_now_ns());
            continue;
        }
        uint32_t now = e4_crc32((const uint8_t *)bo->map + off, e->size);
        fprintf(stderr,
            "E4VERIFY ts=%u handle=%u gpuaddr=0x%llx size=%u crc_then=%08x crc_now=%08x %s rt=%llu\\n",
            ts, e->handle, (unsigned long long)e->gpuaddr, e->size,
            e->crc, now, (now == e->crc) ? "OK" : "MISMATCH", e4_now_ns());
    }
}"""),
    # reuse: live bo, no saved-ptr reads
    ("""        uint32_t now = e->map ? e4_crc32(e->map, e->size) : 0;
        fprintf(stderr,
            "E4REUSE handle=%u ts=%u reached=%d crc_then=%08x crc_now=%08x %s rt=%llu\\n",
            bo->handle, e->ts, reached, e->crc, now,
            (!e->map) ? "NOMAP" : ((now == e->crc) ? "OK" : "MISMATCH"),
            e4_now_ns());""",
     """        /* [0033] read the live mapping of the bo being acquired now. */
        uint32_t now = 0;
        int have = 0;
        if (bo->map && e->iova == bo->iova && bo->size == e->size + (e->gpuaddr - e->iova)) {
            uint64_t off = e->gpuaddr - e->iova;
            if (off + e->size <= bo->size) {
                now = e4_crc32((const uint8_t *)bo->map + off, e->size);
                have = 1;
            }
        }
        fprintf(stderr,
            "E4REUSE handle=%u ts=%u reached=%d crc_then=%08x crc_now=%08x %s rt=%llu\\n",
            bo->handle, e->ts, reached, e->crc, now,
            have ? ((now == e->crc) ? "OK" : "MISMATCH") : "SKIPPED",
            e4_now_ns());"""),
]

FBO = TREE + "/src/freedreno/drm/freedreno_bo.c"
BO_PAIRS = [
    ("""/* allocate a new buffer object, call w/ table_lock held */""",
     """/* [TongYi-Lite 0033 E4r3] live-bo lookup for the E4 verify probe (diag only).
 * Returns a pointer whose liveness is only guaranteed for the duration of the
 * caller's read; acceptable for stderr diagnostics. */
struct fd_bo *
fd_bo_e4_lookup(struct fd_device *dev, uint32_t handle)
{
   struct fd_bo *bo;
   simple_mtx_lock(&table_lock);
   bo = lookup_bo(dev->handle_table, handle);
   simple_mtx_unlock(&table_lock);
   return bo;
}

/* allocate a new buffer object, call w/ table_lock held */"""),
    ("""      else if ((flags == RING_FLAGS) && dev->ring_heap)
         bo = fd_bo_heap_alloc(dev->ring_heap, size, flags);
      if (bo)
         return bo;
""",
     """      else if ((flags == RING_FLAGS) && dev->ring_heap)
         bo = fd_bo_heap_alloc(dev->ring_heap, size, flags);
      if (bo) {
         /* [TongYi-Lite 0033 E4r3] under softpin rings come from the ring
          * heap and never reach fd_bo_cache_alloc, so the reuse observation
          * must fire here too. */
         extern void __attribute__((weak)) kgsl_e4_ring_reused(struct fd_bo *bo);
         if ((flags == RING_FLAGS) && kgsl_e4_ring_reused)
            kgsl_e4_ring_reused(bo);
         return bo;
      }
"""),
]

edit(KRB, RB_PAIRS)
edit(FBO, BO_PAIRS)
print("ALL 0033 EDITS APPLIED")
