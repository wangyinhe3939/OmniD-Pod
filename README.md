# OmniD-Pod

免费的 macOS 刘海工具。把今日清单、灵感、暂存文件和万有引力归档放在随手可用的位置。

**免费使用、开放源码，无订阅、付费解锁或激活码。** 可选 Gemini 功能使用你自己的 API 密钥；Google 可能按你的账号方案收费，OmniD-Pod 不代收费用。

## 下载与使用

- [免费下载未公证预览版](https://github.com/wangyinhe3939/OmniD-Pod/releases/tag/v1.0.0-preview.293)：安装前请阅读页面的签名与系统限制。
- [全部版本](https://github.com/wangyinhe3939/OmniD-Pod/releases)：以后的网站下载按钮也指向本项目 Release。
- [使用与当前限制](交付说明.md)：安装、权限、归档和手机快捷指令。
- [工程与构建](PROJECT.md)：架构、依赖、构建及测试入口。
- [报告问题](https://github.com/wangyinhe3939/OmniD-Pod/issues)：请先隐去个人笔记、文件路径和密钥。

当前候选适用于 **Apple Silicon、macOS 15.0 或更新版本**。现有候选仅作本机临时签名，尚未完成 Developer ID 签名与 Apple 公证；以每次 Release 标明的签名状态为准。源码公开不代表安装包已通过跨机器验收。

## 可以做什么

- **今日与灵感**：记录清单、灵感和项目，可选择连接 Apple 提醒事项。
- **暂存文件**：集中保留文件引用，方便拖出、预览与分享。
- **万有引力**：文字、网址、图片和文件按四类归档，在 Obsidian 中追加总索引。
- **可选智能识别**：主动点击后用 Gemini 提炼网址或建议图片名称；失败回退普通记录。
- **手机与平板中转**：从 App 添加原生快捷指令，经用户授权的 iCloud 文件夹传回 Mac。
- **刘海工具**：媒体、日历、电池、系统提示与键盘清洁，按功能申请相应权限。

## 数据与权限

普通记录和归档不需要 OmniD-Pod 账号。归档位置和 Obsidian 笔记库由你通过系统选择器授权；不会默认双云写入。开启智能识别后，也只有主动点击「智能处理」才会发送相关网址或图片预览给 Google。密钥保存在本机钥匙串。

iCloud / Google Drive 的同步由各自服务完成；本地保存成功不等于另一台设备已收到。源文件、索引和失败恢复规则见[工程说明](PROJECT.md)。

## 开源与参与

本工程基于 [TheBoredTeam / Boring Notch](https://github.com/TheBoredTeam/boring.notch)，由 Double One 进行中文界面、工作区工具和万有引力等改造。保留上游作者署名。

项目沿用 [GNU GPL v3](LICENSE)；依赖各自的声明见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)，早期功能来源见 [OFFKEY 融合说明](OFFKEY-INTEGRATION-NOTICE.md)。免费发行不额外限制 GPL 授予的修改和再分发权利。

参与前请读[贡献说明](CONTRIBUTING.md)和[安全说明](SECURITY.md)。
