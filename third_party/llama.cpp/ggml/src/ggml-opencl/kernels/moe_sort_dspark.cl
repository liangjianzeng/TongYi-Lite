// [dspark 2026-10-14] P3 expert-bucket-sort kernels - standalone program.
// Moved out of gemv_noshuffle_q4_0_f32.cl: on Adreno 830 (E031.47) the q4_0
// batched kernel miscompiles when compiled alongside the perm param / extra
// kernels (NMSE~2.2, 2026-10-14). P3 sort is now q3_K-only, and these kernels
// get their own tiny program so the q4_0/q4_K program texts stay minimal.
// [dspark 2026-10-14] P3: device-side expert bucket sort for the batched MoE
// kernels. Three tiny pre-pass kernels reorder the (slot, token) columns so
// same-expert columns are adjacent in the physical dispatch — the main GEMV
// then re-reads each selected expert's weight layer from L2 instead of
// re-streaming it from VRAM once per column (prefill n_tok=512, top-8 of
// E=128 -> ~32 columns share one expert; ideal traffic cut ~= n_cols/E).
// Layout of the shared scratch buffer:
//   [0, E+1)        histogram (phase 1) -> exclusive-scan offsets (phase 2)
//                   -> mutated into cursors (phase 3; host zeroes before use)
//   [E+1, E+1+n_cols) permuted original column indices
// Invalid expert ids get the reserved bucket E (sorted last, output zeros —
// the main kernels already write zeros for invalid ids).

// phase 1: histogram over expert ids. Column index -> (t, j) MUST mirror the
// main batched kernels exactly: e = ids[ids_elem_off + t*ids_row + j].
__kernel void kernel_moe_sort_hist(
        global int * hist,                     // [E+1], pre-zeroed by the host
        global const int * ids,
        int ids_elem_off,
        int ids_row,
        int n_used,
        int n_expert,
        int n_cols)
{
    int i = get_global_id(0);
    if (i >= n_cols) return;
    int t = i / n_used;
    int j = i - t * n_used;
    int e = ids[ids_elem_off + t * ids_row + j];
    if (e < 0 || e >= n_expert) e = n_expert;
    atomic_add(&hist[e], 1);
}

// phase 2: in-place exclusive scan of the [E+1] histogram (start offsets).
// Single thread: E is tiny (128..256 for current models, cap 2048 host-side),
// a serial scan costs microseconds vs the milliseconds the sort saves.
__kernel void kernel_moe_sort_scan(
        global int * hist,                     // [E+1]
        int n_buckets)                         // E+1
{
    if (get_global_id(0) != 0) return;
    int sum = 0;
    for (int i = 0; i < n_buckets; ++i) {
        int v = hist[i];
        hist[i] = sum;
        sum += v;
    }
}

// phase 3: scatter original column indices into their expert buckets.
__kernel void kernel_moe_sort_scatter(
        global int * hist,                     // [E+1] cursors (mutated)
        global int * perm,                     // [n_cols] output
        global const int * ids,
        int ids_elem_off,
        int ids_row,
        int n_used,
        int n_expert,
        int n_cols)
{
    int i = get_global_id(0);
    if (i >= n_cols) return;
    int t = i / n_used;
    int j = i - t * n_used;
    int e = ids[ids_elem_off + t * ids_row + j];
    if (e < 0 || e >= n_expert) e = n_expert;
    int pos = atomic_add(&hist[e], 1);
    perm[pos] = i;
}
