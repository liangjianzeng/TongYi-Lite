# 贡献指南

感谢你对 TongYi-Lite 感兴趣！我们欢迎所有形式的贡献，包括但不限于：

- 报告 Bug 或提出功能建议
- 提交代码修复或新功能
- 改进文档
- 参与代码审查

---

## 开发环境设置

1. **克隆仓库**

   ```bash
   git clone git@github.com:liangjianzeng/TongYi-Lite.git
   cd TongYi-Lite
   git submodule update --init --recursive
   ```

2. **安装依赖**

   ```bash
   flutter pub get
   ```

3. **配置环境变量**

   参考 [README.md](README.md#前置环境) 中的前置环境章节。

---

## 开发流程

1. **Fork 本仓库**
2. **创建特性分支**

   ```bash
   git checkout -b feature/my-feature
   # 或
   git checkout -b fix/my-bugfix
   ```

3. **编写代码**

   - 遵循 Dart 官方 [Style Guide](https://dart.dev/guides/language/effective-dart)
   - 保持代码风格与现有代码一致
   - 添加必要的注释

4. **本地测试**

   ```bash
   # 运行 lint
   flutter analyze

   # 运行测试（如有）
   flutter test
   ```

5. **提交代码**

   使用 [Conventional Commits](https://www.conventionalcommits.org/) 规范：

   ```
   <type>(<scope>): <subject>

   <body>
   ```

   **Type 类型：**

   | 类型 | 说明 |
   |------|------|
   | `feat` | 新功能 |
   | `fix` | Bug 修复 |
   | `docs` | 文档变更 |
   | `refactor` | 代码重构 |
   | `test` | 测试相关 |
   | `chore` | 构建/工具链变更 |

   **示例：**

   ```
   feat(services): 添加语音识别服务

   集成 sherpa-onnx 实现流式 STT 功能。
   支持 WeNet 模型的实时语音转文字。
   ```

6. **推送并创建 PR**

   ```bash
   git push origin feature/my-feature
   ```

   然后在 GitHub 上创建 Pull Request。

---

## 代码规范

### Dart 代码

- 使用 `flutter analyze` 确保无 lint 警告
- 遵循 Effective Dart 指南
- 公共 API 添加文档注释 (`///`)

### 原生代码 (C++ / Kotlin)

- C++: 遵循 Google C++ Style Guide
- Kotlin: 遵循 [Kotlin 官方风格指南](https://kotlinlang.org/docs/coding-conventions.html)

---

## 提交 Issue

使用 GitHub Issue 模板，提供以下信息：

- **Bug 报告**：复现步骤、预期行为、实际行为、设备信息、日志
- **功能建议**：清晰描述需求和预期效果

---

## 代码审查

- PR 创建后，维护者会进行代码审查
- 请响应用户反馈并更新代码
- 小的、聚焦的 PR 更容易被快速合并

---

## 文档贡献

- 文档位于 `docs/` 目录
- README.md 变更请确保构建和运行步骤准确
- 新增功能请同步更新相关文档

---

## License

本项目采用 MIT License。提交即表示你同意以 MIT License 发布你的贡献。
