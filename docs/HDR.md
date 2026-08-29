# HarmonyOS HDR 输出

针对鸿蒙版 HDR 播放（HDR10 / HDR10+ / 杜比视界 / HDR Vivid）不触发峰值亮度、
颜色不正确的修复说明。

## 问题原因

libmpv 在鸿蒙上其实已经做对了一半：`video/out/ohos_common.c` 会调用
`OH_NativeWindow_SetColorSpace()` 把 NativeWindow 切到 BT.2020 PQ / HLG，
并通过 `OH_NativeWindow_SetMetadataValue()` 挂上 HDR 静态元数据和
`SET_HDR_WHITE_POINT_BRIGHTNESS`。

问题出在这块 surface 之后怎么上屏。之前的实现把视频渲染进 **Flutter 纹理**
（`SurfaceTextureEntry` → `Texture(textureId:)`）。Flutter 引擎会把这个纹理
重采样进它自己的 SDR 合成层，**色域和 HDR 元数据在这一步全部丢失**。于是：

- 系统的 RenderService 从来没有进入 HDR 模式 → 不会拉峰值亮度；
- 已经按 PQ 编码的 BT.2020 画面被当作 sRGB 显示 → 颜色发灰、发暗、不正确。

这与 Android 上的情况完全一致：Android 的 HDR 必须用 SurfaceView，
TextureView 做不到。`cnctem/PiliPlusX` 的 `hdr` 分支正是这样修 Android 的
（`usePlatformView: true` + `EnableSurfaceControl` + `vo=mediacodec_embed,gpu`），
而该分支的 HDR 设置写的是 `if (Platform.isAndroid)`，鸿蒙没有对应实现。

此外 `ohos_common.c` 还有两个缺口：上报的 metadata type 只可能是
`OH_VIDEO_HDR_HDR10` 或 `OH_VIDEO_HDR_HLG`，**永远不会是
`OH_VIDEO_HDR_VIVID`**；`OH_HDR_DYNAMIC_METADATA` 完全没有设置过。

## 修改内容

改动分布在五层，本地布局如下：

```
C:\Programs\PiliPlus                                应用本体（分支 feat/ohos-hdr）
C:\Programs\PiliPlus-hdr-deps\media-kit             分支 feat-ohos-hdr
C:\Programs\PiliPlus-hdr-deps\mpv                   分支 feat-ohos-hdr
C:\Programs\PiliPlus-hdr-deps\ffmpeg                分支 feat-ohos-hdr
C:\Programs\PiliPlus-hdr-deps\libmpv-ohos-build     分支 feat-ohos-hdr
C:\Programs\PiliPlus-hdr-deps\flutter-ohos-engine   引擎 HAR 补丁 + 应用脚本
```

> 两个目录必须保持同级：`pubspec.yaml` 的 `dependency_overrides` 用的是
> `../PiliPlus-hdr-deps/...` 相对路径。
>
> **不要放在 exFAT 分区上。** ohpm 的 `oh_modules` 完全依赖符号链接，exFAT
> 不支持，`ohpm install` 会以 `00625004 SymLink Dir Failed` / `EBUSY` 失败，
> 开发者模式和管理员权限都救不了。必须放在 NTFS 分区。

### 1. FFmpeg（`feat-ohos-hdr`）

- `libavcodec/ohdec.c`：鸿蒙硬解此前**只**从 UNSPEC62 NAL 取杜比视界 RPU，
  完全不解析 SEI，于是 HDR Vivid 的 CUVA 和 HDR10+ 的 ST2094-40 side data
  一个都产不出来（软解的 `hevcdec.c` 是有的）。现在复用同一批已经拆好的 NAL，
  走 h2645 公共 SEI 解析器取出 T.35 载荷，挂到既有的 PTS 队列上随帧下发。
  注意 SEI 扫描不再受 RPU 是否存在影响——HDR Vivid / HDR10+ 片源根本没有 RPU，
  原先 `if (!rpu_nal) return 0;` 会把它们的动态元数据整个丢掉。
