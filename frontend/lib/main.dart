import 'package:flutter/material.dart';

void main() => runApp(const MiejscowkiApp());

class MiejscowkiApp extends StatelessWidget {
  const MiejscowkiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Miejscówki',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF20252B)),
        scaffoldBackgroundColor: Colors.white,
        fontFamily: 'Arial',
      ),
      home: const MapHomePage(),
    );
  }
}

class MapHomePage extends StatefulWidget {
  const MapHomePage({super.key});

  @override
  State<MapHomePage> createState() => _MapHomePageState();
}

class _MapHomePageState extends State<MapHomePage> {
  final _searchController = TextEditingController();
  final _sheetController = DraggableScrollableController();

  String _rating = 'Oceny';
  bool _isWifiActive = false;
  String _sort = 'Sortuj';
  String _price = 'Ceny';
  String _location = 'Lokalizacja';
  String _radius = '+ 0 km';
  bool _filtersOpen = false;
  bool _sheetExpanded = false;
  final List<String> _filterOrder = <String>[
    'rating',
    'wifi',
    'sort',
    'price',
    'filter',
  ];
  final List<String> _spots = <String>[
    'Miejscówka nad rzeką',
    'Polana pod lasem',
  ];

  @override
  void dispose() {
    _searchController.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  void _showFilterMenu({
    required String title,
    required List<String> options,
    required String value,
    required ValueChanged<String> onSelected,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
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
              ...options.map(
                (String option) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    option == value
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    color: option == value
                        ? const Color(0xFF20252B)
                        : const Color(0xFF8A8A8A),
                  ),
                  title: Text(option),
                  onTap: () {
                    onSelected(option);
                    Navigator.of(sheetContext).pop();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAddSpotSheet() async {
    final name = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (BuildContext context) => const AddPlacePage(),
      ),
    );
    if (!mounted || name == null || name.trim().isEmpty) return;
    setState(() => _spots.insert(0, name.trim()));
    if (_sheetController.isAttached) {
      _sheetController.animateTo(
        0.94,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _setSpotSheetExpanded(bool expanded) {
    if (!_sheetController.isAttached) return;
    _sheetController.animateTo(
      expanded ? 0.94 : 0.26,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _openLocationPicker() async {
    final selectedLocation = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (BuildContext context) => const LocationPickerPage(),
      ),
    );
    if (!mounted || selectedLocation == null) return;
    setState(() => _location = selectedLocation);
  }

  Widget _filterChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    bool chevron = true,
  }) {
    final foreground = active ? Colors.white : const Color(0xFF222222);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active ? const Color(0xFF20252B) : const Color(0xFFE2E2E2),
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

  Widget _filterForId(String id) {
    switch (id) {
      case 'rating':
        return _filterChip(
          icon: Icons.star_border_rounded,
          label: _rating,
          active: _rating != 'Oceny',
          onTap: () => _showFilterMenu(
            title: 'Oceny',
            options: <String>[
              'Oceny',
              '5 gwiazdek',
              '4+ gwiazdki',
              '3+ gwiazdki',
            ],
            value: _rating,
            onSelected: (String selected) => setState(() => _rating = selected),
          ),
        );
      case 'wifi':
        return _filterChip(
          icon: Icons.wifi_rounded,
          label: 'Wi-Fi',
          chevron: false,
          active: _isWifiActive,
          onTap: () => setState(() => _isWifiActive = !_isWifiActive),
        );
      case 'sort':
        return _filterChip(
          icon: Icons.swap_vert_rounded,
          label: _sort,
          active: _sort != 'Sortuj',
          onTap: () => _showFilterMenu(
            title: 'Sortuj',
            options: <String>[
              'Sortuj',
              'Najbliżej',
              'Najwyżej oceniane',
              'Najnowsze',
            ],
            value: _sort,
            onSelected: (String selected) => setState(() => _sort = selected),
          ),
        );
      case 'price':
        return _filterChip(
          icon: Icons.payments_outlined,
          label: _price,
          active: _price != 'Ceny',
          onTap: () => _showFilterMenu(
            title: 'Ceny',
            options: <String>['Ceny', 'Bezpłatne', 'Do 30 zł', 'Powyżej 30 zł'],
            value: _price,
            onSelected: (String selected) => setState(() => _price = selected),
          ),
        );
      case 'filter':
        return _filterChip(
          icon: Icons.tune_rounded,
          label: 'Filtruj',
          chevron: false,
          active: _filtersOpen,
          onTap: () => setState(() => _filtersOpen = !_filtersOpen),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(17, 10, 17, 0),
      child: Column(
        children: <Widget>[
          Container(
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFDADADA),
              borderRadius: BorderRadius.circular(22),
            ),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              textAlignVertical: TextAlignVertical.center,
              decoration: const InputDecoration(
                hintText: 'Szukaj miejscówki',
                hintStyle: TextStyle(color: Color(0xFF7A7A7A), fontSize: 13),
                prefixIcon: Icon(Icons.search_rounded, size: 19),
                prefixIconConstraints: BoxConstraints(
                  minWidth: 44,
                  minHeight: 36,
                ),
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFDADADA),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  flex: 4,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: const ValueKey<String>('location-picker-trigger'),
                      onTap: _openLocationPicker,
                      borderRadius: BorderRadius.circular(22),
                      child: Row(
                        children: <Widget>[
                          const Icon(Icons.location_on_outlined, size: 18),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _location,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Container(width: 1, height: 24, color: const Color(0xFF858585)),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: const ValueKey<String>('radius-picker-trigger'),
                      onTap: () => _showFilterMenu(
                        title: 'Promień',
                        options: <String>[
                          '+ 0 km',
                          '+ 1 km',
                          '+ 5 km',
                          '+ 10 km',
                          '+ 25 km',
                        ],
                        value: _radius,
                        onSelected: (String radius) =>
                            setState(() => _radius = radius),
                      ),
                      borderRadius: BorderRadius.circular(18),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              _radius,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF222222),
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(width: 3),
                          const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 18,
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
              child: Row(children: _filterOrder.map(_filterForId).toList()),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 220),
            crossFadeState: _filtersOpen
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.only(top: 9),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.info_outline_rounded,
                    size: 15,
                    color: Color(0xFF656565),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'Możesz łączyć kilka filtrów',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            secondChild: const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ),
    );
  }

  Widget _map() {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const CustomPaint(painter: MapPainter()),
        const Positioned(
          left: 42,
          top: 112,
          child: MapMarker(label: '4.8', color: Color(0xFF232A31)),
        ),
        const Positioned(
          right: 52,
          top: 245,
          child: MapMarker(label: '4.5', color: Color(0xFF385B4C)),
        ),
        const Positioned(
          left: 76,
          bottom: 138,
          child: MapMarker(label: '3.9', color: Color(0xFF765843)),
        ),
        Center(
          child: IgnorePointer(
            child: Text(
              'MAPA',
              style: TextStyle(
                fontSize: 42,
                letterSpacing: 1.5,
                color: Color(0xFF111111),
              ),
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 116,
          child: Material(
            color: Colors.white,
            elevation: 2,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Centrowanie na Twojej lokalizacji'),
                ),
              ),
              child: const Padding(
                padding: EdgeInsets.all(13),
                child: Icon(Icons.my_location_rounded, size: 20),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _spotSheet() {
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: 0.26,
      minChildSize: 0.26,
      maxChildSize: 0.94,
      snap: true,
      snapSizes: const <double>[0.26, 0.94],
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
              decoration: BoxDecoration(
                color: _sheetExpanded
                    ? const Color(0xFFFFFEFA)
                    : const Color(0xFFFFFCF5),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x19000000),
                    blurRadius: 12,
                    offset: Offset(0, -2),
                  ),
                ],
              ),
              child: Stack(
                children: <Widget>[
                  ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 92),
                    children: <Widget>[
                      const SizedBox(height: 22),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 0),
                        child: Text(
                          'Miejscówki',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF191919),
                          ),
                        ),
                      ),
                      const SizedBox(height: 7),
                      if (_sheetExpanded) ...<Widget>[
                        const Text(
                          '32 miejsca',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF777777),
                          ),
                        ),
                        const SizedBox(height: 18),
                        ..._spots.asMap().entries.map(
                          (MapEntry<int, String> entry) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: SpotListTile(
                              name: entry.value,
                              index: entry.key,
                              onTap: () => Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (BuildContext context) =>
                                      SpotDetailsPage(
                                        name: entry.value,
                                        index: entry.key,
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ] else
                        const SizedBox(height: 600),
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
                            color: const Color(0xFFE6DCCB),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    right: 16,
                    top: _sheetExpanded ? null : 10,
                    bottom: _sheetExpanded ? 16 : null,
                    child: Material(
                      color: const Color(0xFFFFC66F),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _showAddSpotSheet,
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
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            _header(),
            Expanded(child: Stack(children: <Widget>[_map(), _spotSheet()])),
          ],
        ),
      ),
    );
  }
}

class AddPlacePage extends StatefulWidget {
  const AddPlacePage({super.key});

  @override
  State<AddPlacePage> createState() => _AddPlacePageState();
}

class _AddPlacePageState extends State<AddPlacePage> {
  static const Color _pageColor = Color(0xFFFFFCF4);
  static const Color _fieldColor = Color(0xFFF5EFDF);
  static const Color _accentColor = Color(0xFFFF8B55);

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final Set<String> _amenities = <String>{};

  String _category = 'Wybierz kategorię';
  String _hours = 'Całe';
  String _atmosphere = 'Spokojnie';
  String _price = '0–20 zł';
  bool _photoAdded = false;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _pickValue({
    required String title,
    required List<String> values,
    required String selected,
    required ValueChanged<String> onSelected,
  }) async {
    final value = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ...values.map(
              (String value) => ListTile(
                leading: Icon(
                  value == selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: value == selected
                      ? _accentColor
                      : const Color(0xFF999999),
                ),
                title: Text(value),
                onTap: () => Navigator.of(context).pop(value),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (value != null) onSelected(value);
  }

  Widget _textField({
    required String label,
    required TextEditingController controller,
    String? hint,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(fontSize: 9, color: Color(0xFF555555)),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            maxLines: maxLines,
            decoration: InputDecoration(
              hintText: hint,
              filled: true,
              fillColor: _fieldColor,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 11,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _choiceField({
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(fontSize: 9, color: Color(0xFF555555)),
          ),
          const SizedBox(height: 4),
          Material(
            color: _fieldColor,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(9),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 11,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        value,
                        style: TextStyle(
                          fontSize: 12,
                          color: value.startsWith('Wybierz')
                              ? const Color(0xFF969696)
                              : const Color(0xFF333333),
                        ),
                      ),
                    ),
                    const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectPill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 5, bottom: 5),
      child: Material(
        color: selected ? const Color(0xFFFFB14D) : _fieldColor,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: selected ? Colors.white : const Color(0xFF555555),
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _amenity(String label) {
    final selected = _amenities.contains(label);
    return InkWell(
      onTap: () => setState(() {
        if (selected) {
          _amenities.remove(label);
        } else {
          _amenities.add(label);
        }
      }),
      child: SizedBox(
        width: 148,
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: selected,
                activeColor: _accentColor,
                side: const BorderSide(color: _accentColor),
                onChanged: (_) => setState(() {
                  if (selected) {
                    _amenities.remove(label);
                  } else {
                    _amenities.add(label);
                  }
                }),
              ),
            ),
            const SizedBox(width: 4),
            Flexible(child: Text(label, style: const TextStyle(fontSize: 10))),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Wpisz nazwę miejscówki')));
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _pageColor,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 5, 12, 22),
          children: <Widget>[
            Row(
              children: <Widget>[
                IconButton(
                  key: const ValueKey<String>('add-place-back'),
                  tooltip: 'Wróć',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 36,
                  ),
                  icon: const Icon(Icons.chevron_left_rounded, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Text(
                  'Dodaj miejsce',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ],
            ),
            const SizedBox(height: 3),
            GestureDetector(
              onTap: () => setState(() => _photoAdded = true),
              child: SizedBox(
                height: 94,
                child: CustomPaint(
                  painter: DashedRoundedBorderPainter(),
                  child: Center(
                    child: _photoAdded
                        ? const Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.check_circle_rounded,
                                color: _accentColor,
                                size: 29,
                              ),
                              SizedBox(height: 5),
                              Text(
                                'Zdjęcie dodane',
                                style: TextStyle(fontSize: 10),
                              ),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Container(
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  color: _accentColor,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Icon(
                                  Icons.image_outlined,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: _accentColor,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  '+  Dodaj zdjęcia',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _textField(label: 'Nazwa', controller: _nameController),
            _textField(label: 'Adres', controller: _addressController),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: 150,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    const CustomPaint(painter: MapPainter()),
                    const Center(
                      child: Icon(
                        Icons.location_on_rounded,
                        color: _accentColor,
                        size: 31,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            _choiceField(
              label: 'Kategoria',
              value: _category,
              onTap: () => _pickValue(
                title: 'Kategoria',
                values: <String>['Park', 'Punkt widokowy', 'Plaża', 'Inne'],
                selected: _category,
                onSelected: (String value) => setState(() => _category = value),
              ),
            ),
            _choiceField(
              label: 'Godziny otwarcia',
              value: _hours,
              onTap: () => _pickValue(
                title: 'Godziny otwarcia',
                values: <String>[
                  'Całe',
                  '6:00–18:00',
                  '9:00–20:00',
                  'Całą dobę',
                ],
                selected: _hours,
                onSelected: (String value) => setState(() => _hours = value),
              ),
            ),
            const Text(
              'Atmosfera',
              style: TextStyle(fontSize: 9, color: Color(0xFF555555)),
            ),
            const SizedBox(height: 4),
            Wrap(
              children: <Widget>[
                _selectPill(
                  label: 'Spokojnie',
                  selected: _atmosphere == 'Spokojnie',
                  onTap: () => setState(() => _atmosphere = 'Spokojnie'),
                ),
                _selectPill(
                  label: 'Na pogaduchy',
                  selected: _atmosphere == 'Na pogaduchy',
                  onTap: () => setState(() => _atmosphere = 'Na pogaduchy'),
                ),
                _selectPill(
                  label: 'Gwarno',
                  selected: _atmosphere == 'Gwarno',
                  onTap: () => setState(() => _atmosphere = 'Gwarno'),
                ),
              ],
            ),
            const SizedBox(height: 2),
            const Text(
              'Cena',
              style: TextStyle(fontSize: 9, color: Color(0xFF555555)),
            ),
            const SizedBox(height: 4),
            Wrap(
              children: <Widget>[
                for (final price in <String>['0–20 zł', '20–40 zł', '40–60 zł'])
                  _selectPill(
                    label: price,
                    selected: _price == price,
                    onTap: () => setState(() => _price = price),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            const Text(
              'Udogodnienia',
              style: TextStyle(fontSize: 9, color: Color(0xFF555555)),
            ),
            const SizedBox(height: 3),
            Wrap(
              children: <Widget>[
                _amenity('Wi-Fi'),
                _amenity('Toaleta'),
                _amenity('Gniazdka'),
                _amenity('Gastronomia'),
                _amenity('Klima'),
                _amenity('Dostęp do komputera'),
              ],
            ),
            _textField(
              label: 'Dodatkowe udogodnienia',
              controller: _notesController,
              maxLines: 2,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey<String>('add-place-submit'),
                onPressed: _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: _accentColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 21,
                    vertical: 9,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: const Text('Opublikuj', style: TextStyle(fontSize: 10)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DashedRoundedBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFE6DCCB)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)),
      );
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + 5).clamp(0, metric.length).toDouble();
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += 9;
      }
    }
  }

  @override
  bool shouldRepaint(covariant DashedRoundedBorderPainter oldDelegate) => false;
}

class LocationPickerPage extends StatefulWidget {
  const LocationPickerPage({super.key});

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  final TextEditingController _locationController = TextEditingController();
  final List<String> _suggestions = <String>[
    'Gdańsk, Wrzeszcz',
    'Gdańsk, Oliwa',
    'Sopot',
    'Gdynia',
  ];

  @override
  void dispose() {
    _locationController.dispose();
    super.dispose();
  }

  void _selectLocation(String location) {
    Navigator.of(context).pop(location);
  }

  @override
  Widget build(BuildContext context) {
    final query = _locationController.text.trim().toLowerCase();
    final locations = _suggestions
        .where((String location) => location.toLowerCase().contains(query))
        .toList();

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
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
              controller: _locationController,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Wpisz miasto lub adres',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _locationController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _locationController.clear();
                          setState(() {});
                        },
                      ),
                filled: true,
                fillColor: const Color(0xFFE7E7E7),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Material(
              color: const Color(0xFFF1F1F1),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => _selectLocation('Moja lokalizacja'),
                child: const Padding(
                  padding: EdgeInsets.all(15),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.my_location_rounded, color: Color(0xFF20252B)),
                      SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Użyj mojej lokalizacji',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Znajdź miejscówki w pobliżu',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF777777),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Ostatnio wybrane',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 7),
            if (locations.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text(
                  'Brak pasujących lokalizacji',
                  style: TextStyle(color: Color(0xFF777777)),
                ),
              )
            else
              ...locations.map(
                (String location) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.location_on_outlined),
                  title: Text(location),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _selectLocation(location),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class MapMarker extends StatelessWidget {
  const MapMarker({required this.label, required this.color, super.key});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(15),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x28000000),
            blurRadius: 5,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.star_rounded, color: Colors.white, size: 12),
            const SizedBox(width: 3),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SpotListTile extends StatelessWidget {
  const SpotListTile({
    required this.name,
    required this.index,
    this.onTap,
    super.key,
  });

  final String name;
  final int index;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool isOpen = index.isEven;
    final String reviewCount = index.isEven ? '217' : '47';
    final String place = index.isEven ? 'Gdańsk, Wrzeszcz' : 'Gdańsk, Oliwa';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFFD7D7D7))),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 108,
                height: 108,
                decoration: BoxDecoration(
                  color: const Color(0xFFD9D9D9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.landscape_outlined,
                  size: 30,
                  color: Color(0xFFB5B5B5),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 7, right: 3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: Color(0xFF111111),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: <Widget>[
                          ...List<Widget>.generate(
                            5,
                            (int _) => const Icon(
                              Icons.star_rounded,
                              size: 12,
                              color: Color(0xFF111111),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            '($reviewCount)',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF777777),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: <Widget>[
                          const Icon(
                            Icons.location_on_outlined,
                            size: 12,
                            color: Color(0xFF777777),
                          ),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(
                              place,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Color(0xFF777777),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: <Widget>[
                          Text(
                            isOpen ? 'Otwarte teraz' : 'Zamknięte',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: isOpen
                                  ? const Color(0xFF2C7A45)
                                  : const Color(0xFFB53131),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            isOpen ? 'do 20:00' : 'do 9:00',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF777777),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: <Widget>[
                          const Icon(
                            Icons.wifi_rounded,
                            size: 13,
                            color: Color(0xFF4E4E4E),
                          ),
                          const SizedBox(width: 3),
                          const Text(
                            'Wi-Fi',
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFF4E4E4E),
                            ),
                          ),
                          const SizedBox(width: 11),
                          const Icon(
                            Icons.power_rounded,
                            size: 13,
                            color: Color(0xFF4E4E4E),
                          ),
                          const SizedBox(width: 3),
                          const Text(
                            'Gniazdka',
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFF4E4E4E),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SpotDetailsPage extends StatelessWidget {
  const SpotDetailsPage({required this.name, required this.index, super.key});

  final String name;
  final int index;

  static const Color pageColor = Color(0xFFFFFCF4);
  static const Color accentColor = Color(0xFFFF8B55);

  Widget _ratingRow() {
    return Row(
      children: <Widget>[
        ...List<Widget>.generate(
          5,
          (int star) => Icon(
            star == 4 ? Icons.star_border_rounded : Icons.star_rounded,
            color: accentColor,
            size: 17,
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          '(217)',
          style: TextStyle(fontSize: 11, color: Color(0xFF777777)),
        ),
      ],
    );
  }

  Widget _detailLine(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 14, color: const Color(0xFF777777)),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(fontSize: 11, color: Color(0xFF555555)),
          ),
        ],
      ),
    );
  }

  Widget _benefit(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: <Widget>[
          const Icon(Icons.check_rounded, size: 15, color: Color(0xFF62B36A)),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(fontSize: 11, color: Color(0xFF444444)),
          ),
        ],
      ),
    );
  }

  Widget _review(String author, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE1DDD4))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const CircleAvatar(
                radius: 11,
                backgroundColor: Color(0xFFE9E3D7),
                child: Icon(Icons.person, size: 13, color: Color(0xFFAAA092)),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  author,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Text(
                '★★★★☆',
                style: TextStyle(fontSize: 11, color: accentColor),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            text,
            style: const TextStyle(fontSize: 10, color: Color(0xFF555555)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool open = index.isEven;
    final String place = index.isEven ? 'Gdańsk, Wrzeszcz' : 'Gdańsk, Oliwa';

    return Scaffold(
      backgroundColor: pageColor,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 28),
          children: <Widget>[
            Row(
              children: <Widget>[
                IconButton(
                  key: const ValueKey<String>('spot-details-back'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 36,
                  ),
                  icon: const Icon(Icons.chevron_left_rounded, size: 23),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Text(
                  'Miejscówka',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            Stack(
              children: <Widget>[
                Container(
                  height: 205,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD9D9D9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(
                    Icons.local_library_outlined,
                    size: 72,
                    color: Color(0xFFB4B0A7),
                  ),
                ),
                Positioned(
                  left: 8,
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: accentColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'Gwarno',
                      style: TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 17),
            Text(
              name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            _ratingRow(),
            const SizedBox(height: 9),
            _detailLine(Icons.location_on_outlined, place),
            _detailLine(Icons.payments_outlined, '0–20 zł'),
            Row(
              children: <Widget>[
                Text(
                  open ? 'Otwarte teraz' : 'Zamknięte',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: open
                        ? const Color(0xFF2C9A51)
                        : const Color(0xFFB53131),
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  open ? 'do 23:00' : 'do 9:00',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF777777),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            const Divider(color: Color(0xFFE1DDD4), height: 1),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 6),
              title: const Text(
                'Godziny otwarcia',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              children: const <Widget>[
                _HoursRow(day: 'Poniedziałek', hours: '8:00 – 17:00'),
                _HoursRow(day: 'Wtorek', hours: '8:00 – 17:00'),
                _HoursRow(day: 'Środa', hours: '8:00 – 17:00'),
                _HoursRow(day: 'Czwartek', hours: '8:00 – 17:00'),
                _HoursRow(day: 'Piątek', hours: '8:00 – 17:00'),
                _HoursRow(day: 'Sobota', hours: 'Nieczynne'),
                _HoursRow(day: 'Niedziela', hours: 'Nieczynne'),
              ],
            ),
            const Divider(color: Color(0xFFE1DDD4), height: 1),
            const SizedBox(height: 13),
            const Text(
              'Udogodnienia',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 9),
            _benefit('Gastronomia'),
            _benefit('Dostęp do komputera'),
            _benefit('Toaleta'),
            _benefit('Klima'),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                const Icon(
                  Icons.wifi_rounded,
                  size: 14,
                  color: Color(0xFF555555),
                ),
                const SizedBox(width: 5),
                const Text(
                  'Wi-Fi',
                  style: TextStyle(fontSize: 11, color: Color(0xFF555555)),
                ),
                const SizedBox(width: 14),
                const Icon(
                  Icons.power_rounded,
                  size: 14,
                  color: Color(0xFF555555),
                ),
                const SizedBox(width: 5),
                const Text(
                  'Gniazdka',
                  style: TextStyle(fontSize: 11, color: Color(0xFF555555)),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Opinie',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: () {},
                  child: const Text(
                    'Dodaj opinię',
                    style: TextStyle(fontSize: 10, color: Color(0xFF555555)),
                  ),
                ),
              ],
            ),
            _review('Karolina', 'Dobre miejsce do nauki.'),
            _review('Marcin', 'Spokojnie i wygodnie.'),
          ],
        ),
      ),
    );
  }
}

class _HoursRow extends StatelessWidget {
  const _HoursRow({required this.day, required this.hours});

  final String day;
  final String hours;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              day,
              style: const TextStyle(fontSize: 10, color: Color(0xFF666666)),
            ),
          ),
          Text(
            hours,
            style: const TextStyle(fontSize: 10, color: Color(0xFF666666)),
          ),
        ],
      ),
    );
  }
}

class MapPainter extends CustomPainter {
  const MapPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFF8F8F7),
    );

    final riverPaint = Paint()..color = const Color(0xFFE7EEF0);
    final river = Path()
      ..moveTo(size.width * .72, -20)
      ..cubicTo(
        size.width * .55,
        size.height * .18,
        size.width * .92,
        size.height * .30,
        size.width * .69,
        size.height * .47,
      )
      ..cubicTo(
        size.width * .53,
        size.height * .59,
        size.width * .74,
        size.height * .76,
        size.width * .58,
        size.height + 20,
      )
      ..lineTo(size.width * .92, size.height + 20)
      ..lineTo(size.width * .95, -20)
      ..close();
    canvas.drawPath(river, riverPaint);

    final minorRoad = Paint()
      ..color = const Color(0xFFD5D4CF)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final roads = <List<Offset>>[
      <Offset>[
        Offset(-20, size.height * .18),
        Offset(size.width * .35, size.height * .27),
        Offset(size.width + 20, size.height * .13),
      ],
      <Offset>[
        Offset(-20, size.height * .67),
        Offset(size.width * .25, size.height * .56),
        Offset(size.width + 20, size.height * .70),
      ],
      <Offset>[
        Offset(size.width * .14, -20),
        Offset(size.width * .28, size.height * .35),
        Offset(size.width * .20, size.height + 20),
      ],
      <Offset>[
        Offset(size.width * .48, -20),
        Offset(size.width * .44, size.height * .30),
        Offset(size.width * .24, size.height + 20),
      ],
      <Offset>[
        Offset(size.width * .92, -20),
        Offset(size.width * .73, size.height * .26),
        Offset(size.width * .81, size.height + 20),
      ],
    ];
    for (final points in roads) {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (var i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      canvas.drawPath(path, minorRoad);
    }

    final mainRoad = Paint()
      ..color = const Color(0xFFBDBCB6)
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke;
    final diagonal = Path()
      ..moveTo(-20, size.height * .42)
      ..cubicTo(
        size.width * .3,
        size.height * .25,
        size.width * .65,
        size.height * .65,
        size.width + 20,
        size.height * .48,
      );
    canvas.drawPath(diagonal, mainRoad);

    final park = Paint()..color = const Color(0xFFE7EBDD);
    canvas.drawOval(
      Rect.fromLTWH(
        size.width * .06,
        size.height * .22,
        size.width * .24,
        size.height * .22,
      ),
      park,
    );
    canvas.drawOval(
      Rect.fromLTWH(
        size.width * .34,
        size.height * .64,
        size.width * .28,
        size.height * .20,
      ),
      park,
    );

    final dot = Paint()..color = const Color(0xFFC5C7C0);
    for (var i = 0; i < 14; i++) {
      final x = ((i * 73) % 100) / 100 * size.width;
      final y = ((i * 47 + 12) % 100) / 100 * size.height;
      canvas.drawCircle(Offset(x, y), 1.5, dot);
    }
  }

  @override
  bool shouldRepaint(covariant MapPainter oldDelegate) => false;
}
