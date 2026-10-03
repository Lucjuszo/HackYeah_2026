import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:miejscowki_map/main.dart';

void main() {
  testWidgets('mapa pokazuje wyszukiwarkę i wszystkie filtry', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MiejscowkiApp());

    expect(find.text('Miejscówki'), findsOneWidget);
    expect(find.text('Oceny'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsOneWidget);
    expect(find.text('Sortuj'), findsOneWidget);
    expect(find.text('Ceny'), findsOneWidget);
    expect(find.text('Filtruj'), findsOneWidget);
    expect(find.text('MAPA'), findsOneWidget);
  });

  testWidgets('kafelek Filtruj rozwija podpowiedź', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MiejscowkiApp());

    await tester.tap(find.text('Filtruj'));
    await tester.pumpAndSettle();

    expect(find.text('Możesz łączyć kilka filtrów'), findsOneWidget);
  });

  testWidgets('plus otwiera formularz nowej miejscówki', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MiejscowkiApp());

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Dodaj miejscówkę'), findsOneWidget);
    expect(find.text('Nazwa miejscówki'), findsOneWidget);
  });

  testWidgets('przeciągnięcie uchwytu rozwija listę miejsc', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MiejscowkiApp());

    await tester.drag(
      find.byKey(const ValueKey<String>('spot-sheet-handle')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();

    expect(find.text('32 miejsca'), findsOneWidget);
    expect(tester.getTopLeft(find.text('32 miejsca')).dy, lessThan(320));
  });
}
