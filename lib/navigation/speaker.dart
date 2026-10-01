import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../services/app_exception.dart';

/// Voice output for turn-by-turn guidance. An interface so the engine can
/// be driven in tests without a platform channel.
abstract class Speaker {
  Future<void> speak(String text);
  Future<void> stop();
}

/// Text-to-speech through the platform engine. One shared instance for the
/// whole app: creating a `FlutterTts` per navigation session leaks native
/// synthesizers and re-runs engine initialisation every trip.
class TtsSpeaker implements Speaker {
  final FlutterTts _tts = FlutterTts();
  Future<void>? _ready;

  TtsSpeaker._();

  static final TtsSpeaker shared = TtsSpeaker._();

  /// BCP-47 language tag; matches the language routing instructions are
  /// requested in, so the voice pronounces them correctly.
  String language = 'en-US';

  Future<void> _configure() => _ready ??= () async {
    try {
      await _tts.setLanguage(language);
      await _tts.setSpeechRate(0.52);
      if (!kIsWeb && Platform.isIOS) {
        // Duck music/podcasts instead of stopping them, and keep
        // speaking with the silent switch on, like every nav app.
        await _tts.setSharedInstance(true);
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.duckOthers,
            IosTextToSpeechAudioCategoryOptions
                .interruptSpokenAudioAndMixWithOthers,
          ],
          IosTextToSpeechAudioMode.voicePrompt,
        );
      }
    } on Exception catch (e, s) {
      logError('tts configure', e, s);
    }
  }();

  @override
  Future<void> speak(String text) async {
    await _configure();
    try {
      // `focus: true` requests transient audio focus on Android so other
      // media ducks for the duration of the prompt.
      await _tts.speak(text, focus: true);
    } on Exception catch (e, s) {
      logError('tts speak', e, s);
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } on Exception catch (e, s) {
      logError('tts stop', e, s);
    }
  }
}
