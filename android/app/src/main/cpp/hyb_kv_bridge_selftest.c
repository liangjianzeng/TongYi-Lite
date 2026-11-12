/*
 * [npu-line M2 Phase C] Host selftest driver for hyb_kv_bridge.c.
 *
 * Standalone main() — NOT part of libtongyilite_jni. Compiled by
 * hyb_kv_bridge_selftest.sh with host gcc against hyb_kv_bridge.c (the exact
 * translation unit the APK ships) and run against the frozen Phase A samples.
 *
 * Usage:
 *   hyb_selftest <kv_dir> <ids.raw> <out.state> <n_real> \
 *                [pos_base=88] [v_h2i=0] [n_layers=42] [nc=512] [ver=0(=4)]
 *
 * Prints "BRIDGE_OK <bytes> <out>" on success (same marker as the Python
 * reference), "BRIDGE_FAIL <code> <reason>" and exits non-zero otherwise.
 */
#include "hyb_kv_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    hyb_kv_params p;
    char err[256];
    FILE *f;
    long sz;
    int rc;

    if (argc < 5) {
        fprintf(stderr,
                "usage: %s <kv_dir> <ids.raw> <out.state> <n_real> "
                "[pos_base=88] [v_h2i=0] [n_layers=42] [nc=512] [ver=0(=4)]\n",
                argv[0]);
        return 2;
    }

    memset(&p, 0, sizeof(p));
    p.kv_dir     = argv[1];
    p.ids_path   = argv[2];
    p.out_path   = argv[3];
    p.n_real     = atoi(argv[4]);
    p.pos_base   = (argc > 5) ? atoll(argv[5]) : (long long)HYB_P0_DEFAULT;
    p.v_h2i      = (argc > 6) ? atoi(argv[6]) : 0;
    p.n_layers   = (argc > 7) ? atoi(argv[7]) : 0; /* 0 => default 42 */
    p.nc         = (argc > 8) ? atoi(argv[8]) : HYB_NC_DEFAULT;
    p.hd         = 0; /* default 128 */
    p.nkv        = 0; /* default 2   */
    p.state_ver  = (argc > 9) ? atoi(argv[9]) : 0; /* 0 => default (v4) */
    p.kc_fmt     = NULL; /* "d2q_kc_%d.raw" */
    p.vc_fmt     = NULL; /* "d2q_vc_%d.raw" */

    rc = hyb_kv_bridge_convert(&p, err, sizeof(err));
    if (rc != HYB_OK) {
        fprintf(stderr, "BRIDGE_FAIL %d %s\n", rc, err);
        return 1;
    }
    f = fopen(p.out_path, "rb");
    if (!f) {
        fprintf(stderr, "BRIDGE_FAIL -3 output vanished: %s\n", p.out_path);
        return 1;
    }
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    fclose(f);
    printf("BRIDGE_OK %ld %s\n", sz, p.out_path);
    return 0;
}
