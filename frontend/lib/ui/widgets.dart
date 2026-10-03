import 'package:flutter/material.dart';

import '../api/models.dart';
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
          color: rating == null ? AppColors.muted : AppColors.ink,
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

/// Rating pin on the map; dark for great places, lighter for weaker / unrated ones.
class MapMarker extends StatelessWidget {
  const MapMarker({required this.rating, this.selected = false, super.key});

  final double? rating;
  final bool selected;

  static Color colorFor(double? rating) {
    if (rating == null) return const Color(0xFF8A8F94);
    if (rating >= 4.5) return const Color(0xFF232A31);
    if (rating >= 4.0) return const Color(0xFF385B4C);
    if (rating >= 3.0) return const Color(0xFF765843);
    return const Color(0xFF9A4A3F);
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
          border: Border.all(color: Colors.white, width: selected ? 2 : 1.2),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x33000000),
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
                color: Colors.white,
                size: 12,
              ),
              if (rating != null) ...<Widget>[
                const SizedBox(width: 3),
                Text(
                  fmt.decimal(rating!),
                  style: const TextStyle(
                    color: Colors.white,
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
  const Pill(this.label, {this.icon, this.color, super.key});

  final String label;
  final IconData? icon;
  final Color? color;

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
            Icon(icon, size: 11, color: AppColors.subtle),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: AppColors.subtle),
          ),
        ],
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
