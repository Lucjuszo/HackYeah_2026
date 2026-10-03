// Checks only that data from the backend shows up (not how it looks).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miejscowki_map/api/models.dart';
import 'package:miejscowki_map/main.dart';
import 'package:miejscowki_map/services/location_service.dart';
import 'package:miejscowki_map/ui/place_details_page.dart';

import 'fake_backend.dart';

/// testWidgets that ignores layout overflow warnings: the test font is much wider than real fonts
/// and the layout is not what these tests check.
void displayTest(String description, Future<void> Function(WidgetTester tester) body) {
  testWidgets(description, (WidgetTester tester) async {
    final original = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      original?.call(details);
    };
    try {
      await body(tester);
    } finally {
      FlutterError.onError = original;
    }
  });
}

Future<FakeBackend> pumpApp(
  WidgetTester tester, {
  FakeBackend? backend,
  LocationService? location,
}) async {
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  backend ??= FakeBackend();
  await tester.pumpWidget(
    MiejscowkiApp(
      api: backend.api(),
      locationService: location ?? FakeLocationService(result: const LatLon(50.06, 19.94)),
      showMapTiles: false,
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

Future<void> expandSheet(WidgetTester tester) async {
  await tester.drag(find.byKey(const ValueKey<String>('spot-sheet-handle')), const Offset(0, -600));
  await tester.pumpAndSettle();
}

Future<void> openLocationPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('location-picker-trigger')));
  await tester.pumpAndSettle();
}

/// The vertical scroll of the details page (it also has a photo PageView and a photo strip).
final Finder detailsScroll = find
    .descendant(
      of: find.byType(PlaceDetailsPage),
      matching: find.byWidgetPredicate((Widget w) => w is Scrollable && w.axisDirection == AxisDirection.down),
    )
    .first;

Finder text(String value) => find.textContaining(value, findRichText: true);

