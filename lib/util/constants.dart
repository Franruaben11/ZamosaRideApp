import 'package:flutter/material.dart';

/// Brand colour (Google-Maps-style blue) used for the route, markers,
/// the seed colour and highlighted chips.
const kBrandBlue = Color(0xFF1A73E8);
const kBrandBlueDark = Color(0xFF0B57D0);

/// Pin colour for the selected place.
const kPinRed = Color(0xFFEA4335);

/// Speed (m/s) above which GPS course is trusted over the compass / route
/// bearing. Shared by the navigation engine and the map screen so both
/// flip between sensors at the same moment.
const kMovingSpeedMps = 1.5;

/// Speed (m/s) below which the map turns with the phone's compass while
/// navigating (stationary at a junction, walking slowly).
const kStationarySpeedMps = 2.0;

/// Speed (m/s) above which a heading that opposes the route counts as a
/// wrong turn (higher than [kMovingSpeedMps] to ignore parking manoeuvres).
const kWrongTurnSpeedMps = 2.5;

/// Place sheet snap points as a fraction of screen height.
const kSheetMinSize = 0.20;
const kSheetPeekSize = 0.32;
const kSheetMaxSize = 0.68;

/// Minimum touch target (Material accessibility guideline).
const kMinTapSize = 48.0;

/// Default snack bar duration.
const kToastDuration = Duration(seconds: 3);