- `configure`：`hevc_oh_decoder_select` 补上 `hevcparse hevc_sei dovi_rpudec`。
  `ohdec.o` 一直在调用 `ff_h2645_packet_split` 和 `ff_dovi_rpu_parse` 却没有
  声明这两个依赖，眼下能链接**只是因为**构建同时启用了软解 `hevc` 把它们捎带
  进来。一旦精简白名单去掉 `hevc`，杜比视界会静默失效。

### 2. mpv（`feat-ohos-hdr`）

- 恢复被 revert 掉的 `vo_ohcodec_embed.c`（“视频直通模式”）。这是鸿蒙版的
  `mediacodec_embed`：OHCodec 硬解码器直接把帧渲染进 OHNativeWindow。
  （**注意**：它并不像早先以为的那样“动态元数据全程由系统处理”——该 VO 连
  `vo_ohos_set_color` / `vo_ohos_set_frame` 都不调用，色域和元数据一个都不设。
  详见下文《HDR 类型映射》一节末尾的更正。）
- `ohos_common.c`：检测帧上的 HDR Vivid（CUVA）side data 并上报
  `OH_VIDEO_HDR_VIVID`；新增 `--ohos-hdr-mode=auto|no|hdr10|hlg|vivid`
  用于强制上报类型，这就是“杜比视界映射为 Vivid”的实现方式
  （DV 的 RPU 由 libplacebo 应用，画面已经是成品 PQ，差别只在信令）。
- `mp_image.c`：把 HDR Vivid 的动态峰值接进 libplacebo 的色调映射。
  libplacebo v7.360.1 完全没有 CUVA 支持（`src/` 下 `vivid` / `cuva` 零命中），
  但它的 **CIE_Y** 通道要的正是 HDR Vivid 携带的那个量：PQ 域 0-1 亮度。
  `maximum_maxrgb` / `average_maxrgb` 是分母 4095 的 12 bit PQ 值，`av_q2d()`
  直接就是目标单位。不用 `scene_max[]` 是因为那个字段的单位是 cd/m²。
  杜比视界的 L1 经 `pl_hdr_metadata_from_dovi_rpu()` 走同一个字段，故同时
  带两者的片源仍以杜比视界为准。

### 3. media_kit（`feat-ohos-hdr`）

- 新增 `MediaKitVideoPlatformView.ets`：用 `XComponent` 承载视频的
  `PlatformView` + 工厂，并把 surfaceId 通过 method channel 交给 Dart。
- 新增 `OhosPlatformVideo` widget：用
  `PlatformViewsService.initExpensiveOhosView` 创建平台视图，走
  **hybrid composition**（`NodeRenderType.RENDER_TYPE_DISPLAY`），
  由 RenderService 直接合成，HDR 元数据得以保留。
- `VideoControllerConfiguration` 新增 `usePlatformView` 与 `ohosHdrMode`。
  默认仍走原来的纹理路径，不影响其他平台。

### 4. Flutter 引擎（HAR 补丁）

- 实现 `PlatformViewsController.configureForHybridComposition`，用
  `NodeRenderType.RENDER_TYPE_DISPLAY` 建节点并挂进视图树——这是让 surface
  被 RenderService 直接合成、从而保住 HDR 元数据的关键一步。
- 让引擎同时监听 `flutter/platform_views_2`，hybrid 视图才会被正常销毁。

### 5. PiliPlus

- `VideoQuality.isHDR` / `isDolbyVision`（对应 qn 125 / 126 / 129）。
- `setDataSource(..., quality:)` 把当前画质传给播放器，播放器据此决定是否
  启用平台视图与 HDR 信令。
- 设置项（仅鸿蒙可见）：启用 HDR 视频 / HDR 使用平台视图渲染 /
  杜比视界映射为 HDR Vivid。

## 构建

### 第一步：安装鸿蒙版 Flutter SDK

```powershell
git clone -b oh-3.41.9-dev https://gitcode.com/CPF-Flutter/flutter_flutter.git C:\flutter
```

### 第二步：配置环境变量

变量名取自 flutter_tools 的 `ohos/ohos_sdk.dart` 与 `hvigor_utils.dart`
（`HOS_SDK_HOME` / `DEVECO_SDK_HOME` / `NODE_HOME`）：

