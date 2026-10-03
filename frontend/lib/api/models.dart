/// Data returned by the backend (see docs/FRONTEND.md and /openapi.json).
library;

typedef Json = Map<String, dynamic>;

double? _double(Object? value) => (value as num?)?.toDouble();

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.parse(value as String).toLocal();

class Page<T> {
  const Page(this.items, this.total);

  final List<T> items;

  /// All matches on the server (X-Total-Count), not just this page.
  final int total;
}

class LatLon {
  const LatLon(this.lat, this.lon);

  factory LatLon.fromJson(Json json) =>
      LatLon(_double(json['lat'])!, _double(json['lon'])!);

  final double lat;
  final double lon;
}

class Address {
  const Address({
    required this.city,
    this.street,
    this.houseNumber,
    this.postcode,
  });

  factory Address.fromJson(Json json) => Address(
    city: json['city'] as String,
    street: json['street'] as String?,
    houseNumber: json['house_number'] as String?,
    postcode: json['postcode'] as String?,
  );

  final String city;
  final String? street;
  final String? houseNumber;
  final String? postcode;

  /// "Floriańska 15, Kraków"
  String get short {
    final streetPart = [street, houseNumber].whereType<String>().join(' ');
    return streetPart.isEmpty ? city : '$streetPart, $city';
  }
}

/// Each flag: true / false / null (unknown).
class Amenities {
  const Amenities({
    this.wifi,
    this.powerOutlets,
    this.computerAccess,
    this.toilet,
    this.wheelchairAccessible,
    this.airConditioning,
    this.food,
  });

  factory Amenities.fromJson(Json json) => Amenities(
    wifi: json['wifi'] as bool?,
    powerOutlets: json['power_outlets'] as bool?,
    computerAccess: json['computer_access'] as bool?,
    toilet: json['toilet'] as bool?,
    wheelchairAccessible: json['wheelchair_accessible'] as bool?,
    airConditioning: json['air_conditioning'] as bool?,
    food: json['food'] as bool?,
  );

  final bool? wifi;
  final bool? powerOutlets;
  final bool? computerAccess;
  final bool? toilet;
  final bool? wheelchairAccessible;
  final bool? airConditioning;
  final bool? food;
}

enum Atmosphere {
  quiet('quiet', 'Spokojnie'),
  chatty('chatty', 'Na pogaduchy'),
  lively('lively', 'Gwarno');

  const Atmosphere(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static Atmosphere? fromApi(Object? value) {
    for (final atmosphere in values) {
      if (atmosphere.apiValue == value) return atmosphere;
    }
    return null;
  }
}

class RatingSummary {
  const RatingSummary({this.average, this.count = 0});

  factory RatingSummary.fromJson(Json? json) => json == null
      ? const RatingSummary()
      : RatingSummary(
          average: _double(json['average']),
          count: (json['count'] as int?) ?? 0,
        );

  /// null until the first rating.
  final double? average;
  final int count;
}

class PriceRange {
  const PriceRange(this.min, this.max);

  static PriceRange? fromJson(Json? json) =>
      json == null ? null : PriceRange(json['min'] as int, json['max'] as int?);

  final int min;

  /// null = open-ended ("60+").
  final int? max;
}

/// Light record for map pins and list cards (GET /places/summary).
class PlaceSummary {
  const PlaceSummary({
    required this.id,
    required this.name,
    required this.address,
    required this.location,
    required this.amenities,
    required this.rating,
    this.usagePrice,
    this.priceRange,
    this.atmosphere,
    this.thumbnailUrl,
    this.photoCount = 0,
    this.openNow,
    this.closesAt,
    this.opensAt,
    this.isMock = false,
    this.distanceM,
  });

