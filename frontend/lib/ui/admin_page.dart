import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/places_api.dart';
import '../auth/auth.dart';
import 'format.dart' as fmt;
import 'place_details_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// Admin only: places added by users wait here until someone approves (publishes) or rejects them.
class AdminPage extends StatefulWidget {
  const AdminPage({required this.api, required this.auth, super.key});

  final PlacesApi api;
  final AuthController auth;

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  static const int _pageSize = 30;

  final _searchController = TextEditingController();
  Timer? _searchDebounce;

  bool _showApproved = false; // false = "Oczekujące"
  List<Place> _places = const <Place>[];
  int _total = 0;
  int? _pendingTotal; // badge on the "Oczekujące" tab, also while the other tab is open
  bool _loading = false;
  String? _error;
  int _requestId = 0;
  final Set<String> _busy =
      <String>{}; // places with an approve / reject request in flight

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<String?> _token() async {
    final token = widget.auth.token;
    if (token == null) {
      setState(() {
        _loading = false;
        _error = 'Sesja wygasła. Zaloguj się ponownie.';
      });
    }
    return token;
  }

  Future<void> _reload({bool more = false}) async {
    final token = await _token();
    if (token == null) return;
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.adminPlaces(
        approved: _showApproved,
        text: _searchController.text,
        token: token,
        limit: _pageSize,
        skip: more ? _places.length : 0,
      );
      if (!mounted || id != _requestId) return;
      setState(() {
        _places = more ? <Place>[..._places, ...page.items] : page.items;
        _total = page.total;
        if (!_showApproved && _searchController.text.trim().isEmpty) {
          _pendingTotal = page.total;
        }
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || id != _requestId) return;
      if (e.statusCode == 401) await widget.auth.invalidate();
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  void _selectTab(bool approved) {
    if (approved == _showApproved) return;
    setState(() {
      _showApproved = approved;
      _places = const <Place>[];
      _total = 0;
    });
    _reload();
  }

  void _onSearchChanged(String _) {
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), _reload);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Runs [action] for one place and takes it off the current list when it succeeds;
  /// [pendingChange] moves the "Oczekujące" counter.
  Future<void> _act(
    Place place,
    Future<void> Function(String token) action,
    String done, {
    int pendingChange = -1,
  }) async {
    final token = await _token();
    if (token == null) return;
    setState(() => _busy.add(place.id));
    try {
      await action(token);
      if (!mounted) return;
      setState(() {
        _places = _places.where((Place p) => p.id != place.id).toList();
        _total = math.max(0, _total - 1);
        if (_pendingTotal case final pending?) {
          _pendingTotal = math.max(0, pending + pendingChange);
        }
      });
      _toast(done);
    } on ApiException catch (e) {
      if (e.statusCode == 401) await widget.auth.invalidate();
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy.remove(place.id));
    }
  }

  Future<void> _approve(Place place) => _act(
    place,
    (token) => widget.api.setApproval(place.id, approved: true, token: token),
    'Zaakceptowano: ${place.name}',
  );

  Future<void> _hide(Place place) => _act(
    place,
    (token) => widget.api.setApproval(place.id, approved: false, token: token),
    'Ukryto: ${place.name}. Czeka teraz w „Oczekujących”.',
    pendingChange: 1,
  );

