import 'package:firebase_analytics/firebase_analytics.dart';

class AnalyticsEvents {
  static FirebaseAnalytics get _analytics => FirebaseAnalytics.instance;

  static Future<void> _log(
    String name, {
    Map<String, Object?> parameters = const <String, Object?>{},
  }) async {
    try {
      final cleanedParameters = <String, Object>{};
      parameters.forEach((key, value) {
        if (value != null) {
          cleanedParameters[key] = value;
        }
      });
      await _analytics.logEvent(name: name, parameters: cleanedParameters);
    } catch (_) {
      // Analytics should never block gameplay if Firebase is unavailable.
    }
  }

  static Future<void> appOpen() async {
    // Firebase Analytics also records app_open automatically.
    try {
      await _analytics.logAppOpen();
    } catch (_) {
      // Ignore analytics failures.
    }
  }

  static Future<void> levelStart({
    required int levelId,
    required int levelIndex,
  }) {
    return _log(
      'level_start',
      parameters: <String, Object?>{
        'level_id': levelId,
        'level_index': levelIndex,
      },
    );
  }

  static Future<void> levelComplete({
    required int levelId,
    required int levelIndex,
    required Duration timeToComplete,
  }) {
    return _log(
      'level_complete',
      parameters: <String, Object?>{
        'level_id': levelId,
        'level_index': levelIndex,
        'time_ms': timeToComplete.inMilliseconds,
        'time_seconds': timeToComplete.inSeconds,
      },
    );
  }

  static Future<void> timeToComplete({
    required int levelId,
    required int levelIndex,
    required Duration duration,
  }) {
    return _log(
      'time_to_complete',
      parameters: <String, Object?>{
        'level_id': levelId,
        'level_index': levelIndex,
        'duration_ms': duration.inMilliseconds,
        'duration_seconds': duration.inSeconds,
      },
    );
  }

  static Future<void> hintUsed({
    required int levelId,
    required int levelIndex,
    required int hintsRemaining,
  }) {
    return _log(
      'hint_used',
      parameters: <String, Object?>{
        'level_id': levelId,
        'level_index': levelIndex,
        'hints_remaining': hintsRemaining,
      },
    );
  }

  static Future<void> interstitialShown({
    required int levelId,
    required int levelIndex,
  }) {
    return _log(
      'interstitial_shown',
      parameters: <String, Object?>{
        'level_id': levelId,
        'level_index': levelIndex,
      },
    );
  }

  static Future<void> rewardedAdRewarded({
    required int levelId,
    required int levelIndex,
    int rewardAmount = 1,
  }) {
    return _log(
      'rewarded_ad_rewarded',
      parameters: <String, Object?>{
        'level_id': levelId,
        'level_index': levelIndex,
        'reward_amount': rewardAmount,
      },
    );
  }

  static Future<void> settingsOpen() {
    return _log('settings_open');
  }

  static Future<void> adFailedToLoad({
    required String adType,
    int? levelId,
    int? levelIndex,
    String? errorCode,
  }) {
    final parameters = <String, Object>{
      'ad_type': adType,
    };
    if (levelId != null) {
      parameters['level_id'] = levelId;
    }
    if (levelIndex != null) {
      parameters['level_index'] = levelIndex;
    }
    if (errorCode != null) {
      parameters['error_code'] = errorCode;
    }
    return _log(
      'ad_failed_to_load',
      parameters: parameters,
    );
  }

  static Future<void> darkModeToggled({required bool enabled}) {
    return _log(
      'dark_mode_toggled',
      parameters: <String, Object?>{
        'enabled': enabled ? 1 : 0,
      },
    );
  }
}