  factory PlaceSummary.fromJson(Json json, {required Uri apiUrl}) =>
      PlaceSummary(
        id: json['id'] as String,
        name: json['name'] as String,
        address: Address.fromJson(json['address'] as Json),
        location: LatLon.fromJson(json['coordinates'] as Json),
        amenities: Amenities.fromJson(json['amenities'] as Json),
        rating: RatingSummary.fromJson(json['rating'] as Json?),
        usagePrice: json['usage_price'] as String?,
        priceRange: PriceRange.fromJson(json['price_range'] as Json?),
        atmosphere: Atmosphere.fromApi(json['atmosphere']),
        thumbnailUrl: resolveUrl(apiUrl, json['thumbnail_url'] as String?),
        photoCount: (json['photo_count'] as int?) ?? 0,
        openNow: json['open_now'] as bool?,
        closesAt: _date(json['closes_at']),
        opensAt: _date(json['opens_at']),
        isMock: (json['is_mock'] as bool?) ?? false,
        distanceM: _double(json['distance_m']),
      );

  final String id;
  final String name;
  final Address address;
  final LatLon location;
  final Amenities amenities;
  final RatingSummary rating;
  final String? usagePrice;
  final PriceRange? priceRange;
  final Atmosphere? atmosphere;
  final String? thumbnailUrl;
  final int photoCount;

  /// null = opening hours unknown.
  final bool? openNow;
  final DateTime? closesAt;
  final DateTime? opensAt;
  final bool isMock;
  final double? distanceM;
}

class PhotoVariant {
  const PhotoVariant({
    required this.url,
    required this.width,
    required this.height,
  });

  factory PhotoVariant.fromJson(Json json, {required Uri apiUrl}) =>
      PhotoVariant(
        url: resolveUrl(apiUrl, json['url'] as String)!,
        width: json['width'] as int,
        height: json['height'] as int,
      );

  final String url;
  final int width;
  final int height;
}

class Photo {
  const Photo({
    required this.id,
    required this.full,
    required this.createdAt,
    this.thumbnail,
    this.uploadedByName,
  });

  factory Photo.fromJson(Json json, {required Uri apiUrl}) => Photo(
    id: json['id'] as String,
    full: PhotoVariant.fromJson(json, apiUrl: apiUrl),
    thumbnail: json['thumbnail'] == null
        ? null
        : PhotoVariant.fromJson(json['thumbnail'] as Json, apiUrl: apiUrl),
    uploadedByName: json['uploaded_by_name'] as String?,
    createdAt: _date(json['created_at'])!,
  );

  final String id;
  final PhotoVariant full;
  final PhotoVariant? thumbnail;
  final String? uploadedByName;
  final DateTime createdAt;

  String get thumbnailUrl => (thumbnail ?? full).url;
}

class OpeningPeriod {
  const OpeningPeriod(this.day, this.open, this.close);

  factory OpeningPeriod.fromJson(Json json) => OpeningPeriod(
    json['day'] as int,
    json['open'] as String,
    json['close'] as String,
  );

  /// 0 = Monday, like the backend (DateTime.weekday - 1).
  final int day;
  final String open;
  final String close;
}

class OpeningHours {
  const OpeningHours({this.alwaysOpen = false, this.periods = const []});

  static OpeningHours? fromJson(Json? json) => json == null
      ? null
      : OpeningHours(
          alwaysOpen: (json['always_open'] as bool?) ?? false,
          periods: [
            for (final p in (json['periods'] as List? ?? const []))
              OpeningPeriod.fromJson(p as Json),
          ],
        );

  final bool alwaysOpen;
  final List<OpeningPeriod> periods;

  List<OpeningPeriod> forDay(int day) =>
      periods.where((p) => p.day == day).toList();
}

class MenuItem {
  const MenuItem({
    required this.name,
    required this.price,
    this.currency = 'PLN',
    this.category,
    this.description,
  });

  factory MenuItem.fromJson(Json json) => MenuItem(
    name: json['name'] as String,
    price: json['price'] as int,
    currency: (json['currency'] as String?) ?? 'PLN',
    category: json['category'] as String?,
    description: json['description'] as String?,
  );

  final String name;

  /// Minor units: 1500 = 15.00.
  final int price;
  final String currency;
  final String? category;
  final String? description;
}

/// Full place (GET /places/{id}).
class Place {
  const Place({
    required this.id,
    required this.name,
    required this.address,
    required this.location,
    required this.amenities,
    required this.rating,
    this.openingHours,
    this.usagePrice,
    this.priceRange,
    this.atmosphere,
    this.features = const [],
    this.menu = const [],
    this.photos = const [],
    this.isMock = false,
    this.mockFields = const [],
  });

