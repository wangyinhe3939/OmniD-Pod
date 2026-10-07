# OmniD-Pod｜工程说明

更新：2026-10-08。OmniD-Pod 免费使用、开放源码；不设置订阅、付费解锁或激活门槛。GitHub 提供源码与版本下载，网站建成后链接到 Releases。

## 当前基线

| 项目 | 当前值 |
| --- | --- |
| 产品 / 版本 | OmniD-Pod，1.0 / 构建 293 |
| 应用标识 | `com.ddone.ddnotch` |
| 当前候选架构 | Apple Silicon（arm64） |
| 最低系统 / Swift 模式 | macOS 15.0 / Swift 5 |
| 工程 / 方案 | `boringNotch.xcodeproj` / `boringNotch` |
| 工作区 | `boringNotch.xcodeproj/project.xcworkspace` |
| 交付文件 | 根目录 `OmniD-Pod.dmg`，打包时只覆盖这一名称 |
| 当前签名 | 本机临时签名；Developer ID、Apple 公证与跨机器首次安装尚未完成 |

## 功能与界面

设置内容区为 390×600pt，长内容内部滚动。标题菜单可切换启动与行为、快捷键、功能、外观、灵动岛、权限与数据、关于。万有引力设置分为归档、智能、中转。

今日与灵感、万有引力采用 320×460pt 内容尺寸。万有引力标题为「万有引力」，副标题为「万物索引与归档」，支持移动、原生控制灯和置顶。未置顶为空心斜图钉，置顶为强调色实心直图钉。上半区输入、四分类和操作固定；最近归档为 96pt 原生滚动列表。

四个分类固定为视觉资产、构想与纪要、工具与脚本、灵感参考。支持文字、URL、普通文件与异步文件承诺；工具与脚本只归档，不执行。历史条目支持改名、分类、访达定位、复制 Obsidian 链接、撤销并移入废纸篓。会更改数据或连接的动作提供确认与取消。

## 归档与授权

设置 → 权限与数据 → 万有引力 → 归档：

1. **图片和文件存到哪里**：选择 iCloud Drive、Google Drive 或本机的一个存放位置；在授权目录内使用或创建「万物仓」。同一资产只选一个权威目标。
2. **在 Obsidian 记在哪里**：选择平时打开的笔记库，即能看到已有笔记的那一层。首次成功归档后创建「万有引力｜万物总索引.md」，以后追加记录。

通过系统选择器持久保存 security-scoped bookmarks。路径字符串与符号链接不代表授权；失效书签需重新选择。不创建同名假库，不覆盖既有索引，不申请全磁盘访问。

每项操作使用稳定操作编号，依次执行：**持久意图 → 目标暂存 → 校验提交 → 幂等追加索引 → 源清理**。归档与索引均成功后才清理源；源已变化、不能安全删除或可执行属性写入受限时保留源，显示「原文件待清理」。索引失败只补索引。关闭窗口不取消已提交事务，重启按本机日志恢复。

阻塞 I/O 使用后台 utility 调度，文件并发上限 2；索引使用独立串行队列和文件协调，各操作独占文件句柄。文字和 URL 原文保存为 `.md`，总索引追加日期、分类、名称、形式、物理路径、备注与幂等标记。本地落盘不宣称云端同步成功，不承诺跨设备恰好一次。

## 可选 Gemini

默认关闭。设置中提供 Google AI Studio 的密钥页面入口，密钥保存在本机钥匙串。普通记录不调用 AI；主动点击「智能处理」才发送公开网址或图片预览，工具与脚本不上传。3 秒超时、断网或处理失败回退普通记录。

图片输入上限 8 MiB、16 MP，预览最长边 1024 像素；归档保留原字节和扩展名，不覆盖同名资产。当前接口模型为 `gemini-2.5-flash`，上线前须核验服务当前可用性与适用地区。第三方服务费用、数据处理及使用条件由用户的 Google 账号和服务条款决定。

## 手机与平板

不提供独立移动端 App。设置 → 中转：创建手机收件箱 → 添加手机快捷指令 → 在设备上分享一次。

用户通过系统选择器授权 iCloud Drive 后，App 创建或使用 `OmniD-Transfer` 并开启接收。这是普通授权文件夹，当前不是 Apple 专用 iCloud 容器；本机文件夹图标不保证同步到手机。关闭接收和断开连接不删除文件。

Mac 在 App 进程内监听并每 15 秒补查；文件稳定至少 2 秒才列为待收，初始平面目录上限 256 项，跳过未下载占位、临时文件、目录、包、别名和符号链接。用户选择分类并确认归档后才处理，成功后清理中转副本，保留手机原件。

模板随源码提供：[万有引力·记录](boringNotch/offkey/OmniRouter/Resources/万有引力·记录.shortcut)、[万有引力·文件](boringNotch/offkey/OmniRouter/Resources/万有引力·文件.shortcut)。在 App 内可添加，也可通过隔空投送发送；设备端仍需确认添加并授权保存到 iCloud Drive → OmniD-Transfer，关闭覆盖已有文件。

## 源码结构与约束

