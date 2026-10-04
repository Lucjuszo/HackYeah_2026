import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/places_api.dart';
import '../auth/auth.dart';
import '../services/travel_time_service.dart';
import 'format.dart' as fmt;
import 'login_sheet.dart';
import 'theme.dart';
import 'widgets.dart';

/// Everything about one place, read-only: photos, rating, hours, amenities, menu, opinions.
class PlaceDetailsPage extends StatefulWidget {
  const PlaceDetailsPage({
    required this.api,
    required this.auth,
    required this.summary,
    this.distanceM,
    this.travelTimes,
    this.origin,
    this.originLabel,
    super.key,
  });

  final PlacesApi api;
  final AuthController auth;

  /// Shown immediately while the full record loads.
  final PlaceSummary summary;
  final double? distanceM;

  /// Route times from [origin] (device position or the chosen city); hidden without both.
  final TravelTimeService? travelTimes;
  final LatLon? origin;

  /// Where [origin] is, shown when it isn't the device position.
  final String? originLabel;

  @override
  State<PlaceDetailsPage> createState() => _PlaceDetailsPageState();
}

class _PlaceDetailsPageState extends State<PlaceDetailsPage> {
  static const int _commentsPage = 10;

  Place? _place;
  String? _error;
  final List<Comment> _comments = <Comment>[];
  int _commentsTotal = 0;
  bool _commentsLoading = true;
  String? _commentsError;

  // Logged-in user's part: their rating, writing / editing / deleting opinions.
  CurrentUser? _me;
  int? _myScore;
  RatingSummary? _rating; // newer than the loaded place after the user rates
  bool _ratingBusy = false;
  final _commentController = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _loadPlace();
    _loadComments();
    _loadMine();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  String get _placeId => widget.summary.id;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// When logged in: who we are (own comments get "Edytuj/Usuń") and our current score.
  Future<void> _loadMine() async {
    final me = await widget.auth.currentUser();
    final token = widget.auth.token;
    if (me == null || token == null || !mounted) return;
    setState(() => _me = me);
    try {
      final score = await widget.api.myRating(_placeId, token: token);
      if (mounted) setState(() => _myScore = score);
    } on ApiException {
      // Not essential: the stars just start empty.
    }
  }

