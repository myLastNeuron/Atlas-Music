import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../services/user_prefs.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/liquid_background.dart';
import 'onboarding_screen.dart';
import 'onboarding_preferences.dart';
import '../screens/home_screen.dart';
import '../screens/search_screen.dart';
import '../screens/library_screen.dart';
import '../screens/profile_screen.dart';
import '../widgets/mini_player.dart';
import '../widgets/floating_glass_nav.dart';
import '../services/audio_service.dart';

/// Owns first-run + future-launch name flight:
/// center name → top-right header, home fades in underneath.
/// BACKGROUND IS ALWAYS VISIBLE — no black-screen gap during flight.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final UserPrefs _prefs = UserPrefs();
  String? _name;
  bool _loading = true;
  bool _showHome = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final saved = await _prefs.getName();
    final done = await _prefs.isOnboardingDone();
    if (!mounted) return;
    final hasName = saved != null && saved.isNotEmpty;
    setState(() {
      _loading = false;
      _name = saved;
      // Home only once onboarding is explicitly stamped complete; otherwise
      // the flow stays on onboarding/preferences. Language "all" is a valid
      // choice, so completion is never inferred from it.
      _showHome = hasName && done;
    });
  }

  Future<void> _onNameComplete(String name) async {
    await _prefs.setName(name);
    if (!mounted) return;
    // Naming advances to the preferences step; showing Home here (before the
    // avatar dialog and preferences) was the premature-Home bug.
    setState(() => _name = name);
    await _pickAvatar();
  }

  Future<void> _pickAvatar() async {
    final choosePhoto = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.glass,
        title: const Text('Add a profile photo'),
        content: const Text(
          'Choose a photo from your device, or skip and use your initials.',
          style: TextStyle(color: AppColors.inkSoft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Skip for now'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.add_a_photo),
            label: const Text('Choose photo'),
          ),
        ],
      ),
    );
    if (choosePhoto != true) return;

    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1024,
      maxHeight: 1024,
    );
    if (picked == null) return;
    final old = await _prefs.getAvatar();
    final dir = await getApplicationDocumentsDirectory();
    final fileName = 'avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final newPath = '${dir.path}/$fileName';
    await picked.saveTo(newPath);
    await _prefs.setAvatar(newPath);
    await removeOldAvatarFile(old, newPath);
    if (mounted) setState(() {});
  }

  Future<void> _onPreferencesComplete() async {
    setState(() => _showHome = true);
  }

  @override
  Widget build(BuildContext context) {
    return LiquidBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    // Smooth hand-off: onboarding → preferences → home (or the boot spinner).
    return AnimatedSwitcher(
      duration: AppMotion.dur(context, AppMotion.page),
      switchInCurve: AppMotion.curve,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: fadeRiseTransition,
      child: _stage(),
    );
  }

  Widget _stage() {
    if (_loading) {
      return const Center(
        key: ValueKey('stage_loading'),
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_name == null) {
      return SafeArea(
        key: const ValueKey('stage_onboarding'),
        child: OnboardingContent(onContinue: _onNameComplete),
      );
    }
    if (!_showHome) {
      return OnboardingPreferences(
        key: const ValueKey('stage_prefs'),
        onComplete: _onPreferencesComplete,
      );
    }
    return MainNavigation(
      key: const ValueKey('stage_home'),
      userName: _name!,
    );
  }
}

/// Root tabs with floating glass nav. [userName] renders top-right only —
/// never app title in header per design spec.
class MainNavigation extends StatefulWidget {
  final String userName;
  const MainNavigation({super.key, required this.userName});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int _index = 0;
  List<Widget>? _screens;
  String? _screensName;

  // One controller drives a cross-fade of the active screen on tab change.
  // It lives in the State (not keyed to the index), so IndexedStack keeps
  // every tab's state alive across switches. No slide: the acrylic nav is
  // fixed, so moving the page against it smeared like a mirror.
  late final AnimationController _tabTransition = AnimationController(
    vsync: this,
    duration: AppMotion.modal,
    value: 1.0,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabTransition.dispose();
    super.dispose();
  }

  void _selectTab(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    if (AppMotion.reduced(context)) {
      _tabTransition.value = 1.0;
    } else {
      _tabTransition.forward(from: 0);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Background pause can drift Dart UI state from native player state.
    // Re-sync on foreground so Play/Pause never appears dead.
    if (!mounted) return;
    try {
      final audio = context.read<AudioPlayerService>();
      if (state == AppLifecycleState.resumed) {
        audio.setAppBackgrounded(false);
        audio.syncPlaybackState();
      } else if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        audio.setAppBackgrounded(true);
      }
    } catch (_) {}
  }

  List<Widget> _buildScreens() {
    // Rebuild when the name changes: a rename on Profile must reach the Home
    // header too, so the two screens never show different identities.
    if (_screens != null && _screensName == widget.userName) return _screens!;
    _screensName = widget.userName;
    return _screens = [
      FadeSlideIn(child: HomeScreen(userName: widget.userName)),
      const FadeSlideIn(child: SearchScreen()),
      const FadeSlideIn(child: LibraryScreen()),
      FadeSlideIn(child: ProfileScreen(userName: widget.userName)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Selector instead of watch: rebuild shell only when song identity
    // changes (start/stop), NOT every 1/sec position tick. Include isLoading
    // so the bar stays visible across auto-advance gaps and cold-start loads
    // instead of vanishing between tracks.
    final hasSong = context.select<AudioPlayerService, bool>(
        (s) => s.currentSong != null || s.isLoading);
    return Stack(
      children: [
        Scaffold(
          backgroundColor: Colors.transparent,
          extendBody: true,
          body: FadeTransition(
            opacity: _tabTransition,
            child: IndexedStack(index: _index, children: _buildScreens()),
          ),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRect(
                child: AnimatedSwitcher(
                  duration: AppMotion.dur(context, AppMotion.modal),
                  switchInCurve: AppMotion.curve,
                  switchOutCurve: AppMotion.curve,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.25),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: hasSong
                      ? const Padding(
                          key: ValueKey('mini_on'),
                          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: MiniPlayer(),
                        )
                      : const SizedBox.shrink(key: ValueKey('mini_off')),
                ),
              ),
              FloatingGlassNav(
                currentIndex: _index,
                onTap: _selectTab,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
