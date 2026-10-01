import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/nav_route.dart';
import '../models/place.dart';
import '../services/app_exception.dart';
import '../ui/icons.dart';
import '../util/geo.dart';

/// Bottom panel in directions mode: travel-mode tabs, route alternatives,
/// expandable step-by-step directions, and the Start button.
///
/// Swipe the handle down (or tap it) to collapse the panel to a compact
/// summary bar so the map stays visible; swipe up to expand it again.
class RoutePanel extends StatefulWidget {
  final Place destination;
  final List<NavRoute> routes;
  final int selectedIndex;
  final TravelMode mode;
  final RouteOptions options;
  final bool loading;
  final AppException? error;
  final ValueChanged<TravelMode> onModeChanged;
  final ValueChanged<RouteOptions> onOptionsChanged;
  final ValueChanged<int> onRouteSelected;

  /// Tapping a step previews it on the map.
  final ValueChanged<RouteManeuver>? onStepTapped;
  final VoidCallback onRetry;
  final VoidCallback onStart;
  final VoidCallback onClose;

  const RoutePanel({
    super.key,
    required this.destination,
    required this.routes,
    required this.selectedIndex,
    required this.mode,
    required this.options,
    required this.loading,
    required this.onModeChanged,
    required this.onOptionsChanged,
    required this.onRouteSelected,
    required this.onRetry,
    required this.onStart,
    required this.onClose,
    this.onStepTapped,
    this.error,
  });

  @override
  State<RoutePanel> createState() => _RoutePanelState();
}

class _RoutePanelState extends State<RoutePanel> {
  bool _showSteps = false;
  bool _collapsed = false;

  NavRoute? get _selected => widget.routes.isEmpty
      ? null
      : widget.routes[widget.selectedIndex.clamp(0, widget.routes.length - 1)];

  void _toggleCollapsed() => setState(() => _collapsed = !_collapsed);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    // Landscape phones: don't let the panel swallow the whole map.
    final maxHeight = size.height * (size.width > size.height ? 0.8 : 0.55);
    return Card(
      margin: const EdgeInsets.all(12),
      elevation: 6,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: 560),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                button: true,
                label: _collapsed ? 'Expand directions' : 'Collapse directions',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleCollapsed,
                  onVerticalDragEnd: (details) {
                    final vy = details.velocity.pixelsPerSecond.dy;
                    setState(() {
                      if (vy > 100) _collapsed = true;
                      if (vy < -100) _collapsed = false;
                    });
                  },
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      if (!_collapsed)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 2, 8, 0),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Your location  →  ${widget.destination.name}',
                                  style: theme.textTheme.titleSmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: 'Close directions',
                                onPressed: widget.onClose,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_collapsed)
                _summaryRow(theme, compact: true)
              else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SegmentedButton<TravelMode>(
                      segments: [
                        for (final m in TravelMode.values)
                          ButtonSegment(
                            value: m,
                            icon: Icon(m.icon, size: 20),
                            tooltip: m.label,
                          ),
                      ],
                      selected: {widget.mode},
                      onSelectionChanged: (s) {
                        unawaited(HapticFeedback.selectionClick());
                        widget.onModeChanged(s.first);
                      },
                      showSelectedIcon: false,
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      icon: Badge(
                        isLabelVisible: widget.options.any,
                        child: const Icon(Icons.tune, size: 20),
                      ),
                      tooltip: 'Route options',
                      onPressed: () => _showOptions(context),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (widget.loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  )
                else if (widget.error != null)
                  _errorBlock(theme, widget.error!)
                else if (_selected != null)
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          for (var i = 0; i < widget.routes.length; i++)
                            _routeOption(context, i),
                          TextButton.icon(
                            icon: Icon(
                              _showSteps
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                            ),
                            label: Text(
                              _showSteps
                                  ? 'Hide steps'
                                  : 'Show steps (${_selected!.maneuvers.length})',
                            ),
                            onPressed: () =>
                                setState(() => _showSteps = !_showSteps),
                          ),
                          if (_showSteps)
                            for (final m in _selected!.maneuvers)
                              ListTile(
                                dense: true,
                                leading: Icon(m.icon, size: 22),
                                title: Text(m.instruction),
                                trailing: m.lengthMeters > 0
                                    ? Text(formatDistance(m.lengthMeters))
                                    : null,
                                onTap: widget.onStepTapped == null
                                    ? null
                                    : () => widget.onStepTapped!(m),
                              ),
                        ],
                      ),
                    ),
                  ),
                if (!widget.loading &&
                    widget.error == null &&
                    _selected != null)
                  _summaryRow(theme, compact: false),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorBlock(ThemeData theme, AppException error) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
    child: Column(
      children: [
        Row(
          children: [
            Icon(
              error is OfflineException ? Icons.wifi_off : Icons.error_outline,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                error.message,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ],
        ),
        if (error.retryable) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: widget.onRetry,
            ),
          ),
        ],
      ],
    ),
  );

  Widget _summaryRow(ThemeData theme, {required bool compact}) {
    final selected = _selected;
    if (selected == null) {
      // Collapsed while loading/error: still give a way back up.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.loading
                    ? 'Finding routes…'
                    : (widget.error?.message ?? ''),
                style: theme.textTheme.bodyMedium,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Close directions',
              onPressed: widget.onClose,
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${formatDuration(selected.timeSeconds)} · '
                '${formatDistance(selected.distanceMeters)} · '
                'arrive ${formatEta(selected.timeSeconds)}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            icon: const Icon(Icons.navigation),
            label: const Text('Start'),
            onPressed: widget.onStart,
          ),
        ],
      ),
    );
  }

  /// Options apply as soon as a switch flips — no Apply button to forget,
  /// nothing lost when the sheet is swiped away.
  void _showOptions(BuildContext context) {
    var current = widget.options;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => StatefulBuilder(
          builder: (context, setSheetState) {
            void update(RouteOptions next) {
              setSheetState(() => current = next);
              widget.onOptionsChanged(next);
            }

            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      'Route options',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Avoid tolls'),
                    secondary: const Icon(Icons.toll),
                    value: current.avoidTolls,
                    onChanged: (v) => update(current.copyWith(avoidTolls: v)),
                  ),
                  SwitchListTile(
                    title: const Text('Avoid highways'),
                    secondary: const Icon(Icons.remove_road),
                    value: current.avoidHighways,
                    onChanged: (v) =>
                        update(current.copyWith(avoidHighways: v)),
                  ),
                  SwitchListTile(
                    title: const Text('Avoid ferries'),
                    secondary: const Icon(Icons.directions_boat),
                    value: current.avoidFerries,
                    onChanged: (v) => update(current.copyWith(avoidFerries: v)),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _routeOption(BuildContext context, int index) {
    final route = widget.routes[index];
    final isSelected = index == widget.selectedIndex;
    final theme = Theme.of(context);
    final badges = route.badges;
    return ListTile(
      dense: true,
      selected: isSelected,
      leading: Icon(
        isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: isSelected ? theme.colorScheme.primary : null,
      ),
      title: Text(
        index == 0 ? 'Fastest route' : 'Alternative ${index + 1}',
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: badges.isEmpty ? null : Text(badges.join(' · ')),
      trailing: Text(
        '${formatDuration(route.timeSeconds)} · ${formatDistance(route.distanceMeters)}',
      ),
      onTap: () {
        unawaited(HapticFeedback.selectionClick());
        widget.onRouteSelected(index);
      },
    );
  }
}
