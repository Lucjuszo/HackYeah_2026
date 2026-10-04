import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/places_api.dart';
import '../services/location_service.dart';
import 'theme.dart';

/// Where to look: a geocoded city / address, the device position or the whole country.
class LocationChoice {
  const LocationChoice({
    required this.label,
    this.point,
    this.bounds,
    this.isDevice = false,
  });

  /// Whole Poland: no reference point, the map shows the entire country.
  static const LocationChoice wholeCountry = LocationChoice(
    label: 'Cała Polska',
  );

  final String label;
  final LatLon? point;
  final GeoBounds? bounds;
  final bool isDevice;
}

class LocationPickerPage extends StatefulWidget {
  const LocationPickerPage({
    required this.api,
    required this.locationService,
    this.recent = const <LocationChoice>[],
    super.key,
  });

  final PlacesApi api;
  final LocationService locationService;
  final List<LocationChoice> recent;

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  int _requestId = 0;
  List<GeocodeResult> _results = const <GeocodeResult>[];
  bool _searching = false;
  bool _locating = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    setState(() {});
    _debounce?.cancel();
    if (text.trim().length < 2) {
      setState(() {
        _requestId++;
        _results = const <GeocodeResult>[];
        _searching = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(text));
  }

  Future<void> _search(String text) async {
    final id = ++_requestId;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await widget.api.geocode(text);
      if (!mounted || id != _requestId) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } on ApiException catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _searching = false;
        _error = e.statusCode == 503
            ? 'Wyszukiwanie adresów chwilowo nie działa.'
            : e.message;
      });
    }
  }

  Future<void> _useDeviceLocation() async {
    setState(() => _locating = true);
    try {
      final point = await widget.locationService.currentLocation();
      if (!mounted) return;
      Navigator.of(context).pop(
        LocationChoice(label: 'Moja lokalizacja', point: point, isDevice: true),
      );
    } on LocationFailure catch (e) {
      if (!mounted) return;
      setState(() => _locating = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _select(LocationChoice choice) => Navigator.of(context).pop(choice);

  Widget _actionTile({
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
    Widget? trailing,
  }) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            children: <Widget>[
              Icon(icon, color: AppColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final typing = _controller.text.trim().length >= 2;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: AppColors.transparent,
        elevation: 0,
        leading: IconButton(
          key: const ValueKey<String>('location-back'),
          tooltip: 'Wróć',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Wybierz lokalizację',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: <Widget>[
            TextField(
              key: const ValueKey<String>('location-search'),
              controller: _controller,
              autofocus: true,
              textAlignVertical: TextAlignVertical.center,
              onChanged: _onChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Wpisz miasto lub adres',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Wyczyść',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _controller.clear();
                          _onChanged('');
                        },
                      ),
                filled: true,
                fillColor: AppColors.field,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 18),
            if (typing) ..._searchResults() else ..._shortcuts(),
            const SizedBox(height: 24),
            const Text(
              'Wyszukiwanie: © OpenStreetMap contributors',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _shortcuts() => <Widget>[
    _actionTile(
      key: const ValueKey<String>('use-my-location'),
      icon: Icons.my_location_rounded,
      title: 'Użyj mojej lokalizacji',
      subtitle: 'Znajdź miejscówki w pobliżu',
      onTap: _locating ? null : _useDeviceLocation,
      trailing: _locating
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
    ),
    const SizedBox(height: 10),
    _actionTile(
      key: const ValueKey<String>('whole-country'),
      icon: Icons.public_rounded,
      title: 'Cała Polska',
      subtitle: 'Pokaż wszystkie miejscówki na mapie kraju',
      onTap: () => _select(LocationChoice.wholeCountry),
    ),
    if (widget.recent.isNotEmpty) ...<Widget>[
      const SizedBox(height: 24),
      const Text(
        'Ostatnio wybrane',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 7),
      for (final choice in widget.recent)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            choice.isDevice ? Icons.my_location_rounded : Icons.history_rounded,
          ),
          title: Text(choice.label),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _select(choice),
        ),
    ],
  ];

  List<Widget> _searchResults() {
    if (_error != null) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Text(_error!, style: const TextStyle(color: AppColors.closed)),
        ),
      ];
    }
    if (_searching && _results.isEmpty) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_results.isEmpty) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Text(
            'Brak pasujących lokalizacji',
            style: TextStyle(color: AppColors.muted),
          ),
        ),
      ];
    }
    return <Widget>[
      if (_searching) const LinearProgressIndicator(minHeight: 2),
      for (final result in _results)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(_iconFor(result.kind)),
          title: Text(result.name),
          subtitle: Text(
            result.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _select(
            LocationChoice(
              label: result.name,
              point: result.location,
              bounds: result.bounds,
            ),
          ),
        ),
    ];
  }

  static IconData _iconFor(String kind) => switch (kind) {
    'city' ||
    'town' ||
    'village' ||
    'municipality' => Icons.location_city_rounded,
    'house' || 'building' || 'road' => Icons.home_work_outlined,
    _ => Icons.location_on_outlined,
  };
}