  /// Runs [action] with a token (asking to log in first); handles expired sessions and errors.
  Future<void> _withLogin(
    Future<void> Function(String token) action, {
    String? reason,
  }) async {
    final token = await requireLogin(context, widget.auth, reason: reason);
    if (token == null || !mounted) return;
    if (_me == null) await _loadMine();
    try {
      await action(token);
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        await widget.auth.invalidate();
        if (mounted) setState(() => _me = null);
      }
      _toast(e.message);
    }
  }

  /// Shows [setBusy] progress only while talking to the API (not while the login sheet is open).
  Future<void> _busy(
    void Function(bool) setBusy,
    Future<void> Function() call,
  ) async {
    setState(() => setBusy(true));
    try {
      await call();
    } finally {
      if (mounted) setState(() => setBusy(false));
    }
  }

  Future<void> _rate(int score) async {
    if (_ratingBusy) return;
    await _withLogin(
      (String token) => _busy((bool v) => _ratingBusy = v, () async {
        final summary = await widget.api.rate(_placeId, score, token: token);
        if (!mounted) return;
        setState(() {
          _rating = summary;
          _myScore = score;
        });
      }),
      reason: 'Zaloguj się, żeby ocenić to miejsce.',
    );
  }

  Future<void> _removeRating() async {
    if (_ratingBusy) return;
    await _withLogin(
      (String token) => _busy((bool v) => _ratingBusy = v, () async {
        final summary = await widget.api.deleteRating(_placeId, token: token);
        if (!mounted) return;
        setState(() {
          _rating = summary;
          _myScore = null;
        });
      }),
    );
  }

  Future<void> _postComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty || _posting) return;
    await _withLogin(
      (String token) => _busy((bool v) => _posting = v, () async {
        final comment = await widget.api.addComment(
          _placeId,
          text,
          token: token,
        );
        if (!mounted) return;
        _commentController.clear();
        FocusScope.of(context).unfocus();
        setState(() {
          _comments.insert(0, comment); // newest first, like the list
          _commentsTotal++;
        });
      }),
      reason: 'Zaloguj się, żeby dodać opinię.',
    );
  }

  Future<void> _editComment(Comment comment) async {
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      builder: (_) => _EditCommentSheet(initial: comment.text),
    );
    if (text == null || text == comment.text || !mounted) return;
    await _withLogin((String token) async {
      final updated = await widget.api.editComment(
        _placeId,
        comment.id,
        text,
        token: token,
      );
      if (!mounted) return;
      setState(() {
        final i = _comments.indexWhere((Comment c) => c.id == comment.id);
        if (i >= 0) _comments[i] = updated;
      });
    });
  }

  Future<void> _deleteComment(Comment comment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Usunąć opinię?'),
        content: const Text('Tej operacji nie można cofnąć.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Anuluj'),
          ),
          TextButton(
            key: const ValueKey<String>('confirm-delete'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              'Usuń',
              style: TextStyle(color: AppColors.closed),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _withLogin((String token) async {
      await widget.api.deleteComment(_placeId, comment.id, token: token);
      if (!mounted) return;
      setState(() {
        _comments.removeWhere((Comment c) => c.id == comment.id);
        _commentsTotal--;
      });
    });
  }

  Future<void> _loadPlace() async {
    setState(() => _error = null);
    try {
      final place = await widget.api.getPlace(widget.summary.id);
      if (mounted) setState(() => _place = place);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _loadComments() async {
    setState(() {
      _commentsLoading = true;
      _commentsError = null;
    });
    try {
      final page = await widget.api.getComments(
        widget.summary.id,
        limit: _commentsPage,
        skip: _comments.length,
      );
      if (!mounted) return;
      setState(() {
        _comments.addAll(page.items);
        _commentsTotal = page.total;
        _commentsLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _commentsLoading = false;
        _commentsError = e.message;
      });
    }
  }

  void _openPhoto(List<Photo> photos, int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerPage(photos: photos, initialIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    final place = _place;
    final photos = place?.photos ?? const <Photo>[];
    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: <Widget>[
          SliverAppBar(
            pinned: true,
            expandedHeight: 260,
            backgroundColor: AppColors.background,
            surfaceTintColor: AppColors.transparent,
            leading: Padding(
              padding: const EdgeInsets.all(8),
              child: CircleAvatar(
                backgroundColor: AppColors.surface,
                child: IconButton(
                  key: const ValueKey<String>('details-back'),
                  tooltip: 'Wróć',
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: AppColors.ink,
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: _PhotoHeader(
                photos: photos,
                fallbackUrl: summary.thumbnailUrl,
                onOpen: (int i) => _openPhoto(photos, i),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _header(summary, place),
                  if (_error != null)
                    MessageView(
                      icon: Icons.cloud_off_rounded,
                      title: 'Nie udało się wczytać szczegółów',
                      message: _error,
                      onRetry: _loadPlace,
                    )
                  else if (place == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else ...<Widget>[
                    _Section(
                      title: 'Udogodnienia',
                      child: _AmenitiesGrid(amenities: place.amenities),
                    ),
                    _Section(
                      title: 'Godziny otwarcia',
                      child: _OpeningHoursDisclosure(hours: place.openingHours),
                    ),
                    if (photos.length > 1)
                      _Section(
                        title: 'Zdjęcia (${photos.length})',
                        child: _PhotoStrip(
                          photos: photos,
                          onOpen: (int i) => _openPhoto(photos, i),
                        ),
                      ),
                    if (place.features.isNotEmpty)
                      _Section(
                        title: 'Wyróżnia się',
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: <Widget>[
                            for (final feature in place.features)
                              Chip(
                                label: Text(
                                  feature,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                visualDensity: VisualDensity.compact,
                                side: BorderSide.none,
                                backgroundColor: AppColors.chip,
                              ),
                          ],
                        ),
                      ),
                    if (place.menu.isNotEmpty)
                      _Section(
                        title: 'Menu',
                        child: _Menu(items: place.menu),
                      ),
                  ],
                  _Section(
                    title: _commentsTotal > 0
                        ? 'Opinie ($_commentsTotal)'
                        : 'Opinie',
                    child: _opinions(
                      _rating ?? place?.rating ?? summary.rating,
                    ),
                  ),
                  if (place?.isMock ?? summary.isMock)
                    const Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.info_outline_rounded,
                            size: 14,
                            color: AppColors.muted,
                          ),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Miejsce z danych demonstracyjnych: nazwa i adres są prawdziwe '
                              '(OpenStreetMap), część szczegółów przykładowa.',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(PlaceSummary summary, Place? place) {
    final price = fmt.priceLabel(
      place?.priceRange ?? summary.priceRange,
      place?.usagePrice ?? summary.usagePrice,
    );
    final atmosphere = place?.atmosphere ?? summary.atmosphere;
    final distance = widget.distanceM;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          summary.name,
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w700,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 8),
        RatingLine(
          rating: _rating ?? place?.rating ?? summary.rating,
          size: 15,
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            const Icon(
              Icons.location_on_outlined,
              size: 15,
              color: AppColors.muted,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                [
                  (place?.address ?? summary.address).short,
                  if (distance != null) fmt.distance(distance),
                ].join(' · '),
                style: const TextStyle(fontSize: 13, color: AppColors.muted),
              ),
            ),
          ],
        ),
        if ((widget.travelTimes, widget.origin)
            case (final service?, final origin?)) ...<Widget>[
          const SizedBox(height: 6),
          TravelTimesLine(
            service: service,
            from: origin,
            to: summary.location,
            fromLabel: widget.originLabel,
            fontSize: 13,
          ),
        ],
        const SizedBox(height: 6),
        OpenStatusLine(place: summary, fontSize: 13),
        if (price != null || atmosphere != null) ...<Widget>[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              if (price != null) Pill(price, icon: Icons.payments_outlined),
              if (atmosphere != null)
                Pill(
                  atmosphere.label,
                  icon: Icons.graphic_eq_rounded,
                  color: AppColors.accent,
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _opinions(RatingSummary rating) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _RatingSummaryCard(rating: rating),
        const SizedBox(height: 14),
        _YourRating(
          score: _myScore,
          busy: _ratingBusy,
          onRate: _rate,
          onRemove: _myScore == null ? null : _removeRating,
        ),
        const SizedBox(height: 14),
        _CommentComposer(
          controller: _commentController,
          posting: _posting,
          onSend: _postComment,
        ),
        const SizedBox(height: 6),
        if (_comments.isEmpty && _commentsLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_comments.isEmpty && _commentsError != null)
          MessageView(
            icon: Icons.cloud_off_rounded,
            title: 'Nie udało się wczytać opinii',
            message: _commentsError,
            onRetry: _loadComments,
          )
        else if (_comments.isEmpty)
          const Text(
            'Nikt jeszcze nie napisał opinii o tym miejscu.',
            style: TextStyle(fontSize: 13, color: AppColors.muted),
          )
        else ...<Widget>[
          for (final comment in _comments)
            _CommentTile(
              comment: comment,
              onEdit: _me?.canModify(comment) ?? false
                  ? () => _editComment(comment)
                  : null,
              onDelete: _me?.canModify(comment) ?? false
                  ? () => _deleteComment(comment)
                  : null,
            ),
          if (_comments.length < _commentsTotal)
            Center(
              child: _commentsLoading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(),
                    )
                  : TextButton(
                      key: const ValueKey<String>('more-comments'),
                      onPressed: _loadComments,
                      child: Text(
                        'Pokaż więcej (${_commentsTotal - _comments.length})',
                      ),
                    ),
            ),
        ],
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _PhotoHeader extends StatefulWidget {
  const _PhotoHeader({
    required this.photos,
    required this.fallbackUrl,
    required this.onOpen,
  });

  final List<Photo> photos;
  final String? fallbackUrl;
  final ValueChanged<int> onOpen;

  @override
  State<_PhotoHeader> createState() => _PhotoHeaderState();
}

class _PhotoHeaderState extends State<_PhotoHeader> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.photos.isEmpty) {
      return PlaceImage(url: widget.fallbackUrl, radius: 0, iconSize: 48);
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        PageView.builder(
          itemCount: widget.photos.length,
          onPageChanged: (int page) => setState(() => _page = page),
          itemBuilder: (_, int i) => GestureDetector(
            onTap: () => widget.onOpen(i),
            child: PlaceImage(
              url: widget.photos[i].full.url,
              radius: 0,
              iconSize: 48,
            ),
          ),
        ),
        if (widget.photos.length > 1)
          Positioned(
            right: 14,
            bottom: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.imageOverlay,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${_page + 1}/${widget.photos.length}',
                style: const TextStyle(color: AppColors.white, fontSize: 12),
              ),
            ),
          ),
      ],
    );
  }
}

class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({required this.photos, required this.onOpen});

  final List<Photo> photos;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, int i) => GestureDetector(
          onTap: () => onOpen(i),
          child: PlaceImage(
            url: photos[i].thumbnailUrl,
            width: 96,
            height: 96,
            radius: 14,
          ),
        ),
      ),
    );
  }
}

