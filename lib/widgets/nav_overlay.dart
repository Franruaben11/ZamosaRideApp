import 'package:flutter/material.dart';

import '../navigation/navigation_engine.dart';
import '../ui/icons.dart';
import '../util/geo.dart';

const _navGreen = Color(0xFF0F7B3E);
const _navGreenDark = Color(0xFF0A5C2E);
const _navAmber = Color(0xFFB26A00);

/// Top instruction banner during turn-by-turn navigation, with a
/// "then …" preview of the maneuver after the upcoming one.
class NavBanner extends StatelessWidget {
  final NavigationEngine engine;

  const NavBanner({super.key, required this.engine});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final next = engine.nextManeuver;
    final following = engine.followingManeuver;
    final showThen = following != null && engine.distanceToNextManeuver < 200;
    final offRoute = engine.offRoute && !engine.rerouting;

    final String line;
    if (engine.rerouting) {
      line = 'Rerouting…';
    } else if (offRoute) {
      line = 'Off route — return to the highlighted road';
    } else {
      line = next?.instruction ?? '';
    }

    return Semantics(
      liveRegion: true,
      label: '${formatDistance(engine.distanceToNextManeuver)}, $line',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            decoration: BoxDecoration(
              color: offRoute ? _navAmber : _navGreen,
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(
                  blurRadius: 12,
                  offset: Offset(0, 4),
                  color: Colors.black38,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      offRoute
                          ? Icons.wrong_location_outlined
                          : (next?.icon ?? Icons.navigation),
                      color: Colors.white,
                      size: 46,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            formatDistance(engine.distanceToNextManeuver),
                            maxLines: 1,
                            // Theme text styles scale with the user's font
                            // size setting; fixed pixel sizes don't.
                            style: theme.textTheme.headlineMedium?.copyWith(
                              color: Colors.white,
                              height: 1.1,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          line,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            height: 1.25,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (showThen && !offRoute)
            Container(
              margin: const EdgeInsets.only(left: 12, top: 4),
              decoration: BoxDecoration(
                color: _navGreenDark,
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'then',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(following.icon, color: Colors.white, size: 20),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Slim bottom status bar: route progress, speed, ETA and exit — nothing
/// that can overflow on narrow screens. Secondary controls (mute,
/// overview/re-center) live as floating buttons above this bar.
class NavBottomBar extends StatelessWidget {
  final NavigationEngine engine;
  final VoidCallback onExit;

  const NavBottomBar({super.key, required this.engine, required this.onExit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = engine.route.distanceMeters;
    final progress = total <= 0
        ? 0.0
        : (1 - engine.remainingDistanceMeters / total).clamp(0.0, 1.0);
    final speed = formatSpeed(engine.speedMps);

    return Container(
      margin: const EdgeInsets.all(12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [
          BoxShadow(
            blurRadius: 12,
            offset: Offset(0, 4),
            color: Colors.black38,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            color: _navGreen,
            semanticsLabel: 'Route progress',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Row(
              children: [
                Semantics(
                  label: '${speed.value} ${speed.unit}',
                  child: ExcludeSemantics(
                    child: Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                          width: 2,
                        ),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              speed.value,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                height: 1,
                              ),
                            ),
                            Text(
                              speed.unit,
                              style: theme.textTheme.labelSmall?.copyWith(
                                height: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          formatDuration(engine.remainingTimeSeconds),
                          maxLines: 1,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            height: 1.1,
                            color: theme.brightness == Brightness.dark
                                ? const Color(0xFF5BD68E)
                                : _navGreen,
                          ),
                        ),
                      ),
                      Text(
                        '${formatDistance(engine.remainingDistanceMeters)} · '
                        'arrive ${formatEta(engine.remainingTimeSeconds)}'
                        '${engine.error != null ? ' · ${engine.error}' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: engine.error != null
                              ? theme.colorScheme.error
                              : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: theme.colorScheme.errorContainer,
                    foregroundColor: theme.colorScheme.onErrorContainer,
                    minimumSize: const Size(48, 48),
                  ),
                  icon: const Icon(Icons.close),
                  onPressed: onExit,
                  tooltip: 'End navigation',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
