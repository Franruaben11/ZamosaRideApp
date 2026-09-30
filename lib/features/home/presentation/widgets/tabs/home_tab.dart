import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as flutter_widgets;
import 'package:mapbox_example/app/constants.dart';
import 'package:mapbox_example/shared/inputs/base_input.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'dart:convert';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  late MapboxMap mapboxMap;
  String? foundPlaceName;
  bool isLoading = false;
  bool isSearchingSuggestions = false;
  bool isMapLoaded = false;
  String? mapLoadError;
  List<_PlaceSuggestion> suggestions = [];

    // debounce
  Timer? _debounce;
  final Duration _debounceDuration = const Duration(milliseconds: 500);

  String mapboxToken = AppConstants.mapboxToken;

  Future<void> _goToCurrentLocation() async {
    final permissionStatus = await Permission.locationWhenInUse.status;

    if (permissionStatus.isDenied) {
      final requested = await Permission.locationWhenInUse.request();
      if (requested.isDenied || requested.isPermanentlyDenied) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Permite el acceso a la ubicación para centrarte en tu posición.'),
          ),
        );
        return;
      }
    }

    if (!mounted) return;

    try {
      final position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
        ),
      );

      mapboxMap.flyTo(
        CameraOptions(
          center: Point(
            coordinates: Position(position.longitude, position.latitude),
          ),
          zoom: 15,
        ),
        MapAnimationOptions(duration: 1000),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo obtener tu ubicación actual.'),
        ),
      );
    }
  }

  Future<void> _onMapCreated(MapboxMap createdMap) async {
    mapboxMap = createdMap;
  }

  void _handleMapLoaded(MapLoadedEventData _) {
    if (!mounted) return;
    setState(() {
      isMapLoaded = true;
      mapLoadError = null;
    });
  }

  void _handleMapLoadError(MapLoadingErrorEventData eventData) {
    if (!mounted) return;
    setState(() {
      isMapLoaded = false;
      mapLoadError = eventData.message;
    });
  }

  Future<void> _searchLocation(String query) async {
    final trimmedQuery = query.trim();

    if (trimmedQuery.isEmpty) {
      if (!mounted) return;
      setState(() {
        suggestions = [];
        isSearchingSuggestions = false;
      });
      return;
    }

    setState(() {
      isSearchingSuggestions = true;
    });

    try {
      final encodedQuery = Uri.encodeComponent(trimmedQuery);
      final url = Uri.parse(
        'https://api.mapbox.com/geocoding/v5/mapbox.places/$encodedQuery.json?autocomplete=true&limit=5&access_token=$mapboxToken'
      );
      final response = await http.get(url);

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final features = (data["features"] as List<dynamic>? ?? const []);
        final nextSuggestions = <_PlaceSuggestion>[];

        for (final feature in features) {
          final placeName = feature["place_name"] as String?;
          final coordinates = feature["geometry"]?["coordinates"] as List<dynamic>?;

          if (placeName == null || coordinates == null || coordinates.length < 2) {
            continue;
          }

          final lng = (coordinates[0] as num).toDouble();
          final lat = (coordinates[1] as num).toDouble();

          nextSuggestions.add(
            _PlaceSuggestion(
              placeName: placeName,
              longitude: lng,
              latitude: lat,
            ),
          );
        }

        setState(() {
          suggestions = nextSuggestions;
        });
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Search error: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          isSearchingSuggestions = false;
        });
      }
    }
  }

  Future<void> _selectSuggestion(_PlaceSuggestion suggestion) async {
    FocusScope.of(context).unfocus();

    mapboxMap.flyTo(
      CameraOptions(
        center: Point(coordinates: Position(suggestion.longitude, suggestion.latitude)),
        zoom: 14,
      ),
      MapAnimationOptions(duration: 1000),
    );

    if (!mounted) return;

    setState(() {
      foundPlaceName = suggestion.placeName;
      suggestions = [];
    });
  }

  double get _suggestionsPanelHeight {
    if (suggestions.isEmpty) {
      return 0;
    }

    return math.min(240, suggestions.length * 56.0);
  }

  Widget _buildSuggestionsPanel() {
    if (suggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: suggestions.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: Colors.grey.shade200),
        itemBuilder: (context, index) {
          final suggestion = suggestions[index];

          return ListTile(
            dense: true,
            title: Text(
              suggestion.placeName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _selectSuggestion(suggestion),
          );
        },
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: BaseInput(
          hint: "Search for a place",
          prefixIcon: Container(
            height: 20,
            width: 20,
            padding: isSearchingSuggestions ? const EdgeInsets.all(16) : EdgeInsets.zero,
            child: isSearchingSuggestions ? const CircularProgressIndicator(
              color: Colors.black,
              strokeWidth: 2,
            ) : const Center(child: Icon(Icons.search, color: Colors.black)),
          ),
          onChanged: (value) {
            _debounce?.cancel();
            _debounce = Timer(_debounceDuration, () {
              _searchLocation(value);
            });
          },
        ),
        bottom: PreferredSize(
          preferredSize: flutter_widgets.Size.fromHeight(_suggestionsPanelHeight),
          child: SizedBox(
            height: _suggestionsPanelHeight,
            child: _buildSuggestionsPanel(),
          ),
        ),
      ),
      body: Container(
        color: Colors.white,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: MapWidget(
                key: const ValueKey("mapWidget"),
                textureView: true,
                cameraOptions: CameraOptions(
                  center: Point(coordinates: Position(-122.433135, 37.785160)),
                  zoom: 14,
                ),
                styleUri: AppConstants.mapboxStyleID,
                onMapCreated: _onMapCreated,
                onMapLoadedListener: _handleMapLoaded,
                onMapLoadErrorListener: _handleMapLoadError,
              ),
            ),
            if (!isMapLoaded && mapLoadError == null)
              Positioned.fill(
                child: Container(
                  color: Colors.white,
                  alignment: Alignment.center,
                  child: const CircularProgressIndicator(color: Colors.black),
                ),
              ),
            if (mapLoadError != null)
              Positioned.fill(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(24),
                  alignment: Alignment.center,
                  child: Text(
                    'No se pudo cargar el mapa:\n${mapLoadError ?? 'Error desconocido'}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.black),
                  ),
                ),
              ),
            Positioned(
              right: 20,
              bottom: 28,
              child: FloatingActionButton(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                onPressed: _goToCurrentLocation,
                tooltip: 'Ir a mi ubicación',
                child: const Icon(Icons.my_location),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaceSuggestion {
  const _PlaceSuggestion({
    required this.placeName,
    required this.longitude,
    required this.latitude,
  });

  final String placeName;
  final double longitude;
  final double latitude;
}
