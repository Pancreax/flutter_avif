import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:flutter_avif_platform_interface/flutter_avif_platform_interface.dart';
import 'package:flutter_avif_platform_interface/models/avif_info.pb.dart';
import 'package:flutter_avif_platform_interface/models/frame.pb.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAvifApi implements FlutterAvif {
  final initialized = <String>[];
  final disposed = <String>[];

  @override
  Future<AvifInfo> initMemoryDecoder({
    required String key,
    required Uint8List avifBytes,
  }) async {
    initialized.add(key);
    return AvifInfo(imageCount: 3, duration: 0.3);
  }

  @override
  Future<bool> disposeDecoder({required String key}) async {
    disposed.add(key);
    return true;
  }

  /// One transparent pixel lasting 1/30 s.
  @override
  Future<Frame> getNextFrame({required String key}) async =>
      Frame(data: [0, 0, 0, 0], width: 1, height: 1, duration: 1 / 30);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Plays [frames] in order, wrapping around after the last one like the
/// native decoder does.
class _FakeCodec implements AvifCodec {
  _FakeCodec(
    this.frames, {
    required this.durationMs,
    this.frameDuration = const Duration(milliseconds: 100),
  });

  final List<ui.Image> frames;
  final Duration frameDuration;
  int framesDecoded = 0;
  bool isDisposed = false;

  /// Holds each decode until completed, when set.
  Completer<void>? gate;

  @override
  final int durationMs;

  @override
  int get frameCount => frames.length;

  @override
  Future<void> ready() async {}

  @override
  Future<AvifFrameInfo> getNextFrame() async {
    final image = frames[framesDecoded++ % frames.length];
    await gate?.future;
    return AvifFrameInfo(duration: frameDuration, image: image.clone());
  }

  @override
  void dispose() => isDisposed = true;
}

class _FakeAvifProvider extends ImageProvider<_FakeAvifProvider> {
  _FakeAvifProvider(this.codec);

  final _FakeCodec codec;
  int loads = 0;

  @override
  Future<_FakeAvifProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _FakeAvifProvider key,
    ImageDecoderCallback decode,
  ) {
    loads++;
    return AvifImageStreamCompleter(
      key: key,
      codec: Future.value(codec),
      scale: 1,
    );
  }
}

/// Fails its first load and leaves the image cache, like the file and network
/// providers do, so a later resolve can try again.
class _FailsOnceProvider extends ImageProvider<_FailsOnceProvider> {
  _FailsOnceProvider(this.codec);

  final _FakeCodec codec;
  int loads = 0;

