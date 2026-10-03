import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api/models.dart';
import '../api/places_api.dart';
import '../auth/auth.dart';
import '../services/location_service.dart';
import 'login_sheet.dart';
import 'theme.dart';

enum _HoursMode { unknown, alwaysOpen, custom }

/// Opening hours for a group of days (Mon–Fri or Sat–Sun).
class _DayGroupHours {
  _DayGroupHours(this.days, this.open, this.close);

  final List<int> days;
  bool isOpen = true;
  TimeOfDay open;
  TimeOfDay close;
}

String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _label(TimeOfDay t) => '${t.hour}:${t.minute.toString().padLeft(2, '0')}';

/// Periods for the backend: closing after midnight is split at 24:00 (e.g. Fri 20:00–02:00
/// becomes Fri 20:00–24:00 + Sat 00:00–02:00), like the backend stores overnight hours.
List<OpeningPeriod> _periods(List<_DayGroupHours> groups) {
  final periods = <OpeningPeriod>[];
  for (final group in groups.where((g) => g.isOpen)) {
    final open = _hhmm(group.open);
    final close = _hhmm(group.close);
    for (final day in group.days) {
      if (close == '00:00') {
        periods.add(OpeningPeriod(day, open, '24:00'));
      } else if (close.compareTo(open) > 0) {
        periods.add(OpeningPeriod(day, open, close));
      } else {
        periods.add(OpeningPeriod(day, open, '24:00'));
        periods.add(OpeningPeriod((day + 1) % 7, '00:00', close));
      }
    }
  }
  return periods;
}

/// "Dodaj miejscówkę": name, a pin on the map (address filled in automatically) and the basics.
/// Pops with the created [Place].
class AddPlacePage extends StatefulWidget {
  const AddPlacePage({
    required this.api,
    required this.auth,
    required this.locationService,
    required this.initialCenter,
    this.initialZoom = 16,
    this.showMapTiles = true,
    super.key,
  });

  final PlacesApi api;
  final AuthController auth;
  final LocationService locationService;
  final LatLon initialCenter;
  final double initialZoom;
  final bool showMapTiles;

  @override
  State<AddPlacePage> createState() => _AddPlacePageState();
}

class _AddPlacePageState extends State<AddPlacePage> {
  static const List<(String, String, IconData)> _amenities = [
    ('wifi', 'Wi-Fi', Icons.wifi_rounded),
    ('power_outlets', 'Gniazdka', Icons.power_rounded),
    ('food', 'Jedzenie', Icons.restaurant_rounded),
    ('toilet', 'Toaleta', Icons.wc_rounded),
    ('wheelchair_accessible', 'Dla wózków', Icons.accessible_rounded),
    ('air_conditioning', 'Klimatyzacja', Icons.ac_unit_rounded),
    ('computer_access', 'Komputery', Icons.computer_rounded),
  ];
  static const List<(String, String)> _prices = [
    ('za darmo', 'Bezpłatnie'),
    ('0-30', 'Do 30 zł'),
    ('30-60', '30–60 zł'),
    ('60+', 'Powyżej 60 zł'),
  ];

  final _nameController = TextEditingController();
  final _addressSearchController = TextEditingController();
  final _mapController = MapController();

  final Set<String> _selectedAmenities = <String>{};
  Atmosphere? _atmosphere;
  String? _price;
  _HoursMode _hoursMode = _HoursMode.unknown;
  final List<_DayGroupHours> _hours = <_DayGroupHours>[
    _DayGroupHours(<int>[0, 1, 2, 3, 4], const TimeOfDay(hour: 8, minute: 0), const TimeOfDay(hour: 20, minute: 0)),
    _DayGroupHours(<int>[5, 6], const TimeOfDay(hour: 10, minute: 0), const TimeOfDay(hour: 18, minute: 0)),
  ];

  late LatLon _point = widget.initialCenter;
  ReverseGeocodeResult? _address;
  LatLon? _addressPoint;
  bool _addressLoading = false;
  String? _addressError;
  int _addressRequest = 0;
  Timer? _addressDebounce;

