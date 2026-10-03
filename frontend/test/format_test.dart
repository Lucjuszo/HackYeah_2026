import 'package:flutter_test/flutter_test.dart';

import 'package:miejscowki_map/api/models.dart';
import 'package:miejscowki_map/ui/format.dart';

PlaceSummary _place({bool? openNow, DateTime? closesAt, DateTime? opensAt}) =>
    PlaceSummary(
      id: 'p1',
      name: 'Kawiarnia',
      address: const Address(city: 'Kraków'),
      location: const LatLon(50.06, 19.94),
      amenities: const Amenities(),
      rating: const RatingSummary(),
      openNow: openNow,
      closesAt: closesAt,
      opensAt: opensAt,
    );

void main() {
  group('plural', () {
    test('odmienia liczebniki po polsku', () {
      expect(placesCount(1), '1 miejsce');
      expect(placesCount(3), '3 miejsca');
      expect(placesCount(5), '5 miejsc');
      expect(placesCount(12), '12 miejsc');
      expect(placesCount(22), '22 miejsca');
      expect(placesCount(0), '0 miejsc');
      expect(ratingsCount(4), '4 oceny');
      expect(commentsCount(11), '11 opinii');
    });
  });

  test('decimal używa przecinka', () {
    expect(decimal(4.25), '4,3');
    expect(decimal(15, 2), '15,00');
  });

  test('distance zaokrągla metry i kilometry', () {
    expect(distance(243), '240 m');
    expect(distance(1530), '1,5 km');
    expect(distance(25300), '25 km');
  });

  test('money formatuje grosze', () {
    expect(money(1500, 'PLN'), '15,00 zł');
    expect(money(250, 'EUR'), '2,50 EUR');
  });

  group('priceLabel', () {
    test('zakresy cen', () {
      expect(priceLabel(const PriceRange(0, 30), null), '0–30 zł');
      expect(priceLabel(const PriceRange(60, null), null), 'od 60 zł');
      expect(priceLabel(const PriceRange(0, 0), null), 'Bezpłatnie');
      expect(priceLabel(const PriceRange(20, 20), null), '20 zł');
    });

    test('bez zakresu zwraca surowy tekst', () {
      expect(priceLabel(null, 'kawa'), 'kawa');
      expect(priceLabel(null, null), isNull);
    });
  });

  group('date', () {
    final now = DateTime(2026, 10, 3, 12);

    test('dzisiaj i wczoraj', () {
      expect(date(DateTime(2026, 10, 3, 8), now: now), 'dzisiaj');
      expect(date(DateTime(2026, 10, 2, 23), now: now), 'wczoraj');
    });

    test('pełna data, rok tylko gdy inny', () {
      expect(date(DateTime(2026, 9, 1), now: now), '1 września');
      expect(date(DateTime(2025, 12, 24), now: now), '24 grudnia 2025');
    });
  });

  group('openStatus', () {
    final now = DateTime(2026, 10, 3, 12); // sobota

    test('otwarte z godziną zamknięcia', () {
      final status = openStatus(
        _place(openNow: true, closesAt: DateTime(2026, 10, 3, 18, 5)),
        now: now,
      );
      expect(status.label, 'Otwarte teraz');
      expect(status.detail, 'do 18:05');
      expect(status.open, isTrue);
    });

    test('otwarte bez godziny zamknięcia = całą dobę', () {
      expect(openStatus(_place(openNow: true), now: now).detail, 'całą dobę');
    });

    test('zamknięte, otwiera jutro lub w dzień tygodnia', () {
      expect(
        openStatus(
          _place(openNow: false, opensAt: DateTime(2026, 10, 4, 9)),
          now: now,
        ).detail,
        'otwiera jutro 9:00',
      );
      expect(
        openStatus(
          _place(openNow: false, opensAt: DateTime(2026, 10, 5, 9)),
          now: now,
        ).detail,
        'otwiera w pon. 9:00',
      );
    });

    test('godziny nieznane', () {
      final status = openStatus(_place(), now: now);
      expect(status.label, 'Godziny nieznane');
      expect(status.open, isNull);
    });
  });

  test('periodLabel skraca wiodące zero', () {
    expect(periodLabel(const OpeningPeriod(0, '08:00', '16:30')), '8:00–16:30');
    expect(periodLabel(const OpeningPeriod(0, '10:00', '24:00')), '10:00–24:00');
  });
}
