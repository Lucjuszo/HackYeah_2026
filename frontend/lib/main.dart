import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'api/models.dart';
import 'api/places_api.dart';
import 'auth/auth.dart';
import 'services/location_service.dart';
import 'services/travel_time_service.dart';
import 'ui/add_place_page.dart';
import 'ui/admin_page.dart';
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
    this.tileProvider,
    this.travelTimes,
    this.locateOnStart = true,
    super.key,
  });

  final PlacesApi api;
  final AuthController auth;
  final LocationService locationService;

  /// Off in widget tests: tiles come from tile.openstreetmap.org.
  final bool showMapTiles;

  /// Where the main map's tiles come from; null = tile.openstreetmap.org (tests use fake images).
  final TileProvider? tileProvider;

  /// Walk / bike / car times to a place; null hides them (tests: no network).
  final TravelTimeService? travelTimes;

  /// Start at the device position if the user allows it, else the whole of Poland.
  final bool locateOnStart;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Focus Map',
      theme: buildTheme(),
      home: MapHomePage(
        api: api,
        auth: auth,
        locationService: locationService,
        showMapTiles: showMapTiles,
        tileProvider: tileProvider,
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
    this.tileProvider,
    this.travelTimes,
    this.locateOnStart = true,
    super.key,
  });

  final PlacesApi api;
  final AuthController auth;
  final LocationService locationService;
  final bool showMapTiles;
  final TileProvider? tileProvider;
  final TravelTimeService? travelTimes;
  final bool locateOnStart;

  @override
  State<MapHomePage> createState() => _MapHomePageState();
}

class _CityTiles extends NetworkTileProvider {
  @override
  ImageProvider getImageWithCancelLoadingSupport(
    TileCoordinates tile,
    TileLayer options,
    Future<void> cancelLoading,
  ) {
    if (tile.z == 14 &&
        tile.x >= 9097 &&
        tile.x <= 9102 &&
        tile.y >= 5550 &&
        tile.y <= 5554) {
      return AssetImage('assets/krakow/${tile.x}-${tile.y}.webp');
    }
    return super.getImageWithCancelLoadingSupport(tile, options, cancelLoading);
  }
}

class _MapHomePageState extends State<MapHomePage> {
  static const double _sheetMin = 0.36;
  static const _krakow = LatLng(50.0568, 19.945);
  // Keep the search, location and filter controls visible above the expanded list.
  static const double _sheetMax = 0.78;

  final _searchController = TextEditingController();
  Timer? _intentTimer;
  void _prefetch(PlaceSummary place, bool active) {
    _intentTimer?.cancel();
    if (active)
      _intentTimer = Timer(const Duration(milliseconds: 180), () async {
        try {
          await widget.api.prefetchPlace(place.id, token: widget.auth.token);
        } on ApiException {
          /* Explicit opening offers retry. */
        }
      });
  }

  final _sheetController = DraggableScrollableController();
  final _mapController = MapController();
  late final _tiles = widget.tileProvider ?? _CityTiles();
  final _reloadTiles = StreamController<void>.broadcast();

  // Filters
  _RatingFilter _rating = _RatingFilter.any;
  bool _wifi = false;
  PlaceSort? _sort; // null = best rated first
  _RadiusFilter _radius = _RadiusFilter.none;
  _PriceFilter _price = _PriceFilter.any;
  bool _openNow = false;
  bool _powerOutlets = false;
  Atmosphere? _atmosphere;

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
  final _recentPages = <String, Page<PlaceSummary>>{};
  final _fetching = <String, Future<Page<PlaceSummary>>>{};
  bool _mapReady = false;
  bool _initialFitDone = false;
  Size? _searchedMapSize; // map size of the last search; a new size shows a different area
  Timer? _reloadDebounce;
  String? _selectedId;

  /// The user moved the map or picked a place: a late GPS fix must not move the camera.
  bool _userMovedMap = false;

