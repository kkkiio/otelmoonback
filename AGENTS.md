# otelmoonback AGENTS.md

## Project Structure Guide

### Repo Structure & Important Files

```text
.
├── otelmoonback.mbt          # 公共 API、请求状态及观测生命周期
├── otelmoonback_test.mbt     # native 真实 HTTP / WebSocket 集成测试
├── pkg.generated.mbti       # moon info 生成的公共接口
├── moon.work                # workspace 成员：根库与 examples/basic
├── moon.mod                 # 模块版本与依赖
├── moon.pkg                 # 包导入与 native 目标
├── examples/basic/          # 独立 module，演示外部消费方式与生命周期
└── README.mbt.md            # 用户指南；README.md 为符号链接
```

## Domain Language

- **可见状态** — 在观测作用域内成功发送响应头的 HTTP 状态。
- **路由模板** — 不含具体用户参数值、包含 mount 前缀的完整注册路径。
- **duration** — 下游 handler 与 middleware 作用域的耗时。

## Policies & Mandatory Rules

- 修改观测时通过真实 HTTP 行为验证；保留异常与取消语义，区分已见响应和框架生成的响应。
- 修改命名与指标时使用低基数属性；不得把原始路径、查询、错误消息加进 metric 标签。

### No Implementation Comments

- 不在函数体或内部逻辑中写解释实现细节的注释。
- 公共接口必须写面向用户的 API doc comment：一句话概述、重要参数与返回值、可能 raise 的错误、非显而易见的边界情况。

### No Backward Compatibility

- 修改 API、数据格式、配置或工作流时不维护向后兼容：不加兼容层、deprecated 别名、双格式解析或回退 shim。
- 直接迁移调用点和数据格式，让当前代码保持简单。

### Black-Box Testing

- 测试只通过公共 API 或 CLI 入口验证行为：不添加 `*_for_test` 导出、不暴露私有类型或函数、不为可测性扩大公共接口。

## Operation Guide

首次准备依赖时运行：

```bash
moon update
```

修改代码或依赖后运行：

```bash
moon check --target native
moon test --target native
moon run examples/basic --target native
moon info --target native
moon fmt
moon fmt --check
```

最终生成接口并格式化后，检查 pkg.generated.mbti 的变化符合预期；有新代码修改或失败修复时重新运行相应验证。集成测试监听 127.0.0.1 随机端口，每个场景设置超时。文档修改只需检查链接和示例同步；改动示例代码时实际运行示例。

### Release

仅根模块 `KKKIIO/otelmoonback` 发布到 Mooncakes；`examples/basic` 标记 `private = true`，不发布。

1. bump `moon.mod` 的 `version`，跑完整验证（check / test / run examples/basic / info / fmt）。
2. 给验证过的 commit 打 tag 并推送：`git tag v<version> && git push origin v<version>`。
3. 在该 tag 上创建 **draft** GitHub release（`gh release create v<version> --draft`）并附 release notes，不发布；由维护者检查后点 Publish。`release.yml` 由 `release: published` 触发：校验 tag 与 `moon.mod` 版本一致，用 `moon view` 跳过已发布版本，未发布则 `moon publish`（需要仓库 secret `MOONCAKES_TOKEN`）。
