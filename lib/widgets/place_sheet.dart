import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/place.dart';
import '../models/weather.dart';
import '../util/constants.dart';
import '../util/geo.dart';

/// Google-Maps-style draggable place sheet: swipe up for details
/// (address, hours, contact), swipe down to peek at just the essentials.
class PlaceSheet extends StatelessWidget {
  final Place place;
  final LatLng? myLocation;
  final bool isSaved;
  final Weather? weather;
  final String? photoUrl;

  /// True while the dropped pin is being reverse-geocoded.
  final bool resolving;
  final DraggableScrollableController? controller;
  final VoidCallback onDirections;
  final VoidCallback onSavePressed;
  final VoidCallback onClose;

  const PlaceSheet({
    super.key,
    required this.place,
    required this.isSaved,
    required this.onDirections,
    required this.onSavePressed,
    required this.onClose,
    this.myLocation,
    this.weather,
    this.photoUrl,
    this.resolving = false,
    this.controller,
  });

  String get _osmUrl =>
      'https://www.openstreetmap.org/?mlat=${place.point.latitude}&mlon=${place.point.longitude}#map=18/${place.point.latitude}/${place.point.longitude}';

  String get _coords =>
      '${place.point.latitude.toStringAsFixed(6)}, ${place.point.longitude.toStringAsFixed(6)}';

  /// Adds a scheme to bare OSM `website` tags ("example.com").
  static Uri? websiteUri(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'https://$s';
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return null;
    return uri;
  }

  Future<void> _open(
    BuildContext context,
    Uri? uri, {
    LaunchMode mode = LaunchMode.platformDefault,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: mode);
      } on PlatformException {
        ok = false;
      }
    }
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            uri == null
                ? 'That link is not valid'
                : 'No app available to open ${uri.scheme == 'tel' ? 'phone numbers' : 'this link'}',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final distance = myLocation == null
        ? null
        : formatDistance(distanceMeters(myLocation!, place.point));
    final website = place.website == null ? null : websiteUri(place.website!);
    final phone = place.phone?.trim();
    final telUri = phone == null || phone.isEmpty
        ? null
        : Uri.parse('tel:${phone.replaceAll(RegExp(r'[\s()-]'), '')}');
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return DraggableScrollableSheet(
      controller: controller,
      initialChildSize: kSheetPeekSize,
      minChildSize: kSheetMinSize,
      maxChildSize: kSheetMaxSize,
      snap: true,
      snapSizes: const [kSheetPeekSize, kSheetMaxSize],
      builder: (context, scrollController) => Material(
        elevation: 10,
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: ListView(
          controller: scrollController,
          padding: EdgeInsets.zero,
          children: [
            Center(
              child: Semantics(
                label: 'Drag handle',
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            if (photoUrl != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.network(
                    photoUrl!,
                    height: 150,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    // Decode at display size, not the 640 px source.
                    cacheHeight: (150 * dpr).round(),
                    semanticLabel: 'Photo of ${place.name}',
                    loadingBuilder: (context, child, progress) =>
                        progress == null
                        ? child
                        : Container(
                            height: 150,
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: const Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                    errorBuilder: (context, error, stack) =>
                        const SizedBox.shrink(),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                place.name,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (resolving) ...[
                              const SizedBox(width: 10),
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  semanticsLabel: 'Finding address',
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            ?distance,
                            if (place.category != null)
                              place.category!.replaceAll('_', ' '),
                            if (weather != null)
                              '${weather!.emoji} ${formatTemperature(weather!.temperatureC)}',
                          ].join(' · '),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Hide details',
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Action row — horizontally scrollable like Google Maps.
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.directions, size: 18),
                    label: const Text('Directions'),
                    onPressed: () {
                      unawaited(HapticFeedback.selectionClick());
                      onDirections();
                    },
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: Icon(
                      isSaved ? Icons.star : Icons.bookmark_border,
                      size: 18,
                    ),
                    label: Text(isSaved ? 'Saved' : 'Save'),
                    onPressed: () {
                      unawaited(HapticFeedback.lightImpact());
                      onSavePressed();
                    },
                  ),
                  const SizedBox(width: 8),
                  if (telUri != null) ...[
                    OutlinedButton.icon(
                      icon: const Icon(Icons.call, size: 18),
                      label: const Text('Call'),
                      onPressed: () => _open(context, telUri),
                    ),
                    const SizedBox(width: 8),
                  ],
                  OutlinedButton.icon(
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Share'),
                    onPressed: () => SharePlus.instance.share(
                      ShareParams(
                        text: '${place.name}\n$_osmUrl',
                        subject: place.name,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.public, size: 18),
                    label: const Text('OSM'),
                    onPressed: () => _open(
                      context,
                      Uri.parse(_osmUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 16),

            // Detail tiles — visible when the sheet is dragged up.
            if (place.address != null)
              ListTile(
                leading: const Icon(Icons.location_on_outlined),
                title: Text(place.address!),
                dense: true,
              ),
            if (place.openingHours != null)
              ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(_prettifyHours(place.openingHours!)),
                dense: true,
              ),
            if (telUri != null)
              ListTile(
                leading: const Icon(Icons.call_outlined),
                title: Text(phone!),
                dense: true,
                onTap: () => _open(context, telUri),
              ),
            if (place.website != null)
              ListTile(
                leading: const Icon(Icons.language),
                title: Text(
                  place.website!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.colorScheme.primary),
                ),
                dense: true,
                onTap: () => _open(
                  context,
                  website,
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ListTile(
              leading: const Icon(Icons.pin_drop_outlined),
              title: Text(_coords),
              trailing: const Icon(Icons.copy, size: 18),
              dense: true,
              onTap: () {
                unawaited(Clipboard.setData(ClipboardData(text: _coords)));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Coordinates copied'),
                    behavior: SnackBarBehavior.floating,
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            if (weather != null)
              ListTile(
                leading: const Icon(Icons.thermostat),
                title: Text(
                  '${weather!.emoji} ${weather!.label} · ${formatTemperature(weather!.temperatureC, decimals: 1)} at this location',
                ),
                dense: true,
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// OSM opening_hours strings are compact ("Mo-Fr 09:00-18:00; Sa 10:00-14:00").
  /// Make them slightly friendlier to read.
  String _prettifyHours(String raw) => raw.replaceAll(';', '\n');
}
