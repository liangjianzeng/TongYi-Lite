R"(// [dspark 2026-10-14] P3 expert-bucket-sort kernels - standalone program.
)"
R"(// Moved out of gemv_noshuffle_q4_0_f32.cl: on Adreno 830 (E031.47) the q4_0
)"
R"(// batched kernel miscompiles when compiled alongside the perm param / extra
)"
R"(// kernels (NMSE~2.2, 2026-10-14). P3 sort is now q3_K-only, and these kernels
)"
R"(// get their own tiny program so the q4_0/q4_K program texts stay minimal.
)"
R"(// [dspark 2026-10-14] P3: device-side expert bucket sort for the batched MoE
)"
R"(// kernels. Three tiny pre-pass kernels reorder the (slot, token) columns so
)"
R"(// same-expert columns are adjacent in the physical dispatch — the main GEMV
)"
R"(// then re-reads each selected expert's weight layer from L2 instead of
)"
R"(// re-streaming it from VRAM once per column (prefill n_tok=512, top-8 of
)"
R"(// E=128 -> ~32 columns share one expert; ideal traffic cut ~= n_cols/E).
)"
R"(// Layout of the shared scratch buffer:
)"
R"(//   [0, E+1)        histogram (phase 1) -> exclusive-scan offsets (phase 2)
)"
R"(//                   -> mutated into cursors (phase 3; host zeroes before use)
)"
R"(//   [E+1, E+1+n_cols) permuted original column indices
)"
R"(// Invalid expert ids get the reserved bucket E (sorted last, output zeros —
)"
R"(// the main kernels already write zeros for invalid ids).
)"
R"(
)"
R"(// phase 1: histogram over expert ids. Column index -> (t, j) MUST mirror the
)"
R"(// main batched kernels exactly: e = ids[ids_elem_off + t*ids_row + j].
)"
R"(__kernel void kernel_moe_sort_hist(
)"
R"(        global int * hist,                     // [E+1], pre-zeroed by the host
)"
R"(        global const int * ids,
)"
R"(        int ids_elem_off,
)"
R"(        int ids_row,
)"
R"(        int n_used,
)"
R"(        int n_expert,
)"
R"(        int n_cols)
)"
R"({
)"
R"(    int i = get_global_id(0);
)"
R"(    if (i >= n_cols) return;
)"
R"(    int t = i / n_used;
)"
R"(    int j = i - t * n_used;
)"
R"(    int e = ids[ids_elem_off + t * ids_row + j];
)"
R"(    if (e < 0 || e >= n_expert) e = n_expert;
)"
R"(    atomic_add(&hist[e], 1);
)"
R"(}
)"
R"(
)"
R"(// phase 2: in-place exclusive scan of the [E+1] histogram (start offsets).
)"
R"(// Single thread: E is tiny (128..256 for current models, cap 2048 host-side),
)"
R"(// a serial scan costs microseconds vs the milliseconds the sort saves.
)"
R"(__kernel void kernel_moe_sort_scan(
)"
R"(        global int * hist,                     // [E+1]
)"
R"(        int n_buckets)                         // E+1
)"
R"({
)"
R"(    if (get_global_id(0) != 0) return;
)"
R"(    int sum = 0;
)"
R"(    for (int i = 0; i < n_buckets; ++i) {
)"
R"(        int v = hist[i];
)"
R"(        hist[i] = sum;
)"
R"(        sum += v;
)"
R"(    }
)"
R"(}
)"
R"(
)"
R"(// phase 3: scatter original column indices into their expert buckets.
)"
R"(__kernel void kernel_moe_sort_scatter(
)"
R"(        global int * hist,                     // [E+1] cursors (mutated)
)"
R"(        global int * perm,                     // [n_cols] output
)"
R"(        global const int * ids,
)"
R"(        int ids_elem_off,
)"
R"(        int ids_row,
)"
R"(        int n_used,
)"
R"(        int n_expert,
)"
R"(        int n_cols)
)"
R"({
)"
R"(    int i = get_global_id(0);
)"
R"(    if (i >= n_cols) return;
)"
R"(    int t = i / n_used;
)"
R"(    int j = i - t * n_used;
)"
R"(    int e = ids[ids_elem_off + t * ids_row + j];
)"
R"(    if (e < 0 || e >= n_expert) e = n_expert;
)"
R"(    int pos = atomic_add(&hist[e], 1);
)"
R"(    perm[pos] = i;
)"
R"(}
)"