- `boringNotch/`：主 App；`BoringNotchXPCHelper/`：现有辅助进程；`mediaremote-adapter/`：媒体适配组件。
- 仓内 MediaRemoteAdapter 主二进制、测试客户端与 Perl 脚本已逐项核对，Git blob 摘要与上游 `TheBoredTeam/boring.notch` 的 `v2.7.3` 完全一致；原作者为 Jonas van den Berg，BSD-3-Clause 声明保留。适配器上游源码为 `ungive/mediaremote-adapter`。
- `boringNotch/offkey/` 是仍在使用的功能源码，包含 Core、工作区与万有引力，不是可删除的旧 App。
- `boringNotch/offkey/OmniRouter/` 使用现有文件系统同步分组，不新增 target/package 或固定模块源引用。中性工厂通过 `NSClassFromString("DDOmniRouterFactory")` 安全加载；缺席时原动作正常回退。模块内窗口与 AppKit 承载在主线程创建，显式注入模型。
- `Package.swift` 与 `Tests/` 负责 Core 测试；归档模块另有条件编译的夹具测试，不能将 Core 通过当作整个 App 验收。
- 所有构建、测试和临时产物放 `.build_tmp/`；保留依赖锁、产品标识、最低系统及权限。普通构建不自动启动 App，不操作个人归档或 Obsidian。
- 既有宿主亮度和媒体功能使用部分非公开系统接口，需要随 macOS 更新实测；源码公开不代表符合 Mac App Store 审核条件。

## 构建与测试

安装完整 Xcode 并选择对应 Command Line Tools。在工程根目录执行以下命令；首次解析依赖需要网络，使用仓库中的 `Package.resolved`，不要自动升级依赖。

```sh
xcodebuild -workspace boringNotch.xcodeproj/project.xcworkspace -scheme boringNotch -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath .build_tmp/Release -clonedSourcePackagesDirPath .build_tmp/SourcePackages -packageCachePath .build_tmp/PackageCache -disablePackageRepositoryCache -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= clean build
swift test --scratch-path .build_tmp/Core --cache-path .build_tmp/SwiftPMCache
```

以上命令生成本机临时签名 App，不生成正式 Developer ID 签名。Debug 使用独立缓存路径。公开源码保留共享工程配置和依赖锁，不包含作者本机缓存、历史截图或父仓库历史。Release 启用原生剥离调试符号并关闭 Swift 调试选项序列化，避免成品带出本机构建路径；不更改优化级别或 Swift 模式。

DMG 使用既有哈希锁定的工具链，需要 Python 3.10 或以上（macOS 自带 3.9 不适用），放入本工程临时环境：

```sh
python3 -m venv .build_tmp/PackagingEnv
.build_tmp/PackagingEnv/bin/python -m pip install --require-hashes -r Configuration/dmg/requirements.txt
PATH="$PWD/.build_tmp/PackagingEnv/bin:$PATH" /bin/bash Configuration/dmg/create_dmg.sh .build_tmp/Release/Build/Products/Release/OmniD-Pod.app "$PWD/OmniD-Pod.dmg" OmniD-Pod
hdiutil verify OmniD-Pod.dmg
ruby scripts/check-workspace-package.rb <实际构建App> <本轮只读挂载App>
```

只打包实际 `OmniD-Pod.app`，不使用上游旧 `boringNotch.app` 路径。完整进程组设 600 秒上限，关闭标准输入；失败记录真实退出码，同类连续两次失败先复盘。卸载时只卸载本轮自己创建的镜像。辅助功能、听写等前台验证与无窗口测试分开进行。

## 当前验证边界

本次预览版完成原 workspace/scheme 的干净 Release 构建、23 项 Core 测试（0 失败）、Release 调试路径清理后再构建，以及原脚本 DMG 打包，均退出 0。镜像完整性和严格签名完整性检查通过；包内外 140 个条目的内容、权限与链接目标一致，三份许可随 App 打包。签名仍是临时签名，Gatekeeper 实测拒绝（退出 3），因此只作为明确标注的未公证预览版发布。

当前 DMG 为 12,547,397 字节，SHA-256 为 `631495a5d57a24d29de39285167d21a52fdfd2842fc42a2bef736ba91f6ec68f`；`SHA256SUMS.txt` 只校验这一安装包。公开源码初始版本从明确的工程文件清单生成，不携带父仓库历史。

此前实际记事存储夹具、OmniRouter 真正拆卸及恢复构建曾通过；本轮没有重跑这些功能验收，也没有自动启动、安装或退出 App。

尚未完成：Developer ID 与 Apple 公证；跨机器首次安装和升级；全部硬件按键、输入法、多屏及压力验收；真实云盘 / Obsidian 的跨设备读回；真实 Gemini 账号与效果；iPhone / iPad 全链路。逐次 Release 应标明实际已测范围，不将候选或截图当作功能验收。

## 发布与许可

公开入口为 `wangyinhe3939/OmniD-Pod`。源码和免费安装包分开发布；DMG 放 Releases，不放源码仓库历史。当前「检查原版新版本」只查看 Boring Notch 上游，不是 OmniD-Pod 自动更新；用户从本项目 Releases 获取新版本。

GPL 文本见 [LICENSE](LICENSE)，锁定依赖与继承代码声明见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。公开前核验源码、配置、许可证、文件权限与内部框架链接；不上传用户书签、API 密钥、笔记、签名私钥或个人运行记录。
