/*
 * jniLibs/arm64-v8a/libhardware.so — app 命名空间内的 libhardware 存根。
 *
 * 背景：捆绑的 Turnip 驱动（libturnip_freedreno.so）DT_NEEDED 依赖
 * libhardware.so（Android HAL 库）。App 进程的 classloader 命名空间
 * （clns-*）不能 dlopen 系统 HAL 库，ggml-vulkan 按 GGML_VK_TURNIP 路径
 * dlopen turnip 时依赖解析失败 → 整个 Vulkan 后端不可用 → 回落 CPU。
 *
 * 方案：把本存根打进 APK 的 jniLibs（与 turnip 同目录）。dlopen turnip
 * 时依赖解析会在 app 自己的 lib 目录命中本存根，dlopen 成功。
 *
 * 符号面：turnip 从 libhardware.so 实际 import 的唯一符号是 hw_get_module
 * （gralloc 模块查询，AHardwareBuffer 导入路径用；LLM 推理不走该路径）。
 * 返回 -ENOENT（无设备）即可——turnip 的调用方按返回值优雅跳过。
 */
#include <stddef.h>

struct hw_module_t; /* 不透明：调用方只在成功时才解引用，存根恒失败 */

int hw_get_module(const char *id, const struct hw_module_t **module)
{
    (void)id;
    if (module != NULL) {
        *module = NULL;
    }
    return -2; /* -ENOENT */
}
