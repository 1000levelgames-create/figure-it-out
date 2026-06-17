import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'analytics_events.dart';
import 'ad_helper.dart';
import 'tutorial.dart';

class AppSettings {
  static bool soundOn = true;
  static bool vibrationOn = true;
  static bool darkMode = false;
  static bool analyticsOn = true;
}

const String _saveKey = 'puzzle_mania_save_state';
const String _settingsKey = 'puzzle_mania_settings';
const String _developerModeKey = 'puzzle_mania_developer_mode';
// Samsung S22 Ultra portrait aspect ratio: 1440 / 3088 ~= 0.466.
const Size _webDesignSize = Size(1440, 3088);

final ValueNotifier<bool> appThemeNotifier = ValueNotifier<bool>(AppSettings.darkMode);
final ValueNotifier<bool> developerModeNotifier = ValueNotifier<bool>(false);
List<_LevelData>? _cachedLevels;
Future<List<_LevelData>>? _cachedLevelsFuture;

enum _StartupPhase {
  loading,
  fadingOut,
  fadingIn,
  ready,
}

Future<List<_LevelData>> _loadAllLevels() async {
  final cached = _cachedLevels;
  if (cached != null) {
    return cached;
  }

  final pending = _cachedLevelsFuture;
  if (pending != null) {
    return pending;
  }

  final future = () async {
    final levels = <_LevelData>[];
    for (final assetKey in _GameScreenState._levelAssetPaths) {
      final fileJson = await rootBundle.loadString(assetKey);
      final parsed = jsonDecode(fileJson) as Map<String, dynamic>;
      final rawLevels = (parsed['levels'] as List<dynamic>? ?? const <dynamic>[]);
      for (final rawLevel in rawLevels) {
        levels.add(_LevelData.fromJson(rawLevel as Map<String, dynamic>));
      }
    }

    if (levels.isEmpty) {
      throw StateError('No level data found.');
    }

    _cachedLevels = levels;
    return levels;
  }();

  _cachedLevelsFuture = future;
  try {
    return await future;
  } finally {
    _cachedLevelsFuture = null;
  }
}

Future<void> _bootstrapAppResources() async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  if (!kIsWeb) {
    await MobileAds.instance.initialize();
  }
  try {
    await Firebase.initializeApp();
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  } catch (_) {
    // Keep the app running even if Firebase is not fully configured yet.
  }
  await _loadAppSettings();
  await _loadDeveloperMode();
  await _applyFirebaseCollectionSettings();
  await _loadAllLevels();
}

final AudioPlayer _uiClickPlayer = AudioPlayer();
bool _uiClickPlayerConfigured = false;

Future<void> _playUiLowPopSound() async {
  if (!AppSettings.soundOn) {
    return;
  }
  if (!_uiClickPlayerConfigured) {
    _uiClickPlayerConfigured = true;
    unawaited(_uiClickPlayer.setPlayerMode(PlayerMode.lowLatency));
  }
  try {
    await _uiClickPlayer.stop();
    await _uiClickPlayer.play(AssetSource('audio/one_pop.wav'));
  } catch (_) {
    // Ignore UI click failures so button taps still work.
  }
}

Future<void> _playUiDoublePopSound() async {
  if (!AppSettings.soundOn) {
    return;
  }
  if (!_uiClickPlayerConfigured) {
    _uiClickPlayerConfigured = true;
    unawaited(_uiClickPlayer.setPlayerMode(PlayerMode.lowLatency));
  }
  try {
    await _uiClickPlayer.stop();
    await _uiClickPlayer.play(AssetSource('audio/double_pop.wav'));
  } catch (_) {
    // Ignore UI click failures so settings toggles still work.
  }
}

Future<void> _saveAppSettings() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _settingsKey,
    jsonEncode(<String, dynamic>{
      'soundOn': AppSettings.soundOn,
      'vibrationOn': AppSettings.vibrationOn,
      'darkMode': AppSettings.darkMode,
      'analyticsOn': AppSettings.analyticsOn,
    }),
  );
}

Future<void> _saveDeveloperMode(bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_developerModeKey, enabled);
  developerModeNotifier.value = enabled;
}

Future<void> _applyFirebaseCollectionSettings() async {
  try {
    await FirebaseAnalytics.instance
        .setAnalyticsCollectionEnabled(AppSettings.analyticsOn);
    await FirebaseCrashlytics.instance
        .setCrashlyticsCollectionEnabled(AppSettings.analyticsOn && !kDebugMode);
  } catch (_) {
    // Ignore Firebase configuration errors so the app keeps running.
  }
}

Future<void> _loadAppSettings() async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString(_settingsKey);
  if (saved == null || saved.isEmpty) {
    appThemeNotifier.value = AppSettings.darkMode;
    return;
  }
  try {
    final decoded = jsonDecode(saved) as Map<String, dynamic>;
    AppSettings.soundOn = decoded['soundOn'] as bool? ?? AppSettings.soundOn;
    AppSettings.vibrationOn = decoded['vibrationOn'] as bool? ?? AppSettings.vibrationOn;
    AppSettings.darkMode = decoded['darkMode'] as bool? ?? AppSettings.darkMode;
    AppSettings.analyticsOn = decoded['analyticsOn'] as bool? ?? AppSettings.analyticsOn;
  } catch (_) {
    // Ignore malformed settings and keep defaults.
  }
  appThemeNotifier.value = AppSettings.darkMode;
}

Future<void> _loadDeveloperMode() async {
  final prefs = await SharedPreferences.getInstance();
  developerModeNotifier.value = prefs.getBool(_developerModeKey) ?? false;
}

Future<int> _loadSavedMenuLevelNumber() async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString(_saveKey);
  if (saved == null || saved.isEmpty) {
    return 1;
  }
  try {
    final decoded = jsonDecode(saved) as Map<String, dynamic>;
    final levelIndex = (decoded['levelIndex'] as num?)?.toInt() ?? 0;
    return levelIndex + 1;
  } catch (_) {
    return 1;
  }
}

Future<void> _playButtonPressFeedback() async {
  unawaited(_playUiLowPopSound());
  if (AppSettings.vibrationOn) {
    unawaited(HapticFeedback.selectionClick());
  }
}

void _handleButtonPress(
  VoidCallback onPressed, {
  bool enableFeedback = true,
}) {
  if (enableFeedback) {
    unawaited(_playButtonPressFeedback());
  }
  onPressed();
}

class AppBannerAd extends StatefulWidget {
  const AppBannerAd({
    this.backgroundColor = const Color(0xfff6efeb),
    super.key,
  });

  final Color backgroundColor;

  @override
  State<AppBannerAd> createState() => _AppBannerAdState();
}

class _AppBannerAdState extends State<AppBannerAd> {
  BannerAd? _bannerAd;
  bool _isLoaded = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      return;
    }
    _loadBannerAd();
  }

  void _loadBannerAd() {
    if (kIsWeb) {
      return;
    }
    final bannerAd = BannerAd(
      adUnitId: AdHelper.bannerAdUnitId(),
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted) {
            ad.dispose();
            return;
          }
          setState(() {
            _bannerAd = ad as BannerAd;
            _isLoaded = true;
          });
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
        },
      ),
    );

    bannerAd.load();
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return const SizedBox.shrink();
    }
    if (!_isLoaded || _bannerAd == null) {
      return const SizedBox(height: 0);
    }

    return Container(
      color: widget.backgroundColor,
      alignment: Alignment.center,
      width: _bannerAd!.size.width.toDouble(),
      height: _bannerAd!.size.height.toDouble(),
      child: AdWidget(ad: _bannerAd!),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PuzzleManiaApp());
}

class PuzzleManiaApp extends StatefulWidget {
  const PuzzleManiaApp({super.key});

  @override
  State<PuzzleManiaApp> createState() => _PuzzleManiaAppState();
}

