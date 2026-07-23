# MpvLibre Runtime

[English](README.md)

可复现、可再分发的 **libmpv + LibreMPEG** 运行时。面向需要 libmpv C API 与
LibreMPEG 编解码能力（含 AC-4）的桌面应用。

本项目只发布**库运行时**，不包含、也不启动 `mpv.exe` / `mpv`，不绑定 Electron 或
任何具体播放器产品。

## 平台

下列目标均已通过 CI **全量验证**（构建 + AC-4 解码 + libmpv client API）。每个
Release 在同一不可变 tag 下发布全部平台产物。

| 目标 | 产物 | 构建方式 |
| --- | --- | --- |
| `win32-x64` | `mpv-libre-runtime-win32-x64.7z` | Alpine 容器，LLVM/MinGW 交叉编译 |
| `darwin-arm64` | `mpv-libre-runtime-darwin-arm64.tar.xz` | 原生 macOS（Cocoa + Swift + MoltenVK） |
| `darwin-x64` | `mpv-libre-runtime-darwin-x64.tar.xz` | 原生 macOS（Cocoa + Swift + MoltenVK） |
| `linux-x64` | `mpv-libre-runtime-linux-x64.tar.xz` | Ubuntu（可移植共享依赖） |
| `linux-arm64` | `mpv-libre-runtime-linux-arm64.tar.xz` | Ubuntu ARM（可移植共享依赖） |

二进制**不能**跨 OS / CPU 混用。请按运行环境选择对应归档。状态与产物名亦记录在
[`versions.lock.json`](versions.lock.json) 与各 Release 的
`runtime-manifest-v1.json` 中。

## 归档内容

**Windows（`win32-x64`）**

```text
libmpv-2.dll
ffmpeg.exe
ffprobe.exe
runtime.json
NOTICE.md
licenses/
```

**Unix（`linux-*`、`darwin-*`）**

```text
lib/libmpv.so.2          # macOS：lib/libmpv.2.dylib
lib/…                    # 可移植共享库（Linux 含 libstdc++）
ffmpeg
ffprobe
runtime.json
NOTICE.md
licenses/
```

`ffmpeg` / `ffprobe` 与库来自同一 LibreMPEG 构建，用于探测、转码与测试。头文件与
导入库不进入精简运行时；如有需要可另发 SDK 包。

## 获取与校验

每个 Release 包含：各平台运行时、`.sha256`、`runtime-manifest-v1.json`、对应源码
归档与许可证信息。

```powershell
$release = "RELEASE_TAG"
$base = "https://github.com/Zencok/mpv-libre-runtime/releases/download/$release"
curl.exe -fLO "$base/mpv-libre-runtime-win32-x64.7z"
curl.exe -fLO "$base/mpv-libre-runtime-win32-x64.7z.sha256"
Get-FileHash mpv-libre-runtime-win32-x64.7z -Algorithm SHA256
```

```bash
# 示例：Linux x64
release=RELEASE_TAG
base="https://github.com/Zencok/mpv-libre-runtime/releases/download/$release"
curl -fLO "$base/mpv-libre-runtime-linux-x64.tar.xz"
curl -fLO "$base/mpv-libre-runtime-linux-x64.tar.xz.sha256"
sha256sum -c mpv-libre-runtime-linux-x64.tar.xz.sha256
```

请固定**不可变**的 Release URL 与 SHA-256，不要在应用 CI 中拉取会变化的
`latest`。

## 使用 libmpv

加载对应平台的动态库，调用上游 libmpv C API：

```c
#include <mpv/client.h>

mpv_handle *player = mpv_create();
mpv_set_option_string(player, "config", "no");
mpv_set_option_string(player, "video", "no");

if (mpv_initialize(player) < 0) {
    return 1;
}

const char *command[] = { "loadfile", "MEDIA_PATH", "replace", NULL };
mpv_command(player, command);
mpv_set_property_string(player, "pause", "no");

/* 由宿主驱动 mpv_wait_event() */
mpv_terminate_destroy(player);
```

同一 ABI 可用于 C/C++、Rust、C#、Python、Node.js FFI 或独立 native helper。应用负
责生命周期、事件循环、线程、渲染与媒体源策略。

