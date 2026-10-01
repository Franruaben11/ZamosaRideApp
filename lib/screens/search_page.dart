import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/place.dart';
import '../services/app_exception.dart';
import '../services/geocoding_service.dart';
import '../services/storage_service.dart';
import '../ui/icons.dart';
import '../util/geo.dart';

/// Full-screen search with live autocomplete (Photon), plus saved places and
/// recent searches when the query is empty. Pops with the chosen [Place].
///
/// Also accepts pasted coordinates ("17.3616, 78.4747", `geo:` URIs).
class SearchPage extends StatefulWidget {
  final GeocodingService geocoding;
  final StorageService storage;
  final LatLng? near;

  const SearchPage({
    super.key,
    required this.geocoding,
    required this.storage,
    this.near,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  int _requestId = 0;
  List<Place> _results = [];
  List<Place> _saved = [];
  List<Place> _recents = [];
  Place? _home;
  Place? _work;
  Place? _coordinateHit;
  bool _loading = false;
  AppException? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLocal());
  }

  Future<void> _loadLocal() async {
    final (saved, recents, home, work) = await (
      widget.storage.getSaved(),
      widget.storage.getRecents(),
      widget.storage.getHome(),
      widget.storage.getWork(),
    ).wait;
    if (mounted) {
      setState(() {
        _saved = saved;
        _recents = recents;
        _home = home;
        _work = work;
      });
    }
  }

