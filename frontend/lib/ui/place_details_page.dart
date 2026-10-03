import 'package:flutter/material.dart';

import '../api/models.dart';
import '../api/places_api.dart';
import 'format.dart' as fmt;
import 'theme.dart';
import 'widgets.dart';

/// Everything about one place, read-only: photos, rating, hours, amenities, menu, opinions.
class PlaceDetailsPage extends StatefulWidget {
  const PlaceDetailsPage({
    required this.api,
    required this.summary,
    this.distanceM,
    super.key,
  });

  final PlacesApi api;

  /// Shown immediately while the full record loads.
  final PlaceSummary summary;
  final double? distanceM;

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

  @override
  void initState() {
    super.initState();
    _loadPlace();
    _loadComments();
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
      body: CustomScrollView(
        slivers: <Widget>[
          SliverAppBar(
            pinned: true,
            expandedHeight: 260,
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            leading: Padding(
              padding: const EdgeInsets.all(8),
              child: CircleAvatar(
                backgroundColor: Colors.white,
                child: IconButton(
                  key: const ValueKey<String>('details-back'),
                  tooltip: 'Wróć',
                  icon: const Icon(Icons.arrow_back_rounded, color: AppColors.ink),
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
                      child: _OpeningHoursTable(hours: place.openingHours),
                    ),
                    if (photos.length > 1)
                      _Section(
                        title: 'Zdjęcia (${photos.length})',
                        child: _PhotoStrip(photos: photos, onOpen: (int i) => _openPhoto(photos, i)),
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
                                label: Text(feature, style: const TextStyle(fontSize: 12)),
                                visualDensity: VisualDensity.compact,
                                side: BorderSide.none,
                                backgroundColor: AppColors.chip,
                              ),
                          ],
                        ),
                      ),
                    if (place.menu.isNotEmpty)
                      _Section(title: 'Menu', child: _Menu(items: place.menu)),
                  ],
                  _Section(
                    title: _commentsTotal > 0 ? 'Opinie ($_commentsTotal)' : 'Opinie',
                    child: _opinions(place?.rating ?? summary.rating),
                  ),
                  if (place?.isMock ?? summary.isMock)
                    const Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: Row(
                        children: <Widget>[
                          Icon(Icons.info_outline_rounded, size: 14, color: AppColors.muted),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Miejsce z danych demonstracyjnych: nazwa i adres są prawdziwe '
                              '(OpenStreetMap), część szczegółów przykładowa.',
                              style: TextStyle(fontSize: 11, color: AppColors.muted),
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
          style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w700, color: AppColors.ink),
        ),
        const SizedBox(height: 8),
        RatingLine(rating: place?.rating ?? summary.rating, size: 15),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            const Icon(Icons.location_on_outlined, size: 15, color: AppColors.muted),
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
        const SizedBox(height: 6),
        OpenStatusLine(place: summary, fontSize: 13),
        if (price != null || atmosphere != null) ...<Widget>[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              if (price != null) Pill(price, icon: Icons.payments_outlined),
              if (atmosphere != null) Pill(atmosphere.label, icon: Icons.graphic_eq_rounded),
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
          for (final comment in _comments) _CommentTile(comment: comment),
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
                      child: Text('Pokaż więcej (${_commentsTotal - _comments.length})'),
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
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.ink),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _PhotoHeader extends StatefulWidget {
  const _PhotoHeader({required this.photos, required this.fallbackUrl, required this.onOpen});

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
            child: PlaceImage(url: widget.photos[i].full.url, radius: 0, iconSize: 48),
          ),
        ),
        if (widget.photos.length > 1)
          Positioned(
            right: 14,
            bottom: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x99000000),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${_page + 1}/${widget.photos.length}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
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
          child: PlaceImage(url: photos[i].thumbnailUrl, width: 96, height: 96, radius: 14),
        ),
      ),
    );
  }
}

/// Fullscreen, swipeable, pinch-to-zoom photos (full versions).
class PhotoViewerPage extends StatefulWidget {
  const PhotoViewerPage({required this.photos, required this.initialIndex, super.key});

  final List<Photo> photos;
  final int initialIndex;

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
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
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
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
                      color: Colors.white54,
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
                if (photo.uploadedByName != null) 'Dodał(a): ${photo.uploadedByName}',
                fmt.date(photo.createdAt),
              ].join(' · '),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
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
                    Icon(icon, size: 18, color: value == false ? AppColors.placeholderIcon : AppColors.subtle),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          color: value == false ? AppColors.muted : AppColors.ink,
                          decoration: value == false ? TextDecoration.lineThrough : null,
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

class _OpeningHoursTable extends StatelessWidget {
  const _OpeningHoursTable({required this.hours});

  final OpeningHours? hours;

  @override
  Widget build(BuildContext context) {
    final hours = this.hours;
    if (hours == null) {
      return const Text('Brak danych o godzinach otwarcia.', style: TextStyle(fontSize: 13, color: AppColors.muted));
    }
    if (hours.alwaysOpen) {
      return const Text('Otwarte całą dobę, 7 dni w tygodniu.', style: TextStyle(fontSize: 13));
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
                      fontWeight: day == today ? FontWeight.w700 : FontWeight.w400,
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
                      fontWeight: day == today ? FontWeight.w700 : FontWeight.w400,
                      color: hours.forDay(day).isEmpty ? AppColors.muted : AppColors.ink,
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
      byCategory.putIfAbsent(item.category ?? 'Inne', () => <MenuItem>[]).add(item);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final MapEntry<String, List<MenuItem>>(:key, :value) in byCategory.entries) ...<Widget>[
          if (byCategory.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Text(
                key,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.muted),
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
                        Text(item.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        if (item.description != null && item.description!.isNotEmpty)
                          Text(
                            item.description!,
                            style: const TextStyle(fontSize: 11, color: AppColors.muted),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(fmt.money(item.price, item.currency), style: const TextStyle(fontSize: 13)),
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
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: <Widget>[
          Text(
            rating.average == null ? '–' : fmt.decimal(rating.average!),
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: AppColors.ink),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              RatingStars(rating: rating.average, size: 18),
              const SizedBox(height: 4),
              Text(
                rating.count == 0 ? 'Brak ocen' : fmt.ratingsCount(rating.count),
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
  const _CommentTile({required this.comment});

  final Comment comment;

  @override
  Widget build(BuildContext context) {
    final name = comment.userName ?? 'Użytkownik';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE6E6E6))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CircleAvatar(
            radius: 17,
            backgroundColor: AppColors.chip,
            child: Text(
              name.characters.first.toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.subtle),
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
                      TextSpan(text: name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      TextSpan(
                        text: '  ${fmt.date(comment.createdAt)}${comment.editedAt != null ? ' · edytowano' : ''}',
                        style: const TextStyle(color: AppColors.muted, fontSize: 11),
                      ),
                    ],
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(comment.text, style: const TextStyle(fontSize: 13, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
