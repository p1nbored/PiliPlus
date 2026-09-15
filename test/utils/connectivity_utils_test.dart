import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // os_type 把鸿蒙 2in1 判定为 PC（isMobile == false）。flutter_test 默认把
  // defaultTargetPlatform 设为 android，而 PlatformUtils.isMobile 是首次读取时
  // 才求值的 static final，所以要在读取之前切到桌面平台来模拟 2in1。
  // 2in1 必须落在宽带档，否则画质 / 音质 / 编码恒按蜂窝档取默认值，HDR 片源
  // 永远不会被自动选中。
  test('non-mobile platforms use broadband prefs', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(PlatformUtils.isMobile, isFalse);
      expect(await ConnectivityUtils.isWiFi, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
