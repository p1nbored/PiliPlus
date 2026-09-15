import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

abstract final class ConnectivityUtils {
  /// 当前链路是否按「宽带档」取偏好（画质 / 音质 / 编码 / 直播清晰度）。
  ///
  /// 非移动端一律按宽带档，不查询链路。os_type 把鸿蒙 2in1 判定为 PC
  /// （`isMobile == false`），若把平台判断写成 `isMobile && wifi` 并进结果，
  /// 2in1 会恒落在蜂窝档：默认画质 / 音质 / 编码设置失效，HDR 片源也永远不会被
  /// 自动选中。上游主线在桌面端靠预置 cacheVideoQa 绕开，鸿蒙版没有这层预置。
  static Future<bool> get isWiFi async {
    if (!PlatformUtils.isMobile) return true;
    try {
      return (await Connectivity().checkConnectivity()).contains(
        ConnectivityResult.wifi,
      );
    } catch (_) {
      return true;
    }
  }
}