class _PuzzleManiaAppState extends State<PuzzleManiaApp>
    with TickerProviderStateMixin {
  late Future<void> _bootstrapFuture;
  late final AnimationController _loadingFadeController;
  late final AnimationController _menuFadeController;
  int _menuLevelNumber = 1;
  _StartupPhase _startupPhase = _StartupPhase.loading;

  @override
  void initState() {
    super.initState();
    _loadingFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _menuFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _startBootstrap();
  }

  @override
  void dispose() {
    _loadingFadeController.dispose();
    _menuFadeController.dispose();
    super.dispose();
  }

  void _startBootstrap() {
    _startupPhase = _StartupPhase.loading;
    _loadingFadeController.reset();
    _menuFadeController.reset();
    _bootstrapFuture = Future.wait<void>([
      _bootstrapAppResources(),
      Future<void>.delayed(const Duration(seconds: 3)),
    ]).then((_) async {
      _menuLevelNumber = await _loadSavedMenuLevelNumber();
    });
    _bootstrapFuture.then((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _startupPhase = _StartupPhase.fadingOut;
      });
      _loadingFadeController.forward(from: 0).then((_) {
        if (!mounted) {
          return;
        }
        setState(() {
          _startupPhase = _StartupPhase.fadingIn;
        });
        _menuFadeController.forward(from: 0).then((_) {
          if (!mounted) {
            return;
          }
          setState(() {
            _startupPhase = _StartupPhase.ready;
          });
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrapFuture,
      builder: (context, snapshot) {
        final Widget home;
        if (snapshot.hasError) {
          home = StartupErrorScreen(
            message: 'Startup failed: ${snapshot.error}',
            onRetry: () {
              setState(() {
                _startBootstrap();
              });
            },
          );
        } else if (snapshot.connectionState != ConnectionState.done ||
            _startupPhase == _StartupPhase.loading) {
          home = const StartupLoadingScreen();
        } else if (_startupPhase == _StartupPhase.fadingOut ||
            _startupPhase == _StartupPhase.fadingIn) {
          home = StartupFadeTransitionScreen(
            loadingChild: const StartupLoadingScreen(),
            menuChild: MenuScreen(initialLevelNumber: _menuLevelNumber),
            loadingAnimation: _loadingFadeController,
            menuAnimation: _menuFadeController,
          );
        } else {
          home = MenuScreen(initialLevelNumber: _menuLevelNumber);
        }
        return ValueListenableBuilder<bool>(
          valueListenable: appThemeNotifier,
          builder: (context, isDarkMode, _) {
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              title: 'Figure It Out',
              themeMode: isDarkMode ? ThemeMode.dark : ThemeMode.light,
              theme: _buildAppTheme(Brightness.light),
              darkTheme: _buildAppTheme(Brightness.dark),
              builder: (context, child) {
                if (child == null) {
                  return const SizedBox.shrink();
                }
                if (!kIsWeb) {
                  return child;
                }
                return _WebPhoneFrame(child: child);
              },
              home: home,
            );
          },
        );
      },
    );
  }
}

class _WebPhoneFrame extends StatelessWidget {
  const _WebPhoneFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = math.min(
          constraints.maxWidth / _webDesignSize.width,
          constraints.maxHeight / _webDesignSize.height,
        );
        final centeredChild = MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: _webDesignSize,
            devicePixelRatio: 1.0,
          ),
          child: SizedBox(
            width: _webDesignSize.width,
            height: _webDesignSize.height,
            child: child,
          ),
        );
        return ColoredBox(
          color: AppColors.background,
          child: Center(
            child: ClipRect(
              child: Transform.scale(
                scale: scale.isFinite && scale > 0 ? scale : 1.0,
                alignment: Alignment.center,
                child: SizedBox(
                  width: _webDesignSize.width,
                  height: _webDesignSize.height,
                  child: centeredChild,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

ThemeData _buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'Arial',
    scaffoldBackgroundColor: isDark ? AppColors.background : AppColors.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xfff7981d),
      brightness: brightness,
      surface: isDark ? AppColors.surface : AppColors.surface,
    ),
  );
}

class MenuScreen extends StatefulWidget {
  const MenuScreen({
    this.initialLevelNumber = 1,
    super.key,
  });

  final int initialLevelNumber;

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  late int _levelNumber;

  String get _levelLabel => 'Level $_levelNumber';

  bool get _isTenLevelStyleLevel => _levelNumber % 10 == 0;

  bool get _isCenturyLevel => _levelNumber % 100 == 0;

  Color get _menuButtonColor {
    if (_isCenturyLevel) {
      return AppColors.purple;
    }
    if (_isTenLevelStyleLevel) {
      return AppColors.red;
    }
    return AppColors.orange;
  }

  bool get _showMenuHorns => _isTenLevelStyleLevel || _isCenturyLevel;

  @override
  void initState() {
    super.initState();
    _levelNumber = widget.initialLevelNumber;
    unawaited(_loadSavedLevelLabel());
  }

  Future<void> _loadSavedLevelLabel() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_saveKey);
    if (saved == null || saved.isEmpty || !mounted) {
      return;
    }
    try {
      final decoded = jsonDecode(saved) as Map<String, dynamic>;
      final levelIndex = (decoded['levelIndex'] as num?)?.toInt() ?? 0;
      setState(() {
        _levelNumber = levelIndex + 1;
      });
    } catch (_) {
      // Keep the default label if the save data is malformed.
    }
  }

  Future<void> _openGame() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const GameScreen(),
      ),
    );
    await _loadSavedLevelLabel();
  }

  Future<void> _openLevelSelect() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const LevelSelectScreen(levelCount: 1000),
      ),
    );
    await _loadSavedLevelLabel();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: appThemeNotifier,
      builder: (context, isDarkMode, _) {
        final titleAsset = isDarkMode ? 'assets/images/title_dark.png' : 'assets/images/title_trans.png';
        return Scaffold(
          backgroundColor: AppColors.background,
          body: Stack(
            children: [
              const Positioned.fill(child: PawTileBackground()),
              Positioned.fill(
                child: IgnorePointer(
                  child: Transform.scale(
                    scale: 1.0,
                    child: Image.asset(
                      titleAsset,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: RoundIconButton(
                            icon: Icons.settings,
                            onPressed: () => showSettingsPopup(context),
                          ),
                        ),
                      ),
                      const Spacer(flex: 3),
                      const Spacer(flex: 4),
                      Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        children: [
                          PillButton(
                            color: _menuButtonColor,
                            label: _levelLabel,
                            preserveColor: true,
                            borderColor: const Color.fromARGB(255, 255, 247, 236),
                            borderWidth: 6,
                            onPressed: _openGame,
                          ),
                          if (_showMenuHorns)
                            Positioned(
                              top: -14,
                              left: 0,
                              right: 0,
                              child: IgnorePointer(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    _DevilHorn(
                                      shape: _HornSide.left,
                                      color: _menuButtonColor,
                                      borderColor: const Color.fromARGB(255, 255, 247, 236),
                                      borderWidth: 6,
                                    ),
                                    const SizedBox(width: 58),
                                    _DevilHorn(
                                      shape: _HornSide.right,
                                      color: _menuButtonColor,
                                      borderColor: const Color.fromARGB(255, 255, 247, 236),
                                      borderWidth: 6,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.bottomCenter,
                        children: [
                          ValueListenableBuilder<bool>(
                            valueListenable: developerModeNotifier,
                            builder: (context, developerModeEnabled, _) {
                              if (!developerModeEnabled) {
                                return const SizedBox.shrink();
                              }
                              return PillButton(
                                color: AppColors.periwinkle,
                                label: 'All levels',
                                onPressed: _openLevelSelect,
                              );
                            },
                          ),
                        ],
                      ),
                      const Spacer(flex: 2),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class StartupLoadingScreen extends StatefulWidget {
  const StartupLoadingScreen({super.key});

  @override
  State<StartupLoadingScreen> createState() => _StartupLoadingScreenState();
}

class _StartupLoadingScreenState extends State<StartupLoadingScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Image.asset(
          'assets/images/1000_level_games.png',
          width: 320,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

class StartupErrorScreen extends StatelessWidget {
  const StartupErrorScreen({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Loading failed',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.cocoa,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.cocoa,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 22),
              PillButton(
                color: AppColors.orange,
                label: 'Retry',
                preserveColor: true,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class StartupFadeTransitionScreen extends StatelessWidget {
  const StartupFadeTransitionScreen({
    required this.loadingChild,
    required this.menuChild,
    required this.loadingAnimation,
    required this.menuAnimation,
    super.key,
  });

  final Widget loadingChild;
  final Widget menuChild;
  final Animation<double> loadingAnimation;
  final Animation<double> menuAnimation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([loadingAnimation, menuAnimation]),
      builder: (context, _) {
        return Stack(
          children: [
            const Positioned.fill(
              child: ColoredBox(color: Colors.black),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: (1.0 - Curves.easeOut.transform(loadingAnimation.value)).clamp(0.0, 1.0),
                  child: loadingChild,
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: Curves.easeIn.transform(menuAnimation.value).clamp(0.0, 1.0),
                  child: menuChild,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class LevelSelectScreen extends StatefulWidget {
  const LevelSelectScreen({
    required this.levelCount,
    super.key,
  });

  final int levelCount;

  @override
  State<LevelSelectScreen> createState() => _LevelSelectScreenState();
}

class _LevelSelectScreenState extends State<LevelSelectScreen> {
  Future<void> _openLevel(int levelIndex) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GameScreen(
          initialLevelIndex: levelIndex,
          restoreSavedProgress: false,
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  RoundIconButton(
                    icon: Icons.arrow_back,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Text(
                    'All Levels',
                    style: TextStyle(
                      color: AppColors.cocoa,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 54),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: GridView.builder(
                  itemCount: widget.levelCount,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1.08,
                  ),
                  itemBuilder: (context, index) {
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => _openLevel(index),
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.surfaceRaised,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x12000000),
                                blurRadius: 10,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '${index + 1}',
                            style: TextStyle(
                              color: AppColors.cocoa,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GameScreen extends StatefulWidget {
  const GameScreen({
    this.initialLevelIndex,
    this.restoreSavedProgress = true,
    super.key,
  });

  final int? initialLevelIndex;
  final bool restoreSavedProgress;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const List<String> _levelAssetPaths = [
    'assets/levels/levels_001_100.json',
    'assets/levels/levels_101_200.json',
    'assets/levels/levels_201_300.json',
    'assets/levels/levels_301_400.json',
    'assets/levels/levels_401_500.json',
    'assets/levels/levels_501_600.json',
    'assets/levels/levels_601_700.json',
    'assets/levels/levels_701_800.json',
    'assets/levels/levels_801_900.json',
    'assets/levels/levels_901_1000.json',
  ];

  final GlobalKey _boardKey = GlobalKey();
  final GlobalKey _trayKey = GlobalKey();
  final GlobalKey _screenStackKey = GlobalKey();
  final GlobalKey _hintButtonKey = GlobalKey();
  final GlobalKey _resetButtonKey = GlobalKey();
  int _currentLevelIndex = 0;
  late List<Piece> _pieces;
  late Map<String, Piece> _piecesById;
  late final AudioPlayer _soundPlayer;
  late final AnimationController _hintAnimationController;
  InterstitialAd? _interstitialAd;
  bool _interstitialAdLoading = false;
  RewardedAd? _rewardedAd;
  bool _rewardedAdLoading = false;
  int _audioPlaybackGeneration = 0;
  bool _levelsLoaded = false;
  String? _levelsLoadError;
  List<_LevelData> _levels = <_LevelData>[];
  Future<void> _soundQueue = Future<void>.value();
  late List<List<Color?>> _placed;
  late List<List<String?>> _placedPieceIds;
  late Set<String> _usedPieces;
  late Set<String> _lockedPieces;
  bool _levelCompletionTriggered = false;
  bool _showCompletionDarkScreen = false;
  int _confettiVersion = 0;
  bool _showNextLevelButton = false;
  final Set<String> _hintedPieceIds = <String>{};
  Set<String> _hintRevealCells = <String>{};
  int _hintRevealVersion = 0;
  bool _hintButtonLocked = false;
  Timer? _levelTimerTicker;
  DateTime? _levelTimerStartedAt;
  DateTime? _gameStartedAt;
  Duration _levelTimerElapsed = Duration.zero;
  bool _levelTimerRunning = false;
  bool _levelTimerPaused = false;
  Offset? _hintOrbStart;
  Offset? _hintOrbEnd;
  Color? _hintOrbColor;
  Offset? _hintExplosionOrigin;
  List<Offset> _hintParticleTargets = <Offset>[];
  bool _hintParticlesVisible = false;
  String? _activeHintPieceId;
  int _hintRevealSequence = 0;
  TutorialStep _tutorialStep = TutorialStep.complete;
  bool _tutorialHintAvailable = false;
  bool _tutorialDragInProgress = false;
  Piece? _hoverPiece;
  int? _hoverRow;
  int? _hoverCol;
  Set<String> _hoverCells = <String>{};
  String? _draggingBoardPieceId;
  Set<String> _draggingOriginalCells = <String>{};
  int _hints = 3;
  int _lives = 3;
  String? _message;
  Timer? _messageTimer;
  Timer? _completionDarkTimer;
  Timer? _confettiTimer;
  Timer? _nextLevelButtonTimer;
  Timer? _shakeTimer;
  int _completedLevelsSinceInterstitial = 0;
  String? _shakingPieceId;
  int _shakeVersion = 0;
  int? _lastTrackedLevelStartId;

  int get _levelCount => _levels.length;

  int get _boardSize => _levels.isEmpty ? 0 : _levels[_currentLevelIndex].board.length;

  List<List<Color>> get _currentLevelBoard => _levels[_currentLevelIndex].board;

  bool get _isTutorialLevel => _levels.isNotEmpty && _levels[_currentLevelIndex].id == 1;

  Rect? _localRectForKey(GlobalKey key) {
    final overlayContext = _screenStackKey.currentContext;
    final targetContext = key.currentContext;
    if (overlayContext == null || targetContext == null) {
      return null;
    }
    final overlayBox = overlayContext.findRenderObject() as RenderBox?;
    final targetBox = targetContext.findRenderObject() as RenderBox?;
    if (overlayBox == null || targetBox == null || !targetBox.hasSize) {
      return null;
    }
    final topLeft = overlayBox.globalToLocal(targetBox.localToGlobal(Offset.zero));
    return topLeft & targetBox.size;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _soundPlayer = AudioPlayer();
    _hintAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 760),
    )..addListener(() {
        if (mounted) {
          setState(() {});
        }
      });
    unawaited(_soundPlayer.setPlayerMode(PlayerMode.lowLatency));
    unawaited(_loadLevelsFromAssets());
    if (AdHelper.interstitialAdsEnabled) {
      _loadInterstitialAd();
    }
    if (AdHelper.rewardedAdsEnabled) {
      _loadRewardedAd();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pauseLevelTimer();
    _hintAnimationController.dispose();
    _interstitialAd?.dispose();
    _rewardedAd?.dispose();
    unawaited(_soundPlayer.dispose());
    _messageTimer?.cancel();
    _confettiTimer?.cancel();
    _nextLevelButtonTimer?.cancel();
    _shakeTimer?.cancel();
    _levelTimerTicker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _pauseLevelTimer();
      unawaited(_saveProgress());
    }
  }

  Future<void> _loadLevelsFromAssets() async {
    try {
      final levels = await _loadAllLevels();

      if (!mounted) {
        return;
      }

      setState(() {
        _levels = levels;
        _levelsLoaded = true;
        _levelsLoadError = null;
        final startLevelIndex = widget.initialLevelIndex;
        _loadLevel(startLevelIndex == null ? 0 : startLevelIndex.clamp(0, levels.length - 1));
        _resetLevelState(persist: false);
        if (_isTutorialLevel) {
          _tutorialStep = TutorialStep.dragPiece;
          _tutorialHintAvailable = true;
        }
      });
      if (widget.restoreSavedProgress && widget.initialLevelIndex == null) {
        await _restoreProgressIfAvailable();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _levelsLoadError = 'Failed to load level data: $error';
      });
    }
  }

  Future<void> _saveProgress() async {
    if (!_levelsLoaded || _levels.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final saveData = <String, dynamic>{
      'levelIndex': _currentLevelIndex,
      'placedPieceIds': _placedPieceIds,
      'hints': _hints,
      'timerElapsedMs': _currentLevelTimerElapsed.inMilliseconds,
      'timerPaused': _levelTimerPaused || _levelTimerRunning,
      'completedLevelsSinceInterstitial': _completedLevelsSinceInterstitial,
      'gameStartedAtMs': _gameStartedAt?.millisecondsSinceEpoch,
    };
    await prefs.setString(_saveKey, jsonEncode(saveData));
  }

  Future<void> _restoreProgressIfAvailable() async {
    if (!_levelsLoaded || _levels.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_saveKey);
    if (saved == null || saved.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(saved) as Map<String, dynamic>;
      final savedLevelIndex = (decoded['levelIndex'] as num?)?.toInt() ?? 0;
      final rawPlacedPieceIds = decoded['placedPieceIds'] as List<dynamic>?;
      final savedHints = (decoded['hints'] as num?)?.toInt();
      final savedTimerElapsedMs = (decoded['timerElapsedMs'] as num?)?.toInt() ?? 0;
      final savedTimerPaused = decoded['timerPaused'] as bool? ?? false;
      final savedCompletedLevelsSinceInterstitial =
          (decoded['completedLevelsSinceInterstitial'] as num?)?.toInt() ?? 0;
      final savedGameStartedAtMs = (decoded['gameStartedAtMs'] as num?)?.toInt();
      if (rawPlacedPieceIds == null) {
        return;
      }

      final restoredLevelIndex = savedLevelIndex.clamp(0, _levelCount - 1);
      _loadLevel(restoredLevelIndex);
      _resetLevelState(persist: false);

      final boardSize = _boardSize;
      final restoredPlacedPieceIds = List.generate(
        boardSize,
        (_) => List<String?>.filled(boardSize, null),
      );

      for (var row = 0; row < boardSize && row < rawPlacedPieceIds.length; row++) {
        final rawRow = rawPlacedPieceIds[row] as List<dynamic>;
        for (var col = 0; col < boardSize && col < rawRow.length; col++) {
          final pieceId = rawRow[col] as String?;
          restoredPlacedPieceIds[row][col] = pieceId;
        }
      }

      final restoredPlaced = List.generate(boardSize, (_) => List<Color?>.filled(boardSize, null));
      final restoredUsedPieces = <String>{};
      for (var row = 0; row < boardSize; row++) {
        for (var col = 0; col < boardSize; col++) {
          final pieceId = restoredPlacedPieceIds[row][col];
          if (pieceId == null) {
            continue;
          }
          final piece = _piecesById[pieceId];
          if (piece == null) {
            continue;
          }
          restoredPlaced[row][col] = piece.color;
          restoredUsedPieces.add(pieceId);
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _currentLevelIndex = restoredLevelIndex;
        _placed = restoredPlaced;
        _placedPieceIds = restoredPlacedPieceIds;
        _usedPieces = restoredUsedPieces;
        _lockedPieces = _pieces
            .where((piece) => piece.cells.length <= 3)
            .map((piece) => piece.id)
            .toSet();
        _levelCompletionTriggered = _usedPieces.length == _pieces.length;
        if (savedHints != null) {
          _hints = savedHints;
        }
        _levelTimerElapsed = Duration(milliseconds: savedTimerElapsedMs);
        _levelTimerPaused = savedTimerPaused || savedTimerElapsedMs > 0;
        _levelTimerRunning = false;
        _levelTimerStartedAt = null;
        _completedLevelsSinceInterstitial = savedCompletedLevelsSinceInterstitial;
        _gameStartedAt = savedGameStartedAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(savedGameStartedAtMs);
        _levelTimerTicker?.cancel();
        _levelTimerTicker = null;
      });
      if (_shouldUseInterstitialAds) {
        _loadInterstitialAd();
      }
    } catch (_) {
      await prefs.remove(_saveKey);
    }
  }

  void _loadInterstitialAd() {
    if (kIsWeb || !_shouldUseInterstitialAds) {
      return;
    }
    if (_interstitialAdLoading || _interstitialAd != null) {
      return;
    }
    _interstitialAdLoading = true;
    InterstitialAd.load(
      adUnitId: AdHelper.interstitialAdUnitId(),
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          if (!mounted) {
            ad.dispose();
            return;
          }
          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (ad) {
              ad.dispose();
              if (!mounted) {
                return;
              }
              setState(() {
                _interstitialAd = null;
              });
              _interstitialAdLoading = false;
              _loadInterstitialAd();
            },
            onAdFailedToShowFullScreenContent: (ad, error) {
              ad.dispose();
              if (!mounted) {
                return;
              }
              setState(() {
                _interstitialAd = null;
              });
              _interstitialAdLoading = false;
              _loadInterstitialAd();
            },
          );
          setState(() {
            _interstitialAd = ad;
            _interstitialAdLoading = false;
          });
        },
        onAdFailedToLoad: (error) {
          _interstitialAdLoading = false;
          final currentLevelId = _levels.isNotEmpty ? _levels[_currentLevelIndex].id : null;
          unawaited(
            AnalyticsEvents.adFailedToLoad(
              adType: 'interstitial',
              levelId: currentLevelId,
              levelIndex: _levels.isNotEmpty ? _currentLevelIndex : null,
              errorCode: error.code.toString(),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showInterstitialThenNextLevel() async {
    if (_levelCount == 0) {
      return;
    }
    final nextLevelIndex = (_currentLevelIndex + 1) % _levelCount;
    final shouldShowInterstitial = AdHelper.interstitialAdsEnabled &&
        _completedLevelsSinceInterstitial >= 2;
    if (kIsWeb || !_shouldUseInterstitialAds) {
      _completedLevelsSinceInterstitial = 0;
      setState(() {
        _loadLevel(nextLevelIndex);
        _resetLevelState();
      });
      unawaited(_saveProgress());
      return;
    }

    if (!shouldShowInterstitial) {
      setState(() {
        _loadLevel(nextLevelIndex);
        _resetLevelState();
      });
      unawaited(_saveProgress());
      return;
    }

    final interstitialAd = _interstitialAd;
    if (interstitialAd == null) {
      _completedLevelsSinceInterstitial = 0;
      setState(() {
        _loadLevel(nextLevelIndex);
        _resetLevelState(persist: false);
      });
      unawaited(_saveProgress());
      return;
    }

    setState(() {
      _interstitialAd = null;
      _completedLevelsSinceInterstitial = 0;
      _loadLevel(nextLevelIndex);
      _resetLevelState(persist: false);
    });

    unawaited(_saveProgress());
    _pauseLevelTimer();
    await _silenceGameplayAudio();
    final currentLevelId = _levels[_currentLevelIndex].id;
    unawaited(
      AnalyticsEvents.interstitialShown(
        levelId: currentLevelId,
        levelIndex: _currentLevelIndex,
      ),
    );
    interstitialAd.show();
  }

  void _loadRewardedAd() {
    if (kIsWeb || !AdHelper.rewardedAdsEnabled) {
      return;
    }
    if (_rewardedAdLoading || _rewardedAd != null) {
      return;
    }
    _rewardedAdLoading = true;
    RewardedAd.load(
      adUnitId: AdHelper.rewardedAdUnitId(),
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          if (!mounted) {
            ad.dispose();
            return;
          }
          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (ad) {
              ad.dispose();
              if (!mounted) {
                return;
              }
              setState(() {
                _rewardedAd = null;
              });
              _rewardedAdLoading = false;
              _loadRewardedAd();
            },
            onAdFailedToShowFullScreenContent: (ad, error) {
              ad.dispose();
              if (!mounted) {
                return;
              }
              setState(() {
                _rewardedAd = null;
              });
              _rewardedAdLoading = false;
              _loadRewardedAd();
            },
          );
          setState(() {
            _rewardedAd = ad;
            _rewardedAdLoading = false;
          });
        },
        onAdFailedToLoad: (error) {
          _rewardedAdLoading = false;
          final currentLevelId = _levels.isNotEmpty ? _levels[_currentLevelIndex].id : null;
          unawaited(
            AnalyticsEvents.adFailedToLoad(
              adType: 'rewarded',
              levelId: currentLevelId,
              levelIndex: _levels.isNotEmpty ? _currentLevelIndex : null,
              errorCode: error.code.toString(),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showRewardedAdForHint() async {
    if (kIsWeb || !AdHelper.rewardedAdsEnabled) {
      setState(() {
        _hints = 1;
      });
      unawaited(_saveProgress());
      _showMessage('Reward earned: +1 hint');
      return;
    }

    final rewardedAd = _rewardedAd;
    if (rewardedAd == null) {
      _showMessage('Ad is loading');
      _loadRewardedAd();
      return;
    }

    setState(() {
      _rewardedAd = null;
    });

    _pauseLevelTimer();
    unawaited(_saveProgress());
    rewardedAd.show(
      onUserEarnedReward: (_, _) {
        if (!mounted) {
          return;
        }
        setState(() {
          _hints = 1;
        });
        final currentLevelId = _levels[_currentLevelIndex].id;
        unawaited(
          AnalyticsEvents.rewardedAdRewarded(
            levelId: currentLevelId,
            levelIndex: _currentLevelIndex,
            rewardAmount: 1,
          ),
        );
        unawaited(_saveProgress());
        _showMessage('Reward earned: +1 hint');
      },
    );
  }

  void _loadLevel(int index) {
    if (_levels.isEmpty) {
      return;
    }
    _currentLevelIndex = index % _levelCount;
    final board = _currentLevelBoard;
    _pieces = buildLevelPieces(board);
    _piecesById = {for (final piece in _pieces) piece.id: piece};
    final currentLevelId = _levels[_currentLevelIndex].id;
    if (currentLevelId == 1) {
      _tutorialStep = TutorialStep.dragPiece;
      _tutorialHintAvailable = true;
      _tutorialDragInProgress = false;
    } else {
      _tutorialStep = TutorialStep.complete;
      _tutorialHintAvailable = false;
      _tutorialDragInProgress = false;
    }
    if (_lastTrackedLevelStartId != currentLevelId) {
      _lastTrackedLevelStartId = currentLevelId;
      unawaited(
        AnalyticsEvents.levelStart(
          levelId: currentLevelId,
          levelIndex: _currentLevelIndex,
        ),
      );
    }
  }

  void _startLevelTimer() {
    if (_levelTimerRunning) {
      return;
    }
    _gameStartedAt ??= DateTime.now();
    _levelTimerStartedAt = DateTime.now().subtract(_levelTimerElapsed);
    _levelTimerRunning = true;
    _levelTimerPaused = false;
    _levelTimerTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_levelTimerRunning || _levelTimerStartedAt == null) {
        return;
      }
      setState(() {
        _levelTimerElapsed = DateTime.now().difference(_levelTimerStartedAt!);
      });
      unawaited(_saveProgress());
    });
    unawaited(_saveProgress());
  }

  void _pauseLevelTimer() {
    if (!_levelTimerRunning) {
      _levelTimerPaused = _levelTimerElapsed > Duration.zero;
      return;
    }
    _levelTimerElapsed = _levelTimerStartedAt == null
        ? _levelTimerElapsed
        : DateTime.now().difference(_levelTimerStartedAt!);
    _levelTimerRunning = false;
    _levelTimerPaused = true;
    _levelTimerTicker?.cancel();
    _levelTimerTicker = null;
    _levelTimerStartedAt = null;
    if (mounted) {
      setState(() {});
    }
    unawaited(_saveProgress());
  }

  void _stopLevelTimer() {
    if (!_levelTimerRunning) {
      return;
    }
    _levelTimerElapsed = _levelTimerStartedAt == null
        ? Duration.zero
        : DateTime.now().difference(_levelTimerStartedAt!);
    _levelTimerRunning = false;
    _levelTimerPaused = false;
    _levelTimerTicker?.cancel();
    _levelTimerTicker = null;
    _levelTimerStartedAt = null;
    if (mounted) {
      setState(() {});
    }
  }

  void _resetLevelState({bool persist = true}) {
    _placed = List.generate(_boardSize, (_) => List<Color?>.filled(_boardSize, null));
    _placedPieceIds = List.generate(_boardSize, (_) => List<String?>.filled(_boardSize, null));
    _usedPieces = <String>{};
    _lockedPieces = <String>{};
    _levelCompletionTriggered = false;
    _hintedPieceIds.clear();
    _hoverPiece = null;
    _hoverRow = null;
    _hoverCol = null;
    _hoverCells = <String>{};
    _hintRevealCells = <String>{};
    _hintRevealVersion++;
    _hintRevealSequence = 0;
    _activeHintPieceId = null;
    _hintOrbStart = null;
    _hintOrbEnd = null;
    _hintOrbColor = null;
    _hintExplosionOrigin = null;
    _hintParticleTargets = <Offset>[];
    _hintParticlesVisible = false;
    _draggingBoardPieceId = null;
    _draggingOriginalCells = <String>{};
    _tutorialDragInProgress = false;
    _messageTimer?.cancel();
    _message = null;
    _completionDarkTimer?.cancel();
    _showCompletionDarkScreen = false;
    _confettiTimer?.cancel();
    _confettiVersion = 0;
    _nextLevelButtonTimer?.cancel();
    _showNextLevelButton = false;
    _shakeTimer?.cancel();
    _shakingPieceId = null;
    _levelTimerTicker?.cancel();
    _levelTimerTicker = null;
    _levelTimerStartedAt = null;
    _levelTimerElapsed = Duration.zero;
    _levelTimerRunning = false;
    _levelTimerPaused = false;
    _seedBoardPlaceholder();
    if (persist) {
      unawaited(_saveProgress());
    }
    if (_shouldUseInterstitialAds) {
      _loadInterstitialAd();
    }
  }

  void _handleResetPressed() {
    setState(_resetLevelState);
  }

  void _handleHintPressed() {
    if (_isTutorialLevel && _tutorialStep == TutorialStep.hintButton) {
      setState(() {
        _tutorialStep = TutorialStep.complete;
      });
    }
    if (_hintButtonLocked) {
      return;
    }
    if (AppSettings.vibrationOn) {
      unawaited(HapticFeedback.selectionClick());
    }
    unawaited(_useHint());
  }

  void _showMessage(
    String message, {
    Duration duration = const Duration(milliseconds: 1500),
  }) {
    _messageTimer?.cancel();
    setState(() {
      _message = message;
    });
    _messageTimer = Timer(duration, () {
      if (!mounted || _message != message) {
        return;
      }
      setState(() {
        _message = null;
      });
    });
  }

  void _showCompletionDarkScreenAfterRipple() {
    _completionDarkTimer?.cancel();
    _completionDarkTimer = Timer(const Duration(milliseconds: 940), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showCompletionDarkScreen = true;
      });
    });
  }

  void _showConfettiAfterRipple() {
    _confettiTimer?.cancel();
    _confettiTimer = Timer(const Duration(milliseconds: 980), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _confettiVersion++;
      });
    });
  }

  void _showNextLevelButtonAfterConfetti() {
    _nextLevelButtonTimer?.cancel();
    _nextLevelButtonTimer = Timer(const Duration(milliseconds: 1880), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showNextLevelButton = true;
      });
    });
  }

  Future<void> _leaveGame() async {
    if (_levels.isEmpty) {
      return;
    }

    if (_isLevelComplete && !_isFinalLevel) {
      final nextLevelIndex = (_currentLevelIndex + 1) % _levelCount;
      _loadLevel(nextLevelIndex);
      _resetLevelState(persist: false);
    } else {
      _pauseLevelTimer();
    }

    await _saveProgress();
    await _saveAppSettings();
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  Widget _buildGameHeaderRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          RoundIconButton(
            icon: Icons.arrow_back,
            onPressed: () => unawaited(_leaveGame()),
          ),
          Text(
            'Level ${_levels[_currentLevelIndex].id}',
            style: TextStyle(
              color: AppColors.cocoa,
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),
          RoundIconButton(
            icon: Icons.settings,
            onPressed: () {
              _pauseLevelTimer();
              showSettingsPopup(context);
            },
          ),
        ],
      ),
    );
  }

  bool get _isHardNextLevel {
    final currentLevelId = _levels[_currentLevelIndex].id;
    return currentLevelId % 10 == 9 && !_isCenturyNextLevel;
  }

  bool get _isCenturyNextLevel {
    final currentLevelId = _levels[_currentLevelIndex].id;
    return currentLevelId % 100 == 99;
  }

  bool get _isFinalLevel {
    return _levels.isNotEmpty && _levels[_currentLevelIndex].id == 1000;
  }

  bool get _shouldUseInterstitialAds {
    return !kIsWeb &&
        AdHelper.interstitialAdsEnabled &&
        _levels.isNotEmpty &&
        _levels[_currentLevelIndex].id >= 10;
  }

  bool get _isRedThemeLevel {
    return _levels.isNotEmpty && !_isFinalLevel && _levels[_currentLevelIndex].id % 10 == 0;
  }

  bool get _isCenturyThemeLevel {
    return _levels.isNotEmpty && _levels[_currentLevelIndex].id % 100 == 0;
  }

  Color get _gameBackgroundColor {
    if (_isCenturyThemeLevel) {
      return AppSettings.darkMode
          ? const Color.fromARGB(255, 58, 36, 86)
          : const Color.fromARGB(255, 205, 162, 243);
    }
    if (!_isRedThemeLevel) {
      return AppColors.background;
    }
    return AppSettings.darkMode ? const Color.fromARGB(255, 39, 2, 11) : const Color.fromARGB(255, 255, 171, 171);
  }

  bool get _isLevelComplete => _usedPieces.length == _pieces.length;

  String get _levelTimerText => _formatLevelTimer(_levelTimerElapsed);

  String get _finalGameDaysText {
    final start = _gameStartedAt;
    if (start == null) {
      return '1 DAY';
    }
    final elapsed = DateTime.now().difference(start);
    final days = math.max(1, (elapsed.inSeconds / Duration.secondsPerDay).ceil());
    return days <= 1 ? '1 DAY' : '$days DAYS';
  }

  String get _completionBadgeText => _isFinalLevel ? _finalGameDaysText : _levelTimerText;

  Duration get _currentLevelTimerElapsed {
    if (_levelTimerRunning && _levelTimerStartedAt != null) {
      return DateTime.now().difference(_levelTimerStartedAt!);
    }
    return _levelTimerElapsed;
  }

  Widget _buildBigPieceReminder({bool compact = false}) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 28),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: compact ? 224 : 390),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 16,
            vertical: compact ? 10 : 12,
          ),
          decoration: BoxDecoration(
            color: AppColors.overlay.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(compact ? 16 : 18),
            border: Border.all(
              color: AppColors.orange.withValues(alpha: 0.32),
              width: 1.5,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 14,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Center(
                  child: Text(
                    'Tip: place the big pieces first.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.cocoa,
                      fontSize: compact ? 13.5 : 16,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNextLevelButton() {
    if (_isFinalLevel) {
      return PillButton(
        color: AppColors.green,
        label: 'MENU',
        preserveColor: true,
        onPressed: () => unawaited(_leaveGame()),
      );
    }
    final buttonColor = _isCenturyNextLevel
        ? AppColors.purple
        : _isHardNextLevel
            ? AppColors.red
            : AppColors.orange;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        PillButton(
          color: buttonColor,
          label: 'NEXT LEVEL',
          preserveColor: true,
          borderColor: const Color.fromARGB(255, 255, 247, 236),
          borderWidth: 6,
          enableFeedback: false,
          onPressed: _showInterstitialThenNextLevel,
        ),
        if (_isHardNextLevel || _isCenturyNextLevel)
          Positioned(
            top: -14,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _DevilHorn(
                    shape: _HornSide.left,
                    color: buttonColor,
                    borderColor: const Color.fromARGB(255, 255, 247, 236),
                    borderWidth: 6,
                  ),
                  const SizedBox(width: 58),
                  _DevilHorn(
                    shape: _HornSide.right,
                    color: buttonColor,
                    borderColor: const Color.fromARGB(255, 255, 247, 236),
                    borderWidth: 6,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  void _showInvalidPlacementFeedback(Piece piece) {
    if (AppSettings.vibrationOn) {
      HapticFeedback.errorNotification();
    }
    _shakeTimer?.cancel();
    setState(() {
      _shakingPieceId = piece.id;
      _shakeVersion++;
    });
    _shakeTimer = Timer(const Duration(milliseconds: 360), () {
      if (!mounted || _shakingPieceId != piece.id) {
        return;
      }
      setState(() {
        _shakingPieceId = null;
      });
    });
  }

  void _handleInvalidDrop(Piece piece) {
    _showMessage('Try another spot');
    unawaited(_playAssetSound('audio/error_.wav'));
    _showInvalidPlacementFeedback(piece);
  }

  Future<void> _playAssetSound(String assetPath) async {
    if (!AppSettings.soundOn) {
      return;
    }
    final generation = _audioPlaybackGeneration;
    try {
      await _soundPlayer.stop();
      if (!mounted ||
          !AppSettings.soundOn ||
          generation != _audioPlaybackGeneration) {
        return;
      }
      await _soundPlayer.play(AssetSource(assetPath));
    } catch (_) {
      // Ignore audio failures so drag handling keeps working.
    }
  }

  Future<void> _playPopSound([int count = 1]) async {
    if (!AppSettings.soundOn) {
      return;
    }
    if (count <= 0) {
      return;
    }

    _soundQueue = _soundQueue.then((_) async {
      for (var i = 0; i < count; i++) {
        if (!mounted || !AppSettings.soundOn) {
          return;
        }
        await _playAssetSound('audio/one_pop.wav');
        if (i < count - 1) {
          await Future<void>.delayed(const Duration(milliseconds: 45));
        }
      }
    });

    await _soundQueue;
  }

  Future<void> _playSingleSound(String assetPath) async {
    if (!AppSettings.soundOn) {
      return;
    }
    await _playAssetSound(assetPath);
  }

  Future<void> _playDelayedSound(String assetPath, Duration delay) async {
    final generation = _audioPlaybackGeneration;
    await Future<void>.delayed(delay);
    if (!mounted || generation != _audioPlaybackGeneration) {
      return;
    }
    await _playSingleSound(assetPath);
  }

  Future<void> _silenceGameplayAudio() async {
    _audioPlaybackGeneration++;
    try {
      await _soundPlayer.stop();
    } catch (_) {
      // Ignore audio failures when transitioning into an ad.
    }
  }

  Set<String> _pieceCellKeys(Piece piece) {
    return {
      for (final cell in piece.cells) '${piece.origin.dy + cell.dy},${piece.origin.dx + cell.dx}',
    };
  }

  Offset _pieceCenterOnBoardLocal(Piece piece, double boardCellSize) {
    final minDx = piece.cells.map((cell) => cell.dx).reduce(math.min);
    final maxDx = piece.cells.map((cell) => cell.dx).reduce(math.max);
    final minDy = piece.cells.map((cell) => cell.dy).reduce(math.min);
    final maxDy = piece.cells.map((cell) => cell.dy).reduce(math.max);
    final pitch = boardCellSize + Board.gap;
    final left = Board.outerPadding + (piece.origin.dx + minDx) * pitch;
    final top = Board.outerPadding + (piece.origin.dy + minDy) * pitch;
    final width = (maxDx - minDx + 1) * boardCellSize + (maxDx - minDx) * Board.gap;
    final height = (maxDy - minDy + 1) * boardCellSize + (maxDy - minDy) * Board.gap;
    return Offset(left + width / 2, top + height / 2);
  }

  Future<void> _playHintReveal(Piece piece) async {
    final revealSequence = ++_hintRevealSequence;
    if (_hintAnimationController.isAnimating) {
      _hintAnimationController.stop();
      _finalizeActiveHintReveal();
    }
    final hintButtonContext = _hintButtonKey.currentContext;
    final boardContext = _boardKey.currentContext;
    if (hintButtonContext == null || boardContext == null) {
      setState(() {
        _hintedPieceIds.add(piece.id);
        _hintRevealCells = _pieceCellKeys(piece);
        _hintRevealVersion++;
      });
      return;
    }

    final hintBox = hintButtonContext.findRenderObject()! as RenderBox;
    final boardBox = boardContext.findRenderObject()! as RenderBox;
    final start = hintBox.localToGlobal(hintBox.size.center(Offset.zero));
    final boardCellSize =
        (boardBox.size.width - Board.outerPadding * 2 - Board.gap * (_boardSize - 1)) / _boardSize;
    final end = boardBox.localToGlobal(_pieceCenterOnBoardLocal(piece, boardCellSize));
    final pitch = boardCellSize + Board.gap;
    final particleTargets = piece.cells
        .map(
          (cell) => boardBox.localToGlobal(
            Offset(
              Board.outerPadding + (piece.origin.dx + cell.dx) * pitch + boardCellSize / 2,
              Board.outerPadding + (piece.origin.dy + cell.dy) * pitch + boardCellSize / 2,
            ),
          ),
        )
        .toList();

    setState(() {
      _activeHintPieceId = piece.id;
      _hintOrbStart = start;
      _hintOrbEnd = end;
      _hintOrbColor = piece.color;
      _hintRevealCells = <String>{};
      _hintExplosionOrigin = null;
      _hintParticleTargets = <Offset>[];
      _hintParticlesVisible = false;
    });

    unawaited(_playDelayedSound('audio/swish_sound.wav', const Duration(milliseconds: 80)));
    await _hintAnimationController.forward(from: 0);
    if (!mounted || revealSequence != _hintRevealSequence) {
      return;
    }

    await _playSingleSound('audio/one_pop.wav');

    setState(() {
      _hintOrbStart = null;
      _hintOrbEnd = null;
      _hintExplosionOrigin = end;
      _hintParticleTargets = particleTargets;
      _hintParticlesVisible = true;
    });

    await _hintAnimationController.forward(from: 0);
    if (!mounted || revealSequence != _hintRevealSequence) {
      return;
    }

    await _playSingleSound('audio/multi_pop.wav');

    _finalizeHintReveal(piece);
  }

  void _finalizeActiveHintReveal() {
    final activePieceId = _activeHintPieceId;
    if (activePieceId == null) {
      return;
    }
    final activePiece = _piecesById[activePieceId];
    if (activePiece == null) {
      return;
    }
    _finalizeHintReveal(activePiece);
  }

  void _finalizeHintReveal(Piece piece) {
    if (!mounted) {
      return;
    }
    setState(() {
      _hintExplosionOrigin = null;
      _hintParticleTargets = <Offset>[];
      _hintParticlesVisible = false;
      _hintOrbStart = null;
      _hintOrbEnd = null;
      _hintOrbColor = null;
      _hintedPieceIds.add(piece.id);
      _hintRevealCells = _pieceCellKeys(piece);
      _hintRevealVersion++;
      _activeHintPieceId = null;
    });
  }

  void _seedBoardPlaceholder() {
    final placeholders = _pieces.where((piece) => piece.cells.length <= 3).toList();
    if (placeholders.isEmpty) {
      return;
    }
    for (final placeholder in placeholders) {
      for (final cell in placeholder.cells) {
        final row = placeholder.origin.dy + cell.dy;
        final col = placeholder.origin.dx + cell.dx;
        _placed[row][col] = placeholder.color;
        _placedPieceIds[row][col] = placeholder.id;
      }
      _usedPieces.add(placeholder.id);
      _lockedPieces.add(placeholder.id);
    }
  }

  Map<String, Color> get _hintColorsByCell {
    final hintedCells = <String, Color>{};
    for (final pieceId in _hintedPieceIds) {
      final piece = _piecesById[pieceId];
      if (piece == null) {
        continue;
      }
      for (final cell in piece.cells) {
        hintedCells['${piece.origin.dy + cell.dy},${piece.origin.dx + cell.dx}'] = piece.color;
      }
    }
    return hintedCells;
  }

  bool _canPlace(Piece piece, int row, int col) {
    for (final cell in piece.cells) {
      final boardRow = row + cell.dy;
      final boardCol = col + cell.dx;
      if (boardRow < 0 || boardCol < 0 || boardRow >= _boardSize || boardCol >= _boardSize) {
        return false;
      }
      if (_placed[boardRow][boardCol] != null) {
        return false;
      }
    }
    return true;
  }

  bool _canPlaceHoverCells(Piece piece) {
    if (_hoverPiece != piece || _hoverCells.length != piece.cells.length) {
      return false;
    }
    for (final key in _hoverCells) {
      final cell = _boardCellFromKey(key);
      if (cell == null) {
        return false;
      }
      final row = cell.dy;
      final col = cell.dx;
      if (row < 0 || col < 0 || row >= _boardSize || col >= _boardSize) {
        return false;
      }
      if (_placed[row][col] != null && _placedPieceIds[row][col] != _draggingBoardPieceId) {
        return false;
      }
    }
    return true;
  }

  void _place(Piece piece, int row, int col) {
    if (_usedPieces.contains(piece.id) && _draggingBoardPieceId != piece.id) {
      return;
    }
    final useHoverCells = _canPlaceHoverCells(piece);
    if (!useHoverCells && !_canPlace(piece, row, col)) {
      setState(() {
        _lives = math.max(0, _lives - 1);
        if (_draggingBoardPieceId == piece.id) {
          _clearPlacedPieceCells(piece);
          _usedPieces.remove(piece.id);
        }
        _hoverPiece = null;
        _hoverRow = null;
        _hoverCol = null;
        _hoverCells = <String>{};
        _draggingBoardPieceId = null;
        _draggingOriginalCells = <String>{};
      });
      _showMessage('Try another spot');
      unawaited(_playAssetSound('audio/error_.wav'));
      _showInvalidPlacementFeedback(piece);
      return;
    }

    setState(() {
      if (_draggingBoardPieceId == piece.id) {
        _clearPlacedPieceCells(piece);
      }
      if (useHoverCells) {
        for (final key in _hoverCells) {
          final cell = _boardCellFromKey(key)!;
          _placed[cell.dy][cell.dx] = piece.color;
          _placedPieceIds[cell.dy][cell.dx] = piece.id;
        }
      } else {
        for (final cell in piece.cells) {
          _placed[row + cell.dy][col + cell.dx] = piece.color;
          _placedPieceIds[row + cell.dy][col + cell.dx] = piece.id;
        }
      }
      _usedPieces.add(piece.id);
      if (_isTutorialLevel && _tutorialStep == TutorialStep.dragPiece) {
        _tutorialStep = TutorialStep.hintButton;
        _tutorialDragInProgress = false;
      }
      _hoverPiece = null;
      _hoverRow = null;
      _hoverCol = null;
      _hoverCells = <String>{};
      _draggingBoardPieceId = null;
      _draggingOriginalCells = <String>{};
      if (_usedPieces.length != _pieces.length) {
        _messageTimer?.cancel();
        _message = null;
      }
    });
    if (AppSettings.vibrationOn) {
      HapticFeedback.successNotification();
    }
    unawaited(_playAssetSound('audio/one_pop.wav'));
    final allPiecesPlaced = _usedPieces.length == _pieces.length;
    if (allPiecesPlaced && !_levelCompletionTriggered) {
      _completedLevelsSinceInterstitial++;
      _stopLevelTimer();
      _levelCompletionTriggered = true;
      _showCompletionDarkScreenAfterRipple();
      _showConfettiAfterRipple();
      _showNextLevelButtonAfterConfetti();
      final currentLevelId = _levels[_currentLevelIndex].id;
      final completionDuration = _currentLevelTimerElapsed;
      unawaited(
        AnalyticsEvents.levelComplete(
          levelId: currentLevelId,
          levelIndex: _currentLevelIndex,
          timeToComplete: completionDuration,
        ),
      );
      unawaited(
        AnalyticsEvents.timeToComplete(
          levelId: currentLevelId,
          levelIndex: _currentLevelIndex,
          duration: completionDuration,
        ),
      );
      unawaited(_playDelayedSound('audio/success.wav', const Duration(milliseconds: 160)));
      _showMessage('Board complete!', duration: const Duration(milliseconds: 1800));
    }
    unawaited(_saveProgress());
  }

  void _placeFromHover(Piece piece) {
    _place(piece, _hoverRow ?? 0, _hoverCol ?? 0);
  }

  Set<String> _placedCellsForPiece(Piece piece) {
    final cells = <String>{};
    for (var row = 0; row < _boardSize; row++) {
      for (var col = 0; col < _boardSize; col++) {
        if (_placedPieceIds[row][col] == piece.id) {
          cells.add('$row,$col');
        }
      }
    }
    return cells;
  }

  void _clearPlacedPieceCells(Piece piece) {
    for (var row = 0; row < _boardSize; row++) {
      for (var col = 0; col < _boardSize; col++) {
        if (_placedPieceIds[row][col] == piece.id) {
          _placed[row][col] = null;
          _placedPieceIds[row][col] = null;
        }
      }
    }
  }

  void _startBoardPieceDrag(Piece piece) {
    _startLevelTimer();
    final originalCells = _placedCellsForPiece(piece);
    setState(() {
      if (_isTutorialLevel && _tutorialStep == TutorialStep.dragPiece) {
        _tutorialDragInProgress = true;
      }
      _draggingBoardPieceId = piece.id;
      _draggingOriginalCells = originalCells;
      _hoverPiece = null;
      _hoverRow = null;
      _hoverCol = null;
      _hoverCells = <String>{};
      _message = null;
    });
  }

  void _finishBoardPieceDrag(Piece piece, bool wasAccepted, Offset globalEndPosition) {
    if (!wasAccepted && _canPlaceHoverCells(piece)) {
      _place(piece, _hoverRow ?? 0, _hoverCol ?? 0);
      return;
    }
    if (!wasAccepted) {
      if (_hoverPiece == piece &&
          !_canPlaceHoverCells(piece) &&
          !_isInsideTray(globalEndPosition)) {
        _handleInvalidDrop(piece);
      }
      _cancelBoardPieceDrag(piece, globalEndPosition);
      return;
    }
    _clearLandingPreview();
  }

  void _finishTrayPieceDrag(Piece piece, bool wasAccepted, Offset globalEndPosition) {
    if (!wasAccepted && _canPlaceHoverCells(piece)) {
      _place(piece, _hoverRow ?? 0, _hoverCol ?? 0);
      return;
    }
    if (!wasAccepted &&
        _hoverPiece == piece &&
        !_canPlaceHoverCells(piece) &&
        !_isInsideTray(globalEndPosition)) {
      _handleInvalidDrop(piece);
    }
    _clearLandingPreview();
  }

  Cell? _boardCellFromKey(String key) {
    final parts = key.split(',');
    if (parts.length != 2) {
      return null;
    }
    final row = int.tryParse(parts[0]);
    final col = int.tryParse(parts[1]);
    if (row == null || col == null) {
      return null;
    }
    return Cell(col, row);
  }

  void _showLandingPreview(Piece piece, int row, int col, Set<String> cells) {
    if (_hoverPiece == piece &&
        _hoverRow == row &&
        _hoverCol == col &&
        _hoverCells.length == cells.length &&
        _hoverCells.containsAll(cells)) {
      return;
    }
    setState(() {
      _hoverPiece = piece;
      _hoverRow = row;
      _hoverCol = col;
      _hoverCells = cells;
    });
  }

  bool _hasVisibleBoardPreview(Set<String> hoverCells) {
    for (final key in hoverCells) {
      final cell = _boardCellFromKey(key);
      if (cell == null) {
        continue;
      }
      if (cell.dy >= 0 && cell.dy < _boardSize && cell.dx >= 0 && cell.dx < _boardSize) {
        return true;
      }
    }
    return false;
  }

  void _showLandingPreviewAtPointer(
    Piece piece,
    Offset globalPointerPosition,
    double boardCellSize,
    Offset? dragAnchor,
  ) {
    final boardContext = _boardKey.currentContext;
    if (boardContext == null) {
      return;
    }

    final feedbackSize = PieceView.sizeFor(
      piece: piece,
      cellSize: boardCellSize,
      gap: Board.gap,
    );
    final resolvedDragAnchor = dragAnchor ??
        Offset(
          feedbackSize.width / 2,
          feedbackSize.height + Board.dragFingerOffset,
        );
    final pieceTopLeftGlobal = globalPointerPosition -
        resolvedDragAnchor;
    final renderBox = boardContext.findRenderObject()! as RenderBox;
    final pieceTopLeftOnGrid =
        renderBox.globalToLocal(pieceTopLeftGlobal) -
            const Offset(Board.outerPadding, Board.outerPadding);
    final pitch = boardCellSize + Board.gap;
    final minDx = piece.cells.map((cell) => cell.dx).reduce(math.min);
    final minDy = piece.cells.map((cell) => cell.dy).reduce(math.min);
    final originRow = (pieceTopLeftOnGrid.dy / pitch).round() - minDy;
    final originCol = (pieceTopLeftOnGrid.dx / pitch).round() - minDx;
    final hoverCells = <String>{};
    for (final cell in piece.cells) {
      hoverCells.add('${originRow + cell.dy},${originCol + cell.dx}');
    }
    final hasVisiblePreview = _hasVisibleBoardPreview(hoverCells);

    final previousRow = _hoverPiece == piece ? _hoverRow : null;
    final previousCol = _hoverPiece == piece ? _hoverCol : null;

    _showLandingPreview(
      piece,
      originRow,
      originCol,
      hoverCells,
    );

    if (hasVisiblePreview && previousRow != null && previousCol != null) {
      final stepCount = math.max(
        (originRow - previousRow).abs(),
        (originCol - previousCol).abs(),
      );
      if (stepCount > 0) {
        if (AppSettings.vibrationOn) {
          unawaited(HapticFeedback.selectionClick());
        }
        unawaited(_playPopSound(stepCount));
      }
    }
  }

  void _clearLandingPreview() {
    if (_hoverPiece == null) {
      return;
    }
    setState(() {
      _hoverPiece = null;
      _hoverRow = null;
      _hoverCol = null;
      _hoverCells = <String>{};
    });
  }

  bool _isInsideTray(Offset globalPosition) {
    final trayContext = _trayKey.currentContext;
    if (trayContext == null) {
      return false;
    }
    final renderBox = trayContext.findRenderObject()! as RenderBox;
    final localPosition = renderBox.globalToLocal(globalPosition);
    return Rect.fromLTWH(0, 0, renderBox.size.width, renderBox.size.height)
        .contains(localPosition);
  }

  bool _isPastBoardReturnZone(Offset globalPosition) {
    final boardContext = _boardKey.currentContext;
    if (boardContext == null) {
      return false;
    }
    final renderBox = boardContext.findRenderObject()! as RenderBox;
    final boardBottom = renderBox.localToGlobal(Offset(0, renderBox.size.height)).dy;
    return globalPosition.dy >= boardBottom + 100;
  }

  void _restoreDraggedPiece(Piece piece) {
    for (final key in _draggingOriginalCells) {
      final cell = _boardCellFromKey(key);
      if (cell == null) {
        continue;
      }
      _placed[cell.dy][cell.dx] = piece.color;
      _placedPieceIds[cell.dy][cell.dx] = piece.id;
    }
    _usedPieces.add(piece.id);
  }

  void _cancelBoardPieceDrag(Piece piece, Offset globalEndPosition) {
    setState(() {
      if (_isInsideTray(globalEndPosition) ||
          _isPastBoardReturnZone(globalEndPosition)) {
        _clearPlacedPieceCells(piece);
        _usedPieces.remove(piece.id);
      } else {
        _restoreDraggedPiece(piece);
      }
      if (_isTutorialLevel && _tutorialStep == TutorialStep.dragPiece) {
        _tutorialDragInProgress = false;
      }
      _draggingBoardPieceId = null;
      _draggingOriginalCells = <String>{};
      _hoverPiece = null;
      _hoverRow = null;
      _hoverCol = null;
      _hoverCells = <String>{};
    });
    unawaited(_saveProgress());
  }

  Future<void> _useHint() async {
    if (_hintButtonLocked) {
      return;
    }
    _hintButtonLocked = true;
    try {
      if (_hints == 0) {
        await _showRewardedAdForHint();
        return;
      }
      if (_hintAnimationController.isAnimating) {
        _hintAnimationController.stop();
        _finalizeActiveHintReveal();
      }
      final nextPiece = _pieces
          .where((piece) => !_usedPieces.contains(piece.id) && !_hintedPieceIds.contains(piece.id))
          .firstOrNull;
      if (nextPiece == null) {
        return;
      }
      setState(() {
        _hints--;
      });
      final currentLevelId = _levels[_currentLevelIndex].id;
      unawaited(
        AnalyticsEvents.hintUsed(
          levelId: currentLevelId,
          levelIndex: _currentLevelIndex,
          hintsRemaining: _hints,
        ),
      );
      unawaited(_saveProgress());
      await _playSingleSound('audio/one_pop.wav');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await _playHintReveal(nextPiece);
    } finally {
      _hintButtonLocked = false;
    }
  }

  Widget _buildHintOrbOverlay() {
    final start = _hintOrbStart;
    final end = _hintOrbEnd;
    final color = _hintOrbColor;
    final explosionOrigin = _hintExplosionOrigin;
    final orbVisible = start != null && end != null && !_hintParticlesVisible;
    final particlesVisible = explosionOrigin != null && _hintParticlesVisible && _hintParticleTargets.isNotEmpty;
    if (color == null || (!orbVisible && !particlesVisible)) {
      return const SizedBox.shrink();
    }

    final overlayContext = _screenStackKey.currentContext;
    if (overlayContext == null) {
      return const SizedBox.shrink();
    }
    final overlayBox = overlayContext.findRenderObject()! as RenderBox;
    final localStart = start != null ? overlayBox.globalToLocal(start) : null;
    final localEnd = end != null ? overlayBox.globalToLocal(end) : null;
    final localExplosionOrigin =
        explosionOrigin != null ? overlayBox.globalToLocal(explosionOrigin) : null;
    final localTargets = _hintParticleTargets
        .map(overlayBox.globalToLocal)
        .toList(growable: false);

    final t = Curves.easeInOutCubic.transform(_hintAnimationController.value);
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            if (orbVisible && localStart != null && localEnd != null)
              Positioned(
                left: Offset.lerp(localStart, localEnd, t)!.dx - (18.0 + (1.0 - (2 * t - 1).abs()) * 6.0) / 2,
                top: Offset.lerp(localStart, localEnd, t)!.dy +
                    math.sin(t * math.pi) * -48 -
                    (18.0 + (1.0 - (2 * t - 1).abs()) * 6.0) / 2,
                child: Container(
                  width: 18.0 + (1.0 - (2 * t - 1).abs()) * 6.0,
                  height: 18.0 + (1.0 - (2 * t - 1).abs()) * 6.0,
                      decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        color.withValues(alpha: 0.98),
                        color.withValues(alpha: 0.72),
                        color.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.65, 1.0],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.7),
                        blurRadius: 18,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
            if (particlesVisible && localExplosionOrigin != null)
              ...List.generate(localTargets.length, (index) {
                final target = localTargets[index];
                final delay = index * 0.08;
                final safeDelay = math.min(delay, 0.85);
                final localT = ((t - safeDelay) / math.max(0.0001, 1 - safeDelay)).clamp(0.0, 1.0).toDouble();
                final eased = Curves.easeOutCubic.transform(localT);
                final ballPosition = Offset.lerp(localExplosionOrigin, target, eased)!;
                final lift = math.sin(localT * math.pi) * -32;
                final ballSize = math.max(5.0, 10.0 - index * 0.4);
                return Positioned(
                  left: ballPosition.dx - ballSize / 2,
                  top: ballPosition.dy - ballSize / 2 + lift,
                  child: Container(
                    width: ballSize,
                    height: ballSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                          color.withValues(alpha: 0.98),
                          color.withValues(alpha: 0.78),
                          color.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.72, 1.0],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.55),
                          blurRadius: 14,
                          spreadRadius: 1.5,
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: appThemeNotifier,
      builder: (context, _, _) {
        if (!_levelsLoaded) {
          return Scaffold(
            backgroundColor: _gameBackgroundColor,
            body: Center(
              child: Text(
                _levelsLoadError ?? 'Loading levels...',
                style: TextStyle(
                  color: AppColors.cocoa,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          );
        }
        return Scaffold(
          backgroundColor: _gameBackgroundColor,
          bottomNavigationBar: AppBannerAd(backgroundColor: _gameBackgroundColor),
          body: SafeArea(
            child: Stack(
              key: _screenStackKey,
              children: [
                Column(
                  children: [
                    IgnorePointer(
                      ignoring: _showCompletionDarkScreen,
                      child: AnimatedOpacity(
                        opacity: _showCompletionDarkScreen ? 0.0 : 1.0,
                        duration: const Duration(milliseconds: 180),
                        child: _buildGameHeaderRow(),
                      ),
                    ),
                    const SizedBox(height: 26),
                    Expanded(
                      child: IgnorePointer(
                        ignoring: _isLevelComplete,
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 28),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  PowerButton(
                                    key: _resetButtonKey,
                                    icon: Icons.refresh,
                                    badge: null,
                                    size: 58,
                                    iconSize: 30,
                                    onPressed: _handleResetPressed,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(child: _buildBigPieceReminder(compact: true)),
                                  const SizedBox(width: 12),
                                  PowerButton(
                                    key: _hintButtonKey,
                                    icon: Icons.lightbulb,
                                    badge: _isTutorialLevel
                                        ? (_tutorialHintAvailable ? '+1' : '+')
                                        : _hints == 0
                                            ? '+'
                                            : '+$_hints',
                                    badgeColor: AppColors.green,
                                    size: 58,
                                    iconSize: 30,
                                    glowColor: _hintOrbColor,
                                    glowStrength: _hintOrbStart != null
                                        ? 1.0 - Curves.easeOut.transform(_hintAnimationController.value)
                                        : 0.0,
                                    enablePressFeedback: false,
                                    onPressed: _handleHintPressed,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 28),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final boardWidth = math.min(constraints.maxWidth - 34, 390.0);
                                  final boardHeight = math.max(
                                    0.0,
                                    constraints.maxHeight - 32 - 184 - 1,
                                  );
                                  final widthBasedCellSize =
                                      (boardWidth - Board.outerPadding * 2 - Board.gap * (_boardSize - 1)) / _boardSize;
                                  final heightBasedCellSize =
                                      (boardHeight - Board.outerPadding * 2 - Board.gap * (_boardSize - 1)) / _boardSize;
                                  final cellSize = math.max(
                                    24.0,
                                    math.min(widthBasedCellSize, heightBasedCellSize),
                                  );
                                  return Column(
                                    children: [
                                      Stack(
                                        alignment: Alignment.topCenter,
                                        children: [
                                          Board(
                                            boardKey: _boardKey,
                                            boardSize: _boardSize,
                                            placed: _placed,
                                            placedPieceIds: _placedPieceIds,
                                            hintColorsByCell: _hintColorsByCell,
                                            hintRevealCells: _hintRevealCells,
                                            hintRevealVersion: _hintRevealVersion,
                                            levelCompleted: _isLevelComplete,
                                            lockedPieceIds: _lockedPieces,
                                            piecesById: _piecesById,
                                            cellSize: cellSize,
                                            hoverPiece: _hoverPiece,
                                            hoverRow: _hoverRow,
                                            hoverCol: _hoverCol,
                                            hoverCells: _hoverCells,
                                            draggingPieceId: _draggingBoardPieceId,
                                            canPlaceHoverPiece: _hoverPiece != null && _canPlaceHoverCells(_hoverPiece!),
                                            onDragStarted: _startBoardPieceDrag,
                                            onDragUpdate: (piece, globalPointerPosition, boardCellSize, dragAnchor) =>
                                                _showLandingPreviewAtPointer(
                                              piece,
                                              globalPointerPosition,
                                              boardCellSize,
                                              dragAnchor,
                                            ),
                                            onDragEnd: _finishBoardPieceDrag,
                                            onAccept: _placeFromHover,
                                          ),
                                          IgnorePointer(
                                            child: Padding(
                                              padding: const EdgeInsets.only(top: 18),
                                              child: AnimatedSwitcher(
                                                duration: const Duration(milliseconds: 250),
                                                transitionBuilder: (child, animation) =>
                                                    FadeTransition(opacity: animation, child: child),
                                                child: _message == null
                                                    ? const SizedBox.shrink()
                                                    : Container(
                                                        key: ValueKey(_message),
                                                        padding: const EdgeInsets.symmetric(
                                                          horizontal: 14,
                                                          vertical: 8,
                                                        ),
                                                        decoration: BoxDecoration(
                                                          color: AppColors.overlay.withValues(alpha: 0.94),
                                                          borderRadius: BorderRadius.circular(12),
                                                          boxShadow: const [
                                                            BoxShadow(
                                                              color: Color(0x12000000),
                                                              blurRadius: 10,
                                                              offset: Offset(0, 4),
                                                            ),
                                                          ],
                                                        ),
                                                        child: Text(
                                                          _message!,
                                                          style: TextStyle(
                                                            color: AppColors.cocoa,
                                                            fontSize: 18,
                                                            fontWeight: FontWeight.w700,
                                                          ),
                                                        ),
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 32),
                                      PieceTray(
                                        key: _trayKey,
                                        pieces: _pieces,
                                        usedPieces: _usedPieces,
                                        draggingPieceId: _draggingBoardPieceId,
                                        shakingPieceId: _shakingPieceId,
                                        shakeVersion: _shakeVersion,
                                        boardCellSize: cellSize,
                                        onDragStarted: _startBoardPieceDrag,
                                        onDragUpdate: (piece, globalPointerPosition, boardCellSize, dragAnchor) =>
                                            _showLandingPreviewAtPointer(
                                          piece,
                                          globalPointerPosition,
                                          boardCellSize,
                                          dragAnchor,
                                        ),
                                        onDragEnd: _finishTrayPieceDrag,
                                      ),
                                      const SizedBox(height: 1),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_showCompletionDarkScreen,
                    child: AnimatedOpacity(
                      opacity: _showCompletionDarkScreen ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: 0.48),
                            ),
                          ),
                          Align(
                            alignment: Alignment.topCenter,
                            child: SafeArea(
                              child: _buildGameHeaderRow(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: ConfettiOverlay(
                      triggerVersion: _confettiVersion,
                      completionImageAsset: _isFinalLevel
                          ? 'assets/images/game_complete.png'
                          : 'assets/images/figured_it.png',
                      completionTimeText: _completionBadgeText,
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_showNextLevelButton,
                    child: AnimatedOpacity(
                      opacity: _showNextLevelButton ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 420),
                      curve: Curves.easeOutCubic,
                      child: Transform.translate(
                        offset: const Offset(0, 260),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 28),
                            child: AnimatedScale(
                              scale: _showNextLevelButton ? 1.0 : 0.88,
                              duration: const Duration(milliseconds: 420),
                              curve: Curves.easeOutBack,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 360),
                                child: _buildNextLevelButton(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_isTutorialLevel && _tutorialStep != TutorialStep.complete)
                  Positioned.fill(
                    child: TutorialGuideOverlay(
                      step: _tutorialStep,
                      trayRect: _localRectForKey(_trayKey),
                      hintButtonRect: _localRectForKey(_hintButtonKey),
                      hideDragStepOverlay: _tutorialDragInProgress,
                    ),
                  ),
                _buildHintOrbOverlay(),
              ],
            ),
          ),
        );
      },
    );
  }
}

class ShakeOnTrigger extends StatefulWidget {
  const ShakeOnTrigger({
    required this.trigger,
    required this.child,
    super.key,
  });

  final int trigger;
  final Widget child;

  @override
  State<ShakeOnTrigger> createState() => _ShakeOnTriggerState();
}

class _ShakeOnTriggerState extends State<ShakeOnTrigger>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
  }

  @override
  void didUpdateWidget(covariant ShakeOnTrigger oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trigger != 0 && widget.trigger != oldWidget.trigger) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final offset = math.sin(_controller.value * math.pi * 8) * 10;
        return Transform.translate(
          offset: Offset(offset, 0),
          child: child,
        );
      },
    );
  }
}

Offset dragAnchorForPiece(Piece piece, Size feedbackSize) {
  final bounds = piece.bounds;
  if (bounds.height > bounds.width) {
    return Offset(feedbackSize.width / 2, feedbackSize.height / 2 + 100);
  }
  return Offset(
    feedbackSize.width / 2,
    feedbackSize.height + Board.dragFingerOffset,
  );
}

class Board extends StatefulWidget {
  const Board({
    required this.boardKey,
    required this.boardSize,
    required this.placed,
    required this.placedPieceIds,
    required this.hintColorsByCell,
    required this.hintRevealCells,
    required this.hintRevealVersion,
    required this.levelCompleted,
    required this.lockedPieceIds,
    required this.piecesById,
    required this.cellSize,
    required this.hoverPiece,
    required this.hoverRow,
    required this.hoverCol,
    required this.hoverCells,
    required this.draggingPieceId,
    required this.canPlaceHoverPiece,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onAccept,
    super.key,
  });

  final GlobalKey boardKey;
  final int boardSize;
  final List<List<Color?>> placed;
  final List<List<String?>> placedPieceIds;
  final Map<String, Color> hintColorsByCell;
  final Set<String> hintRevealCells;
  final int hintRevealVersion;
  final bool levelCompleted;
  final Set<String> lockedPieceIds;
  final Map<String, Piece> piecesById;
  final double cellSize;
  final Piece? hoverPiece;
  final int? hoverRow;
  final int? hoverCol;
  final Set<String> hoverCells;
  final String? draggingPieceId;
  final bool canPlaceHoverPiece;
  final void Function(Piece piece) onDragStarted;
  final void Function(
    Piece piece,
    Offset globalPointerPosition,
    double boardCellSize,
    Offset? dragAnchor,
  ) onDragUpdate;
  final void Function(Piece piece, bool wasAccepted, Offset globalEndPosition) onDragEnd;
  final void Function(Piece piece) onAccept;
  static const double gap = 6;
  static const double outerPadding = 9;
  static const double dragFingerOffset = 18;

  @override
  State<Board> createState() => _BoardState();
}

class _BoardState extends State<Board> with SingleTickerProviderStateMixin {
  late final AnimationController _completionRippleController;
  bool _wasLevelCompleted = false;

  @override
  void initState() {
    super.initState();
    _completionRippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    );
    _wasLevelCompleted = widget.levelCompleted;
    if (widget.levelCompleted) {
      _completionRippleController.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(covariant Board oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.levelCompleted) {
      _wasLevelCompleted = false;
      _completionRippleController.reset();
      return;
    }
    if (_wasLevelCompleted) {
      return;
    }
    _wasLevelCompleted = true;
    _completionRippleController.forward(from: 0);
  }

  @override
  void dispose() {
    _completionRippleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<Piece>(
      onWillAcceptWithDetails: (details) => true,
      onAcceptWithDetails: (details) {
        widget.onAccept(details.data);
      },
      builder: (context, candidateData, rejectedData) {
        return Container(
          key: widget.boardKey,
          width: widget.cellSize * widget.boardSize + Board.gap * (widget.boardSize - 1) + Board.outerPadding * 2,
          height: widget.cellSize * widget.boardSize + Board.gap * (widget.boardSize - 1) + Board.outerPadding * 2,
          padding: const EdgeInsets.all(Board.outerPadding),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Color(0x15000000),
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: AnimatedBuilder(
            animation: _completionRippleController,
            builder: (context, _) {
              return GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: widget.boardSize,
                  crossAxisSpacing: Board.gap,
                  mainAxisSpacing: Board.gap,
                ),
                itemCount: widget.boardSize * widget.boardSize,
                itemBuilder: (context, index) {
                  final row = index ~/ widget.boardSize;
                  final col = index % widget.boardSize;
                  final pieceId = widget.placedPieceIds[row][col];
                  final isDraggingPlacedPiece = pieceId == widget.draggingPieceId;
                  final color = isDraggingPlacedPiece ? null : widget.placed[row][col];
                  final placedPiece = pieceId == null ? null : widget.piecesById[pieceId];
                  final isPreviewCell = _isPreviewCell(row, col);
                  final hintColor = _hintColor(row, col);
                  final hintKey = '$row,$col';
                  final shouldRevealHintCell = widget.hintRevealCells.contains(hintKey);
                  final previewColor = widget.canPlaceHoverPiece
                      ? widget.hoverPiece?.color ?? AppColors.green
                      : AppColors.red;
                  final cellWidget = AnimatedContainer(
                    duration: const Duration(milliseconds: 90),
                    decoration: _cellDecoration(
                      color: color,
                      hintColor: hintColor,
                      isPreviewCell: isPreviewCell,
                      previewColor: previewColor,
                    ),
                  );
                  final cellContent = placedPiece == null
                      ? shouldRevealHintCell
                          ? TweenAnimationBuilder<double>(
                              key: ValueKey('hint-${widget.hintRevealVersion}-$hintKey'),
                              duration: const Duration(milliseconds: 420),
                              curve: Curves.easeOutBack,
                              tween: Tween<double>(begin: 0.25, end: 1.0),
                              builder: (context, scale, child) {
                                return Transform.scale(
                                  scale: scale,
                                  child: Opacity(
                                    opacity: scale.clamp(0.0, 1.0).toDouble(),
                                    child: child,
                                  ),
                                );
                              },
                              child: cellWidget,
                            )
                          : cellWidget
                      : Builder(
                          builder: (context) {
                            if (widget.lockedPieceIds.contains(placedPiece.id)) {
                              return cellWidget;
                            }
                            final feedbackSize = PieceView.sizeFor(
                              piece: placedPiece,
                              cellSize: widget.cellSize,
                              gap: Board.gap,
                            );
                            final dragAnchor = dragAnchorForPiece(placedPiece, feedbackSize);
                            return Draggable<Piece>(
                              data: placedPiece,
                              dragAnchorStrategy: (_, _, _) => dragAnchor,
                              onDragStarted: () => widget.onDragStarted(placedPiece),
                              onDragUpdate: (details) {
                                widget.onDragUpdate(
                                  placedPiece,
                                  details.globalPosition,
                                  widget.cellSize,
                                  dragAnchor,
                                );
                              },
                              onDragEnd: (details) => widget.onDragEnd(
                                placedPiece,
                                details.wasAccepted,
                                details.offset + dragAnchor,
                              ),
                              onDraggableCanceled: (_, offset) => widget.onDragEnd(
                                placedPiece,
                                false,
                                offset + dragAnchor,
                              ),
                              feedback: Material(
                                color: Colors.transparent,
                                child: PieceView.dragFeedback(
                                  piece: placedPiece,
                                  cellSize: widget.cellSize,
                                  gap: Board.gap,
                                ),
                              ),
                              childWhenDragging: DecoratedBox(
                                decoration: _cellDecoration(
                                  color: null,
                                  hintColor: hintColor,
                                  isPreviewCell: false,
                                  previewColor: previewColor,
                                ),
                                child: const SizedBox.expand(),
                              ),
                              child: cellWidget,
                            );
                          },
                        );
                  return _completionRippleWrap(
                    row: row,
                    col: col,
                    child: cellContent,
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Widget _completionRippleWrap({
    required int row,
    required int col,
    required Widget child,
  }) {
    final rippleValue = _completionRippleController.value;
    if (rippleValue <= 0) {
      return child;
    }
    const maxDelay = 0.42;
    final center = (widget.boardSize - 1) / 2;
    final maxDistance = math.max(1.0, (widget.boardSize - 1).toDouble());
    final distanceFromCenter = (row - center).abs() + (col - center).abs();
    final delay = (distanceFromCenter / maxDistance) * maxDelay;
    final progress = ((rippleValue - delay) / (1.0 - delay)).clamp(0.0, 1.0);
    final wave = math.sin(progress * math.pi);
    if (wave <= 0) {
      return child;
    }
    final lift = 7.0 * wave;
    final scale = 1.0 + 0.085 * wave;
    return Transform.translate(
      offset: Offset(0, -lift),
      child: Transform.scale(
        scale: scale,
        child: child,
      ),
    );
  }

  bool _isPreviewCell(int row, int col) {
    if (widget.placed[row][col] != null) {
      if (widget.placedPieceIds[row][col] == widget.draggingPieceId) {
        return widget.hoverCells.contains('$row,$col');
      }
      return false;
    }
    return widget.hoverCells.contains('$row,$col');
  }

  Color? _hintColor(int row, int col) {
    if (widget.placed[row][col] != null || _isPreviewCell(row, col)) {
      return null;
    }
    return widget.hintColorsByCell['$row,$col'];
  }

  BoxDecoration _cellDecoration({
    required Color? color,
    required Color? hintColor,
    required bool isPreviewCell,
    required Color previewColor,
  }) {
    final baseColor = color ??
        (isPreviewCell
            ? previewColor.withValues(alpha: 0.22)
            : hintColor?.withValues(alpha: 0.18) ?? AppColors.cellEmpty);
    return BoxDecoration(
      color: baseColor,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(
        color: color == null
            ? (isPreviewCell
                ? previewColor.withValues(alpha: 0.8)
                : hintColor?.withValues(alpha: 0.55) ?? AppColors.cellLine)
            : color.withValues(alpha: 0.55),
        width: isPreviewCell ? 2 : hintColor != null ? 1.5 : 1,
      ),
      boxShadow: isPreviewCell || hintColor != null
          ? [
              BoxShadow(
                color: (isPreviewCell ? previewColor : hintColor!).withValues(
                  alpha: isPreviewCell ? 0.34 : 0.14,
                ),
                blurRadius: isPreviewCell ? 12 : 8,
                spreadRadius: 1,
              ),
            ]
          : null,
    );
  }
}

class PieceTray extends StatefulWidget {
  const PieceTray({
    required this.pieces,
    required this.usedPieces,
    required this.draggingPieceId,
    required this.shakingPieceId,
    required this.shakeVersion,
    required this.boardCellSize,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragEnd,
    super.key,
  });

  final List<Piece> pieces;
  final Set<String> usedPieces;
  final String? draggingPieceId;
  final String? shakingPieceId;
  final int shakeVersion;
  final double boardCellSize;
  final void Function(Piece piece) onDragStarted;
  final void Function(
    Piece piece,
    Offset globalPointerPosition,
    double boardCellSize,
    Offset? dragAnchor,
  ) onDragUpdate;
  final void Function(Piece piece, bool wasAccepted, Offset globalEndPosition) onDragEnd;

  @override
  State<PieceTray> createState() => _PieceTrayState();
}

class _PieceTrayState extends State<PieceTray> {
  static const double _trayItemWidth = 126;
  static const double _traySeparatorWidth = 18;
  static const double _horizontalPadding = 24;
  static const double _handleHeight = 18;
  static const double _thumbYOffset = 7;

  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Rect? _thumbRect({
    required BoxConstraints constraints,
    required int itemCount,
  }) {
    if (itemCount == 0) {
      return null;
    }

    final trackWidth = constraints.maxWidth;
    final contentWidth = _horizontalPadding * 2 +
        itemCount * _trayItemWidth +
        math.max(0, itemCount - 1) * _traySeparatorWidth;
    final viewportWidth = _scrollController.hasClients
        ? _scrollController.position.viewportDimension
        : trackWidth;
    final maxScrollExtent = math.max(0.0, contentWidth - viewportWidth);
    if (maxScrollExtent <= 0) {
      return null;
    }
    final pixels = _scrollController.hasClients ? _scrollController.position.pixels : 0.0;
    final thumbWidth = math.max(
      52.0,
      trackWidth * (viewportWidth / (viewportWidth + maxScrollExtent)),
    );
    final boundedThumbWidth = math.min(trackWidth, thumbWidth);
    final maxThumbLeft = math.max(0.0, trackWidth - boundedThumbWidth);
    final thumbLeft = maxScrollExtent <= 0
        ? 0.0
        : maxThumbLeft * (pixels / maxScrollExtent);

    return Rect.fromLTWH(
      thumbLeft,
      constraints.maxHeight - _handleHeight + _thumbYOffset,
      math.min(boundedThumbWidth, contentWidth),
      _handleHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.pieces
        .where((piece) =>
            !widget.usedPieces.contains(piece.id) ||
            piece.id == widget.draggingPieceId)
        .toList();
    return SizedBox(
      height: 184,
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return AnimatedBuilder(
                  animation: _scrollController,
                  builder: (context, _) {
                    final thumbRect = _thumbRect(
                      constraints: constraints,
                      itemCount: active.length,
                    );

                    return Stack(
                      children: [
                        ScrollbarTheme(
                          data: ScrollbarThemeData(
                            thumbColor: WidgetStatePropertyAll(AppColors.orange),
                            trackColor: WidgetStatePropertyAll(const Color.fromARGB(211, 160, 139, 112).withValues(alpha: 0.18)),
                            trackBorderColor: WidgetStatePropertyAll(AppColors.orange.withValues(alpha: 0.2)),
                            thickness: const WidgetStatePropertyAll(14),
                            radius: const Radius.circular(999),
                          ),
                          child: Scrollbar(
                            controller: _scrollController,
                            thumbVisibility: true,
                            trackVisibility: true,
                            interactive: true,
                            thickness: 14,
                            radius: const Radius.circular(999),
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 18),
                              child: ListView.separated(
                                controller: _scrollController,
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                                scrollDirection: Axis.horizontal,
                                itemBuilder: (context, index) {
                                  final piece = active[index];
                                  final isDraggedFromBoard =
                                      piece.id == widget.draggingPieceId &&
                                          widget.usedPieces.contains(piece.id);
                                  final shakeTrigger =
                                      piece.id == widget.shakingPieceId ? widget.shakeVersion : 0;
                                  if (isDraggedFromBoard) {
                                    return ShakeOnTrigger(
                                      trigger: shakeTrigger,
                                      child: Opacity(
                                        opacity: 0.25,
                                        child: PieceView.tray(piece: piece),
                                      ),
                                    );
                                  }
                                  final feedbackSize = PieceView.sizeFor(
                                    piece: piece,
                                    cellSize: widget.boardCellSize,
                                    gap: Board.gap,
                                  );
                                  final dragAnchor = dragAnchorForPiece(piece, feedbackSize);
                                  return ShakeOnTrigger(
                                    trigger: shakeTrigger,
                                    child: Draggable<Piece>(
                                      data: piece,
                                      dragAnchorStrategy: (_, _, _) => dragAnchor,
                                      onDragStarted: () => widget.onDragStarted(piece),
                                      onDragUpdate: (details) {
                                        widget.onDragUpdate(
                                          piece,
                                          details.globalPosition,
                                          widget.boardCellSize,
                                          dragAnchor,
                                        );
                                      },
                                      onDragEnd: (details) => widget.onDragEnd(
                                        piece,
                                        details.wasAccepted,
                                        details.offset + dragAnchor,
                                      ),
                                      onDraggableCanceled: (_, offset) => widget.onDragEnd(
                                        piece,
                                        false,
                                        offset + dragAnchor,
                                      ),
                                      feedback: Material(
                                        color: Colors.transparent,
                                        child: PieceView.dragFeedback(
                                          piece: piece,
                                          cellSize: widget.boardCellSize,
                                          gap: Board.gap,
                                        ),
                                      ),
                                      childWhenDragging: Opacity(
                                        opacity: 0.25,
                                        child: PieceView.tray(piece: piece),
                                      ),
                                      child: PieceView.tray(piece: piece),
                                    ),
                                  );
                                },
                                separatorBuilder: (_, _) => const SizedBox(width: 18),
                                itemCount: active.length,
                              ),
                            ),
                          ),
                        ),
                        if (thumbRect != null)
                          Positioned(
                            left: thumbRect.left,
                            bottom: -1.7,
                            width: thumbRect.width,
                            height: _handleHeight,
                            child: IgnorePointer(
                              child: Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    const _GripLine(),
                                    const SizedBox(width: 8),
                                    const _GripLine(),
                                    const SizedBox(width: 8),
                                    const _GripLine(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

class _GripLine extends StatelessWidget {
  const _GripLine();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 4,
      height: 12,
      decoration: BoxDecoration(
        color: const Color(0xff8b4f1e),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class ConfettiOverlay extends StatefulWidget {
  const ConfettiOverlay({
    required this.triggerVersion,
    required this.completionImageAsset,
    required this.completionTimeText,
    super.key,
  });

  final int triggerVersion;
  final String completionImageAsset;
  final String completionTimeText;

  @override
  State<ConfettiOverlay> createState() => _ConfettiOverlayState();
}

class _ConfettiOverlayState extends State<ConfettiOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  List<_ConfettiParticle> _particles = <_ConfettiParticle>[];
  int _lastTriggerVersion = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _lastTriggerVersion = widget.triggerVersion;
    if (widget.triggerVersion > 0) {
      _startBurst(widget.triggerVersion);
    }
  }

  @override
  void didUpdateWidget(covariant ConfettiOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.triggerVersion <= 0) {
      _resetBurst();
      return;
    }
    if (widget.triggerVersion <= _lastTriggerVersion) {
      return;
    }
    _lastTriggerVersion = widget.triggerVersion;
    _startBurst(widget.triggerVersion);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _startBurst(int seedVersion) {
    final random = math.Random(seedVersion * 7919 + 17);
    _particles = List.generate(220, (index) {
      final launchBand = index / 220;
      final baseAngle = -math.pi / 2 + (random.nextDouble() * math.pi * 1.6) - math.pi * 0.3;
      final speed = 240 + random.nextDouble() * 380;
      final drift = -180 + random.nextDouble() * 360;
      final size = 4 + random.nextDouble() * 8;
      return _ConfettiParticle(
        angle: baseAngle,
        speed: speed,
        drift: drift,
        size: size,
        spin: (random.nextDouble() * 2 - 1) * 16,
        color: _confettiColors[index % _confettiColors.length],
        xOffset: -size * 0.5 + (random.nextDouble() - 0.5) * 260 + math.sin(launchBand * math.pi * 6) * 52,
        yOffset: -30 + random.nextDouble() * 120,
      );
    });
    _controller.forward(from: 0);
  }

  void _resetBurst() {
    _lastTriggerVersion = 0;
    _particles = <_ConfettiParticle>[];
    _controller.reset();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_lastTriggerVersion <= 0) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (!_controller.isAnimating && _controller.value == 0) {
          return const SizedBox.shrink();
        }
        final t = Curves.easeOutCubic.transform(_controller.value);
        final popT = ((t - 0.04) / 0.34).clamp(0.0, 1.0).toDouble();
        final popOpacity = ((t - 0.05) / 0.18).clamp(0.0, 1.0).toDouble();
        final popScale = 0.72 + Curves.easeOutBack.transform(popT) * 0.28;
        return Stack(
          children: [
            CustomPaint(
              painter: _ConfettiPainter(
                particles: _particles,
                t: t,
              ),
              child: const SizedBox.expand(),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedOpacity(
                        opacity: popOpacity,
                        duration: const Duration(milliseconds: 0),
                        child: Transform.scale(
                          scale: popScale.clamp(0.72, 1.0),
                          child: SizedBox(
                            width: MediaQuery.sizeOf(context).width,
                            child: Image.asset(
                              widget.completionImageAsset,
                              fit: BoxFit.fitWidth,
                              alignment: Alignment.center,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      AnimatedOpacity(
                        opacity: popOpacity,
                        duration: const Duration(milliseconds: 0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(999),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x22000000),
                                blurRadius: 10,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          foregroundDecoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            gradient: RadialGradient(
                              center: Alignment.center,
                              radius: 1.15,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.15),
                              ],
                              stops: const [0.62, 1.0],
                            ),
                          ),
                          child: Text(
                            'in ${widget.completionTimeText}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color.fromARGB(255, 242, 26, 26),
                              fontSize: 36,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ConfettiParticle {
  const _ConfettiParticle({
    required this.angle,
    required this.speed,
    required this.drift,
    required this.size,
    required this.spin,
    required this.color,
    required this.xOffset,
    required this.yOffset,
  });

  final double angle;
  final double speed;
  final double drift;
  final double size;
  final double spin;
  final Color color;
  final double xOffset;
  final double yOffset;
}

class _ConfettiPainter extends CustomPainter {
  const _ConfettiPainter({
    required this.particles,
    required this.t,
  });

  final List<_ConfettiParticle> particles;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (particles.isEmpty) {
      return;
    }
    for (var i = 0; i < particles.length; i++) {
      final particle = particles[i];
      final lane = (i % 8) / 7.0;
      final originX = size.width * lane + particle.xOffset * 0.65;
      final originY = size.height * 0.18 + particle.yOffset * 0.55;
      final distance = particle.speed * t;
      final gravity = 160 * t * t;
      final arcLift = math.sin((t + lane * 0.35) * math.pi) * -64;
      final dx = originX + math.cos(particle.angle) * distance + particle.drift * t;
      final dy = originY + math.sin(particle.angle) * distance + gravity + arcLift;
      final paint = Paint()..color = particle.color;

      canvas.save();
      canvas.translate(dx, dy);
      canvas.rotate(particle.spin * t);
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: particle.size * 1.25,
        height: particle.size * 0.55,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(particle.size * 0.28)),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) {
    return oldDelegate.t != t || oldDelegate.particles != particles;
  }
}

const _confettiColors = [
  Color(0xfff7981d),
  Color(0xffffd953),
  Color(0xff8fa3f2),
  Color(0xff00c86b),
  Color(0xffce6788),
  Color(0xff40a9bc),
];

class PieceView extends StatelessWidget {
  const PieceView.tray({
    required this.piece,
    this.cellSize,
    this.gap = 6,
    this.showBox = true,
    this.boxSize = 126,
    super.key,
  });

  const PieceView.dragFeedback({
    required this.piece,
    required this.cellSize,
    required this.gap,
    this.showBox = false,
    this.boxSize,
    super.key,
  });

  final Piece piece;
  final double? cellSize;
  final double gap;
  final bool showBox;
  final double? boxSize;

  static Size sizeFor({
    required Piece piece,
    required double cellSize,
    required double gap,
  }) {
    final bounds = piece.bounds;
    return Size(
      bounds.width * cellSize + gap * (bounds.width - 1),
      bounds.height * cellSize + gap * (bounds.height - 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bounds = piece.bounds;
    final padding = showBox ? 10.0 : 0.0;
    final maxDimension = math.max(bounds.width, bounds.height);
    final trayReferenceDimension = showBox ? math.max(maxDimension.toDouble(), 5.0) : maxDimension.toDouble();
    final resolvedCellSize = cellSize ??
        ((boxSize! - padding * 2 - gap * (trayReferenceDimension - 1)) /
            trayReferenceDimension);
    final pieceWidth = bounds.width * resolvedCellSize + gap * (bounds.width - 1);
    final pieceHeight = bounds.height * resolvedCellSize + gap * (bounds.height - 1);
    final width = showBox ? boxSize! : pieceWidth;
    final height = showBox ? boxSize! : pieceHeight;

    return Container(
      width: width,
      height: height,
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: showBox ? AppColors.surfaceRaised : Colors.transparent,
        borderRadius: BorderRadius.circular(showBox ? 14 : 0),
        boxShadow: showBox
            ? const [
                BoxShadow(
                  color: Color(0x18000000),
                  blurRadius: 14,
                  offset: Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          width: pieceWidth,
          height: pieceHeight,
          child: CustomPaint(
            painter: PiecePainter(
              piece: piece,
              cellSize: resolvedCellSize,
              gap: gap,
            ),
          ),
        ),
      ),
    );
  }
}

class PiecePainter extends CustomPainter {
  const PiecePainter({
    required this.piece,
    required this.cellSize,
    required this.gap,
  });

  final Piece piece;
  final double cellSize;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final minDx = piece.cells.map((cell) => cell.dx).reduce(math.min);
    final minDy = piece.cells.map((cell) => cell.dy).reduce(math.min);
    for (final cell in piece.cells) {
      final rect = Rect.fromLTWH(
        (cell.dx - minDx) * (cellSize + gap),
        (cell.dy - minDy) * (cellSize + gap),
        cellSize,
        cellSize,
      );
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(7));
      canvas.drawRRect(
        rrect,
        Paint()..color = piece.color,
      );
    }
  }

  @override
  bool shouldRepaint(PiecePainter oldDelegate) =>
      oldDelegate.piece != piece ||
      oldDelegate.cellSize != cellSize ||
      oldDelegate.gap != gap;
}

class RuleStrip extends StatelessWidget {
  const RuleStrip({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 18),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: const [
          Expanded(child: RuleChip(label: 'Match each color')),
          SizedBox(width: 8),
          Expanded(child: RuleChip(label: 'Fill every square')),
          SizedBox(width: 8),
          Expanded(child: RuleChip(label: 'No gaps left')),
        ],
      ),
    );
  }
}

class RuleChip extends StatelessWidget {
  const RuleChip({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.cream,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AppColors.cocoa,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

Future<void> showSettingsPopup(BuildContext context) {
  unawaited(AnalyticsEvents.settingsOpen());
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x78000000),
    builder: (context) => const _SettingsDialog(),
  );
}

Future<bool> _showDeveloperPasswordDialog(BuildContext context) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        barrierColor: const Color(0x78000000),
        builder: (dialogContext) => const _DeveloperPasswordDialog(),
      ) ??
      false;
}

class _DeveloperPasswordDialog extends StatefulWidget {
  const _DeveloperPasswordDialog();

  @override
  State<_DeveloperPasswordDialog> createState() => _DeveloperPasswordDialogState();
}

class _DeveloperPasswordDialogState extends State<_DeveloperPasswordDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.trim() == '1001') {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _errorText = 'Incorrect password';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 34, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(
              color: Color(0x24000000),
              blurRadius: 24,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Password',
              style: TextStyle(
                color: AppColors.cocoa,
                fontSize: 28,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: true,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'Enter password',
                errorText: _errorText,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _submit,
                  child: const Text('Unlock'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late bool _soundOn;
  late bool _vibrationOn;
  late bool _darkMode;
  late bool _analyticsOn;
  late final Future<PackageInfo> _packageInfoFuture;
  final List<DateTime> _versionTapTimes = <DateTime>[];
  bool _passwordPromptOpen = false;

  @override
  void initState() {
    super.initState();
    _soundOn = AppSettings.soundOn;
    _vibrationOn = AppSettings.vibrationOn;
    _darkMode = AppSettings.darkMode;
    _analyticsOn = AppSettings.analyticsOn;
    _packageInfoFuture = PackageInfo.fromPlatform();
  }

  void _updateSound(bool value) {
    final shouldPlayDoublePop = !_soundOn && value;
    setState(() {
      _soundOn = value;
      AppSettings.soundOn = value;
    });
    unawaited(_saveAppSettings());
    if (shouldPlayDoublePop) {
      unawaited(_playUiDoublePopSound());
    }
  }

  void _updateVibration(bool value) {
    final shouldVibrate = !_vibrationOn && value;
    setState(() {
      _vibrationOn = value;
      AppSettings.vibrationOn = value;
    });
    unawaited(_saveAppSettings());
    if (shouldVibrate) {
      unawaited(HapticFeedback.errorNotification());
    }
  }

  void _updateDarkMode(bool value) {
    setState(() {
      _darkMode = value;
      AppSettings.darkMode = value;
      appThemeNotifier.value = value;
    });
    unawaited(AnalyticsEvents.darkModeToggled(enabled: value));
    unawaited(_saveAppSettings());
  }

  void _updateAnalytics(bool value) {
    setState(() {
      _analyticsOn = value;
      AppSettings.analyticsOn = value;
    });
    unawaited(_saveAppSettings());
    unawaited(_applyFirebaseCollectionSettings());
  }

  void _openLegalDocument(String title, String assetPath) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _LegalDocumentPage(
          title: title,
          assetPath: assetPath,
        ),
      ),
    );
  }

  Future<void> _openPrivacyPreferences() async {
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0x78000000),
      builder: (dialogContext) => _PrivacyPreferencesDialog(
        analyticsEnabled: _analyticsOn,
        onAnalyticsChanged: _updateAnalytics,
      ),
    );
  }

  Future<void> _handleVersionTap() async {
    if (_passwordPromptOpen) {
      return;
    }
    final now = DateTime.now();
    _versionTapTimes.add(now);
    _versionTapTimes.removeWhere((tapTime) => now.difference(tapTime) > const Duration(seconds: 5));
    if (_versionTapTimes.length < 7) {
      return;
    }

    _versionTapTimes.clear();
    if (developerModeNotifier.value) {
      await _saveDeveloperMode(false);
      return;
    }

    _passwordPromptOpen = true;
    final unlocked = await _showDeveloperPasswordDialog(context);
    _passwordPromptOpen = false;
    if (!mounted || !unlocked) {
      return;
    }
    await _saveDeveloperMode(true);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 580),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(28),
          boxShadow: const [
            BoxShadow(
              color: Color(0x24000000),
              blurRadius: 24,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 18, 18, 18),
              decoration: BoxDecoration(
                color: AppColors.cream,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Settings',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.cocoa,
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  PressableScale(
                    child: GestureDetector(
                      onTap: () => _handleButtonPress(() => Navigator.of(context).pop()),
                      child: Icon(
                        Icons.close,
                        color: AppColors.roseBrown,
                        size: 34,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 28, 26, 26),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _SettingsToggleCard(
                          icon: Icons.volume_up,
                          value: _soundOn,
                          onChanged: _updateSound,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _SettingsToggleCard(
                          icon: Icons.vibration,
                          value: _vibrationOn,
                          onChanged: _updateVibration,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SettingsToggleCard(
                    icon: Icons.dark_mode,
                    value: _darkMode,
                    onChanged: _updateDarkMode,
                  ),
                  const SizedBox(height: 26),
                  _SettingsLink(
                    label: 'Privacy Preferences',
                    onTap: _openPrivacyPreferences,
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _SettingsLink(
                        label: 'Terms of Service',
                        onTap: () => _openLegalDocument(
                          'Terms of Service',
                          'legal/terms_of_service.md',
                        ),
                      ),
                      _SettingsLink(
                        label: 'Privacy Policy',
                        onTap: () => _openLegalDocument(
                          'Privacy Policy',
                          'legal/privacy_policy.md',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _handleVersionTap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: FutureBuilder<PackageInfo>(
                        future: _packageInfoFuture,
                        builder: (context, snapshot) {
                          final version = snapshot.data?.version ?? '...';
                          return Text(
                            'Version $version',
                            style: TextStyle(
                              color: AppColors.border,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsToggleCard extends StatelessWidget {
  const _SettingsToggleCard({
    required this.icon,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
  });

  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: AppColors.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0f000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(
            icon,
            size: title == null ? 50 : 42,
            color: AppColors.roseBrown,
          ),
          if (title != null) ...[
            const SizedBox(height: 10),
            Text(
              title!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.cocoa,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.border,
                  fontSize: 13,
                  height: 1.2,
                ),
              ),
            ],
            const SizedBox(height: 12),
          ] else
            const SizedBox(height: 12),
          _SettingsToggle(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _PrivacyPreferencesDialog extends StatefulWidget {
  const _PrivacyPreferencesDialog({
    required this.analyticsEnabled,
    required this.onAnalyticsChanged,
  });

  final bool analyticsEnabled;
  final ValueChanged<bool> onAnalyticsChanged;

  @override
  State<_PrivacyPreferencesDialog> createState() => _PrivacyPreferencesDialogState();
}

class _PrivacyPreferencesDialogState extends State<_PrivacyPreferencesDialog> {
  late bool _analyticsEnabled;

  @override
  void initState() {
    super.initState();
    _analyticsEnabled = widget.analyticsEnabled;
  }

  void _updateAnalytics(bool value) {
    setState(() {
      _analyticsEnabled = value;
    });
    widget.onAnalyticsChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(28),
          boxShadow: const [
            BoxShadow(
              color: Color(0x24000000),
              blurRadius: 24,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Privacy Preferences',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.cocoa,
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 18),
              _SettingsToggleCard(
                icon: Icons.insights,
                value: _analyticsEnabled,
                title: 'Analytics & diagnostics',
                subtitle: 'Help improve the app with crash and usage data.',
                onChanged: _updateAnalytics,
              ),
              const SizedBox(height: 18),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Done',
                  style: TextStyle(
                    color: AppColors.roseBrown,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsToggle extends StatelessWidget {
  const _SettingsToggle({
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: double.infinity,
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: value ? const Color(0xff47bf64) : AppColors.surfaceSoft,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              top: 0,
              bottom: 0,
              left: value ? 16 : null,
              right: value ? null : 16,
              child: Center(
                child: Text(
                  value ? 'ON' : 'OFF',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              top: 6,
              bottom: 6,
              left: value ? null : 6,
              right: value ? 6 : null,
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsLink extends StatelessWidget {
  const _SettingsLink({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      child: GestureDetector(
        onTap: onTap,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.roseBrown,
            fontSize: 17,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.underline,
            decorationColor: AppColors.roseBrown.withValues(alpha: 0.65),
          ),
        ),
      ),
    );
  }
}

class _LegalDocumentPage extends StatelessWidget {
  const _LegalDocumentPage({
    required this.title,
    required this.assetPath,
  });

  final String title;
  final String assetPath;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.cocoa,
        elevation: 0,
        title: Text(title),
      ),
      body: SafeArea(
        child: FutureBuilder<String>(
          future: rootBundle.loadString(assetPath),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text(
                  'Unable to load document.',
                  style: TextStyle(
                    color: AppColors.cocoa,
                    fontSize: 18,
                  ),
                ),
              );
            }
            final content = snapshot.data ?? '';
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
              child: SelectableText(
                content,
                style: TextStyle(
                  color: AppColors.cocoa,
                  fontSize: 16,
                  height: 1.45,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class PillButton extends StatelessWidget {
  const PillButton({
    required this.color,
    required this.label,
    required this.onPressed,
    this.preserveColor = false,
    this.borderColor,
    this.borderWidth = 0,
    this.enableFeedback = true,
    super.key,
  });

  final Color color;
  final String label;
  final VoidCallback onPressed;
  final bool preserveColor;
  final Color? borderColor;
  final double borderWidth;
  final bool enableFeedback;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      child: Container(
        width: double.infinity,
        height: 74,
        decoration: borderWidth > 0
            ? BoxDecoration(
                border: Border.all(
                  color: borderColor ?? AppColors.cocoa,
                  width: borderWidth,
                ),
                borderRadius: BorderRadius.circular(999),
              )
            : null,
        child: ElevatedButton(
          onPressed: () => _handleButtonPress(
            onPressed,
            enableFeedback: enableFeedback,
          ),
          style: ElevatedButton.styleFrom(
            elevation: 12,
            shadowColor: AppColors.shadow,
            backgroundColor: preserveColor ? color : AppColors.toneAccent(color),
            foregroundColor: Colors.white,
            shape: const StadiumBorder(),
          ),
          child: FittedBox(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 31,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _HornSide { left, right }

class _DevilHorn extends StatelessWidget {
  const _DevilHorn({
    required this.shape,
    this.color = const Color(0xffdf4051),
    this.borderColor,
    this.borderWidth = 0,
  });

  final _HornSide shape;
  final Color color;
  final Color? borderColor;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(26, 20),
      painter: _DevilHornPainter(
        shape,
        color,
        borderColor: borderColor,
        borderWidth: borderWidth,
      ),
    );
  }
}

class _DevilHornPainter extends CustomPainter {
  const _DevilHornPainter(
    this.shape,
    this.color, {
    this.borderColor,
    this.borderWidth = 0,
  });

  final _HornSide shape;
  final Color color;
  final Color? borderColor;
  final double borderWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final borderPaint = Paint()
      ..color = borderColor ?? Colors.transparent
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final path = Path();
    if (shape == _HornSide.left) {
      path
        ..moveTo(size.width * 0.08, size.height * 0.95)
        ..quadraticBezierTo(size.width * 0.16, size.height * 0.46, size.width * 0.32, size.height * 0.22)
        ..quadraticBezierTo(size.width * 0.50, size.height * 0.02, size.width * 0.72, size.height * 0.18)
        ..quadraticBezierTo(size.width * 0.44, size.height * 0.48, size.width * 0.80, size.height * 0.95)
        ..quadraticBezierTo(size.width * 0.48, size.height * 0.84, size.width * 0.08, size.height * 0.95)
        ..close();
    } else {
      path
        ..moveTo(size.width * 0.92, size.height * 0.95)
        ..quadraticBezierTo(size.width * 0.84, size.height * 0.46, size.width * 0.68, size.height * 0.22)
        ..quadraticBezierTo(size.width * 0.50, size.height * 0.02, size.width * 0.28, size.height * 0.18)
        ..quadraticBezierTo(size.width * 0.56, size.height * 0.48, size.width * 0.20, size.height * 0.95)
        ..quadraticBezierTo(size.width * 0.52, size.height * 0.84, size.width * 0.92, size.height * 0.95)
        ..close();
    }

    if (borderWidth > 0) {
      canvas.drawPath(path, borderPaint);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _DevilHornPainter oldDelegate) {
    return oldDelegate.shape != shape ||
        oldDelegate.color != color ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.borderWidth != borderWidth;
  }
}

class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      child: SizedBox(
        width: 64,
        height: 64,
        child: IconButton.filled(
          onPressed: () => _handleButtonPress(onPressed),
          icon: Icon(icon, size: 33),
          style: IconButton.styleFrom(
            backgroundColor: AppColors.surfaceRaised,
            foregroundColor: AppColors.roseBrown,
            elevation: 8,
            shadowColor: AppColors.shadow,
          ),
        ),
      ),
    );
  }
}

class PowerButton extends StatelessWidget {
  const PowerButton({
    required this.icon,
    required this.badge,
    required this.onPressed,
    this.badgeColor = const Color(0xffdf4051),
    this.size = 76,
    this.iconSize = 38,
    this.glowColor,
    this.glowStrength = 0,
    this.enablePressAnimation = true,
    this.enablePressFeedback = true,
    super.key,
  });

  final IconData icon;
  final String? badge;
  final VoidCallback onPressed;
  final Color badgeColor;
  final double size;
  final double iconSize;
  final Color? glowColor;
  final double glowStrength;
  final bool enablePressAnimation;
  final bool enablePressFeedback;

  @override
  Widget build(BuildContext context) {
    final button = Stack(
      clipBehavior: Clip.none,
      children: [
        if (glowColor != null && glowStrength > 0)
          Positioned.fill(
            child: Center(
              child: Container(
                width: size + 18 + glowStrength * 12,
                height: size + 18 + glowStrength * 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: glowColor!.withValues(alpha: 0.10 + glowStrength * 0.40),
                      blurRadius: 18 + glowStrength * 18,
                      spreadRadius: 2 + glowStrength * 2,
                    ),
                  ],
                ),
              ),
            ),
          ),
        SizedBox(
          width: size,
          height: size,
          child: IconButton.filled(
            onPressed: () => _handleButtonPress(
              onPressed,
              enableFeedback: enablePressFeedback,
            ),
            icon: Icon(icon, size: iconSize),
            style: IconButton.styleFrom(
              backgroundColor: AppColors.surfaceRaised,
              foregroundColor: icon == Icons.lightbulb ? AppColors.yellow : AppColors.cocoa,
              elevation: 8,
              shadowColor: AppColors.shadow,
            ),
          ),
        ),
        if (badge != null)
          Positioned(
            top: -6,
            right: -8,
            child: Container(
              constraints: const BoxConstraints(minWidth: 30),
              height: 30,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 7),
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Text(
                badge!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
      ],
    );

    if (!enablePressAnimation) {
      return button;
    }

    return PressableScale(child: button);
  }
}

class PressableScale extends StatefulWidget {
  const PressableScale({
    required this.child,
    this.pressedScale = 0.94,
    this.duration = const Duration(milliseconds: 90),
    super.key,
  });

  final Widget child;
  final double pressedScale;
  final Duration duration;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() {
      _pressed = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1,
        duration: widget.duration,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

class StatusBubble extends StatelessWidget {
  const StatusBubble({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: ShapeDecoration(
        color: AppColors.surfaceRaised,
        shape: StadiumBorder(),
      ),
      child: Center(child: child),
    );
  }
}

class TileCatLogo extends StatelessWidget {
  const TileCatLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: SizedBox(
        width: 760,
        height: 470,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 12,
              left: 6,
              child: Transform.rotate(
                angle: -0.1,
                child: const _LogoStarCluster(),
              ),
            ),
            Positioned(
              left: 0,
              bottom: 118,
              child: Transform.rotate(
                angle: -0.04,
                child: const _LogoSparkBurst(),
              ),
            ),
            Positioned(
              right: 12,
              top: 232,
              child: Transform.rotate(
                angle: 0.16,
                child: const _LogoSparkBurst(),
              ),
            ),
            Positioned(
              top: 176,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Transform.rotate(
                    angle: -0.045,
                    child: _PosterTitleLine(
                      text: 'FIGURE',
                      offset: const Offset(10, 10),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Transform.rotate(
                    angle: 0.035,
                    child: _PosterTitleLine(
                      text: 'IT OUT',
                      offset: const Offset(8, 10),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogoStarCluster extends StatelessWidget {
  const _LogoStarCluster();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 162,
      height: 118,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 8,
            top: 18,
            child: Transform.rotate(
              angle: -0.18,
              child: const Icon(Icons.star, size: 54, color: Color(0xffffbf14)),
            ),
          ),
          Positioned(
            left: 56,
            top: 0,
            child: Transform.rotate(
              angle: 0.06,
              child: const Icon(Icons.star, size: 34, color: Color(0xffffd84f)),
            ),
          ),
          Positioned(
            right: 12,
            top: 14,
            child: Transform.rotate(
              angle: 0.26,
              child: const Icon(Icons.star, size: 26, color: Color(0xffffe08a)),
            ),
          ),
          Positioned(
            left: 20,
            bottom: 10,
            child: Transform.rotate(
              angle: -0.12,
              child: const Icon(Icons.star, size: 18, color: Color(0xffffa600)),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _StarSwirlPainter(),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogoSparkBurst extends StatelessWidget {
  const _LogoSparkBurst();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 112,
      height: 74,
      child: CustomPaint(
        painter: _SparkBurstPainter(),
      ),
    );
  }
}

class _PosterTitleLine extends StatelessWidget {
  const _PosterTitleLine({
    required this.text,
    required this.offset,
  });

  final String text;
  final Offset offset;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Positioned(
          left: offset.dx,
          top: offset.dy,
          child: Text(
            text,
            style: LogoTextStyle.shadow,
          ),
        ),
        Positioned(
          left: offset.dx * 0.45,
          top: offset.dy * 0.45,
          child: Text(
            text,
            style: LogoTextStyle.highlight,
          ),
        ),
        Text(
          text,
          style: LogoTextStyle.main,
        ),
      ],
    );
  }
}

class _StarSwirlPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xffffb000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(size.width * 0.1, size.height * 0.58)
      ..quadraticBezierTo(size.width * 0.5, size.height * 0.1, size.width * 0.92, size.height * 0.52);
    canvas.drawPath(path, paint);
    for (final star in <Offset>[
      Offset(size.width * .28, size.height * .28),
      Offset(size.width * .56, size.height * .2),
      Offset(size.width * .82, size.height * .35),
      Offset(size.width * .46, size.height * .62),
    ]) {
      final starPaint = Paint()..color = const Color(0xffffc31a);
      canvas.save();
      canvas.translate(star.dx, star.dy);
      canvas.rotate(-0.18);
      _drawFivePointStar(canvas, starPaint, 0, 0, 10);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SparkBurstPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xffffa000)
      ..strokeWidth = 5.5
      ..strokeCap = StrokeCap.round;
    for (final segment in <List<Offset>>[
      [Offset(size.width * .14, size.height * .52), Offset(size.width * .0, size.height * .3)],
      [Offset(size.width * .3, size.height * .62), Offset(size.width * .18, size.height * .9)],
      [Offset(size.width * .62, size.height * .52), Offset(size.width * .92, size.height * .36)],
      [Offset(size.width * .78, size.height * .6), Offset(size.width * .98, size.height * .86)],
    ]) {
      canvas.drawLine(segment[0], segment[1], paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

void _drawFivePointStar(Canvas canvas, Paint paint, double x, double y, double r) {
  final path = Path();
  for (var i = 0; i < 5; i++) {
    final angle = -math.pi / 2 + i * (2 * math.pi / 5);
    final px = x + math.cos(angle) * r;
    final py = y + math.sin(angle) * r;
    if (i == 0) {
      path.moveTo(px, py);
    } else {
      path.lineTo(px, py);
    }
    final innerAngle = angle + math.pi / 5;
    path.lineTo(
      x + math.cos(innerAngle) * r * 0.45,
      y + math.sin(innerAngle) * r * 0.45,
    );
  }
  path.close();
  canvas.drawPath(path, paint);
}

class CatFace extends StatelessWidget {
  const CatFace({required this.size, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: CatFacePainter(),
    );
  }
}

class CatFacePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final black = Paint()..color = const Color(0xff2c2730);
    final white = Paint()..color = Colors.white;
    final nose = Paint()..color = AppColors.roseBrown;
    final path = Path()
      ..moveTo(size.width * .16, size.height * .32)
      ..lineTo(size.width * .24, size.height * .04)
      ..lineTo(size.width * .42, size.height * .24)
      ..lineTo(size.width * .58, size.height * .24)
      ..lineTo(size.width * .76, size.height * .04)
      ..lineTo(size.width * .84, size.height * .32)
      ..cubicTo(size.width, size.height * .62, size.width * .78, size.height, size.width * .5, size.height)
      ..cubicTo(size.width * .22, size.height, 0, size.height * .62, size.width * .16, size.height * .32)
      ..close();
    canvas.drawPath(path, black);
    canvas.drawCircle(Offset(size.width * .37, size.height * .48), size.width * .12, white);
    canvas.drawCircle(Offset(size.width * .63, size.height * .48), size.width * .12, white);
    canvas.drawCircle(Offset(size.width * .39, size.height * .49), size.width * .045, black);
    canvas.drawCircle(Offset(size.width * .61, size.height * .49), size.width * .045, black);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * .5, size.height * .64),
        width: size.width * .14,
        height: size.height * .08,
      ),
      nose,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class PawTileBackground extends StatelessWidget {
  const PawTileBackground({
    this.forceDarkMode,
    super.key,
  });

  final bool? forceDarkMode;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: PawTilePainter(forceDarkMode: forceDarkMode),
    );
  }
}

class PawTilePainter extends CustomPainter {
  PawTilePainter({this.forceDarkMode});

  final bool? forceDarkMode;

  bool get _darkMode => forceDarkMode ?? AppSettings.darkMode;
  Color get _background => _darkMode ? const Color(0xff1d1720) : const Color(0xfff6efeb);
  Color get _tileLine => _darkMode ? const Color(0xff4c414f) : const Color(0xffeadfd8);

  @override
  void paint(Canvas canvas, Size size) {
    final strokePaint = Paint()
      ..color = _tileLine
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;
    const tile = 118.0;
    for (double y = -20; y < size.height; y += tile) {
      for (double x = -34; x < size.width; x += tile) {
        final rect = Rect.fromLTWH(x, y, tile - 14, tile - 14);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(18)),
          strokePaint,
        );
      }
    }

    final vignettePaint = Paint()
        ..shader = RadialGradient(
        center: Alignment.center,
        radius: 0.92,
        colors: [
          _background.withValues(alpha: 0.0),
          _background.withValues(alpha: 0.0),
          _background.withValues(alpha: _darkMode ? 0.82 : 0.56),
        ],
        stops: const [0.42, 0.68, 1.0],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, vignettePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class TimerBadge extends StatelessWidget {
  const TimerBadge({
    required this.elapsedText,
    super.key,
  });

  final String elapsedText;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border, width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0f000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Text(
        '⏱ $elapsedText',
        style: TextStyle(
          color: AppColors.cocoa,
          fontSize: 17,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

String _formatLevelTimer(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}

class Piece {
  const Piece({
    required this.id,
    required this.color,
    required this.origin,
    required this.cells,
  });

  final String id;
  final Color color;
  final Cell origin;
  final List<Cell> cells;

  PieceBounds get bounds {
    final minDx = cells.map((cell) => cell.dx).reduce(math.min);
    final maxDx = cells.map((cell) => cell.dx).reduce(math.max);
    final minDy = cells.map((cell) => cell.dy).reduce(math.min);
    final maxDy = cells.map((cell) => cell.dy).reduce(math.max);
    return PieceBounds(width: maxDx - minDx + 1, height: maxDy - minDy + 1);
  }
}

class Cell {
  const Cell(this.dx, this.dy);

  final int dx;
  final int dy;
}

class PieceBounds {
  const PieceBounds({required this.width, required this.height});

  final int width;
  final int height;
}

List<Piece> buildLevelPieces(List<List<Color>> board) {
  final boardSize = board.length;
  final pieces = <Piece>[];
  final visited = List.generate(boardSize, (_) => List<bool>.filled(boardSize, false));
  for (var row = 0; row < boardSize; row++) {
    for (var col = 0; col < boardSize; col++) {
      if (visited[row][col]) {
        continue;
      }
      final color = board[row][col];
      final key = color.toARGB32().toRadixString(16);
      final queue = <math.Point<int>>[math.Point(col, row)];
      visited[row][col] = true;
      final cells = <Cell>[];
      while (queue.isNotEmpty) {
        final point = queue.removeLast();
        cells.add(Cell(point.x - col, point.y - row));
        for (final direction in const [
          math.Point(1, 0),
          math.Point(-1, 0),
          math.Point(0, 1),
          math.Point(0, -1),
        ]) {
          final nextX = point.x + direction.x;
          final nextY = point.y + direction.y;
          if (nextX < 0 || nextY < 0 || nextX >= boardSize || nextY >= boardSize) {
            continue;
          }
          if (!visited[nextY][nextX] && board[nextY][nextX] == color) {
            visited[nextY][nextX] = true;
            queue.add(math.Point(nextX, nextY));
          }
        }
      }
      pieces.addAll(
        _buildPiecesForRegion(
          key: key,
          color: color,
          row: row,
          col: col,
          cells: cells,
        ),
      );
    }
  }

  return pieces..sort((a, b) => b.cells.length.compareTo(a.cells.length));
}

List<Piece> _buildPiecesForRegion({
  required String key,
  required Color color,
  required int row,
  required int col,
  required List<Cell> cells,
}) {
  if (cells.length <= 20) {
    return [
      Piece(
        id: '$key-$row-$col',
        color: color,
        origin: Cell(col, row),
        cells: cells,
      ),
    ];
  }

  final orderedCells = [...cells]..sort(_compareCellsByPosition);
  final splitIndex = (orderedCells.length / 2).ceil();
  final firstHalf = orderedCells.take(splitIndex).toList();
  final secondHalf = orderedCells.skip(splitIndex).toList();

  return [
    _createPieceFromCells(
      id: '$key-$row-$col-a',
      color: color,
      cells: firstHalf,
    ),
    _createPieceFromCells(
      id: '$key-$row-$col-b',
      color: color,
      cells: secondHalf,
    ),
  ];
}

Piece _createPieceFromCells({
  required String id,
  required Color color,
  required List<Cell> cells,
}) {
  final minDx = cells.map((cell) => cell.dx).reduce(math.min);
  final minDy = cells.map((cell) => cell.dy).reduce(math.min);
  return Piece(
    id: id,
    color: color,
    origin: Cell(minDx, minDy),
    cells: [
      for (final cell in cells) Cell(cell.dx - minDx, cell.dy - minDy),
    ],
  );
}

int _compareCellsByPosition(Cell a, Cell b) {
  final dy = a.dy.compareTo(b.dy);
  if (dy != 0) {
    return dy;
  }
  return a.dx.compareTo(b.dx);
}

class _LevelData {
  const _LevelData({
    required this.id,
    required this.board,
  });

  final int id;
  final List<List<Color>> board;

  factory _LevelData.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as num).toInt();
    final rawBoard = json['board'] as List<dynamic>;
    final board = rawBoard
        .map(
          (row) => (row as List<dynamic>)
              .map((value) => _levelPalette[(value as num).toInt()])
              .toList(growable: false),
        )
        .toList();
    return _LevelData(
      id: id,
      board: board,
    );
  }
}

const List<Color> _levelPalette = [
  Color(0xffa9c8ea),
  Color(0xffffdd86),
  Color(0xffd5ae00),
  Color(0xffe783d6),
  Color(0xff8fa3f2),
  Color(0xff40a9bc),
  Color(0xff2f9557),
  Color(0xff86cf78),
  Color(0xffaf744f),
  Color(0xfff88f4b),
  Color(0xffce6788),
  Color(0xff6cc8c4),
  Color(0xfff4a56a),
  Color(0xffc39cf0),
  Color(0xffb7db74),
  Color(0xffffa1a1),
  Color(0xff7dd3fc),
  Color(0xffffb703),
  Color(0xff90e0ef),
  Color(0xffdda15e),
  Color(0xffbde0fe),
  Color(0xffcdb4db),
  Color(0xff8ecae6),
  Color(0xffffafcc),
  Color(0xffb8f2e6),
  Color(0xfff9c74f),
  Color(0xff94d2bd),
  Color(0xfff28482),
  Color(0xffcaffbf),
  Color(0xfffdffb6),
  Color(0xffa0c4ff),
  Color(0xffffc6ff),
];

class AppColors {
  static bool get _dark => AppSettings.darkMode;

  static Color get background => _dark ? const Color(0xff1d1720) : const Color(0xfff6efeb);
  static Color get cream => _dark ? const Color(0xff2a232b) : const Color(0xfffff7f0);
  static Color get cellEmpty => _dark ? const Color(0xff342d36) : const Color(0xfff3ebe5);
  static Color get cellLine => _dark ? const Color(0xff4c414f) : const Color(0xffeadfd8);
  static Color get tileLine => _dark ? const Color(0xff5f4336) : const Color(0x45ead8c8);
  static Color get cocoa => _dark ? const Color(0xfff2dcc9) : const Color(0xff8a5a3b);
  static Color get roseBrown => _dark ? const Color(0xffe39ca4) : const Color(0xff9a5960);
  static Color get orange => _dark ? const Color(0xffd4831f) : const Color(0xfff7981d);
  static Color get purple => _dark ? const Color(0xff9d7bff) : const Color(0xff8d67ff);
  static Color get periwinkle => _dark ? const Color(0xff96a8ff) : const Color(0xff8fa3f2);
  static Color get green => _dark ? const Color(0xff27b95f) : const Color(0xff00c86b);
  static Color get red => _dark ? const Color(0xffe25b69) : const Color(0xffdf4051);
  static Color get yellow => _dark ? const Color(0xfff6dc72) : const Color(0xffffd953);
  static Color get surface => _dark ? const Color(0xff2a232b) : const Color(0xfff7f0ec);
  static Color get surfaceRaised => _dark ? const Color(0xff312930) : Colors.white;
  static Color get surfaceSoft => _dark ? const Color(0xff241e26) : const Color(0xfff3ebe5);
  static Color get border => _dark ? const Color(0xff5c5160) : const Color(0xffddcbbd);
  static Color get shadow => _dark ? const Color(0x66000000) : const Color(0x15000000);
  static Color get subtleShadow => _dark ? const Color(0x44000000) : const Color(0x0f000000);
  static Color get overlay => _dark ? const Color(0xff201a22) : Colors.white;
  static Color get overlaySoft => _dark ? const Color(0xff2f2731) : const Color(0xfffbf7f4);

  static Color toneAccent(Color color) {
    if (!_dark) {
      return color;
    }
    return Color.lerp(color, const Color(0xff1d1720), 0.16)!;
  }
}

class LogoTextStyle {
  static const _fontFamily = 'Lilita One';

  static TextStyle get main => const TextStyle(
        color: Color(0xff7a481f),
        fontFamily: _fontFamily,
        fontSize: 90,
        height: .9,
        fontWeight: FontWeight.w400,
        letterSpacing: -1.2,
        shadows: [
          Shadow(
            color: Color(0x32000000),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      );

  static TextStyle get shadow => const TextStyle(
        color: Color(0x83502114),
        fontFamily: _fontFamily,
        fontSize: 90,
        height: .9,
        fontWeight: FontWeight.w400,
        letterSpacing: -1.2,
      );

  static TextStyle get highlight => const TextStyle(
        color: Color(0x22ffffff),
        fontFamily: _fontFamily,
        fontSize: 90,
        height: .9,
        fontWeight: FontWeight.w400,
        letterSpacing: -1.2,
      );
}
