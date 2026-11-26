# 性能实测

2026-11-25，Apple M5、16 GB 内存、macOS 27.2.1，原生 arm64。以下分别测量终端内核、默认回滚和本机应用包大小。窗口绘制、键入延迟及整机空闲 CPU 需要单独测量。

## 三个终端内核处理同一段输出

使用 100 列 × 32 行的网格，三个内核均关闭回滚。每种输入含 512 条记录，预先读入内存，再重放 1,024 次。每次启动独立测试进程，仅对解析输入、更新网格计时。每个场景先预热一轮，再按固定随机种子轮换引擎顺序，取 7 轮中位数。每次运行都将全部 3,200 个可见格的基础字符与独立生成的预期结果核对。

| 吞吐量（MiB/s） | YaaTerm 优化前 | YaaTerm 优化后 | libghostty-vt 1.0.2 | alacritty_terminal 0.26.0 |
| --- | ---: | ---: | ---: | ---: |
| ASCII 日志逐行滚动 | 435.41 | 899.41 | 1,790.72 | 273.93 |
| 带 ANSI 颜色的中英文日志 | 354.37 | 481.20 | 445.52 | 254.55 |
| 回车后覆盖同一行的进度条 | 151.04 | 2,726.13 | 3,481.26 | 343.07 |
| 光标定位、换色后覆盖多行 | 158.65 | 1,065.96 | 1,470.71 | 311.95 |

YaaTerm 以前只会批量写入空白区域。进度条或状态面板更新已有文字时，每个字符都要经过单独的写入流程。现在连续的可打印 ASCII 可以成段覆盖，遇到跨边界的宽字符再逐字修复。进度条吞吐升至原来的 18.0 倍，多行刷新升至 6.7 倍。Ghostty 在 ASCII 滚动、进度条和多行刷新上仍然领先。

| 进程指标 | YaaTerm | libghostty-vt | alacritty_terminal |
| --- | ---: | ---: | ---: |
| 四种负载的峰值 RSS 范围（MiB） | 2.09–2.11 | 6.25–6.45 | 2.23–2.27 |
| 处理进度条负载的 CPU 时间（ms） | 14.43 | 13.05 | 102.19 |
| 处理多行刷新负载的 CPU 时间（ms） | 39.19 | 30.28 | 129.43 |

RSS 和 CPU 由 macOS 的 `wait4` 对每个子进程单独统计，包含启动、读取输入和最终网格导出。内核吞吐的计时区间更窄。这组测试不含 PTY、shell、GUI、GPU 或显示器刷新，不能据此推算桌面应用的内存或帧率。

YaaTerm 基线为 `bd49d77`，优化提交为 `2fa85ea`，均由 Apple clang 21.0.0 以 `-O2` 构建。Ghostty 使用官方 XCFramework 的 ReleaseFast 构建，Alacritty 使用官方 crate 的 Cargo.lock 和 rustc 1.96.0 的 release 配置。库版本号与桌面应用独立。[Ghostty VT](https://lib.ghostty.org/vt/installing.html) · [Alacritty Terminal](https://crates.io/crates/alacritty_terminal/0.26.0)

## YaaTerm 保留一百万行回滚

使用默认回滚配置，连续写入带 ANSI 颜色的中英文日志。吞吐包含网格滚动、历史压缩和临时文件写入。每次检查历史总行数、最早一行的字符与颜色以及末屏输出。先预热一次，再取五次运行的中位数。

| 100 列窗口 | 百万行吞吐（MiB/s） | 10 万行时物理内存（MiB） | 100 万行时物理内存（MiB） |
| --- | ---: | ---: | ---: |
| 32 行 | 200.2 | 2.92 | 2.94 |
| 120 行 | 204.4 | 3.16 | 3.16 |
| 300 行 | 204.9 | 3.48 | 3.48 |

此处内存来自 `proc_pid_rusage` 的物理占用（physical footprint），与上表的峰值 RSS 口径不同。旧记录写入会话临时文件，磁盘用量会随历史增长。

## 本机应用包大小

统计未压缩 `.app` 内常规文件的逻辑字节数，忽略符号链接，硬链接只计一次。包内资源、框架以及主程序架构都会影响结果，系统组件和用户数据另计。

| 本机应用 | 版本 | 主程序架构 | 包内文件合计 |
| --- | --- | --- | ---: |
| YaaTerm | 0.2.15 开发构建 | Apple Silicon、Intel | 5.5 MiB |
| Ghostty | 1.4.0 | Apple Silicon、Intel | 64.2 MiB |
| Tern | 0.9.32 | Apple Silicon | 193.7 MiB |

## 复现

在 macOS 上运行。横向基准额外需要 Python 3.9+ 和 Rust 1.85+。构建脚本会下载并校验指定版本的库，所有产物均位于 `build/terminal-comparison/`。

```sh
sh Tests/compare/build.sh
python3 Tests/compare/run.py
make benchmark
```

`run.py` 输出每种负载的吞吐、峰值 RSS 和 CPU 时间。使用 `--rounds` 或 `--repeats` 可调整样本量。[负载生成和结果校验](https://github.com/yemaster/YaaTerm/blob/master/Tests/compare/run.py) · [百万行回滚基准](https://github.com/yemaster/YaaTerm/blob/master/Tests/ScrollBenchmark.cpp)