```powershell
$deveco = "C:\Program Files\Huawei\DevEco Studio"
[Environment]::SetEnvironmentVariable("HOS_SDK_HOME",    "$deveco\sdk", "User")
[Environment]::SetEnvironmentVariable("DEVECO_SDK_HOME", "$deveco\sdk", "User")
[Environment]::SetEnvironmentVariable("NODE_HOME",       "$deveco\tools\node", "User")
$p = [Environment]::GetEnvironmentVariable("PATH","User")
[Environment]::SetEnvironmentVariable("PATH",
  "$p;C:\flutter\bin;$deveco\tools\ohpm\bin;$deveco\tools\hvigor\bin;$deveco\tools\node;$deveco\sdk\default\openharmony\toolchains","User")
```

重开终端后用 `flutter doctor -v`、`flutter devices` 确认。

### 第三步：给 Flutter 引擎打补丁（必须）

预编译引擎里 hybrid composition 是空实现，不打补丁平台视图不会显示。
HAR 内是未混淆的 ArkTS 源码，解包打补丁再打包即可，不需要编译引擎。
在 Git Bash 里执行：

```bash
cd /c/Programs/PiliPlus-hdr-deps/flutter-ohos-engine
./apply-engine-patch.sh /c/flutter          # 还原用 --revert
```

脚本会自动备份 `*.har.orig`，可重复执行。细节见该目录下的 README。

### 第四步：重新编译 libmpv（必须）

应用默认下载的是预编译 libmpv，**不含上面的 mpv 补丁**，必须自己编译一次。
`build.sh` 只支持 Linux / macOS，Windows 下用 WSL：

```bash
wsl -d Ubuntu
```

```bash
# 几个非显然但必须的依赖：
#   python3-venv  mbedtls 会自己建 virtualenv，缺了它构建中断
#   gperf         fontconfig 的 meson subproject，而 wrap 自动下载是关闭的
#   meson>=1.6.1  Ubuntu 24.04 apt 只有 1.3.2，fontconfig 会直接拒绝
sudo apt update && sudo apt install -y git wget curl build-essential ninja-build \
     python3 python3-pip python3-setuptools python3-venv pkg-config unzip cmake \
     ca-certificates file bzip2 xz-utils autoconf automake libtool libtool-bin \
     gperf nasm yasm flex bison gettext autopoint texinfo help2man
sudo apt remove -y meson
pip3 install --break-system-packages -U meson ninja

git clone https://github.com/cnoim/libmpv-ohos-build.git ~/libmpv-ohos-build
cd ~/libmpv-ohos-build
git remote add local /mnt/c/Programs/PiliPlus-hdr-deps/libmpv-ohos-build && git fetch local
git checkout -B feat-ohos-hdr local/feat-ohos-hdr

# 指向本地打过补丁的 mpv 与 ffmpeg
export MPV_REPO=/mnt/c/Programs/PiliPlus-hdr-deps/mpv
export MPV_REF=feat-ohos-hdr
export FFMPEG_REPO=/mnt/c/Programs/PiliPlus-hdr-deps/ffmpeg
export FFMPEG_REF=feat-ohos-hdr

# download-ohos-rs.sh 只在它自己的进程里 source ~/.cargo/env，等 build.sh 跑到
# dovi_tools.sh（杜比视界）时 cargo 已经不在 PATH 上了，必须自己加回来
export PATH="$HOME/.cargo/bin:$PATH"

./download.sh && ./patch.sh && ./build.sh    # 会拉取数 GB 的 SDK，耗时 1~3 小时
```

从 Windows 克隆的仓库在 WSL 里没有可执行位，`./download.sh` 会
`Permission denied`，先补一下：

```bash
find . -name '*.sh' -exec chmod +x {} +
```

`git fetch` 本地仓库还需要把 **`.git` 路径**也加进 safe.directory
（只加工作树不够，否则报 "Could not read from remote repository"）：

```bash
git config --global --add safe.directory /mnt/c/Programs/PiliPlus-hdr-deps/mpv
git config --global --add safe.directory /mnt/c/Programs/PiliPlus-hdr-deps/mpv/.git
```

产物是 arm64-v8a 的 `libmpv.so`，路径是确定的：
**`~/libmpv-ohos-build/libmpv/arm64-build/libmpv.so`**
（`env.sh` 的 `DEST`，由 `scripts/mpv.sh` 收口）。不要用
`find ~/libmpv-ohos-build -name libmpv.so` —— 它同时会匹配到中间产物
`libmpv/mpv/.build/libmpv.so`。复制到：

