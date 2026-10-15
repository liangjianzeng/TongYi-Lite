// [dspark 2026-10-15] M2: GPU slot bank raw->plane conversion for q3_K batched MoE.
//
// With LLAMA_MOE_BANK_GPU=1 the slot bank lives in FGSVM memory (preadv writes
// raw q3_K bytes straight into it from the IO threads). Per slot fill, this
// kernel converts ONE expert's raw bytes into the batched kernel's planes,
// replicating ggml-backend.cpp set_tensor's Q3_K host packing EXACTLY:
//
//   q plane (E layers, uint pixels): per (row-pair rp, 32-block k) 6 uints at
//     pix = slot*layer_pix + k*3*Mc + (jo + j)*(Mc/2) + rp,  jo = (r&1)*3, rp = r>>1
//     [qs_lo, qs_hi, hmb] = 3 uints per row of the pair; layer_pix = Mc*n_blk*3
//   se0 (row-even) / se1 (row-odd): half2 (dl0, dl1) at
//     idx = (slot*se_half2 + k*(Mc/2) + rp)*2 halves,  se_half2 = n_blk*(Mc/2)
//
// raw layout per 110-byte block: hmask[32] @0, qs[64] @32, scales[12] @96, d(fp16) @108.
// One work item per (row r, superblock sb): global = Mc * n_sb.
#pragma OPENCL EXTENSION cl_khr_fp16 : enable
__kernel void kernel_moe_q3k_pack(
        __global const uchar * raw,   // raw q3_K bytes: cl_mem staging buffer
                                      // (staged upload) or FGSVM slot region
        __global uint  * qplane,      // base q plane (uint pixels)
        __global half  * se0,         // base se0 plane (halves)
        __global half  * se1,         // base se1 plane (halves)
        const uint plane_slot,        // expert-slot index within the base tensor
        const uint Mc,                // rows per expert (K%256==0, M%128==0 gated host-side)
        const uint n_sb,              // superblocks per row (K/256)
        const ulong raw_off)          // byte offset of this expert's raw bytes
                                      // (WriteBuffer path: plane_slot*bpe; SVM
                                      // direct path: 0 — SVM pointer already
                                      /// points at the slot)
{
    // [dspark M2 fix] gid mapping: sb slow, r FAST. Consecutive work items
    // (same sb, consecutive r) write consecutive rp addresses within the same
    // plane strip — the old (r,sb) mapping scattered a subgroup's stores
    // 3*Mc*4B apart (uncoalesced), making the pack ~1.7ms for 4MB (bank13/17).
    const uint gid = get_global_id(0);
    const uint sb  = gid / Mc;
    const uint r   = gid - sb * Mc;
    if (r >= Mc || sb >= n_sb) {
        return;
    }

    const uint   n_blk     = n_sb * 8;
    const size_t layer_pix = (size_t)Mc * n_blk * 3;
    const size_t se_half2  = (size_t)n_blk * (Mc / 2);

    const size_t blk_bytes = 110;
    __global const uchar * blk = raw + raw_off + ((size_t)r * n_sb + sb) * blk_bytes;

    const float d = (float)vload_half(54, (const __global half *)blk);   // byte 108
    const __global uchar * hm = blk + 0;
    const __global uchar * qs = blk + 32;

    // decode the 16 4-bit scales (aux32 shuffle, ggml-quants.c) — little-endian
    const uint kmask1 = 0x03030303;
    const uint kmask2 = 0x0f0f0f0f;
    uint aux0 = ((uint)blk[ 96])       | ((uint)blk[ 97] <<  8) | ((uint)blk[ 98] << 16) | ((uint)blk[ 99] << 24);
    uint aux1 = ((uint)blk[100])       | ((uint)blk[101] <<  8) | ((uint)blk[102] << 16) | ((uint)blk[103] << 24);
    uint tmp  = ((uint)blk[104])       | ((uint)blk[105] <<  8) | ((uint)blk[106] << 16) | ((uint)blk[107] << 24);
    uint aux2 = ((aux0 >> 4) & kmask2) | (((tmp >> 4) & kmask1) << 4);
    uint aux3 = ((aux1 >> 4) & kmask2) | (((tmp >> 6) & kmask1) << 4);
    aux0      = ( aux0       & kmask2) | (((tmp >> 0) & kmask1) << 4);
    aux1      = ( aux1       & kmask2) | (((tmp >> 2) & kmask1) << 4);
    // sign-extend each byte (host: (const int8_t *)aux)
    int scales[16];
    {
        const uint auxw[4] = { aux0, aux1, aux2, aux3 };
        for (int i = 0; i < 16; ++i) {
            scales[i] = (int)(((auxw[i >> 2] >> ((i & 3) * 8)) & 0xffu) << 24) >> 24;
        }
    }

    const size_t jo = (size_t)(r & 1) * 3;
    const size_t rp = (size_t)r >> 1;
    __global half * se_plane = (r & 1) == 0 ? se0 : se1;

    // [dspark M2 v3] hoist the block bytes into registers with vload4 — the
    // original per-element uchar loads (512 global loads per work item) made
    // the pack latency-bound at 1.7ms regardless of read source / store
    // mapping (bank13/17/18). After unrolling, every index is a compile-time
    // constant and the whole pack is a few dozen ALU ops + 24 plane stores.
    // hmask: 32 bytes -> 2 x uint4 (bytes 0..15 / 16..31)
    const uint4 hm04 = vload4(0, (const __global uint *)hm);
    const uint4 hm14 = vload4(1, (const __global uint *)hm);

    #pragma unroll 8
    for (int pos = 0; pos < 8; ++pos) {
        const size_t k = (size_t)sb * 8 + (size_t)pos;
        const float dl0 = d * (float)(scales[pos * 2]     - 32);
        const float dl1 = d * (float)(scales[pos * 2 + 1] - 32);

        __global half * se2 = se_plane + ((plane_slot * se_half2 + k * (Mc / 2) + rp) * 2);
        se2[0] = (half)dl0;
        se2[1] = (half)dl1;

        // byte index of element e = pos*32 + l:  chunk*32 + h16*16 + (e & 15)
        //   l < 16 : idx = (pos>>2)*32 + l          (h16 = 0)
        //   l >= 16: idx = (pos>>2)*32 + 16 + (l-16) (h16 = 1)
        // -> two CONSECUTIVE 16-byte runs per pos, one uint4 vload4 each.
        const __global uchar * qsbase = qs + (pos >> 2) * 32;
        const uint4 qlo_a = vload4(0, (const __global uint *)qsbase);
        const uint4 qlo_b = vload4(1, (const __global uint *)qsbase);
        const uint4 qlo_c = vload4(2, (const __global uint *)qsbase);
        const uint4 qlo_d = vload4(3, (const __global uint *)qsbase);
        const uint4 qhi_a = vload4(4, (const __global uint *)qsbase);
        const uint4 qhi_b = vload4(5, (const __global uint *)qsbase);
        const uint4 qhi_c = vload4(6, (const __global uint *)qsbase);
        const uint4 qhi_d = vload4(7, (const __global uint *)qsbase);
        const int shift = 2 * (pos & 3);

        uint qs_lo = 0, qs_hi = 0;
        #pragma unroll
        for (int l = 0; l < 16; ++l) {
            const int w = l >> 2;               // uint word within the run
            const int bsh = (l & 3) * 8;        // byte within the word
            const uint qlo = (w == 0 ? qlo_a.s0 : w == 1 ? qlo_b.s0 : w == 2 ? qlo_c.s0 : qlo_d.s0) >> bsh;
            const uint qhi = (w == 0 ? qhi_a.s0 : w == 1 ? qhi_b.s0 : w == 2 ? qhi_c.s0 : qhi_d.s0) >> bsh;
            qs_lo |= ((qlo >> shift) & 3u) << (2 * l);
            qs_hi |= ((qhi >> shift) & 3u) << (2 * l);
        }
        // hmask bit of element e = pos*32 + l:  byte (e & 31) = l, bit pos
        //   -> hmb bit l = (hm[l] >> pos) & 1, l = 0..31 (hm04: bytes 0..15)
        uint hmb = 0;
        #pragma unroll
        for (int l = 0; l < 32; ++l) {
            const uint hword = (l < 16)
                ? (l < 4 ? hm04.s0 : l < 8 ? hm04.s1 : l < 12 ? hm04.s2 : hm04.s3)
                : (l < 20 ? hm14.s0 : l < 24 ? hm14.s1 : l < 28 ? hm14.s2 : hm14.s3);
            const int hsh = (l & 3) * 8 + pos;
            hmb |= ((hword >> hsh) & 1u) << l;
        }
        const size_t pix = (size_t)plane_slot * layer_pix + k * 3 * (size_t)Mc;
        qplane[pix + (jo + 0) * (Mc / 2) + rp] = qs_lo;
        qplane[pix + (jo + 1) * (Mc / 2) + rp] = qs_hi;
        qplane[pix + (jo + 2) * (Mc / 2) + rp] = hmb;
    }
}
