# npu 链资产 — NPU 分层链运行时（npu-line M2 Phase C-3 review rework，本文件由 tool/stage_npu_assets.sh 生成）

布局（W^X，P0-3）：可执行体走 **jniLibs**（arm64-v8a）＋ useLegacyPackaging
安装期解出真文件到 nativeLibraryDir（system_file，App uid 可 execve/dlopen）；
manifest 走 assets → NpuAssets.extract 解包 filesDir/npu_m1（链 cwd/产物区），
chainDir/lib 由 extract 建 symlink → nativeLibraryDir（chain_run5 的
dlopen("./lib/libQnnHtp.so") 相对 cwd 解析到真身）。字节与设备
/data/local/tmp/npu_m1 同源。

| 资产 | 位置 | 字节 | sha256 | 来源 |
|---|---|---|---|---|
| libchain_run5_exec.so | jniLibs/arm64-v8a | 69168 | e5b50bb2a8d951944ca9eaaeca665ab645554f75dcdfa3427feaf06f29837b20 | WSL NDK r27c 编 npu-line/probe_m1/dec2/chain_run5.cpp（QAIRT 2.44.0.260225 QNN 头，-ldl）|
| manifest_pre2_A | assets/npu_libs | 5896 | b904f378d4c2490da5e8492771bf71b8807627fca9597d9a7b0d5e1528a3606c | 设备只读 pull（dec2p 三段闸门 manifest，42 层 = A l0-13/B l14-27/C l28-41）|
| manifest_pre2_B | assets/npu_libs | 5978 | 250227156337f23c1950ef0f92f8891c2208b8d3ae5f7b6c87639df531c0d806 | 设备只读 pull（dec2p 三段闸门 manifest，42 层 = A l0-13/B l14-27/C l28-41）|
| manifest_pre2_C | assets/npu_libs | 5978 | 5dec8c95d26d819cc3c1c2df30697f28afe9a069f0b7984472d188264c49b571 | 设备只读 pull（dec2p 三段闸门 manifest，42 层 = A l0-13/B l14-27/C l28-41）|
| libQnnHtp.so | jniLibs/arm64-v8a | 2778176 | 090e993822564851eab1405aff171643b21e644e3f696c95c96f2732aaed813a | 设备只读 pull npu_m1/lib |
| libQnnHtpV73Skel.so | jniLibs/arm64-v8a | 10761464 | 11c76e1d9bcc8a3168e47f73e48baba0da8e1ca03b7c429e4a5777eab5d20c5a | 设备只读 pull npu_m1/lib |
| libQnnHtpV73Stub.so | jniLibs/arm64-v8a | 679168 | ef0d0cbbdd423a81c19fb0f60d1451b602bcd60c08b3564f1c82e632fb59f157 | 设备只读 pull npu_m1/lib |
| libQnnSystem.so | jniLibs/arm64-v8a | 2983560 | 7e69258e1278cc9b2bb62dbc6e2a52c227a100d6505a13fd6324a87993d0bba8 | 设备只读 pull npu_m1/lib |

TODO-B（实机核对，见 tool/npu_exec_probe.sh 与设备 CR5 日志）：
- 42 个 `dec2p_l{k}_ctx.bin`（~3.9GB）**不随 APK**——需另行 staging 到
  filesDir/npu_m1/（owner 推送 / 后续 OTA 资产通道）。缺件表现 = chain_run5
  段日志 `CR5_FAIL open ctx`，prefill 回包 stage=prefill_seg 带 log_tail。
- `libQnnHtpPrepare.so`(85M，建图期库，执行 context-binary 大概率不需要)、
  `libQnnModelDlc.so`、`libCalculator_skel.so`：设备 lib/ 实存，若运行期
  dlopen 需求出现（CR5_FAIL dlopen/dlsym），用本脚本从设备补 pull 四件套清单。
- 其余 arch 变体（V68/V69/V75/V79/V81 Skel/Stub）740 机不加载，不分发。
- strip 豁免已落地：build.gradle.kts packaging.jniLibs.keepDebugSymbols
  用 "**/<文件名>" 形式豁免本清单五件（AGP 8.7 的 compileGlob 对裸名补
  "/name" 永不命中、模式需自带 "**/"；验证须删
  build/app/intermediates/stripped_native_libs/ 强制 strip 全量重跑）。
  包内字节 = 本 README sha256 台账（2026-11-12 zipfile 全五件比对通过）。