```bash
LIBS=/mnt/c/Programs/PiliPlus-hdr-deps/media-kit/libs/ohos/media_kit_libs_ohos/libs/arm64-v8a
mkdir -p $LIBS
cp ~/libmpv-ohos-build/libmpv/arm64-build/libmpv.so $LIBS/
```

注意这里是**模块根**下的 `media_kit_libs_ohos/libs/arm64-v8a/`，
不是 `media_kit_libs_ohos/ohos/libs/arm64-v8a/`。
`ohos/src/main/cpp/CMakeLists.txt` 里的 `LIBMPV_LOCAL` 就指向模块根
（`${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/arm64-v8a/libmpv.so`）；
存在时它会被复制进 `LIBMPV_SRC` 并把 `LIBMPV_SRC_VALID` 置真，
下载和解包两步都跳过。

> **早期版本在这里踩过坑（现已在 CMakeLists 里修掉）。** 当时只认
> `ohos/libs/arm64-v8a/`，而那个目录里早就躺着首次构建下载的预编译包，
> 于是 `LIBMPV_SRC_VALID` 恒为真——既不重新下载，也永远不会发现那个 so 是旧的，
> **编了几个小时的补丁版 mpv 从未进过 HAP**，表现为 HDR 全黑。
> 现在改用模块根路径，它在 ohos 模块之外，不会被解包覆盖，存在即优先。
> 覆盖之后仍要删掉这两个中间产物，否则打包还是会用旧的：
>
> ```
> ohos/build/default/intermediates/libs/default/arm64-v8a/libmpv.so
> ohos/build/default/intermediates/stripped_native_libs/default/arm64-v8a/libmpv.so
> ```

复制前先确认补丁真的编进去了（用的是预编译包就不会有这些字符串）：

```bash
for s in ohos-hdr-mode ohcodec_embed; do
  printf '%-32s ' "$s"; grep -qa -e "$s" libmpv.so && echo FOUND || echo MISSING
done
# 注意：不要用 "dovi" 判断补丁——stock ffmpeg 里也有这个字符串，恒为 present。
```

两个都是 FOUND 才说明用的是打过补丁的 mpv。

**光看源文件不够**，还要确认它真的进了 HAP——这是唯一能证明补丁上了设备的检查：

```bash
cd /c/Programs/PiliPlus
unzip -o -q ohos/entry/build/default/outputs/default/entry-default-unsigned.hap       libs/arm64-v8a/libmpv.so -d /tmp/hapchk
for s in ohos-hdr-mode ohcodec_embed; do
  printf '%-32s ' "$s"
  grep -qa -e "$s" /tmp/hapchk/libs/arm64-v8a/libmpv.so && echo FOUND || echo MISSING
done
```

`bundle.sh` 收口的 `arm64-build/libmpv.so` 已经是 strip 过的，约 **24 MB**
（预编译包约 27 MB 且两项 MISSING）。**不要按大小判断**，以上面几个字符串是否
FOUND 为准。另外「本次构建是不是最新的」有个现成的反向标记：
`ohos-hdr-passthrough` 在 `15939f77e` 里已删除，新构建里应当**查不到**；
还能查到就说明用的是旧 so。

**`ohdec.c` 的前缀 SEI 补丁（R0）另有一个确定的静态验证**，因为它没有引入新的
字符串常量，只能从目标文件的符号引用上看：

```bash
B=~/libmpv-ohos-build/libmpv/ffmpeg/.build
/sdk/bisheng/bin/llvm-nm --undefined-only $B/libavcodec/ohdec.o | grep ff_h2645_sei
# 应当出现 ff_h2645_sei_message_decode 与 ff_h2645_sei_reset
grep -E "^CONFIG_(HEVC_SEI|HEVCPARSE|DOVI_RPUDEC)=" $B/ffbuild/config.mak
# 三项都应当是 =yes
```

### 第五步：配置签名

