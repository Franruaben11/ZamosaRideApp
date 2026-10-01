import 'package:flutter/foundation.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/overpass_service.dart';
import '../ui/icons.dart';

/// Search bar plus the nearby-category chip row shown over the map in
/// browse and place modes.
class MapTopBar extends StatelessWidget {
  final String? title;
  final bool busy;
  final bool showChips;
  final PoiCategory? activeCategory;

  /// The map has moved away from where the active category was searched.
  final ValueListenable<bool> searchAreaStale;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final ValueChanged<PoiCategory> onCategory;
  final VoidCallback onSearchThisArea;

  const MapTopBar({
    super.key,
    required this.title,
    required this.busy,
    required this.showChips,
    required this.activeCategory,
    required this.searchAreaStale,
    required this.onSearch,
    required this.onSettings,
    required this.onCategory,
    required this.onSearchThisArea,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(28),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(28),
                      onTap: onSearch,
                      child: Semantics(
                        button: true,
                        label: title == null
                            ? 'Search places'
                            : 'Search. Selected: $title',
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.search),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  title ?? 'Search here',
                                  style: theme.textTheme.bodyLarge,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (busy)
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: 'Settings',
                    onPressed: onSettings,
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
          if (showChips)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  ValueListenableBuilder<bool>(
                    valueListenable: searchAreaStale,
                    builder: (context, stale, _) =>
                        !stale || activeCategory == null
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              avatar: const Icon(Icons.refresh, size: 16),
                              label: const Text('Search this area'),
                              onPressed: onSearchThisArea,
                            ),
                          ),
                  ),
                  for (final category in PoiCategory.all)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        avatar: Icon(category.icon, size: 16),
                        label: Text(category.label),
                        selected: activeCategory == category,
                        showCheckmark: false,
                        onSelected: (_) {
                          unawaited(HapticFeedback.selectionClick());
                          onCategory(category);
                        },
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