  void _onChanged(String query) {
    _debounce?.cancel();
    final trimmed = query.trim();
    final coordinate = parseCoordinates(trimmed);
    if (coordinate != null) {
      _requestId++;
      setState(() {
        _coordinateHit = Place.pin(
          coordinate,
          name:
              '${coordinate.latitude.toStringAsFixed(5)}, ${coordinate.longitude.toStringAsFixed(5)}',
        );
        _results = [];
        _loading = false;
        _error = null;
      });
      return;
    }
    if (trimmed.length < 2) {
      _requestId++;
      setState(() {
        _coordinateHit = null;
        _results = [];
        _loading = false;
        _error = null;
      });
      return;
    }
    // Keep the previous results on screen until the new ones arrive; only
    // the thin progress bar shows that a search is pending.
    setState(() {
      _coordinateHit = null;
      _loading = true;
      _error = null;
    });
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_search(trimmed)),
    );
  }

  Future<void> _search(String query) async {
    final id = ++_requestId;
    try {
      final results = await widget.geocoding.search(query, near: widget.near);
      if (!mounted || id != _requestId) return;
      setState(() {
        _results = results;
        _loading = false;
        _error = null;
      });
    } on Exception catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _loading = false;
        _error = toAppException(e);
      });
    }
  }

  void _submit(String query) {
    _debounce?.cancel();
    final trimmed = query.trim();
    if (_coordinateHit != null) {
      _select(_coordinateHit!);
    } else if (_results.isNotEmpty) {
      _select(_results.first);
    } else if (trimmed.length >= 2) {
      setState(() {
        _loading = true;
        _error = null;
      });
      unawaited(_search(trimmed));
    }
  }

  void _select(Place place) {
    unawaited(widget.storage.addRecent(place));
    Navigator.of(context).pop(place);
  }

  Future<void> _removeRecent(Place place) async {
    final index = _recents.indexOf(place);
    setState(() => _recents = [..._recents]..remove(place));
    await widget.storage.removeRecent(place);
    _undoBar('Removed from recents', () async {
      await widget.storage.restoreRecent(place, index: index);
      await _loadLocal();
    });
  }

  Future<void> _removeSaved(Place place) async {
    final index = _saved.indexOf(place);
    setState(() => _saved = [..._saved]..remove(place));
    await widget.storage.removeSaved(place);
    _undoBar('Removed from saved places', () async {
      await widget.storage.restoreSaved(place, index: index);
      await _loadLocal();
    });
  }

  void _undoBar(String message, Future<void> Function() undo) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(undo()),
          ),
        ),
      );
  }

  Future<void> _clearRecents() async {
    final previous = _recents;
    setState(() => _recents = []);
    await widget.storage.clearRecents();
    _undoBar('Recent searches cleared', () async {
      for (final p in previous.reversed) {
        await widget.storage.restoreRecent(p);
      }
      await _loadLocal();
    });
  }

  Future<void> _quickTileMenu(
    String label,
    Place? place,
    Future<void> Function(Place?) save,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_location_alt_outlined),
              title: Text(place == null ? 'Set $label' : 'Change $label'),
              subtitle: const Text('Search for a place, then choose it'),
              onTap: () => Navigator.pop(context, 'set'),
            ),
            if (place != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text('Remove $label'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'remove':
        await save(null);
        await _loadLocal();
      case 'set':
        final picked = await Navigator.of(context).push<Place>(
          MaterialPageRoute(
            builder: (_) => SearchPage(
              geocoding: widget.geocoding,
              storage: widget.storage,
              near: widget.near,
            ),
          ),
        );
        if (picked != null) {
          await save(picked);
          await _loadLocal();
        }
    }
  }

  Widget _quickTile({
    required IconData icon,
    required String label,
    required Place? place,
    required Future<void> Function(Place?) save,
  }) {
    return Expanded(
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => place != null
              ? _select(place)
              : _quickTileMenu(label, place, save),
          onLongPress: () => _quickTileMenu(label, place, save),
          child: Semantics(
            button: true,
            label: '$label: ${place?.name ?? 'not set'}',
            hint: 'Long press to change',
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    icon,
                    color: Theme.of(context).colorScheme.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          place?.name ?? 'Set location',
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeTile(Place place, {IconData? leading, Widget? trailing}) {
    final distance = widget.near == null
        ? null
        : formatDistance(distanceMeters(widget.near!, place.point));
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(leading ?? iconForCategory(place.category), size: 20),
      ),
      title: Text(place.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: place.address == null
          ? null
          : Text(place.address!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing:
          trailing ??
          (distance == null
              ? null
              : Text(distance, style: Theme.of(context).textTheme.bodySmall)),
      onTap: () => _select(place),
    );
  }

  Widget _dismissible(
    Place place,
    Widget child,
    Future<void> Function() onRemove,
  ) {
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey('${place.name}@${place.point}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Icon(
          Icons.delete_outline,
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
      onDismissed: (_) => onRemove(),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showingSuggestions =
        _controller.text.trim().length < 2 && _coordinateHit == null;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          onSubmitted: _submit,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search places, addresses, coordinates…',
            border: InputBorder.none,
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear',
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  ),
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _loading
              ? const LinearProgressIndicator(minHeight: 2)
              : const SizedBox(height: 2),
        ),
      ),
      body: _coordinateHit != null
          ? ListView(
              children: [
                const _SectionHeader('Coordinates'),
                _placeTile(_coordinateHit!, leading: Icons.pin_drop_outlined),
              ],
            )
          : _error != null && _results.isEmpty
          ? _errorView(theme)
          : showingSuggestions
          ? _suggestions()
          : _results.isEmpty && !_loading
          ? const Center(child: Text('No results found'))
          : ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) => _placeTile(_results[i]),
            ),
    );
  }

  Widget _errorView(ThemeData theme) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _error is OfflineException ? Icons.wifi_off : Icons.error_outline,
            size: 40,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 12),
          Text(_error!.message, textAlign: TextAlign.center),
          if (_error!.retryable) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              onPressed: () => _submit(_controller.text),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _suggestions() => ListView(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Row(
          children: [
            _quickTile(
              icon: Icons.home,
              label: 'Home',
              place: _home,
              save: widget.storage.setHome,
            ),
            const SizedBox(width: 8),
            _quickTile(
              icon: Icons.work,
              label: 'Work',
              place: _work,
              save: widget.storage.setWork,
            ),
          ],
        ),
      ),
      if (_saved.isNotEmpty) ...[
        const _SectionHeader('Saved'),
        for (final p in _saved)
          _dismissible(
            p,
            _placeTile(
              p,
              leading: Icons.star,
              trailing: const Icon(Icons.star, size: 18, color: Colors.amber),
            ),
            () => _removeSaved(p),
          ),
      ],
      if (_recents.isNotEmpty) ...[
        _SectionHeader(
          'Recent',
          trailing: TextButton(
            onPressed: _clearRecents,
            child: const Text('Clear'),
          ),
        ),
        for (final p in _recents)
          _dismissible(
            p,
            _placeTile(p, leading: Icons.history),
            () => _removeRecent(p),
          ),
      ],
      if (_saved.isEmpty && _recents.isEmpty)
        const Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: Text(
              'Search for places, addresses,\nor points of interest',
              textAlign: TextAlign.center,
            ),
          ),
        ),
    ],
  );

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const _SectionHeader(this.title, {this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        ?trailing,
      ],
    ),
  );
}
