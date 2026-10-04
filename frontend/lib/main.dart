import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'api/models.dart';
import 'api/places_api.dart';
import 'auth/auth.dart';
import 'services/location_service.dart';
import 'services/travel_time_service.dart';
import 'ui/add_place_page.dart';
import 'ui/format.dart' as fmt;
import 'ui/location_picker_page.dart';
import 'ui/place_details_page.dart';
import 'ui/search_page.dart';
import 'ui/theme.dart';
import 'ui/widgets.dart';

void main() {
  final api = PlacesApi();
  runApp(
    MiejscowkiApp(
      api: api,
      auth: AuthController(api: api),
      travelTimes: TravelTimeService(),
    ),
  );
}

class MiejscowkiApp extends StatelessWidget {
  const MiejscowkiApp({
    required this.api,
    required this.auth,
    this.locationService = const GeolocatorLocationService(),
    this.showMapTiles = true,
    this.travelTimes,
    this.locateOnStart = true,
    super.key,
  });

  final PlacesApi api;
  final AuthController auth;
  final LocationService locationService;

  /// Off in widget tests: tiles come from tile.openstreetmap.org.
  final bool showMapTiles;

  /// Walk / bike / car times to a place; null hides them (tests: no network).
  final TravelTimeService? travelTimes;

  /// Start at the device position if the user allows it, else the whole of Poland.
  final bool locateOnStart;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Miejscówki',
      theme: buildTheme(),
      home: MapHomePage(
        api: api,
        auth: auth,
        locationService: locationService,
        showMapTiles: showMapTiles,
        travelTimes: travelTimes,
        locateOnStart: locateOnStart,
      ),
    );
  }
}

/// Poland, for the initial view and "Cała Polska".
final LatLngBounds polandBounds = LatLngBounds(
  const LatLng(49.0, 14.1),
  const LatLng(54.9, 24.2),
);

enum _PriceFilter {
  any('Ceny', null, null),
  free('Bezpłatne', null, 0),
  upTo30('Do 30 zł', null, 30),
  from30('Powyżej 30 zł', 30, null);

  const _PriceFilter(this.label, this.minPrice, this.maxPrice);

  final String label;
  final int? minPrice;
  final int? maxPrice;
}

enum _RatingFilter {
  any('Oceny', null),
  from45('4,5+', 4.5),
  from4('4+', 4.0),
  from3('3+', 3.0);

  const _RatingFilter(this.label, this.minRating);

  final String label;
  final double? minRating;
}

enum _RadiusFilter {
  none('0 km', null),
  one('1 km', 1),
  three('3 km', 3),
  five('5 km', 5),
  ten('10 km', 10),
  twenty('20 km', 20);

  const _RadiusFilter(this.label, this.km);

  final String label;
  final int? km;
}

class MapHomePage extends StatefulWidget {
  const MapHomePage({
    required this.api,
    required this.auth,
    required this.locationService,
    this.showMapTiles = true,
    this.travelTimes,
    this.locateOnStart = true,
    super.key,
  });

  final PlacesApi api;
  final AuthController auth;
  final LocationService locationService;
  final bool showMapTiles;
  final TravelTimeService? travelTimes;
  final bool locateOnStart;

  @override
  State<MapHomePage> createState() => _MapHomePageState();
}

class _MapHomePageState extends State<MapHomePage> {
  static const double _sheetMin = 0.14;
  // Keep the search, location and filter controls visible above the expanded list.
  static const double _sheetMax = 0.78;

  final _searchController = TextEditingController();
  final _sheetController = DraggableScrollableController();
  final _mapController = MapController();

  // Filters
  _RatingFilter _rating = _RatingFilter.any;
  bool _wifi = false;
  PlaceSort? _sort; // null = best rated first
  _RadiusFilter _radius = _RadiusFilter.none;
  _PriceFilter _price = _PriceFilter.any;
  bool _openNow = false;
  bool _powerOutlets = false;
  Atmosphere? _atmosphere;
  bool _filtersOpen = false;

  // Location: reference point for distances ("Moja lokalizacja", a searched city...)
  LocationChoice _location = LocationChoice.wholeCountry;
  final List<LocationChoice> _recentLocations = <LocationChoice>[];
  final List<String> _recentSearches = <String>[];