/// Fullscreen, swipeable, pinch-to-zoom photos (full versions).
class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({
    required this.photos,
    required this.initialIndex,
    super.key,
  });

  final List<Photo> photos;
  final int initialIndex;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int _page = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_page];
    return Scaffold(
      backgroundColor: AppColors.black,
      appBar: AppBar(
        backgroundColor: AppColors.black,
        foregroundColor: AppColors.white,
        title: Text(
          '${_page + 1} z ${widget.photos.length}',
          style: const TextStyle(fontSize: 15),
        ),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.photos.length,
              onPageChanged: (int page) => setState(() => _page = page),
              itemBuilder: (_, int i) => InteractiveViewer(
                maxScale: 4,
                child: Center(
                  child: Image.network(
                    widget.photos[i].full.url,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.broken_image_outlined,
                      color: AppColors.white54,
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              [
                if (photo.uploadedByName != null)
                  'Dodał(a): ${photo.uploadedByName}',
                fmt.date(photo.createdAt),
              ].join(' · '),
              style: const TextStyle(color: AppColors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _AmenitiesGrid extends StatelessWidget {
  const _AmenitiesGrid({required this.amenities});

  final Amenities amenities;

  @override
  Widget build(BuildContext context) {
    final a = amenities;
    final rows = <(IconData, String, bool?)>[
      (Icons.wifi_rounded, 'Wi-Fi', a.wifi),
      (Icons.power_rounded, 'Gniazdka', a.powerOutlets),
      (Icons.restaurant_rounded, 'Jedzenie', a.food),
      (Icons.wc_rounded, 'Toaleta', a.toilet),
      (Icons.accessible_rounded, 'Dla wózków', a.wheelchairAccessible),
      (Icons.ac_unit_rounded, 'Klimatyzacja', a.airConditioning),
      (Icons.computer_rounded, 'Komputery', a.computerAccess),
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final itemWidth = (constraints.maxWidth - 10) / 2;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            for (final (icon, label, value) in rows)
              SizedBox(
                width: itemWidth,
                child: Row(
                  children: <Widget>[
                    Icon(
                      icon,
                      size: 18,
                      color: value == false
                          ? AppColors.placeholderIcon
                          : AppColors.subtle,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          color: value == false
                              ? AppColors.muted
                              : AppColors.ink,
                          decoration: value == false
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                    Icon(
                      switch (value) {
                        true => Icons.check_circle_rounded,
                        false => Icons.cancel_outlined,
                        null => Icons.help_outline_rounded,
                      },
                      size: 16,
                      color: switch (value) {
                        true => AppColors.open,
                        false => AppColors.placeholderIcon,
                        null => AppColors.placeholderIcon,
                      },
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _OpeningHoursDisclosure extends StatelessWidget {
  const _OpeningHoursDisclosure({required this.hours});

  final OpeningHours? hours;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: AppColors.transparent),
      child: ExpansionTile(
        initiallyExpanded: true,
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: const Text(
          'Pokaż tygodniowy rozkład',
          style: TextStyle(fontSize: 13),
        ),
        textColor: AppColors.ink,
        collapsedTextColor: AppColors.subtle,
        iconColor: AppColors.subtle,
        collapsedIconColor: AppColors.subtle,
        children: <Widget>[_OpeningHoursTable(hours: hours)],
      ),
    );
  }
}

class _OpeningHoursTable extends StatelessWidget {
  const _OpeningHoursTable({required this.hours});

  final OpeningHours? hours;

  @override
  Widget build(BuildContext context) {
    final hours = this.hours;
    if (hours == null) {
      return const Text(
        'Brak danych o godzinach otwarcia.',
        style: TextStyle(fontSize: 13, color: AppColors.muted),
      );
    }
    if (hours.alwaysOpen) {
      return const Text(
        'Otwarte całą dobę, 7 dni w tygodniu.',
        style: TextStyle(fontSize: 13),
      );
    }
    final today = DateTime.now().weekday - 1;
    return Column(
      children: <Widget>[
        for (var day = 0; day < 7; day++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 120,
                  child: Text(
                    fmt.weekdayNames[day],
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: day == today
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    hours.forDay(day).isEmpty
                        ? 'Zamknięte'
                        : hours.forDay(day).map(fmt.periodLabel).join(', '),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: day == today
                          ? FontWeight.w700
                          : FontWeight.w400,
                      color: hours.forDay(day).isEmpty
                          ? AppColors.muted
                          : AppColors.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Menu extends StatelessWidget {
  const _Menu({required this.items});

  final List<MenuItem> items;

  @override
  Widget build(BuildContext context) {
    final byCategory = <String, List<MenuItem>>{};
    for (final item in items) {
      byCategory
          .putIfAbsent(item.category ?? 'Inne', () => <MenuItem>[])
          .add(item);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final MapEntry<String, List<MenuItem>>(:key, :value)
            in byCategory.entries) ...<Widget>[
          if (byCategory.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Text(
                key,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.muted,
                ),
              ),
            ),
          for (final item in value)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          item.name,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (item.description != null &&
                            item.description!.isNotEmpty)
                          Text(
                            item.description!,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    fmt.money(item.price, item.currency),
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _RatingSummaryCard extends StatelessWidget {
  const _RatingSummaryCard({required this.rating});

  final RatingSummary rating;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.formField,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: <Widget>[
          Text(
            rating.average == null ? '–' : fmt.decimal(rating.average!),
            style: const TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              RatingStars(rating: rating.average, size: 18),
              const SizedBox(height: 4),
              Text(
                rating.count == 0
                    ? 'Brak ocen'
                    : fmt.ratingsCount(rating.count),
                style: const TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment, this.onEdit, this.onDelete});

  final Comment comment;

  /// Set for the author's own comments (and for admins).
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final name = comment.userName ?? 'Użytkownik';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.lightDivider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CircleAvatar(
            radius: 17,
            backgroundColor: AppColors.chip,
            child: Text(
              name.characters.first.toUpperCase(),
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.subtle,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(
                        text: name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text:
                            '  ${fmt.date(comment.createdAt)}${comment.editedAt != null ? ' · edytowano' : ''}',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  comment.text,
                  style: const TextStyle(fontSize: 13, height: 1.35),
                ),
              ],
            ),
          ),
          if (onEdit != null || onDelete != null)
            PopupMenuButton<String>(
              key: ValueKey<String>('comment-menu-${comment.id}'),
              tooltip: 'Więcej',
              icon: const Icon(
                Icons.more_vert_rounded,
                size: 18,
                color: AppColors.muted,
              ),
              padding: EdgeInsets.zero,
              onSelected: (String action) =>
                  (action == 'edit' ? onEdit : onDelete)?.call(),
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                if (onEdit != null)
                  const PopupMenuItem<String>(
                    value: 'edit',
                    child: Text('Edytuj'),
                  ),
                if (onDelete != null)
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Text('Usuń'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// "Twoja ocena": five tappable stars, like the rating summary above.
class _YourRating extends StatelessWidget {
  const _YourRating({
    required this.score,
    required this.busy,
    required this.onRate,
    this.onRemove,
  });

  final int? score;
  final bool busy;
  final ValueChanged<int> onRate;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text(
          score == null ? 'Oceń to miejsce' : 'Twoja ocena',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        for (var i = 1; i <= 5; i++)
          IconButton(
            key: ValueKey<String>('rate-$i'),
            tooltip: '$i / 5',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: busy ? null : () => onRate(i),
            icon: Icon(
              i <= (score ?? 0)
                  ? Icons.star_rounded
                  : Icons.star_outline_rounded,
              size: 26,
              color: i <= (score ?? 0) ? AppColors.primary : AppColors.muted,
            ),
          ),
        const Spacer(),
        if (busy)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else if (onRemove != null)
          TextButton(
            key: const ValueKey<String>('remove-rating'),
            onPressed: onRemove,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Usuń', style: TextStyle(fontSize: 12)),
          ),
      ],
    );
  }
}

/// "Napisz opinię…" field, styled like the search fields.
class _CommentComposer extends StatelessWidget {
  const _CommentComposer({
    required this.controller,
    required this.posting,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool posting;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 14, right: 4),
      decoration: BoxDecoration(
        color: AppColors.formField,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              key: const ValueKey<String>('comment-input'),
              controller: controller,
              minLines: 1,
              maxLines: 5,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Napisz opinię…',
                border: InputBorder.none,
                counterText: '',
                contentPadding: EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: posting
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    key: const ValueKey<String>('comment-send'),
                    tooltip: 'Wyślij',
                    onPressed: onSend,
                    icon: const Icon(
                      Icons.send_rounded,
                      color: AppColors.primary,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet for editing an opinion (same look as "Dodaj miejscówkę").
class _EditCommentSheet extends StatefulWidget {
  const _EditCommentSheet({required this.initial});

  final String initial;

  @override
  State<_EditCommentSheet> createState() => _EditCommentSheetState();
}

class _EditCommentSheetState extends State<_EditCommentSheet> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Edytuj opinię',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey<String>('edit-comment-input'),
            controller: _controller,
            autofocus: true,
            minLines: 2,
            maxLines: 6,
            maxLength: 2000,
            decoration: InputDecoration(
              filled: true,
              fillColor: AppColors.formField,
              counterText: '',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey<String>('edit-comment-save'),
              onPressed: _save,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: AppColors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
              child: const Text('Zapisz'),
            ),
          ),
        ],
      ),
    );
  }
}