  /// Logged-in admins get the "Panel admina" button.
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    widget.auth.restore();
    _refreshUser();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.locationService.requestPermission());
    });
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _intentTimer?.cancel();
    _searchController.dispose();
    _sheetController.dispose();
    _mapController.dispose();
    _reloadTiles.close();
    super.dispose();
  }

  // --- searching

  /// Phones and browsers may report a zero-sized screen for the first frame(s): a camera
  /// without a real size has no meaningful visible area to search or fit.
  bool get _mapHasSize {
    final size = _mapController.camera.nonRotatedSize;
    return size.width > 0 && size.height > 0 && size.isFinite;
  }

  void _fitPoland() {
    _mapController.fitCamera(
      CameraFit.bounds(bounds: polandBounds, padding: const EdgeInsets.all(16)),
    );
  }

  /// Once, as soon as the map knows its size: initialCameraFit isn't applied yet when the map
  /// is ready, so without this the first search would use flutter_map's default camera (Kyiv).
  void _fitInitialCamera() {
    if (_initialFitDone || !_mapHasSize) return;
    _initialFitDone = true;
    if (!_userMovedMap) {
      // The device position may have arrived while the size was still unknown.
      if (_location.point == null) {
        _mapController.move(_krakow, 14.4);
      } else {
        _showLocation(_location);
      }
    }
    // flutter_map loads tiles only on map events, which at start may carry an older camera:
    // the tiles of the final view would stay blank until the user moved the map.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reloadTiles.add(null);
    });
  }

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
    if (!_mapReady || !_mapHasSize) return;
    _reloadDebounce?.cancel();
    _searchedMapSize = _mapController.camera.nonRotatedSize;
    final id = ++_requestId;
    final query = _query();
    final key = query.toQueryParameters().toString();
    final cached = _recentPages[key];
    setState(() {
      _loading = true;
      if (cached != null) {
        _places = cached.items;
        _total = cached.total;
      }
      _error = null;
    });
    try {
      final page = await _fetching.putIfAbsent(
        key,
        () => widget.api.searchPlaces(query).whenComplete(() {
          _fetching.remove(key);
        }),
      );
      _recentPages.remove(key);
      _recentPages[key] = page;
      if (_recentPages.length > 24)
        _recentPages.remove(_recentPages.keys.first);
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

  /// Who is logged in may change on any page that asks for a login.
  Future<void> _refreshUser() async {
    final user = await widget.auth.currentUser();
    if (mounted && (user?.isAdmin ?? false) != _isAdmin) {
      setState(() => _isAdmin = user?.isAdmin ?? false);
    }
  }

  Future<void> _openAdmin() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AdminPage(api: widget.api, auth: widget.auth),
      ),
    );
    // Approved places show up on the map.
    if (!mounted) return;
    _refreshUser();
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
    if (!mounted) return;
    _refreshUser();
    _reload();
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
      _fitPoland();
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
    if (_sheetController.isAttached &&
        MediaQuery.disableAnimationsOf(context)) {
      _sheetController.jumpTo(expanded ? _sheetMax : _sheetMin);
      return;
    }
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
    if (!mounted) return;
    _refreshUser();
    if (added == null) return;
    final place = added.place;
    if (!place.approved) {
      // Not on the map until an admin approves it.
      _toast(
        [
          'Dzięki! „${place.name}” pojawi się na mapie po akceptacji administratora.',
          ?added.photoError,
        ].join(' '),
      );
      return;
    }
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
    final foreground = active ? AppColors.white : AppColors.ink;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active ? AppColors.ink : AppColors.chip,
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
      active: _extraFilterCount > 0,
      onTap: _showMoreFilters,
    ),
  ];

  Widget _toggle(
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

  void _showMoreFilters() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (BuildContext sheetContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          void update(VoidCallback change) {
            _setFilter(change);
            setSheetState(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Filtry miejsc',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      children: <Widget>[
                        _toggle(
                          'Otwarte teraz',
                          _openNow,
                          () => update(() => _openNow = !_openNow),
                          icon: Icons.schedule_rounded,
                          key: const ValueKey<String>('filter-open-now'),
                        ),
                        _toggle(
                          'Gniazdka',
                          _powerOutlets,
                          () => update(() => _powerOutlets = !_powerOutlets),
                          icon: Icons.power_rounded,
                        ),
                      ],
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 12, bottom: 8),
                      child: Text(
                        'Atmosfera',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Wrap(
                      children: [
                        for (final atmosphere in Atmosphere.values)
                          _toggle(
                            atmosphere.label,
                            _atmosphere == atmosphere,
                            () => update(
                              () => _atmosphere = _atmosphere == atmosphere
                                  ? null
                                  : atmosphere,
                            ),
                            icon: Icons.graphic_eq_rounded,
                          ),
                      ],
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 12, bottom: 8),
                      child: Text(
                        'Wyszukiwanie',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Wrap(
                      runSpacing: 6,
                      children: [
                        ..._filterChips().take(4),
                        _filterChip(
                          icon: Icons.radar,
                          label: _radius.km == null ? 'Promień' : _radius.label,
                          onTap: () => _showOptions<_RadiusFilter>(
                            title: 'Promień wyszukiwania',
                            options: _RadiusFilter.values,
                            value: _radius,
                            label: (r) => r == _RadiusFilter.none
                                ? 'Bez ograniczenia'
                                : r.label,
                            onSelected: _selectRadius,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        FilledButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.ink,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Pokaż miejsca'),
                        ),
                        const Spacer(),
                        if (_hasAnyFilter)
                          TextButton(
                            onPressed: () {
                              _clearFilters();
                              setSheetState(() {});
                            },
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            child: const Text(
                              'Wyczyść',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
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
    _searchController.text = query.trim();
    if (query.isNotEmpty) {
      _recentSearches
        ..remove(query)
        ..insert(0, query);
      if (_recentSearches.length > 6) _recentSearches.removeLast();
    }
    _setFilter(() {});
  }

  Widget _brandBar(bool wide) {
    final location = _location == LocationChoice.wholeCountry
        ? (!_userMovedMap ? 'Kraków' : 'Obszar mapy')
        : _location.label;
    return Material(
      color: AppColors.background,
      child: Container(
        height: wide ? 76 : 56,
        padding: EdgeInsets.symmetric(horizontal: wide ? 28 : 16),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        child: Row(
          children: [
            SvgPicture.asset(
              'assets/focus_map_logo.svg',
              width: wide ? 94 : 74,
              semanticsLabel: 'Focus Map',
            ),
            const Spacer(),
            TextButton.icon(
              key: const ValueKey('location-picker-trigger'),
              onPressed: _openLocationPicker,
              icon: const Icon(Icons.place_outlined, size: 18),
              label: Text(location),
            ),
            const SizedBox(width: 8),
            if (wide)
              OutlinedButton.icon(
                key: const ValueKey('add-place'),
                onPressed: _openAddPlace,
                icon: const Icon(Icons.add, size: 17),
                label: const Text('Dodaj miejsce'),
              )
            else
              IconButton.outlined(
                key: const ValueKey('add-place'),
                onPressed: _openAddPlace,
                tooltip: 'Dodaj miejsce',
                icon: const Icon(Icons.add, size: 19),
              ),
            if (_isAdmin)
              IconButton(
                key: const ValueKey('open-admin'),
                tooltip: 'Panel admina',
                onPressed: _openAdmin,
                icon: const Icon(Icons.admin_panel_settings_outlined),
              ),
          ],
        ),
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: AppColors.field,
          borderRadius: BorderRadius.circular(14),
          child: ListTile(
            key: const ValueKey('place-search'),
            dense: true,
            minTileHeight: 46,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            leading: const Tooltip(
              message: 'Szukaj · Ctrl / ⌘ + K',
              child: Icon(Icons.search_rounded),
            ),
            onTap: _openSearch,
            title: Text(
              _searchController.text.isEmpty
                  ? 'Gdzie chcesz popracować?'
                  : _searchController.text,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
            trailing: _searchController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Wyczyść',
                    icon: const Icon(Icons.close),
                    onPressed: () => _setFilter(_searchController.clear),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip(
                      icon: Icons.volume_down_outlined,
                      label: 'Cicho',
                      active: _atmosphere == Atmosphere.quiet,
                      chevron: false,
                      onTap: () => _setFilter(
                        () => _atmosphere = _atmosphere == Atmosphere.quiet
                            ? null
                            : Atmosphere.quiet,
                      ),
                    ),
                    _filterChip(
                      icon: Icons.power_outlined,
                      label: 'Gniazdka',
                      active: _powerOutlets,
                      chevron: false,
                      onTap: () =>
                          _setFilter(() => _powerOutlets = !_powerOutlets),
                    ),
                    _filterChip(
                      icon: Icons.schedule,
                      label: 'Otwarte',
                      active: _openNow,
                      chevron: false,
                      onTap: () => _setFilter(() => _openNow = !_openNow),
                    ),
                  ],
                ),
              ),
            ),
            IconButton.filledTonal(
              tooltip: 'Wszystkie filtry',
              onPressed: _showMoreFilters,
              icon: const Icon(Icons.tune, size: 18),
            ),
          ],
        ),
      ],
    ),
  );
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
        // Roughly Poland until the size is known; then _fitInitialCamera. (No initialCameraFit:
        // flutter_map applies it after the size arrives, over the device position chosen meanwhile.)
        initialCenter: _krakow,
        initialZoom: 14.4,
        minZoom: 4,
        maxZoom: 19,
        backgroundColor: AppColors.mapBackground,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onMapReady: () {
          _mapReady = true;
          _fitInitialCamera();
          _reload(); // waits for onMapEvent below if the size isn't known yet
          if (widget.locateOnStart) _locateOnStart();
        },
        onMapEvent: (MapEvent event) {
          // The real size arrived after start (or the window was resized / rotated):
          // the visible area changed without any gesture, so search it.
          if (event is! MapEventNonRotatedSizeChange || !_mapReady) return;
          _fitInitialCamera();
          if (_mapController.camera.nonRotatedSize != _searchedMapSize) {
            _reloadSoon(const Duration(milliseconds: 150));
          }
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
            tileProvider: _tiles,
            reset: _reloadTiles.stream,
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
                width: place.id == _selectedId ? 212 : 68,
                height: 44,
                child: InkWell(
                  onTap: () => setState(() => _selectedId = place.id),
                  child: Center(
                    child: MapMarker(
                      label: place.name,
                      rating: place.rating.average,
                      selected: place.id == _selectedId,
                    ),
                  ),
                ),
              ),
          ],
        ),
        Align(
          alignment: Alignment.topRight,
          child: Material(
            color: AppColors.white.withValues(alpha: .9),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                '© OpenStreetMap · OpenMapTiles · OpenFreeMap',
                style: const TextStyle(fontSize: 10, color: AppColors.muted),
              ),
            ),
          ),
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
          for (final step in [1, -1])
            button(
              step > 0 ? Icons.add : Icons.remove,
              step > 0 ? 'Przybliż' : 'Oddal',
              () {
                final camera = _mapController.camera;
                _userMovedMap = true;
                _mapController.move(
                  camera.center,
                  (step > 0 ? camera.zoom.floor() + 1 : camera.zoom.ceil() - 1)
                      .clamp(4, 19)
                      .toDouble(),
                );
                _reloadSoon();
              },
            ),
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

  Widget _results({ScrollController? controller, bool mobile = false}) {
    final sorted = [..._places];
    final index = sorted.indexWhere((p) => p.id == _selectedId);
    if (index > 0) sorted.insert(0, sorted.removeAt(index));
    return ListView.builder(
      controller: controller,
      padding: EdgeInsets.fromLTRB(18, mobile ? 0 : 12, 18, 18),
      itemCount: 1 + (sorted.isEmpty ? 1 : sorted.length),
      itemBuilder: (context, i) {
        if (i == 0)
          return Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Miejsca w okolicy',
                  style: TextStyle(
                    fontSize: mobile ? 23 : 27,
                    letterSpacing: -1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _listSubtitle,
                  key: const ValueKey('places-count'),
                  style: const TextStyle(color: AppColors.muted, fontSize: 13),
                ),
                if (_error != null && sorted.isNotEmpty)
                  TextButton(
                    onPressed: _reload,
                    child: const Text('Widoczne są poprzednie wyniki · Ponów'),
                  ),
              ],
            ),
          );
        if (sorted.isEmpty) {
          if (_loading) return const _LoadingPlace();
          if (_error != null)
            return MessageView(
              icon: Icons.cloud_off_outlined,
              title: 'Nie udało się wczytać miejsc',
              message: _error,
              onRetry: _reload,
            );
          return MessageView(
            icon: Icons.search_off,
            title: 'Brak miejsc w tym obszarze',
            actionLabel: _hasAnyFilter ? 'Wyczyść filtry' : 'Oddal mapę',
            onRetry: _hasAnyFilter
                ? _clearFilters
                : () {
                    _mapController.move(
                      _mapController.camera.center,
                      math.max(4, _mapController.camera.zoom - 1),
                    );
                    _reload();
                  },
          );
        }
        final p = sorted[i - 1];
        return SpotListTile(
          key: ValueKey('spot-${p.id}'),
          place: p,
          selected: p.id == _selectedId,
          onIntent: (active) => _prefetch(p, active),
          distanceM: _distanceTo(p),
          onTap: () => _openDetails(p),
        );
      },
    );
  }

  Widget _spotSheet() => DraggableScrollableSheet(
    controller: _sheetController,
    initialChildSize: _sheetMin,
    minChildSize: _sheetMin,
    maxChildSize: _sheetMax,
    snap: true,
    snapSizes: const [_sheetMin, 0.52, _sheetMax],
    builder: (context, scroll) => Material(
      color: AppColors.background,
      elevation: 6,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            key: const ValueKey('spot-sheet-handle'),
            onTap: () => _setSpotSheetExpanded(_sheetController.size < 0.6),
            child: Tooltip(
              message: 'Rozwiń lub zwiń listę',
              child: SizedBox(
                width: double.infinity,
                height: 26,
                child: Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.sheetHandle,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: _results(controller: scroll, mobile: true)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyK, control: true):
          _openSearch,
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _openSearch,
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= 820;
              return Column(
                children: [
                  _brandBar(wide),
                  if (!wide) _header(),
                  Expanded(
                    child: Row(
                      children: [
                        if (wide)
                          SizedBox(
                            width: 400,
                            child: Column(
                              children: [
                                const SizedBox(height: 10),
                                _header(),
                                const Divider(height: 1),
                                Expanded(child: _results()),
                              ],
                            ),
                          ),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, area) => Stack(
                              children: [
                                Positioned.fill(child: _map()),
                                _mapButtons(
                                  wide ? 24 : area.maxHeight * _sheetMin + 16,
                                ),
                                if (!wide) _spotSheet(),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _LoadingPlace extends StatelessWidget {
  const _LoadingPlace();
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Wczytywanie miejsc',
    child: Row(
      children: [
        Container(
          width: 90,
          height: 94,
          decoration: BoxDecoration(
            color: AppColors.field,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final w in [150.0, 95.0, 120.0])
                Container(
                  width: w,
                  height: 10,
                  margin: const EdgeInsets.only(bottom: 8),
                  color: AppColors.field,
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class SpotListTile extends StatelessWidget {
  const SpotListTile({
    required this.place,
    required this.onTap,
    this.distanceM,
    this.selected = false,
    this.onIntent,
    super.key,
  });

  final bool selected;
  final ValueChanged<bool>? onIntent;
  final PlaceSummary place;
  final double? distanceM;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final price = fmt.priceLabel(place.priceRange, place.usagePrice);
    final atmosphere = place.atmosphere;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? AppColors.primary : AppColors.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onHover: onIntent,
          onFocusChange: onIntent,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                PlaceImage(
                  url: place.thumbnailUrl,
                  width: 86,
                  height: 102,
                  radius: 10,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              place.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                height: 1.2,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.4,
                              ),
                            ),
                          ),
                          if (place.rating.average != null) ...[
                            const SizedBox(width: 5),
                            const Icon(
                              Icons.star_rounded,
                              color: Color(0xffa34b20),
                              size: 15,
                            ),
                            Text(
                              fmt.decimal(place.rating.average!),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          place.address.short,
                          if (distanceM != null) fmt.distance(distanceM!),
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.muted,
                        ),
                      ),
                      const SizedBox(height: 5),
                      OpenStatusLine(place: place, fontSize: 12),
                      const SizedBox(height: 7),
                      Text(
                        [
                          if (atmosphere != null) atmosphere.label,
                          if (place.amenities.powerOutlets == true) 'Gniazdka',
                          if (place.amenities.wifi == true) 'Wi-Fi',
                          if (price != null) price,
                        ].join(' · '),
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: AppColors.ink,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