`ohos/build-profile.json5` 里 `signingConfigs` 目前是空的，未签名的 HAP 无法安装。
用 DevEco Studio 打开 `C:\Programs\PiliPlus\ohos`，登录华为开发者账号并连接设备，
**File → Project Structure → Signing Configs → 勾选自动生成签名**。
调试证书同时绑定 bundleName（`com.example.piliplus`）与设备 UDID，只能交互式生成。

### 第六步：编译应用

```powershell
cd C:\Programs\PiliPlus
dart .vscode\build_env.dart          # 生成 .vscode\env.json
flutter pub get
flutter build hap --release --dart-define-from-file=.vscode/env.json
```

产物在 `ohos\entry\build\default\outputs\default\`。安装：

```powershell
hdc install -r .\ohos\entry\build\default\outputs\default\entry-default-signed.hap
```

`pubspec.yaml` 的 `dependency_overrides` 已指向同级的 media-kit fork。
如果把补丁推到了自己的仓库，把那几项改回 `git:` 形式即可。

## Windows 上的四个坑

实际跑通这套流程时按顺序踩到的，都会让构建以看起来无关的错误失败：

1. **exFAT 不支持符号链接**
   `ohpm install` 报 `00625004 SymLink Dir Failed` / `EBUSY`。
   开发者模式和管理员权限都无效，项目必须放在 NTFS 分区。

2. **`MAX_PATH` 260 字符限制**
   `flutter pub get` 报一堆 `Filename too long`——pub 会克隆
   `flutter_packages` 这个 monorepo，里面
   `webview_flutter_wkwebview/example/ios/.../Icon-App-83.5x83.5@2x.png`
   之类的路径超长。修复：

   ```powershell
   git config --global core.longpaths true
   ```

3. **pub 缓存被上一条的失败搞坏**
   长路径导致 checkout 中途 `Aborting`，pub 缓存里 **29 个中有 7 个**
   停在了错误的 commit 上。表现是看似无关的版本冲突，例如
   `Package not available (the pubspec for shared_preferences 2.5.4 from git has version 2.2.0)`
   ——目录名叫 `flutter_packages-19bd50ff…`，实际 HEAD 却是 `fd410050…`。
   修复：把每个 `<名字>-<sha>` 目录强制 checkout 回它自己名字里的 sha。

4. **Git LFS 对象在远端已丢失**
   `flutter_audio_session` 和 `fluttertpc_audio_service` 用 LFS 跟踪了示例资源
   （`icudtl.dat`、`video2.mp4`），而远端已经没有这些对象，smudge 过滤器会让
   checkout 失败。这些只是示例资源，构建用不到：

   ```powershell
   $env:GIT_LFS_SKIP_SMUDGE = "1"
   ```

另外 Windows 的 git 不记录可执行位，从 Windows 克隆的仓库在 WSL 里
`./download.sh` 会 `Permission denied`，构建脚本里已经统一 `chmod +x`。

## 验证 HDR 是否真的生效

**最可靠的一条**：mpv 自己会打日志。用 verbose 级别抓：

```bash
hdc hilog | grep -i "NativeWindow"
```

正常应看到：

```
NativeWindow output switched to BT.2020 PQ     # HDR10 / 杜比视界
NativeWindow output switched to BT.2020 HLG    # HLG
```

如果看到的是 `Failed to set NativeWindow color space: <err>` 或
`Failed to set NativeWindow HDR metadata type`，说明 surface 不接受 HDR
属性——通常意味着仍然走在纹理路径上（确认“HDR 使用平台视图渲染”已开启）。

**验证前缀 SEI 补丁是否生效（动态元数据）**：`ohos-hdr-mode` / `ohcodec_embed`
两个字符串只能证明「这是打过补丁的 libmpv」，证明不了 `ohdec.c` 的 SEI 补丁在里面
（补丁没有引入新的字符串常量）。要验证它，把 `--ohos-hdr-mode` 临时切回 `auto`
放一段 qn=129 的 HDR Vivid 片源：补丁生效时硬解路径会产出 CUVA side data，
`ohos_common.c` 认出来后上报 `OH_VIDEO_HDR_VIVID`；补丁不在时会落回 `hdr10`。
这也是唯一能把「side data 产出」和「信令正确」一次验完的办法。

若一行 `NativeWindow` 日志都没有，说明 `set_color` 根本没被调用，
即 `vo` 不是 `gpu-next`，或播放器没判定当前片源为 HDR
（确认播放的确实是 qn=125/126/129 的片源，且“启用 HDR 视频”已开启）。

辅助手段：`hdc shell hidumper -s RenderService -a allInfo` 可以看合成器侧的
HDR 状态；不同 ROM 版本输出格式不一致，以 mpv 日志为准。

### 关于 hybrid composition（已确认并已修复）

这一环之前无法静态确认，现在已经查清。把预编译引擎产物
（`https://flutter-ohos.obs.cn-south-1.myhuaweicloud.com/flutter_infra_release/flutter/3fb08d34…/ohos-arm64-release/artifacts.zip`）
解包后可以看到，`flutter_embedding_release.har` 里是**未混淆的 ArkTS 源码**，
其中：