  // Results
  List<PlaceSummary> _places = const <PlaceSummary>[];
  int _total = 0;
  bool _loading = false;
  String? _error;
  int _requestId = 0;
  bool _mapReady = false;
  Timer? _reloadDebounce;
  String? _selectedId;
  bool _sheetExpanded = false;

  /// The user moved the map or picked a place: a late GPS fix must not move the camera.
  bool _userMovedMap = false;

  @override
  void initState() {
    super.initState();
    widget.auth.restore();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.locationService.requestPermission());
    });
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _searchController.dispose();
    _sheetController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // --- searching

  GeoBounds? _visibleBounds() {
    final b = _mapController.camera.visibleBounds;
    final west = math.max(-180.0, b.west);
    final east = math.min(180.0, b.east);
    if (east - west > 180 || east <= west) {
      return null; // zoomed out past the world: everything
    }
    return GeoBounds(
      south: math.max(-90.0, b.south),
      west: west,
      north: math.min(90.0, b.north),
      east: east,
    );
  }

  PlacesQuery _query() {
    final common = (
      text: _searchController.text,
      minRating: _rating.minRating,
      minPrice: _price.minPrice,
      maxPrice: _price.maxPrice,
    );
    final point = _location.point;
    if (_radius.km case final km?) {
      // Without a chosen location the radius is around the map centre.
      final center = _mapController.camera.center;
      return PlacesQuery(
        near: point ?? LatLon(center.latitude, center.longitude),
        radiusM: km * 1000,
        text: common.text,
        wifi: _wifi,
        powerOutlets: _powerOutlets,
        openNow: _openNow,
        atmosphere: _atmosphere,
        minRating: common.minRating,
        minPrice: common.minPrice,
        maxPrice: common.maxPrice,
        sort: _sort ?? PlaceSort.rating,
      );
    }
    if (_sort == PlaceSort.distance) {
      // "Closest" = around the chosen point if it's on screen, else the map centre,
      // far enough to cover the visible area (the backend allows up to 50 km).
      final camera = _mapController.camera;
      final near =
          point != null &&
              camera.visibleBounds.contains(LatLng(point.lat, point.lon))
          ? LatLng(point.lat, point.lon)
          : camera.center;
      final b = camera.visibleBounds;
      const meter = Distance();
      final farthest =
          <LatLng>[b.northWest, b.northEast, b.southWest, b.southEast]
              .map((LatLng corner) => meter.as(LengthUnit.Meter, near, corner))
              .reduce(math.max);
      return PlacesQuery(
        near: LatLon(near.latitude, near.longitude),
        radiusM: farthest.clamp(500, 50000).round(),
        text: common.text,
        wifi: _wifi,
        powerOutlets: _powerOutlets,
        openNow: _openNow,
        atmosphere: _atmosphere,
        minRating: common.minRating,
        minPrice: common.minPrice,
        maxPrice: common.maxPrice,
        sort: PlaceSort.distance,
      );
    }
    return PlacesQuery(
      bounds: _visibleBounds(),
      text: common.text,
      wifi: _wifi,
      powerOutlets: _powerOutlets,
      openNow: _openNow,
      atmosphere: _atmosphere,
      minRating: common.minRating,
      minPrice: common.minPrice,
      maxPrice: common.maxPrice,
      sort: _sort ?? PlaceSort.rating,
    );
  }

  Future<void> _reload() async {
    if (!_mapReady) return;
    _reloadDebounce?.cancel();
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.searchPlaces(_query());
      if (!mounted || id != _requestId) return;
      setState(() {
        _places = page.items;
        _total = page.total;
        _loading = false;
        if (!_places.any((PlaceSummary p) => p.id == _selectedId)) {
          _selectedId = null;
        }
      });
    } on ApiException catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  void _reloadSoon([Duration delay = const Duration(milliseconds: 450)]) {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(delay, _reload);
  }

  void _setFilter(VoidCallback change) {
    setState(change);
    _reload();
  }

  // --- distances, navigation

  /// From the chosen location if there is one, else what the backend measured (map centre).
  double? _distanceTo(PlaceSummary place) {
    final point = _location.point;
    if (point == null) return place.distanceM;
    return const Distance().as(
      LengthUnit.Meter,
      LatLng(point.lat, point.lon),
      LatLng(place.location.lat, place.location.lon),
    );
  }

  Future<void> _openDetails(PlaceSummary place) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaceDetailsPage(
          api: widget.api,
          auth: widget.auth,
          summary: place,
          distanceM: _distanceTo(place),
          travelTimes: widget.travelTimes,
          origin: _location.point,
          originLabel: _location.isDevice ? null : _location.label,
        ),
      ),
    );
    // Ratings may have changed there.
    if (mounted) _reload();
  }

  LocationChoice _deviceChoice(LatLon point) =>
      LocationChoice(label: 'Moja lokalizacja', point: point, isDevice: true);

  /// Where the radius is measured from: the chosen location, else the map centre.
  LatLng _radiusCenter() {
    final point = _location.point;
    return point != null
        ? LatLng(point.lat, point.lon)
        : _mapController.camera.center;
  }

  void _fitRadius(LatLng center, int km) {
    const distance = Distance();
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(<LatLng>[
          for (final bearing in <double>[0, 90, 180, 270])
            distance.offset(center, km * 1000, bearing),
        ]),
        padding: const EdgeInsets.all(24),
      ),
    );
  }

  /// Device position at startup; without it (no permission, no GPS) the map stays on Poland.
  Future<void> _locateOnStart() async {
    final LatLon point;
    try {
      point = await widget.locationService.currentLocation();
    } on LocationFailure {
      return;
    }
    if (!mounted || _location != LocationChoice.wholeCountry) return;
    final choice = _deviceChoice(point);
    _setLocation(choice);
    if (_userMovedMap) {
      _reload(); // distances / travel times from here, the camera stays
    } else {
      _showLocation(choice);
    }
  }

  void _setLocation(LocationChoice choice) {
    setState(() {
      _location = choice;
      if (choice.point != null) {
        _recentLocations.removeWhere(
          (LocationChoice c) => c.label == choice.label,
        );
        _recentLocations.insert(0, choice);
        if (_recentLocations.length > 5) _recentLocations.removeLast();
      }
    });
  }

  /// A radius needs a centre: ask for the device position, else use the map centre.
  Future<void> _selectRadius(_RadiusFilter radius) async {
    setState(() => _radius = radius);
    final km = radius.km;
    if (km == null) {
      _reload();
      return;
    }
    if (_location.point == null) {
      try {
        final point = await widget.locationService.currentLocation();
        if (!mounted) return;
        _setLocation(_deviceChoice(point));
      } on LocationFailure {
        _toast('Brak lokalizacji – promień liczony od środka mapy.');
      }
      if (!mounted || _radius != radius) return;
    }
    _userMovedMap = true;
    _fitRadius(_radiusCenter(), km);
    _reload();
  }

  void _showLocation(LocationChoice choice) {
    final bounds = choice.bounds;
    final point = choice.point;
    if (point != null && _radius.km != null) {
      _fitRadius(LatLng(point.lat, point.lon), _radius.km!);
    } else if (point == null) {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: polandBounds,
          padding: const EdgeInsets.all(16),
        ),
      );
    } else if (bounds != null) {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds(
            LatLng(bounds.south, bounds.west),
            LatLng(bounds.north, bounds.east),
          ),
          padding: const EdgeInsets.all(24),
          maxZoom: 16,
        ),
      );
    } else {
      _mapController.move(
        LatLng(point.lat, point.lon),
        choice.isDevice ? 14 : 16,
      );
    }
    _reload();
  }

  Future<void> _openLocationPicker() async {
    final choice = await Navigator.of(context).push<LocationChoice>(
      MaterialPageRoute<LocationChoice>(
        builder: (_) => LocationPickerPage(
          api: widget.api,
          locationService: widget.locationService,
          recent: _recentLocations,
        ),
      ),
    );
    if (!mounted || choice == null) return;
    _userMovedMap = true;
    _setLocation(choice);
    _showLocation(choice);
  }

  void _setSpotSheetExpanded(bool expanded) {
    if (!_sheetController.isAttached) return;
    _sheetController.animateTo(
      expanded ? _sheetMax : _sheetMin,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  // --- adding a place

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// "+": the form starts where the user is ("Moja lokalizacja") or at the centre of the map.
  Future<void> _openAddPlace() async {
    final camera = _mapController.camera;
    final point = _location.point;
    final start = _location.isDevice && point != null
        ? point
        : LatLon(camera.center.latitude, camera.center.longitude);
    final added = await Navigator.of(context).push<AddedPlace>(
      MaterialPageRoute<AddedPlace>(
        builder: (_) => AddPlacePage(
          api: widget.api,
          auth: widget.auth,
          locationService: widget.locationService,
          initialCenter: start,
          // Zoomed out over the whole country the pin would be meaningless: start closer.
          initialZoom: math.max(camera.zoom, 15),
          showMapTiles: widget.showMapTiles,
        ),
      ),
    );
    if (added == null || !mounted) return;
    final place = added.place;
    _toast(
      added.photoError == null
          ? 'Dodano: ${place.name}'
          : 'Dodano: ${place.name}. ${added.photoError}',
    );
    _mapController.move(
      LatLng(place.location.lat, place.location.lon),
      math.max(camera.zoom, 16),
    );
    await _reload();
    if (mounted) _openDetails(PlaceSummary.fromPlace(place));
  }

  // --- header & filters

  void _showOptions<T>({
    required String title,
    required List<T> options,
    required T value,
    required String Function(T) label,
    required ValueChanged<T> onSelected,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              for (final option in options)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    option == value
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    color: option == value
                        ? AppColors.primary
                        : AppColors.inactiveText,
                  ),
                  title: Text(label(option)),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    onSelected(option);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    bool chevron = true,
  }) {
    final foreground = active ? AppColors.white : AppColors.activeText;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active ? AppColors.primary : AppColors.chip,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 14, color: foreground),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1,
                    color: foreground,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                if (chevron) ...<Widget>[
                  const SizedBox(width: 5),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: foreground,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  int get _extraFilterCount =>
      (_openNow ? 1 : 0) +
      (_powerOutlets ? 1 : 0) +
      (_atmosphere != null ? 1 : 0);

  List<Widget> _filterChips() => <Widget>[
    _filterChip(
      icon: Icons.star_border_rounded,
      label: _rating.label,
      active: _rating != _RatingFilter.any,
      onTap: () => _showOptions<_RatingFilter>(
        title: 'Oceny',
        options: _RatingFilter.values,
        value: _rating,
        label: (r) =>
            r == _RatingFilter.any ? 'Wszystkie' : '${r.label} gwiazdki',
        onSelected: (r) => _setFilter(() => _rating = r),
      ),
    ),
    _filterChip(
      icon: Icons.wifi_rounded,
      label: 'Wi-Fi',
      active: _wifi,
      chevron: false,
      onTap: () => _setFilter(() => _wifi = !_wifi),
    ),
    _filterChip(
      icon: Icons.swap_vert_rounded,
      label: _sort?.label ?? 'Sortuj',
      active: _sort != null,
      onTap: () => _showOptions<PlaceSort?>(
        title: 'Sortuj',
        options: const <PlaceSort?>[
          null,
          PlaceSort.distance,
          PlaceSort.newest,
          PlaceSort.name,
        ],
        value: _sort,
        label: (s) => s?.label ?? 'Najwyżej oceniane',
        onSelected: (s) => _setFilter(() => _sort = s),
      ),
    ),
    _filterChip(
      icon: Icons.payments_outlined,
      label: _price.label,
      active: _price != _PriceFilter.any,
      onTap: () => _showOptions<_PriceFilter>(
        title: 'Ceny',
        options: _PriceFilter.values,
        value: _price,
        label: (p) => p == _PriceFilter.any ? 'Wszystkie' : p.label,
        onSelected: (p) => _setFilter(() => _price = p),
      ),
    ),
    _filterChip(
      icon: Icons.tune_rounded,
      label: _extraFilterCount == 0
          ? 'Filtruj'
          : 'Filtruj ($_extraFilterCount)',
      chevron: false,
      active: _filtersOpen || _extraFilterCount > 0,
      onTap: () => setState(() => _filtersOpen = !_filtersOpen),
    ),
  ];

  Widget _toggle(String label, bool selected, VoidCallback onTap, {Key? key}) {
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: FilterChip(
        key: key,
        label: Text(label, style: const TextStyle(fontSize: 12)),
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

  Widget _moreFilters() {
    return Padding(
      padding: const EdgeInsets.only(top: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            children: <Widget>[
              _toggle(
                'Otwarte teraz',
                _openNow,
                () => _setFilter(() => _openNow = !_openNow),
                key: const ValueKey<String>('filter-open-now'),
              ),
              _toggle(
                'Gniazdka',
                _powerOutlets,
                () => _setFilter(() => _powerOutlets = !_powerOutlets),
              ),
              for (final atmosphere in Atmosphere.values)
                _toggle(
                  atmosphere.label,
                  _atmosphere == atmosphere,
                  () => _setFilter(
                    () => _atmosphere = _atmosphere == atmosphere
                        ? null
                        : atmosphere,
                  ),
                ),
            ],
          ),
          Row(
            children: <Widget>[
              const Icon(
                Icons.info_outline_rounded,
                size: 15,
                color: AppColors.infoText,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  'Możesz łączyć kilka filtrów',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.greyText,
                  ),
                ),
              ),
              if (_hasAnyFilter)
                TextButton(
                  onPressed: _clearFilters,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Wyczyść', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  bool get _hasAnyFilter =>
      _rating != _RatingFilter.any ||
      _wifi ||
      _sort != null ||
      _radius != _RadiusFilter.none ||
      _price != _PriceFilter.any ||
      _extraFilterCount > 0 ||
      _searchController.text.isNotEmpty;

  void _clearFilters() {
    _searchController.clear();
    _setFilter(() {
      _rating = _RatingFilter.any;
      _wifi = false;
      _sort = null;
      _radius = _RadiusFilter.none;
      _price = _PriceFilter.any;
      _openNow = false;
      _powerOutlets = false;
      _atmosphere = null;
    });
  }

  Future<void> _openSearch() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final query = await Navigator.of(context).push<String>(
      PageRouteBuilder<String>(
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (_, _, _) => SearchPage(
          initial: _searchController.text,
          recent: _recentSearches,
        ),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
    if (!mounted || query == null) return; // back = keep the current search
    _searchController.text = query;
    if (query.isNotEmpty) {
      _recentSearches
        ..remove(query)
        ..insert(0, query);
      if (_recentSearches.length > 6) _recentSearches.removeLast();
    }
    _setFilter(() {});
  }

  Widget _header() {
    final locationLabel = _location == LocationChoice.wholeCountry
        ? 'Lokalizacja'
        : _location.label;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        children: <Widget>[
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(22),
            ),
            child: TextField(
              key: const ValueKey<String>('place-search'),
              controller: _searchController,
              textAlignVertical: TextAlignVertical.center,
              // Typing happens on the search screen: no keyboard over the map.
              readOnly: true,
              showCursor: false,
              enableInteractiveSelection: false,
              onTap: _openSearch,
              decoration: InputDecoration(
                hintText: 'Szukaj miejscówki',
                hintStyle: const TextStyle(
                  color: AppColors.hintText,
                  fontSize: 13,
                ),
                prefixIcon: const Icon(Icons.search_rounded, size: 19),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 44,
                  minHeight: 42,
                ),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Wyczyść',
                        iconSize: 17,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _searchController.clear();
                          _setFilter(() {});
                        },
                      ),
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 44,
                  minHeight: 42,
                ),
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Material(
                    color: AppColors.transparent,
                    child: InkWell(
                      key: const ValueKey<String>('location-picker-trigger'),
                      onTap: _openLocationPicker,
                      borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(22),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 13, right: 8),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              _location.isDevice
                                  ? Icons.my_location_rounded
                                  : Icons.location_on_outlined,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                locationLabel,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Container(width: 1, height: 25, color: AppColors.controlBorder),
                Material(
                  color: AppColors.transparent,
                  child: InkWell(
                    key: const ValueKey<String>('radius-picker-trigger'),
                    onTap: () => _showOptions<_RadiusFilter>(
                      title: 'Promień wyszukiwania',
                      options: _RadiusFilter.values,
                      value: _radius,
                      label: (radius) => radius == _RadiusFilter.none
                          ? 'Bez ograniczenia'
                          : radius.label,
                      onSelected: _selectRadius,
                    ),
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(22),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            _radius.km == null ? 'Promień' : '${_radius.km} km',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 17,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 32,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(children: _filterChips()),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 220),
            crossFadeState: _filtersOpen
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: _moreFilters(),
            secondChild: const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ),
    );
  }

  // --- map

  Widget _map() {
    final selected = _places.where((PlaceSummary p) => p.id == _selectedId);
    final ordered = <PlaceSummary>[
      ..._places.where((PlaceSummary p) => p.id != _selectedId),
      ...selected, // drawn last = on top
    ];
    final point = _location.point;
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCameraFit: CameraFit.bounds(
          bounds: polandBounds,
          padding: const EdgeInsets.all(16),
        ),
        minZoom: 4,
        maxZoom: 19,
        backgroundColor: AppColors.mapBackground,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onMapReady: () {
          // initialCameraFit isn't applied yet at this point: without this the first search
          // would use flutter_map's default camera (Kyiv).
          _mapController.fitCamera(
            CameraFit.bounds(
              bounds: polandBounds,
              padding: const EdgeInsets.all(16),
            ),
          );
          _mapReady = true;
          _reload();
          if (widget.locateOnStart) _locateOnStart();
        },
        onPositionChanged: (MapCamera camera, bool hasGesture) {
          if (hasGesture) {
            _userMovedMap = true;
            _reloadSoon();
          }
        },
        onTap: (_, _) {
          if (_selectedId != null) setState(() => _selectedId = null);
        },
      ),
      children: <Widget>[
        if (widget.showMapTiles)
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'pl.hackyeah.miejscowki',
            maxZoom: 19,
          ),
        if (_radius.km case final km?)
          Builder(
            // Rebuilt with the camera: without a location the circle follows the map centre.
            builder: (BuildContext context) {
              final camera = MapCamera.of(context);
              return CircleLayer(
                circles: <CircleMarker>[
                  CircleMarker(
                    point: point != null
                        ? LatLng(point.lat, point.lon)
                        : camera.center,
                    radius: km * 1000,
                    useRadiusInMeter: true,
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderColor: AppColors.primary,
                    borderStrokeWidth: 2,
                  ),
                ],
              );
            },
          ),
        if (point != null)
          MarkerLayer(
            markers: <Marker>[
              Marker(
                point: LatLng(point.lat, point.lon),
                width: 22,
                height: 22,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.mapMarker,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.white, width: 3),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(color: AppColors.shadow, blurRadius: 6),
                    ],
                  ),
                ),
              ),
            ],
          ),
        MarkerLayer(
          markers: <Marker>[
            for (final place in ordered)
              Marker(
                key: ValueKey<String>('marker-${place.id}'),
                point: LatLng(place.location.lat, place.location.lon),
                width: 64,
                height: 30,
                child: GestureDetector(
                  onTap: () => setState(() => _selectedId = place.id),
                  child: Center(
                    child: MapMarker(
                      rating: place.rating.average,
                      selected: place.id == _selectedId,
                    ),
                  ),
                ),
              ),
          ],
        ),
        SimpleAttributionWidget(
          source: const Text('OpenStreetMap contributors'),
          alignment: Alignment.topRight,
          backgroundColor: AppColors.white.withValues(alpha: 0.75),
        ),
      ],
    );
  }

  Widget _mapButtons(double bottom) {
    Widget button(IconData icon, String tooltip, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: AppColors.white,
        elevation: 2,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Tooltip(
            message: tooltip,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Icon(icon, size: 20),
            ),
          ),
        ),
      ),
    );
    return Positioned(
      right: 16,
      bottom: bottom,
      child: Column(
        children: <Widget>[
          if (_location.point != null)
            button(
              Icons.my_location_rounded,
              'Wróć do: ${_location.label}',
              () => _showLocation(_location),
            ),
        ],
      ),
    );
  }

  // --- list

  String get _listSubtitle {
    if (_loading && _places.isEmpty) return 'Szukam miejscówek…';
    final shown = _places.length < _total
        ? ' (pokazano ${_places.length})'
        : '';
    final where = _radius.km != null
        ? 'w promieniu ${_radius.km} km'
        : _sort == PlaceSort.distance
        ? 'w pobliżu'
        : 'na mapie';
    return '${fmt.placesCount(_total)} $where$shown';
  }

  Widget _listContent() {
    if (_error != null && _places.isEmpty) {
      return MessageView(
        icon: Icons.cloud_off_rounded,
        title: 'Nie udało się wczytać miejsc',
        message: _error,
        onRetry: _reload,
      );
    }
    if (!_loading && _places.isEmpty) {
      return MessageView(
        icon: Icons.search_off_rounded,
        title: 'Brak miejscówek w tym obszarze',
        message: _hasAnyFilter
            ? 'Zmień filtry albo przesuń mapę.'
            : 'Oddal lub przesuń mapę, żeby zobaczyć więcej.',
        onRetry: _hasAnyFilter ? _clearFilters : null,
      );
    }
    return Column(
      children: <Widget>[
        for (final place in _places)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SpotListTile(
              key: ValueKey<String>('spot-${place.id}'),
              place: place,
              distanceM: _distanceTo(place),
              onTap: () => _openDetails(place),
            ),
          ),
        if (_places.length < _total)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Przybliż mapę, żeby zobaczyć resztę miejsc.',
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ),
      ],
    );
  }

  Widget _spotSheet() {
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: _sheetMin,
      minChildSize: _sheetMin,
      maxChildSize: _sheetMax,
      snap: true,
      snapSizes: const <double>[_sheetMin, _sheetMax],
      builder: (BuildContext context, ScrollController scrollController) =>
          NotificationListener<DraggableScrollableNotification>(
            onNotification: (DraggableScrollableNotification notification) {
              final expanded = notification.extent > 0.42;
              if (expanded != _sheetExpanded) {
                setState(() => _sheetExpanded = expanded);
              }
              return false;
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: const BoxDecoration(
                color: AppColors.sheet,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: AppColors.sheetShadow,
                    blurRadius: 12,
                    offset: Offset(0, -2),
                  ),
                ],
              ),
              child: Stack(
                children: <Widget>[
                  ListView(
                    controller: scrollController,
                    scrollCacheExtent: const ScrollCacheExtent.pixels(1600),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 92),
                    children: <Widget>[
                      const SizedBox(height: 22),
                      Row(
                        children: <Widget>[
                          const Expanded(
                            child: Text(
                              'Miejscówki',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: AppColors.ink,
                              ),
                            ),
                          ),
                          if (_loading)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Text(
                        _listSubtitle,
                        key: const ValueKey<String>('places-count'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.muted,
                        ),
                      ),
                      if (_sheetExpanded) ...<Widget>[
                        const SizedBox(height: 18),
                        _listContent(),
                      ],
                    ],
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 44,
                    child: GestureDetector(
                      key: const ValueKey<String>('spot-sheet-handle'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _setSpotSheetExpanded(!_sheetExpanded),
                      onVerticalDragEnd: (DragEndDetails details) {
                        final velocity = details.primaryVelocity ?? 0;
                        if (velocity < -80) {
                          _setSpotSheetExpanded(true);
                        } else if (velocity > 80) {
                          _setSpotSheetExpanded(false);
                        } else {
                          _setSpotSheetExpanded(!_sheetExpanded);
                        }
                      },
                      child: Center(
                        child: Container(
                          width: 46,
                          height: 4,
                          decoration: BoxDecoration(
                            color: AppColors.loading,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: Material(
                      color: AppColors.accent,
                      shape: const CircleBorder(),
                      child: InkWell(
                        key: const ValueKey<String>('add-place'),
                        customBorder: const CircleBorder(),
                        onTap: _openAddPlace,
                        child: const Padding(
                          padding: EdgeInsets.all(14),
                          child: Icon(Icons.add_rounded, size: 25),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _places
        .where((PlaceSummary p) => p.id == _selectedId)
        .firstOrNull;
    return Scaffold(
      body: SafeArea(
        top: false,
        bottom: false,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final sheetTop = constraints.maxHeight * _sheetMin;
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: _sheetExpanded ? 0 : 1,
                  child: IgnorePointer(ignoring: _sheetExpanded, child: _map()),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(top: true, bottom: false, child: _header()),
                ),
                if (!_sheetExpanded && _error != null && _places.isNotEmpty)
                  Positioned(
                    top: 190,
                    left: 16,
                    right: 16,
                    child: Material(
                      color: AppColors.closed,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            color: AppColors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                _mapButtons(sheetTop + (selected != null ? 172 : 16)),
                if (selected != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: sheetTop + 10,
                    child: _PlacePreviewCard(
                      place: selected,
                      distanceM: _distanceTo(selected),
                      travelTimes: switch ((
                        widget.travelTimes,
                        _location.point,
                      )) {
                        (final service?, final origin?) => TravelTimesLine(
                          service: service,
                          from: origin,
                          to: selected.location,
                          fontSize: 11,
                        ),
                        _ => null,
                      },
                      onTap: () => _openDetails(selected),
                      onClose: () => setState(() => _selectedId = null),
                    ),
                  ),
                _spotSheet(),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Floating card above the list after tapping a pin.
class _PlacePreviewCard extends StatelessWidget {
  const _PlacePreviewCard({
    required this.place,
    required this.onTap,
    required this.onClose,
    this.distanceM,
    this.travelTimes,
  });

  final PlaceSummary place;
  final double? distanceM;
  final Widget? travelTimes;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey<String>('place-preview'),
      color: AppColors.white,
      elevation: 6,
      shadowColor: AppColors.shadow,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: <Widget>[
              PlaceImage(
                url: place.thumbnailUrl,
                width: 96,
                height: 96,
                radius: 14,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      place.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    RatingLine(rating: place.rating),
                    const SizedBox(height: 4),
                    Text(
                      [
                        place.address.short,
                        if (distanceM != null) fmt.distance(distanceM!),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.muted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    OpenStatusLine(place: place, fontSize: 11),
                    if (travelTimes case final line?) ...<Widget>[
                      const SizedBox(height: 4),
                      line,
                    ],
                    const SizedBox(height: 6),
                    const Text(
                      'Zobacz szczegóły ›',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Zamknij',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SpotListTile extends StatelessWidget {
  const SpotListTile({
    required this.place,
    required this.onTap,
    this.distanceM,
    super.key,
  });

  final PlaceSummary place;
  final double? distanceM;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final price = fmt.priceLabel(place.priceRange, place.usagePrice);
    final atmosphere = place.atmosphere;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Stack(
              children: <Widget>[
                PlaceImage(url: place.thumbnailUrl, width: 126, height: 126),
                if (atmosphere != null)
                  Positioned(
                    left: 8,
                    bottom: 8,
                    child: Pill(
                      atmosphere.label,
                      color: AppColors.placeMarker,
                      textColor: AppColors.white,
                    ),
                  ),
                if (place.photoCount > 1)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.imageOverlay,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(
                            Icons.photo_library_outlined,
                            size: 10,
                            color: AppColors.white,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '${place.photoCount}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 7, right: 3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      place.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: AppColors.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    RatingLine(rating: place.rating),
                    const SizedBox(height: 3),
                    Row(
                      children: <Widget>[
                        const Icon(
                          Icons.location_on_outlined,
                          size: 12,
                          color: AppColors.muted,
                        ),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            [
                              place.address.short,
                              if (distanceM != null) fmt.distance(distanceM!),
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    OpenStatusLine(place: place),
                    const SizedBox(height: 6),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: AmenityBadges(amenities: place.amenities),
                        ),
                        if (price != null) ...<Widget>[
                          const SizedBox(width: 6),
                          Pill(price),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
