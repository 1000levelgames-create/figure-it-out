import 'dart:io';

class AdHelper {
  static const bool rewardedAdsEnabled = true;
  static const bool interstitialAdsEnabled = true;

  static String bannerAdUnitId() {
    if (Platform.isAndroid) {
      return 'ca-app-pub-4261132020137319/5065694226';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-4261132020137319/5445802322';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  static String rewardedAdUnitId() {
    if (Platform.isAndroid) {
      return 'ca-app-pub-4261132020137319/2436495601';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-4261132020137319/6609834475';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }

  static String interstitialAdUnitId() {
    if (Platform.isAndroid) {
      return 'ca-app-pub-4261132020137319/3558005581';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-4261132020137319/2244923914';
    } else {
      throw UnsupportedError('Unsupported platform');
    }
  }
}
