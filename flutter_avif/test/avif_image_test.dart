import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:flutter_avif_platform_interface/flutter_avif_platform_interface.dart';
import 'package:flutter_avif_platform_interface/models/avif_info.pb.dart';
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

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Plays [frames] in order, wrapping around after the last one like the
/// native decoder does.
class _FakeCodec implements AvifCodec {
  _FakeCodec(this.frames, {required this.durationMs});

  final List<ui.Image> frames;
  int framesDecoded = 0;
  bool isDisposed = false;

  @override
  final int durationMs;

  @override
  int get frameCount => frames.length;

  @override
  Future<void> ready() async {}

  @override
  Future<AvifFrameInfo> getNextFrame() async {
    final image = frames[framesDecoded++ % frames.length];
    return AvifFrameInfo(
      duration: const Duration(milliseconds: 100),
      image: image.clone(),
    );
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

  AvifImageStreamCompleter completerOf(FutureOr<AvifCodec> codec) {
    return AvifImageStreamCompleter(
      key: MemoryAvifImage(Uint8List(0)),
      codec: Future.value(codec),
      scale: 1,
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
}
