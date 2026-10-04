// The map's tiles must show up right after start, without moving the map first.
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miejscowki_map/api/models.dart';
import 'package:miejscowki_map/auth/auth.dart';
import 'package:miejscowki_map/main.dart';

import 'fake_backend.dart';

/// 1x1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// An already decoded image, handed out synchronously: decoding doesn't run in the widget tests' fake time.
class _ReadyImage extends ImageProvider<_ReadyImage> {
  const _ReadyImage(this.image, this.coordinates);

  final ui.Image image;
  final TileCoordinates coordinates;

  @override
  Future<_ReadyImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture<_ReadyImage>(this);

  @override
  ImageStreamCompleter loadImage(_ReadyImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(SynchronousFuture<ImageInfo>(ImageInfo(image: image.clone())));

  @override
  bool operator ==(Object other) => other is _ReadyImage && other.coordinates == coordinates;

  @override
  int get hashCode => coordinates.hashCode;
}

/// Tiles from memory instead of tile.openstreetmap.org.
class FakeTileProvider extends TileProvider {
  FakeTileProvider(this.image);

  final ui.Image image;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) => _ReadyImage(image, coordinates);
}

Future<ui.Image> _decodePng(WidgetTester tester) async {
  final image = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(_png);
    return (await codec.getNextFrame()).image;
  });
  return image!;
}

Future<void> startApp(WidgetTester tester, {required Size firstSize, bool locateOnStart = false}) async {
  // The test font is much wider than real fonts: ignore overflow warnings (layout isn't checked here).
  final original = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (!details.exceptionAsString().contains('overflowed')) original?.call(details);
  };
  addTearDown(() => FlutterError.onError = original);
  tester.view.physicalSize = firstSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = FakeBackend();
  final tileProvider = FakeTileProvider(await _decodePng(tester));
  await tester.pumpWidget(
    MiejscowkiApp(
      api: backend.api(),
      auth: AuthController(api: backend.api(), store: MemoryTokenStore(), launcher: FakeOAuthLauncher()),
      locationService: FakeLocationService(result: const LatLon(50.06, 19.94)),
      tileProvider: tileProvider,
      locateOnStart: locateOnStart,
    ),
  );
}

/// The tiles the map draws now (flutter_map creates them ahead and loads them only on a map event).
/// (`Tile` isn't exported by flutter_map, hence the lookup by name.)
List<TileImage> drawnTiles(WidgetTester tester) => [
  for (final tile in tester.widgetList(find.byWidgetPredicate((w) => w.runtimeType.toString() == 'Tile')))
    (tile as dynamic).tileImage as TileImage,
];

/// Poland fits at zoom ~7, flutter_map's default camera (Kyiv) is zoom 13, the device position 14.
void expectTilesShown(WidgetTester tester, {required int zoom}) {
  final tiles = drawnTiles(tester);
  expect(tiles, isNotEmpty);
  expect(tiles.map((t) => t.coordinates.z).toSet(), {zoom});
  final blank = [for (final t in tiles) if (t.imageInfo == null) t.coordinates];
  expect(blank, isEmpty, reason: 'tiles never loaded: $blank');
}

void main() {
  Future<void> settle(WidgetTester tester) async {
    // No gesture, no tap: only time passes.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  testWidgets('kafelki mapy są widoczne od razu po starcie, bez przesuwania', (tester) async {
    await startApp(tester, firstSize: const Size(900, 1000));
    await settle(tester);
    expectTilesShown(tester, zoom: 7);
  });

  testWidgets('kafelki są widoczne, gdy ekran ma rozmiar dopiero po starcie', (tester) async {
    // Phones and browsers often report a zero-sized screen for the first frame(s).
    await startApp(tester, firstSize: Size.zero);
    await tester.pump();
    tester.view.physicalSize = const Size(900, 1000);
    await settle(tester);
    expectTilesShown(tester, zoom: 7);
  });

  testWidgets('start z lokalizacji urządzenia: kafelki okolicy są widoczne bez przesuwania', (tester) async {
    await startApp(tester, firstSize: Size.zero, locateOnStart: true);
    await tester.pump();
    tester.view.physicalSize = const Size(900, 1000);
    await settle(tester);
    expectTilesShown(tester, zoom: 14);
  });
}
