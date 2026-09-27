// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video/ohos_platform_video.dart';
import 'package:media_kit_video/src/video_controller/ohos_video_controller/ohos_video_controller.dart';

class _FakeOhosVideoController extends Fake implements OhosVideoController {
  _FakeOhosVideoController(this.log);

  final List<String> log;

  /// 真实的 attach 要等 XComponent 拿到 surface，detach 要先在锁里把 vo 置空；
  /// 两者都是异步往返，测试用它们模拟「还没回来」。
  Future<void> Function()? onAttach;
  Future<void> Function()? onDetach;

  @override
  Future<void> attachPlatformView(int viewId) async {
    await onAttach?.call();
    log.add('attach:$viewId');
  }

  @override
  Future<void> detachPlatformView() async {
    log.add('detach');
    await onDetach?.call();
  }
}

void main() {
  // 鸿蒙 HDR 平台视图在 Flutter 3.44 上走引擎自带的 HCPP：原生视图创建时
  // opacity 为 0，只有出现在 layer tree 里的 PlatformViewLayer 才会被引擎逐帧
  // 摆放并显示。以前那种「什么都不画、手动发 resize/offset」的做法在 HCPP 下
  // 整块视频区是黑的（XComponent 0x0，mpv 拿不到 wid）。
  late List<String> log;
  late List<MethodCall> platformViewsCalls;
  late _FakeOhosVideoController player;

  setUp(() {
    log = [];
    platformViewsCalls = [];
    player = _FakeOhosVideoController(log);
  });

  Future<void> pumpVideo(WidgetTester tester) async {
    final messenger = tester.binding.defaultBinaryMessenger
      ..setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
        platformViewsCalls.add(call);
        log.add('platform_views.${call.method}');
        return null;
      })
      ..setMockMethodCallHandler(SystemChannels.platform_views_2, (call) async {
        log.add('platform_views_2.${call.method}');
        return null;
      });
    addTearDown(() {
      messenger
        ..setMockMethodCallHandler(SystemChannels.platform_views, null)
        ..setMockMethodCallHandler(SystemChannels.platform_views_2, null);
    });

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 320,
            height: 180,
            child: OhosPlatformVideo(controller: player),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('composes the video through a platform view layer', (
    tester,
  ) async {
    await pumpVideo(tester);

    final create = platformViewsCalls.firstWhere((c) => c.method == 'create');
    final args = create.arguments as Map<Object?, Object?>;
    expect(args['viewType'], kOhosVideoViewType);
    expect(args['hybrid'], isTrue);

    final viewId = args['id']! as int;
    final layers = tester.layers.whereType<PlatformViewLayer>().toList();
    expect(layers, hasLength(1));
    expect(layers.single.viewId, viewId);
    expect(log, contains('attach:$viewId'));
  });

  testWidgets('leaves placement to the engine', (tester) async {
    await pumpVideo(tester);

    // HCPP 按每帧的 PlatformViewLayer 摆放视图；旧通道上的 resize / offset
    // 会落到纹理控制器，对 HCPP 视图无效（resize 甚至会抛异常）。
    expect(platformViewsCalls.map((c) => c.method), ['create']);
  });

  testWidgets('detaches the player before disposing the view', (tester) async {
    await pumpVideo(tester);
    log.clear();

    await tester.pumpWidget(const SizedBox());

    expect(log, ['detach', 'platform_views_2.dispose']);
  });

  testWidgets('keeps the view alive until the player has let go of it', (
    tester,
  ) async {
    await pumpVideo(tester);
    final detached = Completer<void>();
    player.onDetach = () => detached.future;
    log.clear();

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    // vo 还没置空时销毁视图，mpv 会往已释放的 NativeWindow 里写帧。
    expect(log, ['detach']);

    detached.complete();
    await tester.pump();
    expect(log, ['detach', 'platform_views_2.dispose']);
  });

  testWidgets('undoes an attach that lands after the widget is gone', (
    tester,
  ) async {
    final surface = Completer<void>();
    player.onAttach = () => surface.future;
    await pumpVideo(tester);
    final viewId = platformViewsCalls.single.arguments['id'] as int;

    // 还没拿到 surface 就退出全屏：dispose 时 player 还没 attach，detach 是空操作。
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    log.clear();

    surface.complete();
    await tester.pump();
    expect(log, ['attach:$viewId', 'detach']);
  });

  testWidgets('reports a failed attach instead of throwing', (tester) async {
    player.onAttach = () async =>
        throw PlatformException(code: 'surface', message: 'view is gone');
    final printed = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    try {
      await pumpVideo(tester);
    } finally {
      // 框架在 addTearDown 之前就校验 debugPrint 已复原，必须在测试体内还原。
      debugPrint = previousDebugPrint;
    }

    expect(printed.join('\n'), contains('view is gone'));
  });

  testWidgets('never claims pointer events', (tester) async {
    await pumpVideo(tester);

    // 播放器的手势层在 Flutter 里，视频区域的点按 / 拖动必须留给它。
    final result = HitTestResult();
    tester.binding.hitTestInView(
      result,
      tester.getCenter(find.byType(OhosPlatformVideo)),
      tester.view.viewId,
    );
    expect(
      result.path.map((e) => e.target),
      isNot(contains(isA<PlatformViewRenderBox>())),
    );
  });
}
