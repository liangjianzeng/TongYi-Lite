R"(// [dspark 2026-10-15] M2: GPU slot bank raw->plane conversion for q3_K batched MoE.
)"
R"(//
)"
R"(// With LLAMA_MOE_BANK_GPU=1 the slot bank lives in FGSVM memory (preadv writes
)"
R"(// raw q3_K bytes straight into it from the IO threads). Per slot fill, this
)"
R"(// kernel converts ONE expert's raw bytes into the batched kernel's planes,
)"
R"(// replicating ggml-backend.cpp set_tensor's Q3_K host packing EXACTLY:
)"
R"(//
)"
R"(//   q plane (E layers, uint pixels): per (row-pair rp, 32-block k) 6 uints at
)"
R"(//     pix = slot*layer_pix + k*3*Mc + (jo + j)*(Mc/2) + rp,  jo = (r&1)*3, rp = r>>1
)"
R"(//     [qs_lo, qs_hi, hmb] = 3 uints per row of the pair; layer_pix = Mc*n_blk*3
)"
R"(//   se0 (row-even) / se1 (row-odd): half2 (dl0, dl1) at
)"
R"(//     idx = (slot*se_half2 + k*(Mc/2) + rp)*2 halves,  se_half2 = n_blk*(Mc/2)
)"
R"(//
)"
R"(// raw layout per 110-byte block: hmask[32] @0, qs[64] @32, scales[12] @96, d(fp16) @108.
)"
R"(// One work item per (row r, superblock sb): global = Mc * n_sb.
)"
R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(__kernel void kernel_moe_q3k_pack(
)"
R"(        __global const uchar * raw,   // raw q3_K bytes: cl_mem staging buffer
)"
R"(                                      // (staged upload) or FGSVM slot region
)"
R"(        __global uint  * qplane,      // base q plane (uint pixels)
)"
R"(        __global half  * se0,         // base se0 plane (halves)
)"
R"(        __global half  * se1,         // base se1 plane (halves)
)"
R"(        const uint plane_slot,        // expert-slot index within the base tensor
)"
R"(        const uint Mc,                // rows per expert (K%256==0, M%128==0 gated host-side)
)"
R"(        const uint n_sb,              // superblocks per row (K/256)
)"
R"(        const ulong raw_off)          // byte offset of this expert's raw bytes
)"
R"(                                      // (WriteBuffer path: plane_slot*bpe; SVM
)"
R"(                                      // direct path: 0 — SVM pointer already
)"
R"(                                      /// points at the slot)
)"
R"({
)"
R"(    // [dspark M2 fix] gid mapping: sb slow, r FAST. Consecutive work items
)"
R"(    // (same sb, consecutive r) write consecutive rp addresses within the same
)"
R"(    // plane strip — the old (r,sb) mapping scattered a subgroup's stores
)"
R"(    // 3*Mc*4B apart (uncoalesced), making the pack ~1.7ms for 4MB (bank13/17).
)"
R"(    const uint gid = get_global_id(0);
)"
R"(    const uint sb  = gid / Mc;
)"
R"(    const uint r   = gid - sb * Mc;
)"
R"(    if (r >= Mc || sb >= n_sb) {
)"
R"(        return;
)"
R"(    }
)"
R"(
)"
R"(    const uint   n_blk     = n_sb * 8;
)"
R"(    const size_t layer_pix = (size_t)Mc * n_blk * 3;
)"
R"(    const size_t se_half2  = (size_t)n_blk * (Mc / 2);
)"
R"(
)"
R"(    const size_t blk_bytes = 110;
)"
R"(    __global const uchar * blk = raw + raw_off + ((size_t)r * n_sb + sb) * blk_bytes;
)"
R"(
)"
R"(    const float d = (float)vload_half(54, (const __global half *)blk);   // byte 108
)"
R"(    const __global uchar * hm = blk + 0;
)"
R"(    const __global uchar * qs = blk + 32;
)"
R"(
)"
R"(    // decode the 16 4-bit scales (aux32 shuffle, ggml-quants.c) — little-endian
)"
R"(    const uint kmask1 = 0x03030303;
)"
R"(    const uint kmask2 = 0x0f0f0f0f;
)"
R"(    uint aux0 = ((uint)blk[ 96])       | ((uint)blk[ 97] <<  8) | ((uint)blk[ 98] << 16) | ((uint)blk[ 99] << 24);
)"
R"(    uint aux1 = ((uint)blk[100])       | ((uint)blk[101] <<  8) | ((uint)blk[102] << 16) | ((uint)blk[103] << 24);
)"
R"(    uint tmp  = ((uint)blk[104])       | ((uint)blk[105] <<  8) | ((uint)blk[106] << 16) | ((uint)blk[107] << 24);
)"
R"(    uint aux2 = ((aux0 >> 4) & kmask2) | (((tmp >> 4) & kmask1) << 4);
)"
R"(    uint aux3 = ((aux1 >> 4) & kmask2) | (((tmp >> 6) & kmask1) << 4);
)"
R"(    aux0      = ( aux0       & kmask2) | (((tmp >> 0) & kmask1) << 4);
)"
R"(    aux1      = ( aux1       & kmask2) | (((tmp >> 2) & kmask1) << 4);
)"
R"(    // sign-extend each byte (host: (const int8_t *)aux)
)"
R"(    int scales[16];
)"
R"(    {
)"
R"(        const uint auxw[4] = { aux0, aux1, aux2, aux3 };
)"
R"(        for (int i = 0; i < 16; ++i) {
)"
R"(            scales[i] = (int)(((auxw[i >> 2] >> ((i & 3) * 8)) & 0xffu) << 24) >> 24;
)"
R"(        }
)"
R"(    }
)"
R"(
)"
R"(    const size_t jo = (size_t)(r & 1) * 3;
)"
R"(    const size_t rp = (size_t)r >> 1;
)"
R"(    __global half * se_plane = (r & 1) == 0 ? se0 : se1;
)"
R"(
)"
R"(    // [dspark M2 v3] hoist the block bytes into registers with vload4 — the
)"
R"(    // original per-element uchar loads (512 global loads per work item) made
)"
R"(    // the pack latency-bound at 1.7ms regardless of read source / store
)"
R"(    // mapping (bank13/17/18). After unrolling, every index is a compile-time
)"
R"(    // constant and the whole pack is a few dozen ALU ops + 24 plane stores.
)"
R"(    // hmask: 32 bytes -> 2 x uint4 (bytes 0..15 / 16..31)
)"
R"(    const uint4 hm04 = vload4(0, (const __global uint *)hm);
)"
R"(    const uint4 hm14 = vload4(1, (const __global uint *)hm);
)"
R"(
)"
R"(    #pragma unroll 8
)"
R"(    for (int pos = 0; pos < 8; ++pos) {
)"
R"(        const size_t k = (size_t)sb * 8 + (size_t)pos;
)"
R"(        const float dl0 = d * (float)(scales[pos * 2]     - 32);
)"
R"(        const float dl1 = d * (float)(scales[pos * 2 + 1] - 32);
)"
R"(
)"
R"(        __global half * se2 = se_plane + ((plane_slot * se_half2 + k * (Mc / 2) + rp) * 2);
)"
R"(        se2[0] = (half)dl0;
)"
R"(        se2[1] = (half)dl1;
)"
R"(
)"
R"(        // byte index of element e = pos*32 + l:  chunk*32 + h16*16 + (e & 15)
)"
R"(        //   l < 16 : idx = (pos>>2)*32 + l          (h16 = 0)
)"
R"(        //   l >= 16: idx = (pos>>2)*32 + 16 + (l-16) (h16 = 1)
)"
R"(        // -> two CONSECUTIVE 16-byte runs per pos, one uint4 vload4 each.
)"
R"(        const __global uchar * qsbase = qs + (pos >> 2) * 32;
)"
R"(        const uint4 qlo_a = vload4(0, (const __global uint *)qsbase);
)"
R"(        const uint4 qlo_b = vload4(1, (const __global uint *)qsbase);
)"
R"(        const uint4 qlo_c = vload4(2, (const __global uint *)qsbase);
)"
R"(        const uint4 qlo_d = vload4(3, (const __global uint *)qsbase);
)"
R"(        const uint4 qhi_a = vload4(4, (const __global uint *)qsbase);
)"
R"(        const uint4 qhi_b = vload4(5, (const __global uint *)qsbase);
)"
R"(        const uint4 qhi_c = vload4(6, (const __global uint *)qsbase);
)"
R"(        const uint4 qhi_d = vload4(7, (const __global uint *)qsbase);
)"
R"(        const int shift = 2 * (pos & 3);
)"
R"(
)"
R"(        uint qs_lo = 0, qs_hi = 0;
)"
R"(        #pragma unroll
)"
R"(        for (int l = 0; l < 16; ++l) {
)"
R"(            const int w = l >> 2;               // uint word within the run
)"
R"(            const int bsh = (l & 3) * 8;        // byte within the word
)"
R"(            const uint qlo = (w == 0 ? qlo_a.s0 : w == 1 ? qlo_b.s0 : w == 2 ? qlo_c.s0 : qlo_d.s0) >> bsh;
)"
R"(            const uint qhi = (w == 0 ? qhi_a.s0 : w == 1 ? qhi_b.s0 : w == 2 ? qhi_c.s0 : qhi_d.s0) >> bsh;
)"
R"(            qs_lo |= ((qlo >> shift) & 3u) << (2 * l);
)"
R"(            qs_hi |= ((qhi >> shift) & 3u) << (2 * l);
)"
R"(        }
)"
R"(        // hmask bit of element e = pos*32 + l:  byte (e & 31) = l, bit pos
)"
R"(        //   -> hmb bit l = (hm[l] >> pos) & 1, l = 0..31 (hm04: bytes 0..15)
)"
R"(        uint hmb = 0;
)"
R"(        #pragma unroll
)"
R"(        for (int l = 0; l < 32; ++l) {
)"
R"(            const uint hword = (l < 16)
)"
R"(                ? (l < 4 ? hm04.s0 : l < 8 ? hm04.s1 : l < 12 ? hm04.s2 : hm04.s3)
)"
R"(                : (l < 20 ? hm14.s0 : l < 24 ? hm14.s1 : l < 28 ? hm14.s2 : hm14.s3);
)"
R"(            const int hsh = (l & 3) * 8 + pos;
)"
R"(            hmb |= ((hword >> hsh) & 1u) << l;
)"
R"(        }
)"
R"(        const size_t pix = (size_t)plane_slot * layer_pix + k * 3 * (size_t)Mc;
)"
R"(        qplane[pix + (jo + 0) * (Mc / 2) + rp] = qs_lo;
)"
R"(        qplane[pix + (jo + 1) * (Mc / 2) + rp] = qs_hi;
)"
R"(        qplane[pix + (jo + 2) * (Mc / 2) + rp] = hmb;
)"
R"(    }
)"
R"(}
)"
