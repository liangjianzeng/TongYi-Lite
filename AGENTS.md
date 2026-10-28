# AGENTS.md — 已迁出本公开仓

本项目的智能体项目指令 / 记忆（原本文件约 4000 行）属**私有工程记忆**（真机清单与内网 IP、
签名证书信息、构建流水、排障判例），已于 2026-10-28 迁入私有文档仓，公开克隆不再携带。

- 私有仓：`git@github.com:liangjianzeng/TongYi-Lite-docs.git`（仅仓库所有者可见）
- 位置：`docs/` 子模块下的 `AGENTS.md`（所有者检出后即 `docs/AGENTS.md`）
- 同批迁出：`android/AGENTS.md` → `docs/android_AGENTS.md`、`BUILD.md` → `docs/BUILD.md`、
  `thinking_runaway_notes.md`、`thinking_effort_token_meter_notes.md`
- 迁移清单与逐字节 sha256 校验：私有仓 `私有化迁移_自公开仓_2026-10-28.md`

公开克隆中 `docs/` 是无访问权限的子模块指针，上述文件只对所有者可见。
面向使用者的文档请看 [`README.md`](README.md)、[`CONTRIBUTING.md`](CONTRIBUTING.md)、
[`CHANGELOG.md`](CHANGELOG.md)；构建入口见 `tool/build_apk.sh` / `tool/build_apk.ps1`。

> 注：App 内「工作区 AGENTS.md」功能（`lib/agent/agents_md/`）读的是**手机工作区目录**里的
> AGENTS.md，与本仓根目录无关，迁出本文件不影响该功能。
