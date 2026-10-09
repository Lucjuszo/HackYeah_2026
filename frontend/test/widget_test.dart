// Checks only that data from the backend shows up (not how it looks).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:miejscowki_map/api/models.dart';
import 'package:miejscowki_map/auth/auth.dart';
import 'package:miejscowki_map/main.dart';
import 'package:miejscowki_map/services/location_service.dart';
import 'package:miejscowki_map/ui/add_place_page.dart';
import 'package:miejscowki_map/ui/place_details_page.dart';
import 'package:miejscowki_map/ui/search_page.dart';

import 'fake_backend.dart';

/// testWidgets that ignores layout overflow warnings: the test font is much wider than real fonts
/// and the layout is not what these tests check.
void displayTest(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
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

/// Login state for tests: an in-memory token store and a fake GitHub/Google login.
class TestAuth {
  TestAuth({LoginException? failure, bool loggedIn = false})
    : launcher = FakeOAuthLauncher(failure: failure),
      store = MemoryTokenStore()
        ..token = loggedIn
            ? StoredToken(
                FakeOAuthLauncher.token,
                DateTime.now().add(const Duration(hours: 5)),
              )
            : null;

  final FakeOAuthLauncher launcher;
  final MemoryTokenStore store;

  AuthController controller(FakeBackend backend) =>
      AuthController(api: backend.api(), store: store, launcher: launcher);
}

/// Installs a fake gallery for the current test.
FakeImagePicker fakePicker([List<String> names = const <String>[]]) {
  final picker = FakeImagePicker()
    ..files = [for (final name in names) FakeImagePicker.photo(name)];
  final original = ImagePickerPlatform.instance;
  ImagePickerPlatform.instance = picker;
  addTearDown(() => ImagePickerPlatform.instance = original);
  return picker;
}

Future<FakeBackend> pumpApp(
  WidgetTester tester, {
  FakeBackend? backend,
  LocationService? location,
  TestAuth? auth,
  bool locateOnStart = false,
}) async {
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  backend ??= FakeBackend();
  await tester.pumpWidget(
    MiejscowkiApp(
      api: backend.api(),
      auth: (auth ?? TestAuth()).controller(backend),
      locationService:
          location ?? FakeLocationService(result: const LatLon(50.06, 19.94)),
      showMapTiles: false,
      locateOnStart: locateOnStart,
    ),
  );
  await tester.pumpAndSettle();
  return backend;
}

Future<void> expandSheet(WidgetTester tester) async {
  await tester.drag(
    find.byKey(const ValueKey<String>('spot-sheet-handle')),
    const Offset(0, -600),
  );
  await tester.pumpAndSettle();
}

Future<void> openLocationPicker(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('location-picker-trigger')),
  );
  await tester.pumpAndSettle();
}

