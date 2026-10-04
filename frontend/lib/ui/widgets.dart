import 'package:flutter/material.dart';

import '../api/models.dart';
import '../services/travel_time_service.dart';
import 'format.dart' as fmt;
import 'theme.dart';

/// Stars with halves: 4.3 -> ★★★★½
class RatingStars extends StatelessWidget {
  const RatingStars({required this.rating, this.size = 12, super.key});

  final double? rating;
  final double size;

  @override
  Widget build(BuildContext context) {
    final value = rating ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List<Widget>.generate(5, (int i) {
        final fill = value - i;
        final icon = fill >= 0.75
            ? Icons.star_rounded
            : fill >= 0.25
            ? Icons.star_half_rounded
            : Icons.star_outline_rounded;
        return Icon(
          icon,
          size: size,
          color: rating == null ? AppColors.muted : AppColors.primary,
        );
      }),
    );
  }
}

/// "★★★★½ 4,3 (12)" or "Brak ocen".
class RatingLine extends StatelessWidget {
  const RatingLine({required this.rating, this.size = 12, super.key});

  final RatingSummary rating;
  final double size;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: size - 1, color: AppColors.muted);
    if (rating.average == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          RatingStars(rating: null, size: size),
          const SizedBox(width: 5),
          Text('Brak ocen', style: style),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        RatingStars(rating: rating.average, size: size),
        const SizedBox(width: 5),
        Text(
          fmt.decimal(rating.average!),
          style: TextStyle(
            fontSize: size - 1,
            fontWeight: FontWeight.w700,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(width: 3),
        Text('(${rating.count})', style: style),
      ],
    );
  }
}

/// Network image with a neutral placeholder while loading and on errors.
class PlaceImage extends StatelessWidget {
  const PlaceImage({
    required this.url,
    this.width,
    this.height,
    this.radius = 20,
    this.fit = BoxFit.cover,
    this.iconSize = 30,
    super.key,
  });

  final String? url;
  final double? width;
  final double? height;
  final double radius;
  final BoxFit fit;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: width,
      height: height,
      color: AppColors.placeholder,
      alignment: Alignment.center,
      child: Icon(
        Icons.local_cafe_outlined,
        size: iconSize,
        color: AppColors.placeholderIcon,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url == null
          ? placeholder
          : Image.network(
              url!,
              width: width,
              height: height,
              fit: fit,
              errorBuilder: (_, _, _) => placeholder,
              loadingBuilder: (_, Widget child, ImageChunkEvent? progress) =>
                  progress == null ? child : placeholder,
            ),
    );
  }
}

/// "Otwarte teraz · do 20:00" in green / red / grey.
class OpenStatusLine extends StatelessWidget {
  const OpenStatusLine({required this.place, this.fontSize = 10, super.key});

  final PlaceSummary place;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final status = fmt.openStatus(place);
    final color = switch (status.open) {
      true => AppColors.open,
      false => AppColors.closed,
      null => AppColors.muted,
    };
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: status.label,
            style: TextStyle(fontWeight: FontWeight.w700, color: color),
          ),
          if (status.detail != null)
            TextSpan(
              text: '  ${status.detail}',
              style: const TextStyle(color: AppColors.muted),
            ),
        ],
      ),
      style: TextStyle(fontSize: fontSize),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Small "icon label" pairs for the amenities that are known to be available.
class AmenityBadges extends StatelessWidget {
  const AmenityBadges({required this.amenities, this.fontSize = 10, super.key});

  final Amenities amenities;
  final double fontSize;

  static List<(IconData, String)> available(
    Amenities a,
  ) => <(IconData, String)>[
    if (a.wifi ?? false) (Icons.wifi_rounded, 'Wi-Fi'),
    if (a.powerOutlets ?? false) (Icons.power_rounded, 'Gniazdka'),
    if (a.food ?? false) (Icons.restaurant_rounded, 'Jedzenie'),
    if (a.toilet ?? false) (Icons.wc_rounded, 'Toaleta'),
    if (a.wheelchairAccessible ?? false) (Icons.accessible_rounded, 'Dostępne'),
    if (a.airConditioning ?? false) (Icons.ac_unit_rounded, 'Klima'),
    if (a.computerAccess ?? false) (Icons.computer_rounded, 'Komputery'),
  ];

  @override
  Widget build(BuildContext context) {
    final items = available(amenities);
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      children: <Widget>[
        for (final (icon, label) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: fontSize + 3, color: AppColors.subtle),
              const SizedBox(width: 3),
              Text(
                label,
                style: TextStyle(fontSize: fontSize, color: AppColors.subtle),
              ),
            ],
          ),
      ],
    );
  }
}

/// Place pin on the map. The selected state changes its scale, while all pins
/// use the single brand color from [AppColors.placeMarker].
class MapMarker extends StatelessWidget {
  const MapMarker({required this.rating, this.selected = false, super.key});

  final double? rating;
  final bool selected;