  @override
  Future<_FailsOnceProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _FailsOnceProvider key,
    ImageDecoderCallback decode,
  ) {
    loads++;
    return AvifImageStreamCompleter(codec: _load(key, loads), scale: 1);
  }

  Future<AvifCodec> _load(_FailsOnceProvider key, int load) async {
    await Future<void>.value();
    if (load == 1) {
      PaintingBinding.instance.imageCache.evict(key);
      throw StateError('Not there yet.');
    }
    return codec;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final api = _FakeAvifApi();
  // Frame i is 1 pixel wide and i + 1 tall, so a test can tell which one shows.
  late final List<ui.Image> frames;

  setUpAll(() async {
    FlutterAvifPlatform.api = api;
    frames = [
      for (var i = 0; i < 3; i++)
        await createTestImage(width: 1, height: i + 1, cache: false),
    ];
  });

  setUp(() {
    api.initialized.clear();
    api.disposed.clear();
  });

  tearDownAll(() {
    for (final frame in frames) {
      frame.dispose();
    }
  });

  Future<void> playThrough(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  AvifImageStreamCompleter completerOf(FutureOr<AvifCodec> codec,
      {bool playOnce = false}) {
    return AvifImageStreamCompleter(
      codec: Future.value(codec),
      scale: 1,
      playOnce: playOnce,
    );
  }

  test('gives each codec of an image its own native decoder', () async {
    final first = MultiFrameAvifCodec(key: 7, avifBytes: Uint8List(0));
    final second = MultiFrameAvifCodec(key: 7, avifBytes: Uint8List(0));
    await first.ready();
    await second.ready();

    first.dispose();

    expect(api.initialized.toSet(), hasLength(2));
    expect(api.disposed, [api.initialized.first]);
  });

  test('keeps frame durations below the millisecond', () async {
    final codec = MultiFrameAvifCodec(key: 8, avifBytes: Uint8List(0));
    await codec.ready();

    final frame = await codec.getNextFrame();

    expect(frame.duration, const Duration(microseconds: 33333));
    frame.image.dispose();
    codec.dispose();
  });

  group('AvifImageStreamCompleter', () {
    late _FakeCodec codec;
    late List<int> shownHeights;
    late ImageStreamListener listener;

    setUp(() {
      codec = _FakeCodec(frames, durationMs: 300);
      shownHeights = [];
      listener = ImageStreamListener((info, _) {
        shownHeights.add(info.image.height);
        info.dispose();
      });
    });

    testWidgets(
        'stays on the last frame when listened to again after playing once',
        (tester) async {
      final completer = completerOf(codec);
      completer.addListener(listener);
      await playThrough(tester);
      final handle = completer.keepAlive();
      completer.removeListener(listener);
      shownHeights.clear();

      completer.addListener(listener);
      await playThrough(tester);

      expect(shownHeights, [3]);
      expect(codec.framesDecoded, 3);
      completer.removeListener(listener);
      handle.dispose();
    });

    testWidgets('shows each frame once when listened to again mid-animation',
        (tester) async {
      final completer = completerOf(codec);
      completer.addListener(listener);
      for (var i = 0; i < 5 && shownHeights.isEmpty; i++) {
        await tester.pump();
      }
      final handle = completer.keepAlive();
      completer.removeListener(listener);

      completer.addListener(listener);
      shownHeights.clear();
      await playThrough(tester);

      expect(shownHeights, [2, 3]);
      expect(codec.framesDecoded, 3);
      completer.removeListener(listener);
      handle.dispose();
    });

    testWidgets(
        'stops on the last frame when the frames round down to less than the duration',
        (tester) async {
      // Three frames of 1/30 s: 99 ms in whole milliseconds, 100 ms in the file.
      final roundingCodec = _FakeCodec(frames,
          durationMs: 100, frameDuration: const Duration(microseconds: 33333));
      final completer = completerOf(roundingCodec);

      completer.addListener(listener);
      await playThrough(tester);

      expect(shownHeights, [1, 2, 3]);
      expect(roundingCodec.framesDecoded, 3);
      completer.removeListener(listener);
    });

    testWidgets(
        'stops after one pass when it plays once, even if the duration runs past the frames',
        (tester) async {
      final longCodec = _FakeCodec(frames, durationMs: 500);
      final completer = completerOf(longCodec, playOnce: true);

      completer.addListener(listener);
      await playThrough(tester);

      expect(shownHeights, [1, 2, 3]);
      expect(longCodec.framesDecoded, 3);
      completer.removeListener(listener);
    });

    testWidgets('lets its last listener leave on the frame it shows',
        (tester) async {
      final completer = completerOf(codec);
      late final ImageStreamListener leavesOnFirstFrame;
      leavesOnFirstFrame = ImageStreamListener((info, _) {
        info.dispose();
        completer.removeListener(leavesOnFirstFrame);
      });

      completer.addListener(leavesOnFirstFrame);
      await playThrough(tester);

      expect(tester.takeException(), isNull);
      expect(codec.framesDecoded, 1);
      expect(codec.isDisposed, true);
    });

    testWidgets('does not decode for a listener added after it was disposed',
        (tester) async {
      final completer = completerOf(codec);
      completer.addListener(listener);
      await tester.pump();
      completer.removeListener(listener);
      final framesBeforeDisposal = codec.framesDecoded;

      expect(() => completer.addListener(listener), throwsStateError);
      expect(codec.isDisposed, true);
      expect(codec.framesDecoded, framesBeforeDisposal);
    });

    testWidgets('frees its codec only once a decode in flight returns',
        (tester) async {
      final gate = Completer<void>();
      codec.gate = gate;
      final completer = completerOf(codec);
      completer.addListener(listener);
      await tester.pump();
      completer.removeListener(listener);
      final disposedWhileDecoding = codec.isDisposed;

      gate.complete();
      await tester.pump();

      expect(disposedWhileDecoding, false);
      expect(codec.isDisposed, true);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps its codec while a handle keeps it alive',
        (tester) async {
      final completer = completerOf(codec);
      completer.addListener(listener);
      await tester.pump();
      final widgetHandle = completer.keepAlive();
      final cacheHandle = completer.keepAlive();

      completer.removeListener(listener);
      cacheHandle.dispose();
      final disposedWhileKept = codec.isDisposed;
      widgetHandle.dispose();

      expect(disposedWhileKept, false);
      expect(codec.isDisposed, true);
    });

    testWidgets('frees a codec that arrives after it was disposed',
        (tester) async {
      final pendingCodec = Completer<AvifCodec>();
      final completer = completerOf(pendingCodec.future);
      completer.addListener(listener);
      completer.removeListener(listener);

      pendingCodec.complete(codec);
      await tester.pump();

      expect(codec.isDisposed, true);
    });
  });

  testWidgets(
      'AvifImage keeps its stream when its ticker mode turns off and on',
      (tester) async {
    final imageCache = PaintingBinding.instance.imageCache;
    final maximumSize = imageCache.maximumSize;
    addTearDown(() {
      imageCache.clear();
      imageCache.clearLiveImages();
      imageCache.maximumSize = maximumSize;
    });
    imageCache.maximumSize = 0;
    final provider = _FakeAvifProvider(_FakeCodec(frames, durationMs: 300));
    final tickerEnabled = ValueNotifier(true);
    addTearDown(tickerEnabled.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: tickerEnabled,
        builder: (_, enabled, __) => TickerMode(
          enabled: enabled,
          child: AvifImage(image: provider),
        ),
      ),
    );
    await playThrough(tester);

    tickerEnabled.value = false;
    await tester.pump();
    tickerEnabled.value = true;
    await playThrough(tester);

    expect(provider.loads, 1);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.height, 3);
  });

  testWidgets(
      'AvifImage shows an image mounted with its ticker off once the ticker turns on',
      (tester) async {
    final imageCache = PaintingBinding.instance.imageCache;
    final maximumSize = imageCache.maximumSize;
    addTearDown(() {
      imageCache.clear();
      imageCache.clearLiveImages();
      imageCache.maximumSize = maximumSize;
    });
    imageCache.maximumSize = 0;
    final provider = _FakeAvifProvider(_FakeCodec(frames, durationMs: 300));
    final tickerEnabled = ValueNotifier(false);
    addTearDown(tickerEnabled.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: tickerEnabled,
        builder: (_, enabled, __) => TickerMode(
          enabled: enabled,
          child: AvifImage(image: provider),
        ),
      ),
    );
    await playThrough(tester);
    final pausedHeight =
        tester.widget<RawImage>(find.byType(RawImage)).image?.height;

    tickerEnabled.value = true;
    await playThrough(tester);

    expect(tester.takeException(), isNull);
    expect(pausedHeight, 1);
    expect(provider.loads, 1);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.height, 3);
  });

  testWidgets(
      'AvifImage shows a new image set while its ticker is off once the ticker turns on',
      (tester) async {
    final imageCache = PaintingBinding.instance.imageCache;
    final maximumSize = imageCache.maximumSize;
    addTearDown(() {
      imageCache.clear();
      imageCache.clearLiveImages();
      imageCache.maximumSize = maximumSize;
    });
    imageCache.maximumSize = 0;
    final first = _FakeAvifProvider(_FakeCodec(frames, durationMs: 300));
    final second = _FakeAvifProvider(_FakeCodec(frames, durationMs: 300));
    final tickerEnabled = ValueNotifier(true);
    final image = ValueNotifier(first);
    addTearDown(tickerEnabled.dispose);
    addTearDown(image.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: tickerEnabled,
        builder: (_, enabled, __) => ValueListenableBuilder<_FakeAvifProvider>(
          valueListenable: image,
          builder: (_, provider, __) => TickerMode(
            enabled: enabled,
            child: AvifImage(image: provider),
          ),
        ),
      ),
    );
    await playThrough(tester);
    tickerEnabled.value = false;
    await tester.pump();

    image.value = second;
    await playThrough(tester);
    final pausedHeight =
        tester.widget<RawImage>(find.byType(RawImage)).image?.height;
    tickerEnabled.value = true;
    await playThrough(tester);

    expect(tester.takeException(), isNull);
    expect(pausedHeight, 1);
    expect(first.codec.isDisposed, true);
    expect(second.loads, 1);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.height, 3);
  });

  testWidgets(
      'AvifImage resolves a failed image again on the next dependency change',
      (tester) async {
    final provider = _FailsOnceProvider(_FakeCodec(frames, durationMs: 300));
    final textScale = ValueNotifier(1.0);
    addTearDown(textScale.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<double>(
        valueListenable: textScale,
        builder: (_, scale, __) => MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: AvifImage(
            image: provider,
            errorBuilder: (_, __, ___) => const Text('failed',
                textDirection: TextDirection.ltr),
          ),
        ),
      ),
    );
    await playThrough(tester);
    expect(find.text('failed'), findsOneWidget);

    textScale.value = 2;
    await playThrough(tester);

    expect(provider.loads, 2);
    expect(find.text('failed'), findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.height, 3);
  });
}
