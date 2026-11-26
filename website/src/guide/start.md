# 安装与更新

YaaTerm 支持 macOS 13 及以上版本。Apple Silicon 和 Intel Mac 使用同一个安装包。

## 安装发行版

1. 打开 [GitHub Releases](https://github.com/yemaster/YaaTerm/releases/latest)，在 Assets 中下载 `YaaTerm-<版本>-macOS.zip`。
2. 解压，将 `YaaTerm.app` 拖入「应用程序」，双击打开。
3. 在第一个标签页输入 `pwd`，按回车查看当前目录。

发行包使用 ad-hoc 签名，尚未通过 Apple 公证。首次打开时，macOS 可能会要求在「系统设置 → 隐私与安全性」中确认。

## 开始使用

按 **⌘D** 左右分屏。左边的命令可以继续运行，点右边就能输入另一条命令。按 **⌘T** 新开一个标签，按 **⌘W** 关闭当前分屏。窗口右上角的齿轮打开设置，点标签名回到终端。

YaaTerm 使用账户的登录 shell。zsh 会读取原有启动文件，并启用命令高亮、表格和 AI 集成。普通终端功能可以直接使用，需要命令解释或 Agent 时再[连接模型服务](../ai/service)。

## 检查更新

在「设置 → 关于」查看当前版本、更新日志，也可以手动检查更新。默认每天检查一次，下载完成后在退出应用时安装。自动检查和自动安装可以分别关闭。

## 从源码运行

安装 Xcode Command Line Tools 后执行以下命令。首次构建会下载并校验 Sparkle。

```sh
git clone https://github.com/yemaster/YaaTerm.git
cd YaaTerm
make run
```

构建产物位于 `build/YaaTerm.app`。发行版之间的改动可以从源码体验，也可以在 [Actions 构建记录](https://github.com/yemaster/YaaTerm/actions/workflows/macos.yml)中找到对应的通用安装包。
