import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:latlong2/latlong.dart';

import '../api/models.dart';
import '../api/places_api.dart';
import '../auth/auth.dart';
import 'photo_picker.dart';
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

String _hhmm(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _label(TimeOfDay t) =>
    '${t.hour}:${t.minute.toString().padLeft(2, '0')}';

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
/// What AddPlacePage returns: the new place and, when some photos didn't make it, why.
class AddedPlace {
  const AddedPlace(this.place, {this.photoError});

  final Place place;
  final String? photoError;
}

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
  static const double _fontSize = 11;

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
    ('0-30', '0–30 zł'),
    ('30-60', '30–60 zł'),
    ('60+', '60+ zł'),
  ];
  static const List<String> _categories = <String>[
    'Kawiarnia',
    'Biblioteka',
    'Coworking',
    'Restauracja',
    'Park',
    'Inne',
  ];

  /// Label shown in the form -> `category` sent to the API.
  static const Map<String, String> _categoryApiValues = <String, String>{
    'Kawiarnia': 'cafe',
    'Biblioteka': 'library',
    'Coworking': 'coworking',
    'Restauracja': 'restaurant',
    'Park': 'park',
    'Inne': 'other',
  };

  final _nameController = TextEditingController();
  final _addressSearchController = TextEditingController();
  final _extraAmenitiesController = TextEditingController();
  final _openingTimeController = TextEditingController(text: '08:00');
  final _closingTimeController = TextEditingController(text: '20:00');
  final _mapController = MapController();

  final Set<String> _selectedAmenities = <String>{};
  final List<String> _extraAmenities = <String>[];
  String _category = _categories.first;
  Atmosphere? _atmosphere;
  String? _price;
  _HoursMode _hoursMode = _HoursMode.unknown;
  // "Ustal godziny" edits one pair of times: the same hours every day of the week.
  final List<_DayGroupHours> _hours = <_DayGroupHours>[
    _DayGroupHours(
      <int>[0, 1, 2, 3, 4, 5, 6],
      const TimeOfDay(hour: 8, minute: 0),
      const TimeOfDay(hour: 20, minute: 0),
    ),
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

  /// Chosen before saving, uploaded right after the place is created.
  final List<PickedPhoto> _photos = <PickedPhoto>[];
  static const int _maxPhotos = 20; // MAX_PHOTOS_PER_PLACE in the API
  String? _uploadProgress;

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
    _extraAmenitiesController.dispose();
    _openingTimeController.dispose();
    _closingTimeController.dispose();
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
      if (address != null && _addressSearchController.text.trim().isEmpty) {
        _addressSearchController.text = Address(
          city: address.city ?? '',
          street: address.street,
          houseNumber: address.houseNumber,
        ).short;
      }
    } on ApiException catch (e) {
      if (!mounted || id != _addressRequest) return;
      setState(() {
        _address = null;
        _addressLoading = false;
        _addressError = e.statusCode == 503
            ? 'Wyszukiwanie adresów chwilowo nie działa.'
            : e.message;
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

  Future<void> _pickPhotos() async {
    final free = _maxPhotos - _photos.length;
    if (free <= 0) return;
    final picked = await pickPhotos(context, limit: free);
    if (picked.isEmpty || !mounted) return;
    setState(() => _photos.addAll(picked));
  }

  /// Sends the chosen photos to the just-created place; the reason of the first failure, if any.
  Future<String?> _uploadPhotos(Place place, String token) async {
    String? error;
    var failed = 0;
    for (final (i, photo) in _photos.indexed) {
      if (mounted) {
        setState(
          () => _uploadProgress = 'Wysyłam zdjęcia ${i + 1}/${_photos.length}…',
        );
      }
      try {
        await widget.api.uploadPhoto(
          place.id,
          photo.bytes,
          filename: photo.name,
          token: token,
        );
      } on ApiException catch (e) {
        failed++;
        error ??= e.message;
      }
    }
    if (error == null) return null;
    return 'Nie dodano $failed z ${_photos.length} zdjęć ($error). Spróbuj ponownie w szczegółach miejsca.';
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
      amenities: <String, bool>{
        for (final key in _selectedAmenities) key: true,
      },
      atmosphere: _atmosphere,
      category: _categoryApiValues[_category],
      usagePrice: _price,
      openingHours: switch (_hoursMode) {
        _HoursMode.unknown => null,
        _HoursMode.alwaysOpen => const OpeningHours(alwaysOpen: true),
        _HoursMode.custom => OpeningHours(periods: _periods(_hours)),
      },
      features: List<String>.of(_extraAmenities),
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
      setState(
        () => _error = _addressLoading
            ? 'Chwila, ustalam adres…'
            : 'Ustaw pinezkę w miejscu z adresem (miejscowość).',
      );
      return;
    }
    final draft = _draft();
    final token = await requireLogin(
      context,
      widget.auth,
      reason: 'Zaloguj się, żeby dodać miejscówkę.',
    );
    if (token == null || !mounted) return;
    setState(() => _saving = true);
    try {
      var place = await widget.api.createPlace(draft, token: token);
      String? photoError;
      if (_photos.isNotEmpty) {
        photoError = await _uploadPhotos(place, token);
        // Fresh record with the photos (thumbnail on the map, header in the details).
        try {
          place = await widget.api.getPlace(place.id);
        } on ApiException {
          // The place exists either way; photos show up after the next refresh.
        }
      }
      if (mounted) {
        Navigator.of(context).pop(AddedPlace(place, photoError: photoError));
      }
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

  InputDecoration _fieldDecoration(
    String hint, {
    IconData? icon,
    String? error,
  }) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(fontSize: _fontSize, color: AppColors.muted),
    errorText: error,
    prefixIcon: icon == null ? null : Icon(icon),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    filled: true,
    fillColor: AppColors.formField,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
  );

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: const TextStyle(
            fontSize: _fontSize,
            fontWeight: FontWeight.w700,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );

  Widget _fieldLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(fontSize: _fontSize, color: AppColors.ink),
    ),
  );

  Widget _labeled(String label, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[_fieldLabel(label), child],
    ),
  );

  Widget _selectField({
    required Widget leading,
    required String value,
    required VoidCallback onTap,
    Key? key,
  }) => Material(
    color: AppColors.formField,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      key: key,
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
        height: 40,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: <Widget>[
              leading,
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  value,
                  style: const TextStyle(
                    fontSize: _fontSize,
                    color: AppColors.muted,
                  ),
                ),
              ),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: AppColors.muted,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _choiceRow<T>({
    required List<(T, String)> choices,
    required T? selected,
    required ValueChanged<T> onSelected,
  }) => Container(
    height: 40,
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: AppColors.formField,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: <Widget>[
        for (final (value, label) in choices)
          Expanded(
            child: Material(
              color: selected == value
                  ? AppColors.accent
                  : AppColors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onSelected(value),
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: _fontSize,
                      color: selected == value
                          ? AppColors.white
                          : AppColors.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Future<void> _chooseCategory() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      builder: (BuildContext context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final category in _categories)
              ListTile(
                title: Text(
                  category,
                  style: const TextStyle(fontSize: _fontSize),
                ),
                trailing: category == _category
                    ? const Icon(Icons.check_rounded, color: AppColors.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(category),
              ),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) setState(() => _category = chosen);
  }

  Future<void> _chooseHours() async {
    final choice = await showModalBottomSheet<_HoursMode>(
      context: context,
      backgroundColor: AppColors.background,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              title: const Text(
                'Nie znane',
                style: TextStyle(fontSize: _fontSize),
              ),
              onTap: () => Navigator.of(context).pop(_HoursMode.unknown),
            ),
            ListTile(
              key: const ValueKey<String>('hours-always'),
              title: const Text(
                'Całą dobę',
                style: TextStyle(fontSize: _fontSize),
              ),
              onTap: () => Navigator.of(context).pop(_HoursMode.alwaysOpen),
            ),
            ListTile(
              key: const ValueKey<String>('hours-custom'),
              title: const Text(
                'Ustal godziny',
                style: TextStyle(fontSize: _fontSize),
              ),
              onTap: () => Navigator.of(context).pop(_HoursMode.custom),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _hoursMode = choice);
  }

  void _setTypedTime(String value, {required bool opening}) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
    if (match == null) return;
    final hour = int.tryParse(match.group(1)!) ?? -1;
    final minute = int.tryParse(match.group(2)!) ?? -1;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return;
    final time = TimeOfDay(hour: hour, minute: minute);
    setState(() {
      for (final group in _hours) {
        if (opening) {
          group.open = time;
        } else {
          group.close = time;
        }
      }
    });
  }

  void _normaliseTypedTime(
    TextEditingController controller, {
    required bool opening,
  }) {
    final match = RegExp(r'^(\d{1,2})(?::(\d{1,2}))?$')
        .firstMatch(controller.text.trim());
    if (match == null) return;
    final hour = int.tryParse(match.group(1)!) ?? -1;
    final minute = int.tryParse(match.group(2) ?? '0') ?? -1;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return;
    final formatted =
        '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
    controller.value = TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
    _setTypedTime(formatted, opening: opening);
  }

  Widget _customHoursEditor() => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 18),
    child: Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            key: const ValueKey<String>('hours-open'),
            controller: _openingTimeController,
            keyboardType: TextInputType.datetime,
            style: const TextStyle(fontSize: _fontSize),
            onChanged: (String value) => _setTypedTime(value, opening: true),
            onEditingComplete: () =>
                _normaliseTypedTime(_openingTimeController, opening: true),
            onSubmitted: (_) =>
                _normaliseTypedTime(_openingTimeController, opening: true),
            decoration: _fieldDecoration('Od'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Text('–', style: TextStyle(fontSize: _fontSize)),
        ),
        Expanded(
          child: TextField(
            key: const ValueKey<String>('hours-close'),
            controller: _closingTimeController,
            keyboardType: TextInputType.datetime,
            style: const TextStyle(fontSize: _fontSize),
            onChanged: (String value) => _setTypedTime(value, opening: false),
            onEditingComplete: () =>
                _normaliseTypedTime(_closingTimeController, opening: false),
            onSubmitted: (_) =>
                _normaliseTypedTime(_closingTimeController, opening: false),
            decoration: _fieldDecoration('Do'),
          ),
        ),
      ],
    ),
  );

  String get _hoursLabel => switch (_hoursMode) {
    _HoursMode.unknown => 'Nie znane',
    _HoursMode.alwaysOpen => 'Całą dobę',
    _HoursMode.custom =>
      '${_label(_hours.first.open)}–${_label(_hours.first.close)}',
  };

  Widget _chip(
    String label,
    bool selected,
    VoidCallback onTap, {
    IconData? icon,
    Key? key,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: FilterChip(
        key: key,
        avatar: icon == null
            ? null
            : Icon(
                icon,
                size: 15,
                color: selected ? AppColors.white : AppColors.ink,
              ),
        label: Text(label, style: const TextStyle(fontSize: _fontSize)),
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        side: BorderSide.none,
        backgroundColor: AppColors.chip,
        selectedColor: AppColors.primary,
        labelStyle: TextStyle(
          color: selected ? AppColors.white : AppColors.ink,
        ),
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
        ? (
            Icons.wrong_location_outlined,
            'Tu nie ma adresu – przesuń pinezkę na miejscowość.',
            AppColors.closed,
          )
        : (
            Icons.location_on_outlined,
            Address(
              city: address.city!,
              street: address.street,
              houseNumber: address.houseNumber,
            ).short,
            AppColors.ink,
          );
    return Row(
      key: const ValueKey<String>('new-place-address'),
      children: <Widget>[
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: _fontSize, color: color),
          ),
        ),
      ],
    );
  }

  Widget _map() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        height: 112,
        child: Stack(
          children: <Widget>[
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: LatLng(
                  widget.initialCenter.lat,
                  widget.initialCenter.lon,
                ),
                initialZoom: widget.initialZoom,
                minZoom: 4,
                maxZoom: 19,
                backgroundColor: AppColors.mapBackground,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                ),
                onPositionChanged: _onMapMoved,
              ),
              children: <Widget>[
                if (widget.showMapTiles)
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'pl.hackyeah.miejscowki',
                    maxZoom: 19,
                  ),
                SimpleAttributionWidget(
                  source: const Text('OpenStreetMap contributors'),
                  alignment: Alignment.topRight,
                  backgroundColor: AppColors.white.withValues(alpha: 0.75),
                ),
              ],
            ),
            // The pin stays in the middle; the map moves under it.
            const IgnorePointer(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 34),
                  child: Icon(
                    Icons.location_on,
                    size: 30,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 10,
              bottom: 10,
              child: Material(
                color: AppColors.white,
                elevation: 2,
                shape: const CircleBorder(),
                child: InkWell(
                  key: const ValueKey<String>('new-place-my-location'),
                  customBorder: const CircleBorder(),
                  onTap: _useMyLocation,
                  child: const Tooltip(
                    message: 'Moja lokalizacja',
                    child: Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.my_location_rounded, size: 20),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: AppColors.background,
        surfaceTintColor: AppColors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Wróć',
          icon: const Icon(Icons.arrow_back_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Dodaj miejsce',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            children: <Widget>[
              if (_photos.isNotEmpty)
                _ChosenPhotos(
                  photos: _photos,
                  onAdd: _saving || _photos.length >= _maxPhotos
                      ? null
                      : _pickPhotos,
                  onRemove: _saving
                      ? null
                      : (int i) => setState(() => _photos.removeAt(i)),
                )
              else
                Material(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    height: 106,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        SvgPicture.asset(
                          'assets/images/obrazek.svg',
                          width: 68,
                          height: 52,
                          fit: BoxFit.contain,
                        ),
                        const SizedBox(height: 16),
                        Material(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(15),
                          child: InkWell(
                            key: const ValueKey<String>('new-place-photos'),
                            borderRadius: BorderRadius.circular(15),
                            onTap: _saving ? null : _pickPhotos,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 13,
                                vertical: 6,
                              ),
                              child: Text(
                                'Dodaj zdjęcia',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 18),
              TextField(
                key: const ValueKey<String>('new-place-name'),
                controller: _nameController,
                autofocus: true,
                textInputAction: TextInputAction.next,
                onChanged: (_) {
                  if (_nameMissing) setState(() => _nameMissing = false);
                },
                decoration: _fieldDecoration(
                  'Nazwa miejscówki',
                  error: _nameMissing ? 'Podaj nazwę' : null,
                ),
              ),
              const SizedBox(height: 22),
              _labeled(
                'Adres',
                TextField(
                  key: const ValueKey<String>('new-place-address-search'),
                  controller: _addressSearchController,
                  style: const TextStyle(fontSize: _fontSize),
                  textInputAction: TextInputAction.search,
                  onSubmitted: _searchAddress,
                  decoration: _fieldDecoration('ul. Wielicka, Kraków'),
                ),
              ),
              _map(),
              const SizedBox(height: 22),
              if (_addressError != null || _address == null) _addressLine(),
              _labeled(
                'Kategoria',
                _selectField(
                  leading: const Icon(
                    Icons.local_cafe_outlined,
                    size: 16,
                    color: AppColors.muted,
                  ),
                  value: _category,
                  onTap: _chooseCategory,
                ),
              ),
              _labeled(
                'Godziny otwarcia',
                _selectField(
                  key: const ValueKey<String>('hours-selector'),
                  leading: const Icon(
                    Icons.schedule_outlined,
                    size: 16,
                    color: AppColors.muted,
                  ),
                  value: _hoursLabel,
                  onTap: _chooseHours,
                ),
              ),
              if (_hoursMode == _HoursMode.custom) _customHoursEditor(),
              _labeled(
                'Atmosfera',
                _choiceRow<Atmosphere>(
                  choices: <(Atmosphere, String)>[
                    for (final atmosphere in Atmosphere.values)
                      (atmosphere, atmosphere.label),
                  ],
                  selected: _atmosphere,
                  onSelected: (Atmosphere value) => setState(
                    () => _atmosphere = _atmosphere == value ? null : value,
                  ),
                ),
              ),
              _labeled(
                'Cena',
                _choiceRow<String>(
                  choices: <(String, String)>[
                    for (final (value, label) in _prices) (value, label),
                  ],
                  selected: _price,
                  onSelected: (String value) =>
                      setState(() => _price = _price == value ? null : value),
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
                          if (!_selectedAmenities.remove(key)) {
                            _selectedAmenities.add(key);
                          }
                        }),
                        icon: icon,
                        key: ValueKey<String>('amenity-$key'),
                      ),
                  ],
                ),
              ),
              _labeled(
                'Dodatkowe udogodnienia',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    TextField(
                      key: const ValueKey<String>('new-place-extra-amenities'),
                      controller: _extraAmenitiesController,
                      style: const TextStyle(fontSize: _fontSize),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (String value) {
                        final text = value.trim();
                        if (text.isEmpty) return;
                        setState(() {
                          _extraAmenities.add(text);
                          _extraAmenitiesController.clear();
                        });
                      },
                      decoration: _fieldDecoration('Dodaj udogodnienie'),
                    ),
                    if (_extraAmenities.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: <Widget>[
                          for (final feature in _extraAmenities)
                            Chip(
                              label: Text(
                                feature,
                                style: const TextStyle(
                                  fontSize: _fontSize,
                                  color: AppColors.extraAmenityText,
                                ),
                              ),
                              deleteIcon: const Icon(
                                Icons.close_rounded,
                                size: 13,
                                color: AppColors.extraAmenityText,
                              ),
                              onDeleted: () => setState(
                                () => _extraAmenities.remove(feature),
                              ),
                              backgroundColor: AppColors.extraAmenityBackground,
                              side: BorderSide.none,
                              visualDensity: VisualDensity.compact,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 4),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: AppColors.closed,
                      fontSize: _fontSize,
                    ),
                  ),
                ),
              if (_saving && _uploadProgress != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _uploadProgress!,
                    key: const ValueKey<String>('new-place-upload-progress'),
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: _fontSize,
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const ValueKey<String>('new-place-submit'),
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 21,
                      vertical: 9,
                    ),
                    textStyle: const TextStyle(fontSize: _fontSize),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.white,
                          ),
                        )
                      : const Text('Opublikuj'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Photos picked for the new place: thumbnails with a remove button, plus an "add more" tile.
class _ChosenPhotos extends StatelessWidget {
  const _ChosenPhotos({
    required this.photos,
    required this.onAdd,
    required this.onRemove,
  });

  final List<PickedPhoto> photos;
  final VoidCallback? onAdd;
  final ValueChanged<int>? onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 106,
      child: ListView.separated(
        key: const ValueKey<String>('new-place-chosen-photos'),
        scrollDirection: Axis.horizontal,
        itemCount: photos.length + (onAdd == null ? 0 : 1),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, int i) {
          if (i == photos.length) {
            return Material(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                key: const ValueKey<String>('new-place-more-photos'),
                borderRadius: BorderRadius.circular(14),
                onTap: onAdd,
                child: const SizedBox(
                  width: 106,
                  child: Icon(
                    Icons.add_a_photo_outlined,
                    color: AppColors.primary,
                  ),
                ),
              ),
            );
          }
          return Stack(
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.memory(
                  photos[i].bytes,
                  width: 106,
                  height: 106,
                  fit: BoxFit.cover,
                  cacheWidth: 320,
                  errorBuilder: (_, _, _) => Container(
                    width: 106,
                    height: 106,
                    color: AppColors.field,
                    child: const Icon(
                      Icons.broken_image_outlined,
                      color: AppColors.placeholderIcon,
                    ),
                  ),
                ),
              ),
              if (onRemove != null)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Material(
                    color: AppColors.imageOverlay,
                    shape: const CircleBorder(),
                    child: InkWell(
                      key: ValueKey<String>('remove-photo-$i'),
                      customBorder: const CircleBorder(),
                      onTap: () => onRemove!(i),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: AppColors.white,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