  Future<void> _reject(Place place) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Odrzucić miejsce?'),
        content: Text(
          '„${place.name}” zostanie usunięte razem ze zdjęciami. Tego nie da się cofnąć.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Anuluj'),
          ),
          TextButton(
            key: const ValueKey<String>('admin-reject-confirm'),
            style: TextButton.styleFrom(foregroundColor: AppColors.closed),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Odrzuć'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _act(
      place,
      (token) => widget.api.deletePlace(place.id, token: token),
      'Odrzucono: ${place.name}',
    );
  }

  Future<void> _openDetails(Place place) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlaceDetailsPage(
          api: widget.api,
          auth: widget.auth,
          summary: PlaceSummary.fromPlace(place),
        ),
      ),
    );
  }

  // --- UI

  Widget _tab(String label, bool approved, {int? count}) {
    final active = approved == _showApproved;
    final foreground = active ? AppColors.white : AppColors.activeText;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active ? AppColors.primary : AppColors.chip,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: ValueKey<String>(
            approved ? 'admin-tab-approved' : 'admin-tab-pending',
          ),
          onTap: () => _selectTab(approved),
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Text(
              count == null ? label : '$label ($count)',
              style: TextStyle(
                fontSize: 12,
                height: 1,
                color: foreground,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchField() {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: AppColors.field,
        borderRadius: BorderRadius.circular(22),
      ),
      child: TextField(
        key: const ValueKey<String>('admin-search'),
        controller: _searchController,
        onChanged: _onSearchChanged,
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          hintText: 'Szukaj po nazwie lub ulicy',
          hintStyle: const TextStyle(color: AppColors.hintText, fontSize: 13),
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
                    _onSearchChanged('');
                  },
                ),
          isDense: true,
          contentPadding: EdgeInsets.zero,
          border: InputBorder.none,
        ),
      ),
    );
  }

  Widget _content() {
    if (_error != null && _places.isEmpty) {
      return MessageView(
        icon: Icons.cloud_off_rounded,
        title: 'Nie udało się wczytać miejsc',
        message: _error,
        onRetry: widget.auth.isLoggedIn ? _reload : null,
      );
    }
    if (_places.isEmpty) {
      if (_loading) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      final searching = _searchController.text.trim().isNotEmpty;
      return MessageView(
        icon: _showApproved || searching
            ? Icons.search_off_rounded
            : Icons.task_alt_rounded,
        title: searching
            ? 'Nic nie znaleziono'
            : _showApproved
            ? 'Brak zaakceptowanych miejsc'
            : 'Wszystko sprawdzone',
        message: searching || _showApproved
            ? null
            : 'Nowe miejsca od użytkowników pojawią się tutaj.',
      );
    }
    return Column(
      children: <Widget>[
        for (final place in _places)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _AdminPlaceTile(
              key: ValueKey<String>('admin-place-${place.id}'),
              place: place,
              busy: _busy.contains(place.id),
              onTap: () => _openDetails(place),
              onApprove: _showApproved ? null : () => _approve(place),
              onReject: _showApproved ? null : () => _reject(place),
              onHide: _showApproved ? () => _hide(place) : null,
            ),
          ),
        if (_places.length < _total)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : OutlinePill(
                    label: 'Pokaż więcej (${_total - _places.length})',
                    onPressed: () => _reload(more: true),
                  ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: AppColors.transparent,
        elevation: 0,
        leading: const BackChevron(),
        title: const Text(
          'Panel admina',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Odśwież',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _reload,
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.primary,
          onRefresh: _reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: <Widget>[
              _searchField(),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  _tab('Oczekujące', false, count: _pendingTotal),
                  _tab('Zaakceptowane', true),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _showApproved
                    ? '${fmt.placesCount(_total)} publicznie widocznych'
                    : 'Nowe miejsca widzi tylko autor, dopóki ich nie zaakceptujesz.',
                key: const ValueKey<String>('admin-count'),
                style: const TextStyle(fontSize: 12, color: AppColors.muted),
              ),
              const SizedBox(height: 14),
              _content(),
            ],
          ),
        ),
      ),
    );
  }
}

/// One place on the admin list: what was added, by when, and the decision buttons.
class _AdminPlaceTile extends StatelessWidget {
  const _AdminPlaceTile({
    required this.place,
    required this.busy,
    required this.onTap,
    this.onApprove,
    this.onReject,
    this.onHide,
    super.key,
  });

  final Place place;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onHide;

  @override
  Widget build(BuildContext context) {
    final summary = PlaceSummary.fromPlace(place);
    final atmosphere = place.atmosphere;
    final createdAt = place.createdAt;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.only(bottom: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                PlaceImage(
                  url: summary.thumbnailUrl,
                  width: 96,
                  height: 96,
                  radius: 14,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          place.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: AppColors.ink,
                          ),
                        ),
                        const SizedBox(height: 4),
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
                                place.address.short,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppColors.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (createdAt != null) ...<Widget>[
                          const SizedBox(height: 3),
                          Text(
                            'Dodano ${fmt.date(createdAt.toLocal())}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: <Widget>[
                            if (place.photos.isNotEmpty)
                              Pill(
                                '${place.photos.length} zdj.',
                                icon: Icons.photo_library_outlined,
                              ),
                            if (atmosphere != null) Pill(atmosphere.label),
                            if (place.isMock) const Pill('Demo'),
                          ],
                        ),
                        const SizedBox(height: 6),
                        AmenityBadges(amenities: place.amenities),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                if (busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else ...<Widget>[
                  if (onReject != null)
                    OutlinedButton.icon(
                      key: ValueKey<String>('admin-reject-${place.id}'),
                      onPressed: onReject,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.closed,
                        side: const BorderSide(color: AppColors.divider),
                        shape: const StadiumBorder(),
                      ),
                      icon: const Icon(Icons.close_rounded, size: 17),
                      label: const Text('Odrzuć'),
                    ),
                  if (onHide != null)
                    OutlinedButton.icon(
                      key: ValueKey<String>('admin-hide-${place.id}'),
                      onPressed: onHide,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.ink,
                        side: const BorderSide(color: AppColors.divider),
                        shape: const StadiumBorder(),
                      ),
                      icon: const Icon(Icons.visibility_off_outlined, size: 17),
                      label: const Text('Ukryj'),
                    ),
                  if (onApprove != null) ...<Widget>[
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      key: ValueKey<String>('admin-approve-${place.id}'),
                      onPressed: onApprove,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: AppColors.white,
                        shape: const StadiumBorder(),
                      ),
                      icon: const Icon(Icons.check_rounded, size: 17),
                      label: const Text('Akceptuj'),
                    ),
                  ],
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
