import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/places_api.dart';
import '../auth/auth.dart';
import '../services/travel_time_service.dart';
import 'format.dart' as fmt;
import 'login_sheet.dart';
import 'photo_picker.dart';
import 'theme.dart';
import 'widgets.dart';

/// Everything about one place: photos, rating, hours, amenities, menu, opinions.
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

  // Logged-in user's part: their rating, writing / editing / deleting / liking opinions.
  CurrentUser? _me;
  int? _myScore;
  RatingSummary? _rating; // newer than the loaded place after the user rates
  bool _ratingBusy = false;
  final _commentController = TextEditingController();
  bool _posting = false;
  final Set<String> _liking = <String>{}; // comment ids with a like request in flight
  int _uploading = 0; // photos still being sent

  /// Same limit as the API (MAX_PHOTOS_PER_PLACE).
  static const int _maxPhotos = 20;

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
    final score = _myScore;
    if (score == null) {
      _toast('Wybierz ocenę gwiazdkami, aby dodać komentarz.');
      return;
    }
    await _withLogin(
      (String token) => _busy((bool v) => _posting = v, () async {
        final comment = await widget.api.addComment(
          _placeId,
          text,
          token: token,
          score: score,
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

  /// Thumbs up, or takes it back when already given. The list keeps its order until reloaded
  /// (no comment jumps away from under the finger); the API sorts the most liked first.
  Future<void> _toggleLike(Comment comment) async {
    if (_liking.contains(comment.id)) return;
    await _withLogin(
      (String token) => _busy((bool v) {
        v ? _liking.add(comment.id) : _liking.remove(comment.id);
      }, () async {
        final updated = await widget.api.likeComment(
          _placeId,
          comment.id,
          liked: !comment.isLikedBy(_me?.id),
          token: token,
        );
        if (!mounted) return;
        setState(() {
          final i = _comments.indexWhere((Comment c) => c.id == comment.id);
          if (i >= 0) _comments[i] = updated;
        });
      }),
      reason: 'Zaloguj się, żeby polubić opinię.',
    );
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
        // The order follows likes, which can change between pages: a comment that moved down
        // would come again, so don't show it twice.
        final shown = {for (final c in _comments) c.id};
        _comments.addAll(page.items.where((Comment c) => !shown.contains(c.id)));
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
        builder: (_) => PhotoViewerPage(
          photos: photos,
          initialIndex: index,
          canDelete: (Photo photo) => _me?.canDeletePhoto(photo) ?? false,
          onDelete: _deletePhoto,
        ),
      ),
    );
  }

  Future<void> _addPhotos() async {
    if (_uploading > 0) return;
    final token = await requireLogin(
      context,
      widget.auth,
      reason: 'Zaloguj się, żeby dodać zdjęcie.',
    );
    if (token == null || !mounted) return;
    if (_me == null) await _loadMine();
    if (!mounted) return;
    final free = _maxPhotos - (_place?.photos.length ?? 0);
    if (free <= 0) {
      _toast('To miejsce ma już maksymalną liczbę zdjęć.');
      return;
    }
    final picked = await pickPhotos(context, limit: free);
    if (picked.isEmpty || !mounted) return;

    setState(() => _uploading = picked.length);
    var added = 0;
    String? error;
    for (final photo in picked) {
      try {
        await widget.api.uploadPhoto(
          _placeId,
          photo.bytes,
          filename: photo.name,
          token: token,
        );
        added++;
      } on ApiException catch (e) {
        error = e.message;
        if (e.statusCode == 401) {
          await widget.auth.invalidate();
          if (mounted) setState(() => _me = null);
        }
        // Session gone or the place is full: the remaining ones would fail the same way.
        if (e.statusCode == 401 || e.statusCode == 409) break;
      } finally {
        if (mounted) setState(() => _uploading--);
      }
    }
    if (!mounted) return;
    setState(() => _uploading = 0);
    if (added > 0) await _loadPlace();
    _toast(switch ((added, error)) {
      (0, final String e) => e,
      (_, final String e) => 'Dodano $added z ${picked.length} zdjęć. $e',
      (1, _) => 'Dodano zdjęcie.',
      _ => 'Dodano $added zdjęć.',
    });
  }

  /// From the photo viewer; true when the photo is gone (the viewer closes then).
  Future<bool> _deletePhoto(Photo photo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Usunąć zdjęcie?'),
        content: const Text('Tej operacji nie można cofnąć.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Anuluj'),
          ),
          TextButton(
            key: const ValueKey<String>('confirm-delete-photo'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              'Usuń',
              style: TextStyle(color: AppColors.closed),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;
    var deleted = false;
    await _withLogin((String token) async {
      await widget.api.deletePhoto(_placeId, photo.id, token: token);
      deleted = true;
    });
    if (deleted && mounted) {
      _toast('Usunięto zdjęcie.');
      await _loadPlace();
    }
    return deleted;
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
                    _Section(
                      title: photos.isEmpty
                          ? 'Zdjęcia'
                          : 'Zdjęcia (${photos.length})',
                      child: _PhotoStrip(
                        photos: photos,
                        onOpen: (int i) => _openPhoto(photos, i),
                        onAdd: photos.length < _maxPhotos ? _addPhotos : null,
                        uploading: _uploading,
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
        if ((widget.travelTimes, widget.origin) case (
          final service?,
          final origin?,
        )) ...<Widget>[
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
        _ReviewComposer(
          score: _myScore,
          ratingBusy: _ratingBusy,
          posting: _posting,
          controller: _commentController,
          onRate: _rate,
          onRemove: _myScore == null ? null : _removeRating,
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
              liked: comment.isLikedBy(_me?.id),
              onLike: () => _toggleLike(comment),
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
  const _PhotoStrip({
    required this.photos,
    required this.onOpen,
    required this.onAdd,
    required this.uploading,
  });

  final List<Photo> photos;
  final ValueChanged<int> onOpen;

  /// The "add" tile in front; null hides it (place full).
  final VoidCallback? onAdd;

  /// Photos still being sent: the add tile shows progress instead.
  final int uploading;

  @override
  Widget build(BuildContext context) {
    final lead = onAdd == null && uploading == 0 ? 0 : 1;
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length + lead,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, int i) {
          if (i < lead) {
            return _AddPhotoTile(onTap: onAdd, uploading: uploading);
          }
          return GestureDetector(
            onTap: () => onOpen(i - lead),
            child: PlaceImage(
              url: photos[i - lead].thumbnailUrl,
              width: 96,
              height: 96,
              radius: 14,
            ),
          );
        },
      ),
    );
  }
}

class _AddPhotoTile extends StatelessWidget {
  const _AddPhotoTile({required this.onTap, required this.uploading});

  final VoidCallback? onTap;
  final int uploading;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.field,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: const ValueKey<String>('add-photo'),
        borderRadius: BorderRadius.circular(14),
        onTap: uploading > 0 ? null : onTap,
        child: SizedBox(
          width: 96,
          height: 96,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (uploading > 0) ...<Widget>[
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(height: 8),
                Text(
                  'Wysyłam ($uploading)',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ] else ...<Widget>[
                const Icon(
                  Icons.add_a_photo_outlined,
                  color: AppColors.primary,
                  size: 26,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Dodaj',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ],
            ],
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
    this.canDelete,
    this.onDelete,
    super.key,
  });

  final List<Photo> photos;
  final int initialIndex;

  /// Whether the current user may delete a photo (shows the trash button).
  final bool Function(Photo photo)? canDelete;

  /// Deletes the photo; true closes the viewer.
  final Future<bool> Function(Photo photo)? onDelete;

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
        actions: <Widget>[
          if (widget.onDelete != null &&
              (widget.canDelete?.call(photo) ?? false))
            IconButton(
              key: const ValueKey<String>('delete-photo'),
              tooltip: 'Usuń zdjęcie',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () async {
                final deleted = await widget.onDelete!(photo);
                if (deleted && context.mounted) Navigator.of(context).pop();
              },
            ),
        ],
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
  const _CommentTile({
    required this.comment,
    required this.liked,
    required this.onLike,
    this.onEdit,
    this.onDelete,
  });

  final Comment comment;

  /// Whether the logged-in user gave this comment a thumbs up.
  final bool liked;
  final VoidCallback onLike;

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
                if (comment.score != null) ...<Widget>[
                  const SizedBox(height: 3),
                  RatingStars(rating: comment.score!.toDouble(), size: 14),
                ],
                const SizedBox(height: 4),
                Text(
                  comment.text,
                  style: const TextStyle(fontSize: 13, height: 1.35),
                ),
                const SizedBox(height: 4),
                InkWell(
                  key: ValueKey<String>('comment-like-${comment.id}'),
                  onTap: onLike,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          liked ? Icons.thumb_up_alt_rounded : Icons.thumb_up_alt_outlined,
                          size: 16,
                          color: liked ? AppColors.primary : AppColors.muted,
                        ),
                        if (comment.likes > 0) ...<Widget>[
                          const SizedBox(width: 4),
                          Text(
                            '${comment.likes}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: liked ? AppColors.primary : AppColors.muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
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

/// One review box: the user can submit a rating alone or add an optional comment.
class _ReviewComposer extends StatelessWidget {
  const _ReviewComposer({
    required this.score,
    required this.ratingBusy,
    required this.posting,
    required this.controller,
    required this.onRate,
    required this.onSend,
    this.onRemove,
  });

  final int? score;
  final bool ratingBusy;
  final bool posting;
  final TextEditingController controller;
  final ValueChanged<int> onRate;
  final VoidCallback onSend;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
      decoration: BoxDecoration(
        color: AppColors.formField,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'Twoja opinia',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              if (ratingBusy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (onRemove != null)
                TextButton(
                  key: const ValueKey<String>('remove-rating'),
                  onPressed: onRemove,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Usuń', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              for (var i = 1; i <= 5; i++)
                IconButton(
                  key: ValueKey<String>('rate-$i'),
                  tooltip: '$i / 5',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  onPressed: ratingBusy ? null : () => onRate(i),
                  icon: Icon(
                    i <= (score ?? 0)
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    size: 27,
                    color: i <= (score ?? 0)
                        ? AppColors.primary
                        : AppColors.muted,
                  ),
                ),
            ],
          ),
          Row(
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
                    hintText: 'Dodaj komentarz (opcjonalnie)…',
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
                        tooltip: 'Dodaj opinię',
                        onPressed: onSend,
                        icon: const Icon(
                          Icons.send_rounded,
                          color: AppColors.primary,
                        ),
                      ),
              ),
            ],
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