  static Color colorFor(double? rating) {
    return AppColors.placeMarker;
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(rating);
    return AnimatedScale(
      scale: selected ? 1.18 : 1,
      duration: const Duration(milliseconds: 160),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: AppColors.white, width: selected ? 2 : 1.2),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: AppColors.subtleShadow,
              blurRadius: 5,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                rating == null ? Icons.local_cafe_rounded : Icons.star_rounded,
                color: AppColors.white,
                size: 12,
              ),
              if (rating != null) ...<Widget>[
                const SizedBox(width: 3),
                Text(
                  fmt.decimal(rating!),
                  style: const TextStyle(
                    color: AppColors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Grey rounded pill, e.g. "Demo" or "0–30 zł".
class Pill extends StatelessWidget {
  const Pill(this.label, {this.icon, this.color, this.textColor, super.key});

  final String label;
  final IconData? icon;
  final Color? color;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color ?? AppColors.chip,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 11, color: textColor ?? AppColors.subtle),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: textColor ?? AppColors.subtle,
            ),
          ),
        ],
      ),
    );
  }
}

/// "‹" back button of the full-screen pages.
class BackChevron extends StatelessWidget {
  const BackChevron({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey<String>('back'),
      tooltip: 'Wróć',
      icon: const Icon(Icons.arrow_back_rounded, color: AppColors.ink),
      onPressed: () => Navigator.of(context).maybePop(),
    );
  }
}

/// Outlined rounded button, e.g. a recent search.
class OutlinePill extends StatelessWidget {
  const OutlinePill({
    required this.label,
    required this.onPressed,
    this.leading,
    this.fontSize = 12,
    this.height = 30,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;
  final Widget? leading;
  final double fontSize;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          side: const BorderSide(color: AppColors.divider),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (leading case final icon?) ...<Widget>[
              icon,
              const SizedBox(width: 6),
            ],
            Text(label, style: TextStyle(fontSize: fontSize)),
          ],
        ),
      ),
    );
  }
}

/// Centered message with an optional retry button (errors, empty results).
class MessageView extends StatelessWidget {
  const MessageView({
    required this.icon,
    required this.title,
    this.message,
    this.onRetry,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 34, color: AppColors.placeholderIcon),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          if (message != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ],
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Spróbuj ponownie'),
            ),
          ],
        ],
      ),
    );
  }
}

/// "🚶 12 min · 🚲 5 min · 🚗 4 min" from [from] to [to], by road (loads on its own).
class TravelTimesLine extends StatefulWidget {
  const TravelTimesLine({
    required this.service,
    required this.from,
    required this.to,
    this.fromLabel,
    this.fontSize = 12,
    super.key,
  });

  final TravelTimeService service;
  final LatLon from;
  final LatLon to;

  /// "Moja lokalizacja", a city name...; shown as "z: ..." when not the device.
  final String? fromLabel;
  final double fontSize;

  @override
  State<TravelTimesLine> createState() => _TravelTimesLineState();
}

class _TravelTimesLineState extends State<TravelTimesLine> {
  late Future<TravelTimes> _times;

  @override
  void initState() {
    super.initState();
    _times = widget.service.between(widget.from, widget.to);
  }

  @override
  void didUpdateWidget(TravelTimesLine old) {
    super.didUpdateWidget(old);
    if (old.from.lat != widget.from.lat ||
        old.from.lon != widget.from.lon ||
        old.to.lat != widget.to.lat ||
        old.to.lon != widget.to.lon) {
      _times = widget.service.between(widget.from, widget.to);
    }
  }

  static IconData _icon(TravelMode mode) => switch (mode) {
    TravelMode.walk => Icons.directions_walk_rounded,
    TravelMode.bike => Icons.directions_bike_rounded,
    TravelMode.car => Icons.directions_car_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: widget.fontSize, color: AppColors.subtle);
    final iconSize = widget.fontSize + 3;
    return FutureBuilder<TravelTimes>(
      future: _times,
      builder: (BuildContext context, AsyncSnapshot<TravelTimes> snapshot) {
        final times = snapshot.data;
        if (times == null) {
          if (snapshot.connectionState == ConnectionState.done) {
            return const SizedBox.shrink();
          }
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: widget.fontSize,
                height: widget.fontSize,
                child: const CircularProgressIndicator(strokeWidth: 1.5),
              ),
              const SizedBox(width: 6),
              Text('Liczę czas dojazdu…', style: style),
            ],
          );
        }
        if (times.isEmpty) return const SizedBox.shrink();
        return Wrap(
          key: const ValueKey<String>('travel-times'),
          spacing: 10,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            for (final MapEntry(key: mode, value: duration)
                in times.durations.entries)
              Tooltip(
                message: mode.label,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(_icon(mode), size: iconSize, color: AppColors.subtle),
                    const SizedBox(width: 2),
                    Text(fmt.travelDuration(duration), style: style),
                  ],
                ),
              ),
            if (widget.fromLabel case final label?)
              Text('z: $label', style: style.copyWith(color: AppColors.muted)),
          ],
        );
      },
    );
  }
}