  bool _nameMissing = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lookUpAddress();
  }

  @override
  void dispose() {
    _addressDebounce?.cancel();
    _nameController.dispose();
    _addressSearchController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // --- location & address

  Future<void> _lookUpAddress() async {
    final point = _point;
    final id = ++_addressRequest;
    setState(() {
      _addressLoading = true;
      _addressError = null;
    });
    try {
      final address = await widget.api.reverseGeocode(point);
      if (!mounted || id != _addressRequest) return;
      setState(() {
        _address = address;
        _addressPoint = point;
        _addressLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || id != _addressRequest) return;
      setState(() {
        _address = null;
        _addressLoading = false;
        _addressError = e.statusCode == 503 ? 'Wyszukiwanie adresów chwilowo nie działa.' : e.message;
      });
    }
  }

  void _onMapMoved(MapCamera camera, bool hasGesture) {
    _point = LatLon(camera.center.latitude, camera.center.longitude);
    _addressDebounce?.cancel();
    _addressDebounce = Timer(const Duration(milliseconds: 600), _lookUpAddress);
  }

  void _moveTo(LatLon point, {double zoom = 17}) {
    _mapController.move(LatLng(point.lat, point.lon), zoom);
    _point = point;
    _addressDebounce?.cancel();
    _lookUpAddress();
  }

  Future<void> _searchAddress(String text) async {
    if (text.trim().length < 2) return;
    try {
      final results = await widget.api.geocode(text);
      if (!mounted) return;
      if (results.isEmpty) {
        setState(() => _addressError = 'Nie znaleziono takiego adresu.');
        return;
      }
      _moveTo(results.first.location);
    } on ApiException catch (e) {
      if (mounted) setState(() => _addressError = e.message);
    }
  }

  Future<void> _useMyLocation() async {
    try {
      _moveTo(await widget.locationService.currentLocation(), zoom: 18);
    } on LocationFailure catch (e) {
      if (mounted) setState(() => _addressError = e.message);
    }
  }

  Future<void> _pickTime(_DayGroupHours group, {required bool opening}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: opening ? group.open : group.close,
      helpText: opening ? 'Otwarcie' : 'Zamknięcie',
    );
    if (picked == null || !mounted) return;
    setState(() => opening ? group.open = picked : group.close = picked);
  }

  // --- saving

  bool get _addressReady {
    final address = _address;
    return !_addressLoading &&
        address != null &&
        address.city != null &&
        address.countryCode != null &&
        _addressPoint == _point;
  }

  NewPlace _draft() {
    final address = _address!;
    return NewPlace(
      name: _nameController.text.trim(),
      location: _point,
      city: address.city!,
      countryCode: address.countryCode!,
      street: address.street,
      houseNumber: address.houseNumber,
      postcode: address.postcode,
      amenities: <String, bool>{for (final key in _selectedAmenities) key: true},
      atmosphere: _atmosphere,
      usagePrice: _price,
      openingHours: switch (_hoursMode) {
        _HoursMode.unknown => null,
        _HoursMode.alwaysOpen => const OpeningHours(alwaysOpen: true),
        _HoursMode.custom => OpeningHours(periods: _periods(_hours)),
      },
    );
  }

  Future<void> _save() async {
    final nameMissing = _nameController.text.trim().isEmpty;
    setState(() {
      _nameMissing = nameMissing;
      _error = null;
    });
    if (nameMissing) return;
    if (!_addressReady) {
      setState(() => _error = _addressLoading
          ? 'Chwila, ustalam adres…'
          : 'Ustaw pinezkę w miejscu z adresem (miejscowość).');
      return;
    }
    final draft = _draft();
    final token = await requireLogin(context, widget.auth, reason: 'Zaloguj się, żeby dodać miejscówkę.');
    if (token == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final place = await widget.api.createPlace(draft, token: token);
      if (mounted) Navigator.of(context).pop(place);
    } on ApiException catch (e) {
      if (e.statusCode == 401) await widget.auth.invalidate();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    }
  }

  // --- UI

  InputDecoration _fieldDecoration(String hint, {IconData? icon, String? error}) => InputDecoration(
    hintText: hint,
    errorText: error,
    prefixIcon: icon == null ? null : Icon(icon),
    filled: true,
    fillColor: const Color(0xFFF1F1F1),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
  );

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );

  Widget _chip(String label, bool selected, VoidCallback onTap, {IconData? icon, Key? key}) {
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: FilterChip(
        key: key,
        avatar: icon == null ? null : Icon(icon, size: 15, color: selected ? Colors.white : AppColors.ink),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        side: BorderSide.none,
        backgroundColor: AppColors.chip,
        selectedColor: AppColors.primary,
        labelStyle: TextStyle(color: selected ? Colors.white : AppColors.ink),
      ),
    );
  }

  Widget _addressLine() {
    final address = _address;
    final (IconData icon, String text, Color color) = _addressLoading
        ? (Icons.more_horiz_rounded, 'Ustalam adres…', AppColors.muted)
        : _addressError != null
        ? (Icons.error_outline_rounded, _addressError!, AppColors.closed)
        : address == null || address.city == null
        ? (Icons.wrong_location_outlined, 'Tu nie ma adresu – przesuń pinezkę na miejscowość.', AppColors.closed)
        : (Icons.location_on_outlined, Address(
            city: address.city!,
            street: address.street,
            houseNumber: address.houseNumber,
          ).short, AppColors.ink);
    return Row(
      key: const ValueKey<String>('new-place-address'),
      children: <Widget>[
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: color))),
      ],
    );
  }

  Widget _map() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 220,
        child: Stack(
          children: <Widget>[
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: LatLng(widget.initialCenter.lat, widget.initialCenter.lon),
                initialZoom: widget.initialZoom,
                minZoom: 4,
                maxZoom: 19,
                backgroundColor: const Color(0xFFF2EFE9),
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                onPositionChanged: _onMapMoved,
              ),
              children: <Widget>[
                if (widget.showMapTiles)
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'pl.hackyeah.miejscowki',
                    maxZoom: 19,
                  ),
                SimpleAttributionWidget(
                  source: const Text('OpenStreetMap contributors'),
                  alignment: Alignment.topRight,
                  backgroundColor: Colors.white.withValues(alpha: 0.75),
                ),
              ],
            ),
            // The pin stays in the middle; the map moves under it.
            const IgnorePointer(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 34),
                  child: Icon(Icons.location_on, size: 40, color: AppColors.primary),
                ),
              ),
            ),
            Positioned(
              right: 10,
              bottom: 10,
              child: Material(
                color: Colors.white,
                elevation: 2,
                shape: const CircleBorder(),
                child: InkWell(
                  key: const ValueKey<String>('new-place-my-location'),
                  customBorder: const CircleBorder(),
                  onTap: _useMyLocation,
                  child: const Tooltip(
                    message: 'Moja lokalizacja',
                    child: Padding(padding: EdgeInsets.all(10), child: Icon(Icons.my_location_rounded, size: 20)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hoursRow(String label, _DayGroupHours group) {
    Widget time(TimeOfDay value, bool opening) => OutlinedButton(
      onPressed: group.isOpen ? () => _pickTime(group, opening: opening) : null,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        foregroundColor: AppColors.ink,
        side: const BorderSide(color: AppColors.divider),
      ),
      child: Text(_label(value)),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: <Widget>[
          SizedBox(width: 64, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
          Switch(value: group.isOpen, onChanged: (bool v) => setState(() => group.isOpen = v)),
          const SizedBox(width: 6),
          if (group.isOpen) ...<Widget>[
            time(group.open, true),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('–')),
            time(group.close, false),
          ] else
            const Text('Zamknięte', style: TextStyle(color: AppColors.muted)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Wróć',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Dodaj miejscówkę', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('new-place-name'),
              controller: _nameController,
              autofocus: true,
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (_nameMissing) setState(() => _nameMissing = false);
              },
              decoration: _fieldDecoration('Nazwa miejscówki', error: _nameMissing ? 'Podaj nazwę' : null),
            ),
            _section(
              'Gdzie to jest?',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    key: const ValueKey<String>('new-place-address-search'),
                    controller: _addressSearchController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _searchAddress,
                    decoration: _fieldDecoration('Szukaj adresu, np. Floriańska 15, Kraków', icon: Icons.search_rounded),
                  ),
                  const SizedBox(height: 10),
                  _map(),
                  const SizedBox(height: 8),
                  const Text(
                    'Przesuń mapę, żeby pinezka wskazywała wejście.',
                    style: TextStyle(fontSize: 11, color: AppColors.muted),
                  ),
                  const SizedBox(height: 8),
                  _addressLine(),
                ],
              ),
            ),
            _section(
              'Udogodnienia',
              Wrap(
                children: <Widget>[
                  for (final (key, label, icon) in _amenities)
                    _chip(
                      label,
                      _selectedAmenities.contains(key),
                      () => setState(() {
                        if (!_selectedAmenities.remove(key)) _selectedAmenities.add(key);
                      }),
                      icon: icon,
                      key: ValueKey<String>('amenity-$key'),
                    ),
                ],
              ),
            ),
            _section(
              'Atmosfera',
              Wrap(
                children: <Widget>[
                  for (final atmosphere in Atmosphere.values)
                    _chip(
                      atmosphere.label,
                      _atmosphere == atmosphere,
                      () => setState(() => _atmosphere = _atmosphere == atmosphere ? null : atmosphere),
                    ),
                ],
              ),
            ),
            _section(
              'Ile kosztuje wizyta?',
              Wrap(
                children: <Widget>[
                  for (final (value, label) in _prices)
                    _chip(label, _price == value, () => setState(() => _price = _price == value ? null : value)),
                ],
              ),
            ),
            _section(
              'Godziny otwarcia',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Wrap(
                    children: <Widget>[
                      _chip('Nie wiem', _hoursMode == _HoursMode.unknown,
                          () => setState(() => _hoursMode = _HoursMode.unknown)),
                      _chip('Całą dobę', _hoursMode == _HoursMode.alwaysOpen,
                          () => setState(() => _hoursMode = _HoursMode.alwaysOpen),
                          key: const ValueKey<String>('hours-always')),
                      _chip('Ustal godziny', _hoursMode == _HoursMode.custom,
                          () => setState(() => _hoursMode = _HoursMode.custom),
                          key: const ValueKey<String>('hours-custom')),
                    ],
                  ),
                  if (_hoursMode == _HoursMode.custom) ...<Widget>[
                    const SizedBox(height: 6),
                    _hoursRow('Pon–Pt', _hours[0]),
                    _hoursRow('Sob–Nd', _hours[1]),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 26),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(_error!, style: const TextStyle(color: AppColors.closed, fontSize: 13)),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey<String>('new-place-submit'),
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Dodaj'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