  factory Place.fromJson(Json json, {required Uri apiUrl}) => Place(
    id: json['id'] as String,
    name: json['name'] as String,
    address: Address.fromJson(json['address'] as Json),
    location: LatLon.fromJson(json['coordinates'] as Json),
    amenities: Amenities.fromJson(json['amenities'] as Json),
    rating: RatingSummary.fromJson(json['rating'] as Json?),
    openingHours: OpeningHours.fromJson(json['opening_hours'] as Json?),
    usagePrice: json['usage_price'] as String?,
    priceRange: PriceRange.fromJson(json['price_range'] as Json?),
    atmosphere: Atmosphere.fromApi(json['atmosphere']),
    features: [
      for (final f in (json['features'] as List? ?? const [])) f as String,
    ],
    menu: [
      for (final item in (json['menu'] as List? ?? const []))
        MenuItem.fromJson(item as Json),
    ],
    photos: [
      for (final photo in (json['photos'] as List? ?? const []))
        Photo.fromJson(photo as Json, apiUrl: apiUrl),
    ],
    isMock: (json['is_mock'] as bool?) ?? false,
    mockFields: [
      for (final f in (json['mock_fields'] as List? ?? const [])) f as String,
    ],
  );

  final String id;
  final String name;
  final Address address;
  final LatLon location;
  final Amenities amenities;
  final RatingSummary rating;
  final OpeningHours? openingHours;
  final String? usagePrice;
  final PriceRange? priceRange;
  final Atmosphere? atmosphere;
  final List<String> features;
  final List<MenuItem> menu;
  final List<Photo> photos;
  final bool isMock;
  final List<String> mockFields;
}

class Comment {
  const Comment({
    required this.id,
    required this.text,
    required this.createdAt,
    this.userName,
    this.editedAt,
  });

  factory Comment.fromJson(Json json) => Comment(
    id: json['id'] as String,
    text: json['text'] as String,
    userName: json['user_name'] as String?,
    createdAt: _date(json['created_at'])!,
    editedAt: _date(json['edited_at']),
  );

  final String id;
  final String text;
  final String? userName;
  final DateTime createdAt;
  final DateTime? editedAt;
}

/// A city / address from GET /geocode.
class GeocodeResult {
  const GeocodeResult({
    required this.name,
    required this.displayName,
    required this.location,
    required this.kind,
    this.bounds,
  });

  factory GeocodeResult.fromJson(Json json) {
    final bbox = json['bbox'] as List?;
    return GeocodeResult(
      name: json['name'] as String,
      displayName: json['display_name'] as String,
      location: LatLon.fromJson(json),
      kind: json['kind'] as String,
      // Backend order: [south, north, west, east].
      bounds: bbox == null
          ? null
          : GeoBounds(
              south: _double(bbox[0])!,
              north: _double(bbox[1])!,
              west: _double(bbox[2])!,
              east: _double(bbox[3])!,
            ),
    );
  }

  final String name;
  final String displayName;
  final LatLon location;
  final String kind;
  final GeoBounds? bounds;
}

class GeoBounds {
  const GeoBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  final double south;
  final double west;
  final double north;
  final double east;
}

/// Photo URLs are relative ("/media/...") unless the backend has PUBLIC_BASE_URL set.
///
/// During local development the backend can still return an absolute
/// `http://localhost:8000/media/...` URL. On a phone, `localhost` points to
/// the phone itself, so reuse the host configured for API requests instead.
String? resolveUrl(Uri apiUrl, String? url) {
  if (url == null) return null;
  final resolved = apiUrl.resolve(url);
  final isLoopback = resolved.host == 'localhost' ||
      resolved.host == '127.0.0.1' ||
      resolved.host == '::1';
  final apiIsLoopback = apiUrl.host == 'localhost' ||
      apiUrl.host == '127.0.0.1' ||
      apiUrl.host == '::1';
  if (isLoopback && !apiIsLoopback) {
    return resolved
        .replace(
          scheme: apiUrl.scheme,
          host: apiUrl.host,
          port: apiUrl.hasPort ? apiUrl.port : null,
        )
        .toString();
  }
  return resolved.toString();
}
