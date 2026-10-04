/// Polish formatting helpers (no intl dependency).
library;

import 'dart:math' as math;

import '../api/models.dart';

const List<String> weekdayNames = [
  'Poniedziałek',
  'Wtorek',
  'Środa',
  'Czwartek',
  'Piątek',
  'Sobota',
  'Niedziela',
];

const List<String> _weekdayShort = [
  'pon.',
  'wt.',
  'śr.',
  'czw.',
  'pt.',
  'sob.',
  'niedz.',
];

const List<String> _monthsGenitive = [
  'stycznia',
  'lutego',
  'marca',
  'kwietnia',
  'maja',
  'czerwca',
  'lipca',
  'sierpnia',
  'września',
  'października',
  'listopada',
  'grudnia',
];

/// "1 miejsce", "3 miejsca", "5 miejsc", "22 miejsca"
String plural(int n, String one, String few, String many) {
  if (n == 1) return '$n $one';
  final lastTwo = n % 100;
  final last = n % 10;
  if (last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14)) {
    return '$n $few';
  }
  return '$n $many';
}

String placesCount(int n) => plural(n, 'miejsce', 'miejsca', 'miejsc');

String ratingsCount(int n) => plural(n, 'ocena', 'oceny', 'ocen');

String commentsCount(int n) => plural(n, 'opinia', 'opinie', 'opinii');

/// 4.25 -> "4,3"
String decimal(double value, [int digits = 1]) =>
    value.toStringAsFixed(digits).replaceAll('.', ',');

/// 240 -> "240 m", 1530 -> "1,5 km", 25300 -> "25 km"
String distance(double meters) {
  if (meters < 1000) return '${(meters / 10).round() * 10} m';
  if (meters < 10000) return '${decimal(meters / 1000)} km';
  return '${(meters / 1000).round()} km';
}

/// Travel time: "1 min", "25 min", "1 h 5 min", "3 h".
String travelDuration(Duration d) {
  final minutes = math.max(1, (d.inSeconds / 60).round());
  if (minutes < 60) return '$minutes min';
  final rest = minutes % 60;
  return rest == 0 ? '${minutes ~/ 60} h' : '${minutes ~/ 60} h $rest min';
}

String hhmm(DateTime time) =>
    '${time.hour}:${time.minute.toString().padLeft(2, '0')}';

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// "jutro 9:00", "w pon. 9:00", "9:00" – relative to [now].
String _when(DateTime time, DateTime now) {
  final days = _day(time).difference(_day(now)).inDays;
  if (days <= 0) return hhmm(time);
  if (days == 1) return 'jutro ${hhmm(time)}';
  return 'w ${_weekdayShort[time.weekday - 1]} ${hhmm(time)}';
}

class OpenStatusText {
  const OpenStatusText(this.label, this.detail, {required this.open});

  final String label;
  final String? detail;

  /// null = unknown.
  final bool? open;
}

OpenStatusText openStatus(PlaceSummary place, {DateTime? now}) {
  now ??= DateTime.now();
  switch (place.openNow) {
    case true:
      final closes = place.closesAt;
      return OpenStatusText(
        'Otwarte teraz',
        closes == null ? 'całą dobę' : 'do ${_when(closes, now)}',
        open: true,
      );
    case false:
      final opens = place.opensAt;
      return OpenStatusText(
        'Zamknięte',
        opens == null ? null : 'otwiera ${_when(opens, now)}',
        open: false,
      );
    case null:
      return const OpenStatusText('Godziny nieznane', null, open: null);
  }
}

/// 1500 PLN -> "15,00 zł"
String money(int minorUnits, String currency) {
  final value = decimal(minorUnits / 100, 2);
  return currency == 'PLN' ? '$value zł' : '$value $currency';
}

/// Price chip: "0–30 zł", "od 60 zł", "Bezpłatnie", or the raw text.
String? priceLabel(PriceRange? range, String? raw) {
  if (range == null) return raw;
  if (range.max == 0) return 'Bezpłatnie';
  if (range.max == null) return 'od ${range.min} zł';
  if (range.min == range.max) return '${range.min} zł';
  return '${range.min}–${range.max} zł';
}

/// "3 października 2026" (+ "dzisiaj" / "wczoraj")
String date(DateTime time, {DateTime? now}) {
  now ??= DateTime.now();
  final days = _day(now).difference(_day(time)).inDays;
  if (days == 0) return 'dzisiaj';
  if (days == 1) return 'wczoraj';
  final year = time.year == now.year ? '' : ' ${time.year}';
  return '${time.day} ${_monthsGenitive[time.month - 1]}$year';
}

/// "08:00" -> "8:00", "24:00" stays.
String _shortTime(String value) =>
    value.startsWith('0') ? value.substring(1) : value;

String periodLabel(OpeningPeriod period) =>
    '${_shortTime(period.open)}–${_shortTime(period.close)}';