```ts
private configureForHybridComposition(platformView, request): void {
  // This path is not implemented yet on OHOS. ...
  Log.i(TAG, "Using hybrid composition for platform view: " + request.viewId);
}
```

**引擎侧 hybrid composition 确实没有实现**（旁证：本项目里的
`flutter_inappwebview_ohos` 也只用纹理路径的 `initOhosView`，注释写着
“这里对比安卓没有 PlatformViewLink 暂时用 OhosView 替代”）。
不打这个补丁，平台视图会被创建但永远不会挂进视图树，视频区域一片空白。

补丁见 `PiliPlus-hdr-deps/flutter-ohos-engine/`，用法见其 README。
另外两点也一并解决了：

- hybrid 控制器的 `dispose` 发到 `flutter/platform_views_2`，而引擎只监听
  `flutter/platform_views`，平台视图不会被销毁；
- Flutter 框架侧 `_HybridOhosViewControllerInternals` 的 `setSize` / `setOffset`
  直接 `throw`（上游假定由引擎合成器负责定位，鸿蒙没有这一层），所以 media_kit
  的 `OhosPlatformVideo` 自己在 `flutter/platform_views` 上发 `resize` / `offset`
  来同步几何。

肉眼判断：进入 HDR 后屏幕峰值亮度会明显抬升（尤其高光部分），
而不只是整体画面变亮。

### XComponent 的不透明黑底会盖住平台视图（黑屏根因）

平台视图接上了、尺寸也对了，视频区域**仍然全黑**，SDR 正常——这是第三个坑，
和 HDR 本身无关。

`FlutterPage.ets`（引擎 HAR 内）的 `defaultPage()` 层级是：

```ts
Stack() {
  ForEach(this.rootDvModel!!, ...)   // 平台视图（下层）
  Text("").id("unfocus-xcomponent-node")
  FlutterSurface({ ..., xComponentColor: this.xComponentColor })   // Flutter（上层）
}
```

而 `FlutterSurface` 给 XComponent 刷的背景是：

```ts
.backgroundColor(this.firstFrameDisplayed && this.xComponentRenderFit == RenderFit.RESIZE_FILL ?
  this.xComponentColor : Color.Transparent)
```

`xComponentColor` 在 `FlutterSurface` 和 `FlutterPage` 两处的默认值都是
**`Color.Black`**，`xComponentRenderFit` 默认就是 `RESIZE_FILL`。也就是说
**首帧之后，XComponent 会被刷上一层不透明黑底，而它在 Stack 里排在平台视图上方**，
于是平台视图被完整遮住。

这层黑底是 ArkUI 侧画的，位于平台视图之上、Flutter 画面之下，
所以 Dart 侧再怎么把 `Video(fill:)` 设成透明都没用——`fill` 只作用于
Flutter 表面内部。引擎的 `0001` / `0002` 两个补丁只解决了「挂不上视图树」和
「尺寸 0×0」，没有碰这层背景。

修复在应用侧一行即可，不需要再打引擎补丁（`Index.ets`）：

```ts
FlutterPage({ viewId: this.viewId, xComponentColor: Color.Transparent })
```

`FlutterPage.xComponentColor` 是 `@State`，ArkUI 允许父组件在构造时初始化，
该初始值会经 `FlutterPage` 透传给 `FlutterSurface` 的同名 `@Prop`。

