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

改动分布在四层，本地布局如下：

```
E:\project\PiliPlus                                应用本体（分支 feat/ohos-hdr）
E:\project\PiliPlus-hdr-deps\media-kit             分支 feat-ohos-hdr
E:\project\PiliPlus-hdr-deps\mpv                   分支 feat-ohos-hdr
E:\project\PiliPlus-hdr-deps\libmpv-ohos-build     分支 feat-ohos-hdr
E:\project\PiliPlus-hdr-deps\flutter-ohos-engine   引擎 HAR 补丁 + 应用脚本
```

### 1. mpv（`feat-ohos-hdr`）

- 恢复被 revert 掉的 `vo_ohcodec_embed.c`（“视频直通模式”）。这是鸿蒙版的
  `mediacodec_embed`：OHCodec 硬解码器直接把帧渲染进 OHNativeWindow，
  **HDR10 / HDR10+ / HDR Vivid 的动态元数据由系统解码器和合成器全程处理**。
- `ohos_common.c`：检测帧上的 HDR Vivid（CUVA）side data 并上报
  `OH_VIDEO_HDR_VIVID`；新增 `--ohos-hdr-mode=auto|no|hdr10|hlg|vivid`
  用于强制上报类型，这就是“杜比视界映射为 Vivid”的实现方式
  （DV 的 RPU 由 libplacebo 应用，画面已经是成品 PQ，差别只在信令）；
  新增 `--ohos-hdr-passthrough-metadata` 用于转发 HDR10+ 动态元数据。

### 2. media_kit（`feat-ohos-hdr`）

- 新增 `MediaKitVideoPlatformView.ets`：用 `XComponent` 承载视频的
  `PlatformView` + 工厂，并把 surfaceId 通过 method channel 交给 Dart。
- 新增 `OhosPlatformVideo` widget：用
  `PlatformViewsService.initExpensiveOhosView` 创建平台视图，走
  **hybrid composition**（`NodeRenderType.RENDER_TYPE_DISPLAY`），
  由 RenderService 直接合成，HDR 元数据得以保留。
- `VideoControllerConfiguration` 新增 `usePlatformView` 与 `ohosHdrMode`。
  默认仍走原来的纹理路径，不影响其他平台。

### 3. Flutter 引擎（HAR 补丁）

- 实现 `PlatformViewsController.configureForHybridComposition`，用
  `NodeRenderType.RENDER_TYPE_DISPLAY` 建节点并挂进视图树——这是让 surface
  被 RenderService 直接合成、从而保住 HDR 元数据的关键一步。
- 让引擎同时监听 `flutter/platform_views_2`，hybrid 视图才会被正常销毁。

### 4. PiliPlus

- `VideoQuality.isHDR` / `isDolbyVision`（对应 qn 125 / 126 / 129）。
- `setDataSource(..., quality:)` 把当前画质传给播放器，播放器据此决定是否
  启用平台视图与 HDR 信令。
- 设置项（仅鸿蒙可见）：启用 HDR 视频 / HDR 使用平台视图渲染 /
  杜比视界映射为 HDR Vivid。

## 构建

### 第一步：给 Flutter 引擎打补丁（必须）

预编译引擎里 hybrid composition 是空实现，不打补丁平台视图不会显示。
HAR 内是未混淆的 ArkTS 源码，解包打补丁再打包即可，不需要编译引擎：

```bash
cd PiliPlus-hdr-deps/flutter-ohos-engine
./apply-engine-patch.sh /path/to/flutter          # 还原用 --revert
```

脚本会自动备份 `*.har.orig`，可重复执行。细节见该目录下的 README。

### 第二步：重新编译 libmpv（必须）

应用默认下载的是预编译 libmpv，**不含上面的 mpv 补丁**，必须自己编译一次。
`build.sh` 只支持 Linux / macOS，Windows 下请用 WSL 或 Linux 机器：

```bash
cd libmpv-ohos-build
# 指向本地打过补丁的 mpv
export MPV_REPO=/path/to/PiliPlus-hdr-deps/mpv
export MPV_REF=feat-ohos-hdr
./download.sh
./patch.sh
./build.sh
```

产物是 arm64-v8a 的 `libmpv.so`。把它放到：

```
PiliPlus-hdr-deps/media-kit/libs/ohos/media_kit_libs_ohos/libs/arm64-v8a/libmpv.so
```

该目录非空时 CMake 会跳过下载，直接使用这个 so。

### 第三步：编译应用

```bash
cd PiliPlus
flutter pub get
flutter build hap --release   # 或用 VSCode 的 build_hap 任务
```

`pubspec.yaml` 的 `dependency_overrides` 已指向本地 media-kit fork。
如果把补丁推到了自己的仓库，把那几项改回 `git:` 形式即可。

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

## 已知限制

- **HDR Vivid / HDR10+ 的动态元数据只在直通模式（`vo=ohcodec_embed`）下完整**。
  走 `gpu-next` 时 FFmpeg 只提供解析后的 `AVDynamicHDRVivid` 结构，
  **没有** `av_dynamic_hdr_vivid_to_t35()` 之类的反序列化 API，
  无法还原成 `OH_HDR_DYNAMIC_METADATA` 需要的 CUVA SEI 原始字节流。
  HDR10+ 可以（`av_dynamic_hdr_plus_to_t35()` 存在），因此提供了
  `--ohos-hdr-passthrough-metadata`，默认关闭——因为 `gpu-next` 交给合成器的
  已经是 libplacebo 处理完的画面，再叠一层动态元数据会重复处理。
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
