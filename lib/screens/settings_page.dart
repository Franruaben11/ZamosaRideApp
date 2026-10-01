import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/render_quality.dart';
import '../services/storage_service.dart';
import '../util/units.dart';
import '../widgets/vector_basemap.dart';

/// Units, theme, voice guidance, rendering and data management.
class SettingsPage extends StatelessWidget {
  final StorageService storage;

  const SettingsPage({super.key, required this.storage});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _header(theme, 'Display'),
          ValueListenableBuilder<Units>(
            valueListenable: AppSettings.units,
            builder: (context, units, _) => ListTile(
              leading: const Icon(Icons.straighten),
              title: const Text('Distance units'),
              subtitle: Text(units.label),
              trailing: SegmentedButton<Units>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: Units.metric, label: Text('km')),
                  ButtonSegment(value: Units.imperial, label: Text('mi')),
                ],
                selected: {units},
                onSelectionChanged: (s) => AppSettings.units.value = s.first,
              ),
            ),
          ),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: AppSettings.themeMode,
            builder: (context, mode, _) => ListTile(
              leading: const Icon(Icons.dark_mode_outlined),
              title: const Text('Theme'),
              trailing: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ],
                selected: {mode},
                onSelectionChanged: (s) =>
                    AppSettings.themeMode.value = s.first,
              ),
            ),
          ),
          const Divider(),
          _header(theme, 'Navigation'),
          ValueListenableBuilder<bool>(
            valueListenable: AppSettings.voiceGuidance,
            builder: (context, on, _) => SwitchListTile(
              secondary: const Icon(Icons.record_voice_over_outlined),
              title: const Text('Voice guidance'),
              subtitle: const Text('Spoken turn-by-turn instructions'),
              value: on,
              onChanged: (v) => AppSettings.voiceGuidance.value = v,
            ),
          ),
          const Divider(),
          _header(theme, 'Map rendering'),
          ValueListenableBuilder<RenderQuality>(
            valueListenable: RenderQualitySettings.choice,
            builder: (context, q, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<RenderQuality>(
                    showSelectedIcon: false,
                    segments: [
                      for (final v in RenderQuality.values)
                        ButtonSegment(value: v, label: Text(v.label)),
                    ],
                    selected: {q},
                    onSelectionChanged: (s) =>
                        RenderQualitySettings.set(s.first),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Text(
                    '${RenderQualitySettings.effective.label}: '
                    '${RenderQualitySettings.effective.description}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          _header(theme, 'Your data'),
          ListTile(
            leading: const Icon(Icons.history_toggle_off),
            title: const Text('Clear recent searches'),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Clear recent searches?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await storage.clearRecents();
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Recent searches cleared'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
          ),
          const Divider(),
          _header(theme, 'About'),
          const ListTile(
            leading: Icon(Icons.map_outlined),
            title: Text('ZamosaRide'),
            subtitle: Text(
              'Map data © OpenStreetMap contributors (ODbL) · '
              'Places © Overture Maps Foundation · Routing by Valhalla/FOSSGIS · '
              'Search by Photon & Nominatim · Weather by Open-Meteo · '
              'Photos via Wikimedia Commons',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.layers_outlined),
            title: const Text('Vector tiles'),
            subtitle: Text(
              'OpenFreeMap (liberty) · Overture release ${VectorBasemap.overtureRelease}',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Open-source licences'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'ZamosaRide',
              applicationVersion: '0.1.0',
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.primary,
      ),
    ),
  );
}
