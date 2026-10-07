# OFFKEY 融合说明

OmniD-Pod 2.7.7（构建 276）将 Double One 自有的 OFFKEY 0.3.2 工作区作为行为参考，在 Swift / SwiftUI 中重新实现并融合了键盘清洁、原生记事和“快速命名”三个模块。

- OFFKEY 工作区未被复制、改写或作为运行时依赖打包。
- 键盘清洁复用 OmniD-Pod 的唯一 `MediaKeyInterceptor` 事件监听。
- 记事只使用 OmniD-Pod 自己的 Application Support 容器；没有旧数据时不会虚构迁移来源。
- “起个名”只访问用户明确选择并授权的单个文件和目录，不申请全盘权限。
- Boring Notch 的 GPL-3.0 许可与现有第三方许可文件继续适用于本工程和分发边界。

OFFKEY 工作区的 `Info.plist` 标注 `Copyright © 2026 Double One`，该工作区没有单独提供额外的第三方许可证文件。本说明不改变上游 Boring Notch 及其依赖的许可义务。