Linux 需保证 `lib/` 在 `LD_LIBRARY_PATH` 中（或通过 RPATH 与进程同布局）。macOS 下
库已使用 `lib/` 内的 `@loader_path`。

## 本地构建

通用依赖：**Node.js 22+**、**Git**。

### Windows x64

需要 Docker（Linux 容器）：

```bash
npm run check
npm run build:windows-x64
# 发布构建 + 源码归档：
npm run build:windows-x64:release
# 强制全量冷构建（不使用 GHCR 依赖镜像）：
npm run build:windows-x64:full
# 构建 CI 使用的 MinGW 依赖镜像（方案 B）：
npm run build:windows-x64:deps-image
npm run windows:deps-image-name
```

CI 分两层：

1. **依赖镜像（GHCR）** — 单一自包含多阶段 `Dockerfile.deps`（tools+deps 同一
   Buildx 图，不依赖主机 `docker load` base）。`DEPENDS` 从 package CMake 自动
   解析。经 `windows-runtime` → `windows-mingw-deps` 构建并启用 GHA 层缓存；
   去掉 `.git`/下载包，保留 install 前缀。
2. **运行时任务** — 拉镜像后 **reconfigure** 写真实 pin，只重编 LibreMPEG +
   libmpv；ccache 稳定 key。缓存保存失败不拖垮 job。归档校验用 deps 镜像或
   宿主机 `7z`。

本地构建会优先拉取依赖镜像，不可用时回退全量构建。提交钉死在
`versions.lock.json`；产物仍是 Windows PE/DLL。

### Unix（macOS / Linux）

额外工具：Meson、Ninja、NASM、pkg-config。

- **Linux：** build-essential，以及 libass/fontconfig/freetype/harfbuzz/alsa/pulse
  等开发包，patchelf
- **macOS：** 完整 Xcode（`swiftc`），Homebrew（`libass`、`meson`、MoltenVK 等）

```bash
npm run check
npm run build:unix -- linux-x64
# npm run build:unix -- linux-arm64
# npm run build:unix -- darwin-arm64
# npm run build:unix -- darwin-x64
```

打包策略：

- **Linux：** LibreMPEG/libplacebo 为 static+PIC；系统字体/UI 库保持共享并复制到
  `lib/`（`$ORIGIN` RPATH）；始终附带 `libstdc++`，保证 libplacebo 的 C++ 符号在
  `dlopen` 下可解析。
- **macOS：** 启用 Cocoa、Swift、`gl-cocoa`、`macos-cocoa-cb` 与 Vulkan/MoltenVK；
  非系统 dylib 改写为 `@loader_path`。

CI 校验（全平台）：`ffmpeg -decoders` 含 AC-4、实际解码 fixture、libmpv
`decoder-list` 含 AC-4、归档布局与许可证完整。

## 发布流程

1. 定时 workflow 检查上游并打开更新 `versions.lock.json` 的 PR。
2. CI 对全部目标构建并验证。
3. 合并到 `main` 后，在**同一不可变 tag** 上分阶段发布：
   - **Unix 先发** — linux/darwin 通过后立刻建 tag，上传 Unix 归档与阶段性
     `runtime-manifest-v1.json`（`phase: unix`）。
   - **Windows 后补** — win32 完成后（**不依赖 Unix 是否成功**）把产物与源码包挂
     到**同一 tag**；五平台齐全时 manifest 为 `phase: complete`，否则为 `auto`。
4. 只需要 Unix 的消费方可在首发后即固定 URL；需要全平台的应等待 manifest 中
   `complete: true`（或 win32 资产出现）后再升级。

上游 pin 不会在消费方应用内被静默替换。

## 可复现性

归档时间戳归一、条目排序确定；校验和覆盖最终字节。源码归档包含该次运行时使用的
构建定义与源码快照。

AC-4 冒烟样例的 URL 与哈希见
[`fixtures/ac4-smoke.json`](fixtures/ac4-smoke.json)。CI 下载到临时目录；媒体文件
不由本仓库再分发。

## 许可证

本仓库构建自动化为 MIT。

运行时二进制遵循组合后的上游义务。当前配置为 `AGPL-3.0-or-later`，不启用
nonfree，并附带许可证文本与对应源码。再分发或嵌入前请阅读
[`NOTICE.md`](NOTICE.md)。

本项目不是 mpv 或 LibreMPEG 的官方发行版。
