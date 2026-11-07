R"(#pragma OPENCL EXTENSION cl_khr_fp16 : enable
)"
R"(
)"
R"(//------------------------------------------------------------------------------
)"
R"(// add_id(gate) + add_id(up) + swiglu_oai, fused
)"
R"(//
)"
R"(// gpt-oss-class MoE FFNs run three full passes over the same
)"
R"(// [n_ff, n_expert_used, n_tokens] f32 tensor: a per-expert bias add on the gate
)"
R"(// matmul output, the same on the up matmul output, then swiglu_oai over the
)"
R"(// two. Both bias adds are in-place, so each costs a full read plus a full write
)"
R"(// of a tensor that is only read once more. Folding them into the swiglu pass
)"
R"(// leaves two reads and one write instead of six passes.
)"
R"(//
)"
R"(// Grouping matches kernel_add_id: group 0 = expert slot (i1), group 1 = token
)"
R"(// (i2). For a contiguous destination that addressing is identical to the flat
)"
R"(// row walk kernel_swiglu_oai uses, since row i1 + i2*ne1 sits at
)"
R"(// i1*nb1 + i2*ne1*nb1.
)"
R"(//------------------------------------------------------------------------------
)"
R"(kernel void kernel_add_id_add_id_swiglu_oai(
)"
R"(    global char * src_g,
)"
R"(    ulong         offset_g,
)"
R"(    global char * src_gb,
)"
R"(    ulong         offset_gb,
)"
R"(    global char * src_u,
)"
R"(    ulong         offset_u,
)"
R"(    global char * src_ub,
)"
R"(    ulong         offset_ub,
)"
R"(    global char * src_ids,
)"
R"(    ulong         offset_ids,
)"
R"(    global char * dst,
)"
R"(    ulong         offsetd,
)"
R"(    ulong         nb01_g,
)"
R"(    ulong         nb02_g,
)"
R"(    ulong         nb01_u,
)"
R"(    ulong         nb02_u,
)"
R"(    ulong         nb11_g,
)"
R"(    ulong         nb11_u,
)"
R"(    ulong         nb21,
)"
R"(    ulong         nbd1,
)"
R"(    ulong         nbd2,
)"
R"(    int           ne0,
)"
R"(    float         limit,
)"
R"(    float         alpha
)"
R"() {
)"
R"(    src_g   = (global char *)(src_g   + offset_g);
)"
R"(    src_gb  = (global char *)(src_gb  + offset_gb);
)"
R"(    src_u   = (global char *)(src_u   + offset_u);
)"
R"(    src_ub  = (global char *)(src_ub  + offset_ub);
)"
R"(    src_ids = (global char *)(src_ids + offset_ids);
)"
R"(    dst     = (global char *)(dst     + offsetd);
)"
R"(
)"
R"(    const int i1 = get_group_id(0);
)"
R"(    const int i2 = get_group_id(1);
)"
R"(
)"
R"(    // The ids tensor is a view into a [n_expert, n_tokens] buffer, so its row
)"
R"(    // stride is nb21 and the k selected ids are NOT contiguous per token.
)"
R"(    const int i11 = *((global const int *) (src_ids + i1*sizeof(int) + i2*nb21));
)"
R"(
)"
R"(    global const float * g_row  = (global const float *)(src_g  + i1*nb01_g + i2*nb02_g);
)"
R"(    global const float * u_row  = (global const float *)(src_u  + i1*nb01_u + i2*nb02_u);
)"
R"(    global const float * gb_row = (global const float *)(src_gb + i11*nb11_g);
)"
R"(    global const float * ub_row = (global const float *)(src_ub + i11*nb11_u);
)"
R"(    global       float * d_row  = (global       float *)(dst    + i1*nbd1   + i2*nbd2);
)"
R"(
)"
R"(    for (int i0 = get_local_id(0); i0 < ne0; i0 += get_local_size(0)) {
)"
R"(        float x0 = g_row[i0] + gb_row[i0];
)"
R"(        float x1 = u_row[i0] + ub_row[i0];
)"
R"(
)"
R"(        x0 = min(x0, limit);
)"
R"(        x1 = max(min(x1, limit), -limit);
)"
R"(
)"
R"(        float out_glu = x0 / (1.0f + exp(-x0 * alpha));
)"
R"(        out_glu = out_glu * (1.0f + x1);
)"
R"(
)"
R"(        d_row[i0] = out_glu;
)"
R"(    }
)"
R"(}
)"