void main() {
  group('lista i mapa', () {
    displayTest('miejsca z backendu są na liście i na mapie', (tester) async {
      final backend = await pumpApp(tester);
      expect(backend.searches, isNotEmpty);

      expect(find.text('2 miejsca na mapie'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('marker-p1')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('marker-p2')), findsOneWidget);

      await expandSheet(tester);
      expect(find.text('Kawiarnia Pod Kodem'), findsOneWidget);
      expect(find.text('Czytelnia'), findsOneWidget);
      expect(find.text('4,6'), findsWidgets);
      expect(text('Floriańska 15, Kraków'), findsWidgets);
      expect(text('Otwarte teraz'), findsWidgets);
      expect(text('Zamknięte'), findsWidgets);
    });

    displayTest('pusta lista', (tester) async {
      await pumpApp(tester, backend: FakeBackend(places: []));
      await expandSheet(tester);
      expect(find.text('Brak miejscówek w tym obszarze'), findsOneWidget);
    });

    displayTest('błąd serwera i ponowna próba', (tester) async {
      final backend = FakeBackend()..failPlaces = true;
      await pumpApp(tester, backend: backend);
      await expandSheet(tester);
      expect(find.text('Nie udało się wczytać miejsc'), findsOneWidget);

      backend.failPlaces = false;
      await tester.tap(find.text('Spróbuj ponownie'));
      await tester.pumpAndSettle();
      expect(find.text('Kawiarnia Pod Kodem'), findsOneWidget);
    });

    displayTest('pinezka pokazuje podgląd miejsca', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const ValueKey<String>('marker-p1')));
      await tester.pumpAndSettle();
      final preview = find.byKey(const ValueKey<String>('place-preview'));
      expect(preview, findsOneWidget);
      expect(find.descendant(of: preview, matching: find.text('Kawiarnia Pod Kodem')), findsOneWidget);
    });
  });

  group('filtry', () {
    displayTest('kafelki filtrów są widoczne', (tester) async {
      await pumpApp(tester);
      for (final label in ['Oceny', 'Wi-Fi', 'Sortuj', 'Ceny', 'Filtruj']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    displayTest('Filtruj pokazuje dodatkowe filtry', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Filtruj'));
      await tester.pumpAndSettle();
      expect(find.text('Otwarte teraz'), findsWidgets);
      expect(find.text('Gniazdka'), findsWidgets);
      expect(find.text('Spokojnie'), findsOneWidget);
    });

    displayTest('menu filtra pokazuje opcje', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Ceny'));
      await tester.pumpAndSettle();
      expect(find.text('Bezpłatne'), findsOneWidget);
      expect(find.text('Do 30 zł'), findsOneWidget);
      expect(find.text('Powyżej 30 zł'), findsOneWidget);
    });
  });

  group('lokalizacja', () {
    displayTest('wyszukiwarka adresów pokazuje wyniki z backendu', (tester) async {
      final backend = await pumpApp(tester);
      await openLocationPicker(tester);
      expect(find.text('Wybierz lokalizację'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey<String>('location-search')), 'Gdańsk');
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(backend.requests.any((u) => u.path == '/geocode'), isTrue);
      expect(find.text('Gdańsk, województwo pomorskie, Polska'), findsOneWidget);

      await tester.tap(find.text('Gdańsk, województwo pomorskie, Polska'));
      await tester.pumpAndSettle();
      expect(find.text('Gdańsk'), findsOneWidget);
    });

    displayTest('Moja lokalizacja', (tester) async {
      await pumpApp(tester);
      await openLocationPicker(tester);
      await tester.tap(find.byKey(const ValueKey<String>('use-my-location')));
      await tester.pumpAndSettle();
      expect(find.text('Moja lokalizacja'), findsOneWidget);
    });

    displayTest('brak zgody na GPS pokazuje komunikat', (tester) async {
      await pumpApp(
        tester,
        location: FakeLocationService(failure: const LocationFailure('Brak zgody na lokalizację.')),
      );
      await openLocationPicker(tester);
      await tester.tap(find.byKey(const ValueKey<String>('use-my-location')));
      await tester.pumpAndSettle();
      expect(find.text('Brak zgody na lokalizację.'), findsOneWidget);
    });
  });

  group('szczegóły miejsca', () {
    Future<FakeBackend> openDetails(WidgetTester tester, {FakeBackend? backend}) async {
      backend = await pumpApp(tester, backend: backend);
      await expandSheet(tester);
      await tester.tap(find.text('Kawiarnia Pod Kodem'));
      await tester.pumpAndSettle();
      return backend;
    }

    displayTest('pokazuje dane miejsca z backendu', (tester) async {
      final backend = await openDetails(tester);
      expect(backend.requests.any((u) => u.path == '/places/p1'), isTrue);

      expect(find.text('Kawiarnia Pod Kodem'), findsOneWidget);
      expect(find.text('Udogodnienia'), findsOneWidget);
      expect(find.text('Godziny otwarcia'), findsOneWidget);
      expect(find.text('8:00–20:00'), findsWidgets);
      expect(find.text('Zdjęcia (2)'), findsOneWidget);
      expect(find.text('Pokoje wygłuszane'), findsOneWidget);

      await tester.ensureVisible(find.text('Flat white'));
      await tester.pumpAndSettle();
      expect(find.text('14,00 zł'), findsOneWidget);
    });

    displayTest('pokazuje opinie i doczytuje kolejne', (tester) async {
      final backend = await openDetails(tester, backend: FakeBackend(comments: 13));
      expect(backend.requests.any((u) => u.path == '/places/p1/comments'), isTrue);

      await tester.ensureVisible(find.text('Opinia numer 0'));
      await tester.pumpAndSettle();
      expect(find.text('Opinie (13)'), findsOneWidget);

      final more = find.byKey(const ValueKey<String>('more-comments'));
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(backend.requests.last.queryParameters['skip'], '10');
      expect(find.text('Opinia numer 12', skipOffstage: false), findsOneWidget);
    });

    displayTest('zdjęcie otwiera się na pełnym ekranie', (tester) async {
      await openDetails(tester);
      await tester.tap(find.byType(PageView).first);
      await tester.pumpAndSettle();
      expect(find.text('1 z 2'), findsOneWidget);
    });
  });
}