注意它是 `@State` 而非 `@Prop`，**只取构造时的初始值，之后父组件再改不会同步**，
所以这里只能无条件置透明，没法按「是否正在放 HDR」动态切换。这不会影响非 HDR
场景：Flutter 自身画面是不透明的，透明的只有它主动画透明的区域（即平台视图模式
下的视频区）。代价仅是首帧前/窗口尺寸变化的瞬间，露出的是窗口背景而不是黑色。

### HDR 类型映射与色调映射标定（已按源码核对）

| 片源 | qn | `--ohos-hdr-mode` | `--target-peak` | 谁做色调映射 |
| --- | --- | --- | --- | --- |
| HDR Vivid（原生） | 129 | `vivid`† | 1600 | libplacebo |
| 杜比视界 | 126 | `vivid`* | 1600 | libplacebo |
| HDR10 / HDR10+ | 125 | `hdr10` | 1600 | libplacebo |

\* 仅当面板实测支持 Vivid（`HarmonyChannel.displaySupportsHdrVivid`）时；否则 `hdr10`。

† 仍然显式指定，不依赖 `auto`。历史原因是：`auto` 要靠 `ohos_common.c` 从帧的
CUVA side data 认出片源，而鸿蒙硬解此前不解析 SEI，side data 永远不会产生，
`auto` 于是一路落到 `hdr10`——原生 Vivid 反被报成 HDR10。
**这一条已随 FFmpeg 的 `ohdec.c` 补丁修复**（见《修改内容》第 1 节），硬解路径
现在也会产出 CUVA side data，`auto` 已经能正确认出 Vivid。但片源类型从 qn 就已经
知道，显式指定仍然更省事、也不依赖具体 libmpv 版本，故保持现状。

**动态元数据由 libplacebo 消费，而不是转交给合成器。** 这是两件事，
早先的版本把它们混为一谈了：

- **「转交给系统」确实做不到**，`--ohos-hdr-passthrough-metadata` 已连同转交分支
  一起删除，理由见下面三条。
- **但「被利用」一直在发生，而且是逐帧的**：杜比视界的 RPU 由 libplacebo 应用
  （多项式 / MMR reshaping + L1 动态峰值），HDR10+ 的 ST2094-40 经
  `mp_image.c` 的 `pl_map_hdr_metadata()` 进入 `pl_hdr_metadata`，
  HDR Vivid 的 maxRGB 经本次新增的映射进入 CIE_Y 通道。
  **这就是动态元数据被利用的方式**，不需要合成器参与。

结论都在源码 / 符号表 / SDK 头文件里核对过：

- **硬解路径此前产不出 SEI 类动态元数据**：`enableHA` 默认开、`hwdec` 默认 `auto`，
  mpv 会选中 `ohcodec`，实际解码器是 `ff_hevc_oh_decoder`——它**完全不解析 SEI**，
  只从 UNSPEC62 NAL 取杜比视界的 RPU。
  **已由 `ohdec.c` 补丁修复**：现在同一批 NAL 里的前缀 SEI 也会被解析，
  CUVA 与 2094-40 side data 都能正常产出。
  （注意 side data「一个都产不出」的说法从来就不准确：杜比视界的 RPU 与
  DOVI_METADATA 在硬解路径上一直是产出的。）
- **HDR Vivid**：就算有 side data 也转交不了。FFmpeg 能解析 CUVA
  （`ff_parse_itu_t_t35_to_dynamic_hdr_vivid`），但**没有 `_to_t35`**——本地
  `libmpv.so` 符号表里只有 `av_dynamic_hdr_vivid_alloc` / `_create_side_data`，
  上游 FFmpeg 至今也没有；原始 T.35 字节又在 SEI 解析时就被丢弃了。
- **杜比视界**：`ohos_common.c` 里没有任何 DOVI 分支。RPU 在
  `mp_image.c:1185-1212` 就被 libplacebo 吃掉了，VO 层拿到的已经是成品 PQ。
  按 Vivid 上报只是换个标签，源码注释自己写着「only the signalling differs」。