/// The vertical scroll of the details page (it also has a photo PageView and a photo strip).
final Finder detailsScroll = find
    .descendant(
      of: find.byType(PlaceDetailsPage),
      matching: find.byWidgetPredicate(
        (Widget w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      ),
    )
    .first;

Finder text(String value) => find.textContaining(value, findRichText: true);

void main() {
  group('lista i mapa', () {
    displayTest('miejsca z backendu są na liście i na mapie', (tester) async {
      final backend = await pumpApp(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(backend.searches, hasLength(1)); // one search at start, not one per startup event

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

    displayTest('mapa wczytuje miejsca od razu, choć rozmiar ekranu był znany dopiero po starcie', (tester) async {
      // Phones and browsers often report a zero-sized screen for the first frame(s).
      tester.view.physicalSize = Size.zero;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = FakeBackend();
      await tester.pumpWidget(
        MiejscowkiApp(
          api: backend.api(),
          auth: TestAuth().controller(backend),
          locationService: FakeLocationService(result: const LatLon(50.06, 19.94)),
          showMapTiles: false,
          locateOnStart: false,
        ),
      );
      await tester.pump();

      expect(backend.searches, isEmpty); // nothing to search yet

      tester.view.physicalSize = const Size(900, 1000);
      await tester.pump(); // the frame that learns the size
      await tester.pump(const Duration(seconds: 1)); // no gesture, no tap: just waiting
      await tester.pumpAndSettle();

      expect(backend.searches, hasLength(1));
      expect(find.text('2 miejsca na mapie'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('marker-p1')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('marker-p2')), findsOneWidget);
      // The search covers the whole of Poland, not a degenerate zero-sized area.
      final bbox = backend.lastSearch.queryParameters['bbox']!.split(',').map(double.parse).toList();
      expect(bbox[2] - bbox[0], greaterThan(5));
      expect(bbox[3] - bbox[1], greaterThan(5));
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
      expect(
        find.descendant(
          of: preview,
          matching: find.text('Kawiarnia Pod Kodem'),
        ),
        findsOneWidget,
      );
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

    displayTest('wyszukiwanie otwiera osobny ekran i wraca z frazą', (tester) async {
      final backend = await pumpApp(tester);
      await tester.tap(find.byKey(const ValueKey<String>('place-search')));
      await tester.pumpAndSettle();
      expect(find.byType(SearchPage), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey<String>('search-input')), 'kawa');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.byType(SearchPage), findsNothing);
      expect(backend.requests.last.queryParameters['q'], 'kawa');

      // The phrase is remembered as a recent search.
      await tester.tap(find.byKey(const ValueKey<String>('place-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('recent-kawa')), findsOneWidget);
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
    displayTest('wyszukiwarka adresów pokazuje wyniki z backendu', (
      tester,
    ) async {
      final backend = await pumpApp(tester);
      await openLocationPicker(tester);
      expect(find.text('Wybierz lokalizację'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey<String>('location-search')),
        'Gdańsk',
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(backend.requests.any((u) => u.path == '/geocode'), isTrue);
      expect(
        find.text('Gdańsk, województwo pomorskie, Polska'),
        findsOneWidget,
      );

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

    displayTest('na starcie mapa pokazuje okolicę urządzenia', (tester) async {
      await pumpApp(tester, locateOnStart: true);
      expect(find.text('Moja lokalizacja'), findsOneWidget);
      // Zoomed to Kraków: the place in Warsaw is off screen.
      expect(find.text('1 miejsce na mapie'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('marker-p1')), findsOneWidget);
    });

    displayTest('bez zgody na GPS na starcie widać całą Polskę', (tester) async {
      await pumpApp(
        tester,
        locateOnStart: true,
        location: FakeLocationService(failure: const LocationFailure('Brak zgody na lokalizację.')),
      );
      expect(find.text('Lokalizacja'), findsOneWidget);
      expect(find.text('2 miejsca na mapie'), findsOneWidget);
    });

    displayTest('promień szuka wokół mojej lokalizacji', (tester) async {
      final backend = await pumpApp(tester);
      await tester.tap(find.byKey(const ValueKey<String>('radius-picker-trigger')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5 km'));
      await tester.pumpAndSettle();

      final query = backend.requests.lastWhere((u) => u.path == '/places/summary').queryParameters;
      expect(query['radius_m'], '5000');
      expect(query['lat'], '50.06000');
      expect(query['lon'], '19.94000');
      expect(find.text('Moja lokalizacja'), findsOneWidget);
      expect(find.text('1 miejsce w promieniu 5 km'), findsOneWidget);
    });

    displayTest('brak zgody na GPS pokazuje komunikat', (tester) async {
      await pumpApp(
        tester,
        location: FakeLocationService(
          failure: const LocationFailure('Brak zgody na lokalizację.'),
        ),
      );
      await openLocationPicker(tester);
      await tester.tap(find.byKey(const ValueKey<String>('use-my-location')));
      await tester.pumpAndSettle();
      expect(find.text('Brak zgody na lokalizację.'), findsOneWidget);
    });
  });

  group('szczegóły miejsca', () {
    Future<FakeBackend> openDetails(
      WidgetTester tester, {
      FakeBackend? backend,
    }) async {
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

    displayTest('dodaje zdjęcia z galerii', (tester) async {
      fakePicker(['a.jpg', 'b.jpg']);
      final backend = FakeBackend();
      await pumpApp(tester, backend: backend, auth: TestAuth(loggedIn: true));
      await expandSheet(tester);
      await tester.tap(find.text('Kawiarnia Pod Kodem'));
      await tester.pumpAndSettle();

      final add = find.byKey(const ValueKey<String>('add-photo'));
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();

      expect(backend.uploadedPhotos, [('p1', 'a.jpg'), ('p1', 'b.jpg')]);
      expect(find.text('Dodano 2 zdjęć.'), findsOneWidget);
    });

    displayTest('błąd wysyłki zdjęcia jest pokazany', (tester) async {
      fakePicker(['a.jpg']);
      final backend = FakeBackend()..photoUploadError = 415;
      await pumpApp(tester, backend: backend, auth: TestAuth(loggedIn: true));
      await expandSheet(tester);
      await tester.tap(find.text('Kawiarnia Pod Kodem'));
      await tester.pumpAndSettle();

      final add = find.byKey(const ValueKey<String>('add-photo'));
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();

      expect(find.text('Ten plik nie jest obsługiwanym zdjęciem.'), findsOneWidget);
    });

    displayTest('autor usuwa swoje zdjęcie, cudzego nie może', (tester) async {
      final backend = FakeBackend();
      await pumpApp(tester, backend: backend, auth: TestAuth(loggedIn: true));
      await expandSheet(tester);
      await tester.tap(find.text('Kawiarnia Pod Kodem'));
      await tester.pumpAndSettle();

      // Header photo 1 of 2 is the test user's own.
      await tester.tap(find.byType(PageView).first);
      await tester.pumpAndSettle();
      expect(find.text('1 z 2'), findsOneWidget);
      await tester.drag(find.byType(PageView).last, const Offset(-800, 0));
      await tester.pumpAndSettle();
      expect(find.text('2 z 2'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('delete-photo')), findsNothing);
      await tester.drag(find.byType(PageView).last, const Offset(800, 0));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('delete-photo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('confirm-delete-photo')));
      await tester.pumpAndSettle();

      expect(backend.deletedPhotos, [('p1', 'ph0')]);
      expect(find.text('1 z 2'), findsNothing); // viewer closed
      expect(find.text('Usunięto zdjęcie.'), findsOneWidget);
    });

    displayTest('pokazuje opinie i doczytuje kolejne', (tester) async {
      final backend = await openDetails(
        tester,
        backend: FakeBackend(comments: 13),
      );
      expect(
        backend.requests.any((u) => u.path == '/places/p1/comments'),
        isTrue,
      );

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

    displayTest('doczytanie po zmianie kolejności (łapki) nie dubluje opinii', (tester) async {
      final backend = await openDetails(tester, backend: FakeBackend(comments: 13));
      // Meanwhile someone's like took a comment off the first page ("Opinia numer 9" moves down).
      final list = backend.commentsOf('p1');
      list.insert(10, list.removeAt(9));

      final more = find.byKey(const ValueKey<String>('more-comments'));
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('Opinia numer 9', skipOffstage: false), findsOneWidget);
    });

    displayTest('zdjęcie otwiera się na pełnym ekranie', (tester) async {
      await openDetails(tester);
      await tester.tap(find.byType(PageView).first);
      await tester.pumpAndSettle();
      expect(find.text('1 z 2'), findsOneWidget);
    });
  });

  group('logowanie', () {
    Future<void> openLoginByRating(WidgetTester tester) async {
      await expandSheet(tester);
      await tester.tap(find.text('Kawiarnia Pod Kodem'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey<String>('rate-4')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('rate-4')));
      await tester.pumpAndSettle();
    }

    displayTest('użytkownik loguje się przez GitHub', (tester) async {
      final auth = TestAuth();
      await pumpApp(tester, auth: auth);
      await openLoginByRating(tester);

      expect(find.text('Połącz z GitHub'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('login-google')), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('login-github')));
      await tester.pumpAndSettle();
      expect(auth.launcher.logins.single.path, '/auth/github/login');
      expect(auth.store.token?.accessToken, FakeOAuthLauncher.token);
    });

    displayTest('anulowane logowanie zostaje na stronie z komunikatem', (
      tester,
    ) async {
      final backend = await pumpApp(
        tester,
        auth: TestAuth(failure: const LoginException('Logowanie anulowane.')),
      );
      await openLoginByRating(tester);
      await tester.tap(find.byKey(const ValueKey<String>('login-github')));
      await tester.pumpAndSettle();
      expect(find.text('Logowanie anulowane.'), findsOneWidget);
      expect(find.text('Połącz z GitHub'), findsOneWidget);
      expect(backend.myRatings, isEmpty);
    });

    displayTest('powrót ze strony logowania nic nie zapisuje', (tester) async {
      final backend = await pumpApp(tester);
      await openLoginByRating(tester);
      await tester.tap(find.byKey(const ValueKey<String>('login-back')));
      await tester.pumpAndSettle();
      expect(find.text('Połącz z GitHub'), findsNothing);
      expect(backend.myRatings, isEmpty);
    });
  });

  group('ocena i opinie', () {
    Future<void> openPlace(WidgetTester tester) async {
      await expandSheet(tester);
      await tester.tap(find.text('Kawiarnia Pod Kodem'));
      await tester.pumpAndSettle();
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(ValueKey<String>(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey<String>(key)));
      await tester.pumpAndSettle();
    }

    displayTest('gwiazdki zapisują ocenę i odświeżają średnią', (tester) async {
      final backend = await pumpApp(tester, auth: TestAuth(loggedIn: true));
      await openPlace(tester);
      expect(find.text('Twoja opinia'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('remove-rating')), findsNothing);

      await tapKey(tester, 'rate-5');
      expect(backend.myRatings['p1'], 5);
      expect(find.byKey(const ValueKey<String>('remove-rating')), findsOneWidget);
      expect(
        find.text('13 ocen'),
        findsOneWidget,
      ); // summary from the API response
      expect(find.text('5,0'), findsWidgets);

      await tapKey(tester, 'remove-rating');
      expect(backend.myRatings, isEmpty);
      expect(find.byKey(const ValueKey<String>('remove-rating')), findsNothing);
    });

    displayTest('wcześniejsza ocena jest widoczna po wejściu', (tester) async {
      final backend = FakeBackend()..myRatings['p1'] = 3;
      await pumpApp(tester, backend: backend, auth: TestAuth(loggedIn: true));
      await openPlace(tester);
      expect(
        find.byKey(const ValueKey<String>('remove-rating')),
        findsOneWidget,
      );
      final third = tester.widget<Icon>(
        find.descendant(of: find.byKey(const ValueKey<String>('rate-3')), matching: find.byType(Icon)),
      );
      expect(third.icon, Icons.star_rounded);
    });

    displayTest('dodanie opinii pokazuje ją na górze listy', (tester) async {
      final backend = await pumpApp(tester, auth: TestAuth(loggedIn: true));
      await openPlace(tester);
      await tapKey(tester, 'rate-5'); // an opinion needs stars
      await tester.enterText(
        find.byKey(const ValueKey<String>('comment-input')),
        'Świetna kawa i cisza',
      );
      await tapKey(tester, 'comment-send');

      expect(backend.commentsOf('p1').first['text'], 'Świetna kawa i cisza');
      expect(find.text('Świetna kawa i cisza'), findsOneWidget);
      expect(find.text('Opinie (4)'), findsOneWidget);
    });

    displayTest('opinia bez gwiazdek nic nie wysyła', (tester) async {
      final backend = await pumpApp(tester, auth: TestAuth(loggedIn: true));
      await openPlace(tester);
      await tester.ensureVisible(find.byKey(const ValueKey<String>('comment-input')));
      await tester.enterText(find.byKey(const ValueKey<String>('comment-input')), 'Bez oceny');
      await tapKey(tester, 'comment-send');
      expect(backend.commentsOf('p1'), hasLength(3));
      expect(find.text('Wybierz ocenę gwiazdkami, aby dodać komentarz.'), findsOneWidget);
    });

    displayTest('pusta opinia nic nie wysyła', (tester) async {
      final backend = await pumpApp(tester, auth: TestAuth(loggedIn: true));
      await openPlace(tester);
      await tapKey(tester, 'comment-send');
      expect(backend.commentsOf('p1'), hasLength(3));
    });

    displayTest('własną opinię można edytować i usunąć, cudzej nie', (
      tester,
    ) async {
      final backend = await pumpApp(tester, auth: TestAuth(loggedIn: true));
      await openPlace(tester);
      expect(
        find.byKey(const ValueKey<String>('comment-menu-c0')),
        findsNothing,
      ); // someone else's

      await tapKey(tester, 'rate-4');
      await tester.enterText(
        find.byKey(const ValueKey<String>('comment-input')),
        'Pierwsza wersja',
      );
      await tapKey(tester, 'comment-send');
      final id = backend.commentsOf('p1').first['id'] as String;

      await tapKey(tester, 'comment-menu-$id');
      await tester.tap(find.text('Edytuj'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('edit-comment-input')),
        'Poprawiona wersja',
      );
      await tester.tap(find.byKey(const ValueKey<String>('edit-comment-save')));
      await tester.pumpAndSettle();
      expect(find.text('Poprawiona wersja'), findsOneWidget);
      expect(backend.commentsOf('p1').first['text'], 'Poprawiona wersja');

      await tapKey(tester, 'comment-menu-$id');
      await tester.tap(find.text('Usuń').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('confirm-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Poprawiona wersja'), findsNothing);
      expect(backend.commentsOf('p1'), hasLength(3));
    });

    displayTest('łapka w górę dodaje i cofa polubienie', (tester) async {
      final backend = await pumpApp(tester, auth: TestAuth(loggedIn: true));
      await openPlace(tester);
      await tapKey(tester, 'comment-like-c1');
      expect(backend.commentsOf('p1')[1]['liked_by'], hasLength(1));
      expect(find.text('1'), findsOneWidget);

      await tapKey(tester, 'comment-like-c1');
      expect(backend.commentsOf('p1')[1]['liked_by'], isEmpty);
      expect(find.text('1'), findsNothing);
    });

    displayTest(
      'niezalogowany: opinia czeka na logowanie i zapisuje się po nim',
      (tester) async {
        final auth = TestAuth();
        final backend = await pumpApp(tester, auth: auth);
        await openPlace(tester);
        await tester.ensureVisible(
          find.byKey(const ValueKey<String>('comment-input')),
        );
        await tester.enterText(
          find.byKey(const ValueKey<String>('comment-input')),
          'Po zalogowaniu',
        );
        await tapKey(tester, 'rate-4'); // stars first: they ask to log in
        await tester.tap(find.byKey(const ValueKey<String>('login-github')));
        await tester.pumpAndSettle();
        expect(backend.myRatings['p1'], 4);
        await tapKey(tester, 'comment-send'); // the typed text is still there
        expect(backend.commentsOf('p1').first['text'], 'Po zalogowaniu');
        expect(find.text('Po zalogowaniu'), findsOneWidget);
      },
    );

    displayTest(
      'wygasła sesja: token jest zapominany, akcja prosi o ponowne logowanie',
      (tester) async {
        final auth = TestAuth(loggedIn: true);
        final backend = FakeBackend()..validToken = 'nowy-token';
        await pumpApp(tester, backend: backend, auth: auth);
        await openPlace(tester); // GET /auth/me -> 401
        expect(auth.store.token, isNull);
        await tapKey(tester, 'rate-4');
        expect(find.byKey(const ValueKey<String>('login-github')), findsOneWidget);
        expect(backend.myRatings, isEmpty);
      },
    );
  });

  group('dodawanie miejsca', () {
    Future<void> openForm(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.widgetWithText(AppBar, 'Dodaj miejsce'), findsOneWidget);
    }

    /// Opening hours are picked in a sheet: 'hours-always' or 'hours-custom'.
    Future<void> chooseHours(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(const ValueKey<String>('hours-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('hours-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey<String>(key)));
      await tester.pumpAndSettle();
    }

    Future<void> submit(WidgetTester tester) async {
      // The form is a lazy ListView: scroll until the button is built.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('new-place-submit')),
        300,
        scrollable: find
            .descendant(
              of: find.byType(AddPlacePage),
              matching: find.byWidgetPredicate(
                (Widget w) =>
                    w is Scrollable && w.axisDirection == AxisDirection.down,
              ),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('new-place-submit')));
      await tester.pumpAndSettle();
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(ValueKey<String>(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey<String>(key)));
      await tester.pumpAndSettle();
    }

    displayTest('formularz pokazuje adres pinezki i wysyła wszystkie pola', (
      tester,
    ) async {
      final auth = TestAuth();
      final backend = await pumpApp(tester, auth: auth);
      await openForm(tester);
      expect(
        find.text('Floriańska 15, Kraków'),
        findsOneWidget,
      ); // reverse geocoding of the pin

      await tester.enterText(
        find.byKey(const ValueKey<String>('new-place-name')),
        'Nowa Kawiarnia',
      );
      await tapKey(tester, 'amenity-wifi');
      await tapKey(tester, 'amenity-power_outlets');
      await tester.ensureVisible(find.text('Kawiarnia'));
      await tester.tap(find.text('Kawiarnia'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Coworking'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Spokojnie'));
      await tester.tap(find.text('Spokojnie'));
      await tester.tap(find.text('0–30 zł'));
      await chooseHours(tester, 'hours-always');
      expect(find.text('Całą dobę'), findsOneWidget);
      await submit(tester);

      // Not logged in yet: choose a provider.
      await tester.tap(find.byKey(const ValueKey<String>('login-github')));
      await tester.pumpAndSettle();

      final body = backend.created.single;
      expect(body['name'], 'Nowa Kawiarnia');
      expect(body['address'], {
        'city': 'Kraków',
        'country_code': 'pl',
        'street': 'Floriańska',
        'house_number': '15',
        'postcode': '31-019',
      });
      expect(body['coordinates'], isNotNull);
      expect(body['amenities'], {'wifi': true, 'power_outlets': true});
      expect(body['atmosphere'], 'quiet');
      expect(body['category'], 'coworking');
      expect(body['usage_price'], '0-30');
      expect(body['opening_hours'], {
        'always_open': true,
        'periods': <Object>[],
      });

      // Back on the map, the new place's details are open.
      expect(find.text('Dodano: Nowa Kawiarnia'), findsOneWidget);
      expect(find.text('Udogodnienia'), findsOneWidget);
    });

    displayTest('wybrane zdjęcia są wysyłane po utworzeniu miejsca', (
      tester,
    ) async {
      fakePicker(['front.jpg', 'inside.jpg']);
      final backend = await pumpApp(tester, auth: TestAuth(loggedIn: true));
      await openForm(tester);
      await tester.tap(find.byKey(const ValueKey<String>('new-place-photos')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('new-place-chosen-photos')),
        findsOneWidget,
      );
      // Changed my mind about the second one.
      await tester.tap(find.byKey(const ValueKey<String>('remove-photo-1')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('new-place-name')),
        'Ze Zdjęciem',
      );
      await submit(tester);

      expect(backend.uploadedPhotos, [('new1', 'front.jpg')]);
      expect(find.text('Dodano: Ze Zdjęciem'), findsOneWidget);
    });

    displayTest('własne godziny: te same codziennie', (tester) async {
      final backend = await pumpApp(tester, auth: TestAuth(loggedIn: true));
      await openForm(tester);
      await tester.enterText(
        find.byKey(const ValueKey<String>('new-place-name')),
        'Biblioteka',
      );
      await chooseHours(tester, 'hours-custom');
      expect(find.text('8:00–20:00'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey<String>('hours-open')), '09:30');
      await tester.enterText(find.byKey(const ValueKey<String>('hours-close')), '17:00');
      await tester.pumpAndSettle();
      expect(find.text('9:30–17:00'), findsOneWidget);
      await submit(tester);

      // What the form shows is what is sent: the same hours every day, weekend too.
      final hours = backend.created.single['opening_hours'] as Map;
      final periods = (hours['periods'] as List).cast<Map>();
      expect(periods, [
        for (var day = 0; day < 7; day++) {'day': day, 'open': '09:30', 'close': '17:00'},
      ]);
    });

    displayTest('nieznane godziny nie pokazują wymyślonych godzin', (tester) async {
      final backend = await pumpApp(tester, auth: TestAuth(loggedIn: true));
      await openForm(tester);
      expect(find.text('Nie znane'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey<String>('new-place-name')), 'Czytelnia');
      await submit(tester);
      expect(backend.created.single.containsKey('opening_hours'), isFalse);
    });

    displayTest('bez nazwy nie wysyła', (tester) async {
      final backend = await pumpApp(tester, auth: TestAuth(loggedIn: true));
      await openForm(tester);
      await submit(tester);
      expect(find.text('Podaj nazwę'), findsOneWidget);
      expect(backend.created, isEmpty);
    });

    displayTest('punkt bez adresu', (tester) async {
      final backend = FakeBackend()..reverseResult = null;
      await pumpApp(tester, backend: backend, auth: TestAuth(loggedIn: true));
      await openForm(tester);
      expect(find.textContaining('Tu nie ma adresu'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey<String>('new-place-name')),
        'Na morzu',
      );
      await submit(tester);
      expect(backend.created, isEmpty);
    });

    displayTest('wyszukanie adresu przenosi pinezkę', (tester) async {
      final backend = await pumpApp(tester, auth: TestAuth(loggedIn: true));
      await openForm(tester);
      final before = backend.requests
          .where((u) => u.path == '/geocode/reverse')
          .length;
      await tester.enterText(
        find.byKey(const ValueKey<String>('new-place-address-search')),
        'Gdańsk',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      final reverse = backend.requests
          .where((u) => u.path == '/geocode/reverse')
          .toList();
      expect(reverse.length, greaterThan(before));
      expect(
        double.parse(reverse.last.queryParameters['lat']!),
        closeTo(54.352, 0.001),
      );
    });

    displayTest('miejsce od użytkownika czeka na akceptację admina', (
      tester,
    ) async {
      final backend = FakeBackend()..requireApproval = true;
      await pumpApp(tester, backend: backend, auth: TestAuth(loggedIn: true));
      await openForm(tester);
      await tester.enterText(
        find.byKey(const ValueKey<String>('new-place-name')),
        'Ukryta Kawiarnia',
      );
      await submit(tester);

      expect(backend.created, hasLength(1));
      expect(text('po akceptacji administratora'), findsOneWidget);
      // Stays on the map, no details of a place nobody else can see yet.
      expect(find.byType(PlaceDetailsPage), findsNothing);
      expect(backend.places.map((p) => p['name']), isNot(contains('Ukryta Kawiarnia')));
    });
  });

  group('panel admina', () {
    FakeBackend adminBackend() => FakeBackend()
      ..me = const {'id': 'boss', 'name': 'Szef', 'role': 'admin'}
      ..pending = [
        {...placeJson('n1', 'Nowa Czytelnia'), 'approved': false},
        {...placeJson('n2', 'Spam'), 'approved': false},
      ];

    Future<void> openPanel(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey<String>('open-admin')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Panel admina'), findsOneWidget);
    }

    displayTest('zwykły użytkownik nie widzi panelu', (tester) async {
      await pumpApp(tester, auth: TestAuth(loggedIn: true));
      expect(find.byKey(const ValueKey<String>('open-admin')), findsNothing);
    });

    displayTest('niezalogowany nie widzi panelu', (tester) async {
      await pumpApp(tester, backend: adminBackend());
      expect(find.byKey(const ValueKey<String>('open-admin')), findsNothing);
    });

    displayTest('admin akceptuje miejsce i pojawia się ono na mapie', (
      tester,
    ) async {
      final backend = await pumpApp(
        tester,
        backend: adminBackend(),
        auth: TestAuth(loggedIn: true),
      );
      await openPanel(tester);
      expect(find.text('Nowa Czytelnia'), findsOneWidget);
      expect(find.text('Spam'), findsOneWidget);
      expect(find.text('Oczekujące (2)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('admin-approve-n1')));
      await tester.pumpAndSettle();
      expect(backend.approvals, [('n1', true)]);
      expect(find.text('Nowa Czytelnia'), findsNothing);
      expect(find.text('Oczekujące (1)'), findsOneWidget);

      final searchesBefore = backend.searches.length;
      await tester.tap(find.byKey(const ValueKey<String>('back')));
      await tester.pumpAndSettle();
      expect(backend.searches.length, greaterThan(searchesBefore));
      expect(
        find.byKey(const ValueKey<String>('marker-n1')),
        findsOneWidget,
      );
    });

    displayTest('odrzucenie pyta o potwierdzenie i usuwa miejsce', (
      tester,
    ) async {
      final backend = await pumpApp(
        tester,
        backend: adminBackend(),
        auth: TestAuth(loggedIn: true),
      );
      await openPanel(tester);
      await tester.tap(find.byKey(const ValueKey<String>('admin-reject-n2')));
      await tester.pumpAndSettle();
      expect(text('Tego nie da się cofnąć'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('admin-reject-confirm')),
      );
      await tester.pumpAndSettle();
      expect(backend.deletedPlaces, ['n2']);
      expect(find.text('Spam'), findsNothing);
    });

    displayTest('zaakceptowane miejsce można ukryć', (tester) async {
      final backend = await pumpApp(
        tester,
        backend: adminBackend(),
        auth: TestAuth(loggedIn: true),
      );
      await openPanel(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('admin-tab-approved')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Kawiarnia Pod Kodem'), findsOneWidget);
      expect(find.text('Nowa Czytelnia'), findsNothing);

      await tester.tap(find.byKey(const ValueKey<String>('admin-hide-p1')));
      await tester.pumpAndSettle();
      expect(backend.approvals, [('p1', false)]);
      expect(find.text('Kawiarnia Pod Kodem'), findsNothing);
      expect(find.text('Oczekujące (3)'), findsOneWidget);
    });
  });
}
