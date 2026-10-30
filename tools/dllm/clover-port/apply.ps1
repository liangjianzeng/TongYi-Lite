# dllm(clover) 移植注入脚本 — 新开发机一键把 Clover-35B-A3B llama 层打进 submodule
#
# 背景：submodule third_party/llama.cpp 的 origin 是上游 ggml-org（无推送权），
# Clover 移植提交（产品仓 feat/dllm-clover-integration 的 submodule 指针所指）
# 无法远端拉取，以本目录 *.patch 随产品仓分发，用本脚本 git am 注入。
#
# 用法（在已 checkout feat/dllm-clover-integration 且 submodule 已 init 的产品仓根）：
#   pwsh -File tools\dllm\clover-port\apply.ps1
#
# 幂等：已注入（存在 src/models/clover-moe.cpp）则只校验不重复打。
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$sub  = Join-Path $root 'third_party\llama.cpp'
Set-Location $sub

if (Test-Path (Join-Path $sub 'src\models\clover-moe.cpp')) {
    Write-Host '[apply] clover-moe.cpp 已存在，跳过 git am，直接校验'
} else {
    git am --abort 2>$null | Out-Null
    Get-ChildItem $PSScriptRoot -Filter '*.patch' | Sort-Object Name | ForEach-Object {
        Write-Host "[apply] git am $($_.Name)"
        git am $_.FullName
        if ($LASTEXITCODE -ne 0) { throw "git am 失败：$($_.Name)（先 git am --abort 再排查冲突）" }
    }
}

# 校验门：模型类文件 + arch 注册 + op 表，三处字符串级命中才算注入成功
$checks = @(
    @{ f = 'src\models\clover-moe.cpp'; p = 'llama_model_clover_moe' },
    @{ f = 'src\llama-arch.cpp';        p = 'LLM_ARCH_CLOVER_MOE' },
    @{ f = 'src\models\models.h';       p = 'clover_moe' }
)
foreach ($c in $checks) {
    $hits = (Select-String -Path (Join-Path $sub $c.f) -Pattern $c.p -AllMatches -ErrorAction SilentlyContinue |
             ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum
    if (-not $hits) { throw "校验失败：$($c.f) 未命中 $($c.p)" }
    Write-Host ("[apply] OK {0} :: {1} ×{2}" -f $c.f, $c.p, $hits)
}
Write-Host "[apply] Clover 注入完成：HEAD = $(git log --oneline -1)"
Write-Host '[apply] 后续：产品仓根执行标准打包（flutter assemble → 镜像 intermediates → gradlew assembleDebug -x compileFlutterBuildDebug）；'
Write-Host '[apply] 注意 src/CMakeLists.txt 已含 dllm-clover-port bump，若你本地 CMake 缓存早于本提交，删 .cxx\Debug 全量重编一次以让 GLOB 收录 clover-moe.cpp。'
