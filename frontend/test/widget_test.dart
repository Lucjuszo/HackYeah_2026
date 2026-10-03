import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:miejscowki_map/main.dart';

void main() {
  testWidgets('mapa pokazuje wyszukiwarkę i wszystkie filtry', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MiejscowkiApp(locateOnStart: false));

    expect(find.text('Oceny'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsOneWidget);
    expect(find.text('Sortuj'), findsOneWidget);
    expect(find.text('Ceny'), findsOneWidget);
    expect(find.text('Filtruj'), findsOneWidget);
    expect(find.byIcon(Icons.my_location_rounded), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('spot-sheet-handle')),
      findsOneWidget,
    );
  });

  testWidgets('kafelek Filtruj rozwija podpowiedź', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MiejscowkiApp(locateOnStart: false));

    await tester.tap(find.text('Filtruj'));
    await tester.pumpAndSettle();

    expect(find.text('Możesz łączyć kilka filtrów'), findsOneWidget);
  });

  testWidgets('plus otwiera formularz nowej miejscówki', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MiejscowkiApp(locateOnStart: false));

    await tester.drag(
      find.byKey(const ValueKey<String>('spot-sheet-handle')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Dodaj miejsce'), findsOneWidget);
    expect(find.text('Nazwa'), findsOneWidget);
  });

  testWidgets('przeciągnięcie uchwytu rozwija listę miejsc', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MiejscowkiApp(locateOnStart: false));

    await tester.drag(
      find.byKey(const ValueKey<String>('spot-sheet-handle')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();

    expect(find.text('32 miejsca'), findsOneWidget);
    expect(tester.getTopLeft(find.text('32 miejsca')).dy, lessThan(320));
  });

  testWidgets('rząd kafelków można przewijać poziomo', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MiejscowkiApp(locateOnStart: false));

    final scrollable = find.byType(SingleChildScrollView);
    expect(scrollable, findsOneWidget);

    await tester.drag(scrollable, const Offset(-260, 0));
    await tester.pumpAndSettle();

    expect(find.text('Ceny'), findsOneWidget);
    expect(find.text('Filtruj'), findsOneWidget);
  });

  testWidgets('pasek lokalizacji otwiera ekran z powrotem do homepage', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MiejscowkiApp(locateOnStart: false));

    await tester.tap(
      find.byKey(const ValueKey<String>('location-picker-trigger')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Wybierz lokalizację'), findsOneWidget);
    expect(find.text('Wpisz miasto lub adres'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('location-back')));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.my_location_rounded), findsOneWidget);
  });

  testWidgets('kliknięcie miejscówki otwiera szczegóły i rozwija godziny', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MiejscowkiApp());

    await tester.drag(
      find.byKey(const ValueKey<String>('spot-sheet-handle')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Miejscówka nad rzeką'));
    await tester.pumpAndSettle();

    expect(find.text('Godziny otwarcia'), findsOneWidget);
    await tester.tap(find.text('Godziny otwarcia'));
    await tester.pumpAndSettle();

    expect(find.text('Poniedziałek'), findsOneWidget);
    expect(find.text('8:00 – 17:00'), findsNWidgets(5));
  });
}
