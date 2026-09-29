# jniLibs/arm64-v8a — 随 APK 捆绑的原生库

## libturnip_freedreno.so — Mesa Turnip (Adreno 开源 Vulkan 驱动)

- **来源**: Mesa Turnip `v26.3.0-20260918-r6-A8xx`（The412Banner 的 whitebelyash
  turnip/gen8 A8xx stack，KGSL build，Vulkan 1.4.363），适配 Snapdragon 8 Elite
  (A840/A830/A829/A825/A810)。
- **SHA256**: `7446A2926A716EAACF2F341AA943E496D04C0FB8589EAB632509F88CE6583D7C`
- **为什么入库**: 根 `.gitignore` 全局忽略 `*.so`，本目录经白名单放行。没有这个文件，
  任何机器 clone 后编译出的 APK 都**打不出 Turnip 包**——Bonsai 系 PTQ1_0 在
  原厂 Adreno 驱动 0800.71 上有乱码问题，Turnip 直载是唯一可用路径
  （验证记录：`docs/vulkan_bonsai2_turnip_verify_2026-09-28.md`）。
- **加载机制**: App 启动时由 JNI 解包到 native lib 目录，经 `GGML_VK_TURNIP` 环境变量
  接给 ggml-vulkan 选择该 ICD；`vk_flags.conf` 里设 `GGML_VK_TURNIP=`（空值）可强制
  回原厂驱动。
- **更新方法**: 从上游替换本文件后，务必更新本 README 的来源版本与 SHA256。
  替换属驱动行为变更，需真机跑 MUL_MAT/HADAMARD tbo + e2e 回归再合入。
