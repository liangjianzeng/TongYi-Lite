import sys
QAIRT_BIN = '/mnt/d/MyLLM/qairt/2.44.0.260225/bin/x86_64-linux-clang'
sys.path.insert(0, QAIRT_BIN)
from qti.aisw.converters import onnx as onnx_frontend
from qti.aisw.converters.common.converter_ir.op_graph_optimizations import IROptimizations
from qti.aisw.converters.qnn_backend.custom_ops.op_factory import QnnCustomOpFactory
import runpy

mod = runpy.run_path(QAIRT_BIN + '/qnn-onnx-converter', run_name='not_main')
args = mod['ONNXtoQNNArgParser']().parse_args()
print('ARGS weights_bw=%s act_bw=%s fb=%s' % (getattr(args, 'weights_bitwidth', '?'), getattr(args, 'act_bitwidth', '?'), getattr(args, 'float_fallback', '?')), flush=True)
converter = onnx_frontend.OnnxConverterFrontend(args, custom_op_factory=QnnCustomOpFactory())
ir_graph = converter.convert()
args.perform_axes_to_spatial_first_order = True
args.squash_box_decoder = True
args.match_caffe_ssd_to_tf = True
args.adjust_nms_features_dims = True
args.extract_color_transform = True
args.preprocess_roi_pool_inputs = True
args.unroll_lstm_time_steps = True
args.expand_gru_op_structure = True
args.unroll_gru_time_steps = True
args.inject_cast_for_gather = True
args.force_prune_cast_ops = False
args.align_matmul_ranks = True
args.handle_gather_negative_indices = True
optimizer = IROptimizations(args)
optimized = optimizer.optimize(ir_graph)

nodes = optimized.list_nodes() if hasattr(optimized, 'list_nodes') else []
shown = 0
for node in nodes:
    op = getattr(node, 'op', None)
    tstr = str(getattr(op, 'type', ''))
    if 'rmsnorm' not in tstr.lower().replace('_', ''):
        continue
    print('RMS', node.op.name, flush=True)
    for i in node.input_names:
        try:
            b = optimized.get_buffer(i)
            dt = getattr(b, 'dtype', '?')
            prod = optimized.get_producer_node(i)
            pt = getattr(getattr(prod, 'op', None), 'tensor', None)
            tdt = getattr(pt, 'dtype', None)
            print('   in %-50s buf=%s tensordtype=%s' % (i[:50], dt, tdt), flush=True)
        except Exception as e:
            print('   in %s ERR %s' % (i[:50], e), flush=True)
    shown += 1
    if shown >= 3:
        break
print('PROBE DONE', flush=True)