- **HDR10+**：唯一能序列化的（`av_dynamic_hdr_plus_to_t35`），但
  `OH_NativeBuffer_MetadataType` **没有 HDR10+ 这个类型**，只能挂在
  `OH_VIDEO_HDR_VIVID` 下发出去——而那个类型意味着 CUVA 载荷。更糟的是它不会被
  拒绝：`av_dynamic_hdr_plus_to_t35` 输出的是不带 T.35 头、首字节为
  `application_version = 0x01` 的载荷，而 CUVA 解析器只校验
  `system_start_code ∈ 0x01..0x07`——**0x01 正好通过**，于是被静默误解析成垃圾
  曲线参数，比什么都不发更糟。这条分支因此已删除。

**`--target-peak` 所有 HDR 片源都要给。** 之前以为原生 Vivid 是「直通」所以不该给，
那是错的：`vo=gpu-next` 一定会跑完整的 libplacebo 渲染，没有直通路径。不给
target-peak 只是让它按 PQ 的名义峰值 10000 nit 反推目标，等于假设了一块比实际亮
6 倍多的屏幕。目标机型标定值 `_kDisplayPeakNits = 1600`（SLM-W32，典型 700 nit /
峰值 1600 nit）；鸿蒙没有查询面板峰值亮度的接口，所以按机型写死。

> **`vo=ohcodec_embed` 不是「完整动态元数据」的出路，恰恰相反。**
> `vo_ohcodec_embed.c` 从不调用 `vo_ohos_set_color` / `vo_ohos_set_frame`，
> `reconfig()` 直接 `return 0`——这个 VO 下 mpv **色域、类型、静态元数据、动态
> 元数据一个都不设**。动态元数据转交只在 gpu-next 上实现。本文档早先的相反说法
> 是错的。

## 已知限制

- **动态 HDR 元数据不转交给合成器**（但会被 libplacebo 逐帧利用，见上文）。
  `--ohos-hdr-passthrough-metadata` 已删除。转交做不到的理由：FFmpeg 没有 CUVA
  的序列化接口（只有 `_to_t35` 的反向，没有正向），原始 T.35 字节在 SEI 解析时
  被丢弃；HDR10+ 的 2094-40 载荷挂上 CUVA 标签会被**静默误解析**
  （`application_version = 0x01` 恰好通过 CUVA 的 `system_start_code` 校验），
  比不发更糟；而 `OH_NativeBuffer_MetadataType` 里压根没有 HDR10+ 这个类型。
  更根本的是：`vo=gpu-next` 交给 swapchain 的已经是**做完色调映射的成品 PQ**，
  再挂上描述原始片源的动态元数据，只会让合成器基于错误的统计量再映射一遍。
  真要走转交路线，得先让 libplacebo 停止色调映射，而 gpu-next 没有直通路径。
- **杜比视界 P10（AV1）不可达**：`ohdec.c` 只声明了 h264 / hevc 硬解，
  鸿蒙侧 `preferCodecs` 也只有 HEVC / AVC，`VideoDecodeFormatType` 里没有
  `dvav` / `dav1`。手机上 4K HDR 的 AV1 软解也不现实。P5 / P8.1 / P8.4 走的是
  同一条 RPU 路径，不受影响。
- 直通模式没有 mpv 的着色器、超分、tone mapping 和 VO 层字幕 / OSD 渲染，
  且只接受硬解帧。当前默认仍是 `gpu-next`；`ohcodec_embed` 已经编进去，
  可通过 `--vo` 切换验证。
- 平台视图的合成开销高于纹理，且不能被 Flutter 任意变换，
  所以只在 HDR 片源上启用，SDR 仍走纹理路径。
- **平台视图渲染在 Flutter 画面之下**（见引擎补丁 README 里的 `Stack` 层级）。
  好处是播放器控件天然叠在视频上方，代价是视频区域 Flutter 必须画透明：
  `OhosPlatformVideo` 本身不绘制任何内容，`Video(fill:)` 在该模式下被置为
  `Colors.transparent`。如果外层还有不透明背景盖住播放区，视频会看不见。
- 平台视图不参与 Flutter 命中测试（`hitTestSelf` 恒为 false），手势仍由
  播放器自己的 Flutter 层处理；视频表面上不需要原生触摸。
- 杜比视界在鸿蒙上没有原生信令。这里的做法是让 libplacebo 应用 DV RPU 得到
  PQ 画面，再按 HDR Vivid（或 HDR10）上报。若希望从源头规避，
  可在片源选择时优先选 qn=129 的 HDR Vivid 版本。
