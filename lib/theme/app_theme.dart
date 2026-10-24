import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// Mono glass palette: two modes, one set of names. Dark is the app's
/// original look; light is a paper-and-ink reading of the same surfaces.
///
/// The values are getters, not consts: a const colour freezes the mode it was
/// compiled with. [ThemeSettings] swaps the mode and the app rebuilds from the
/// root, so every surface re-reads them.
class AppColors {
  static bool _light = false;

  static bool get isLight => _light;

  /// Switches the palette. The caller owns the rebuild.
  static void setLight(bool value) => _light = value;

  /// Page backdrop.
  static Color get paper =>
      _light ? const Color(0xFFF6F6F8) : const Color(0xFF0E0E12);

  /// Recessed fill: inputs, placeholder tiles.
  static Color get mist =>
      _light ? const Color(0xFFECECF0) : const Color(0xFF17171C);

  static Color get card =>
      _light ? const Color(0xFFFFFFFF) : const Color(0xFF1A1A20);

  /// Hairline.
  static Color get line =>
      _light ? const Color(0x1F000000) : const Color(0x24FFFFFF);

  /// Primary text and icon.
  static Color get ink =>
      _light ? const Color(0xFF13131A) : const Color(0xFFFFFFFF);

  static Color get inkSoft =>
      _light ? const Color(0xFF4C4C57) : const Color(0xFFC6C6CE);

  static Color get mute =>
      _light ? const Color(0xFF7E7E89) : const Color(0xFF9A9AA3);

  /// The one filled primary action surface (buttons, selected chips).
  static Color get action =>
      _light ? const Color(0xFF16161D) : const Color(0xFFFFFFFF);

  /// Content drawn on [action].
  static Color get charcoal =>
      _light ? const Color(0xFFFFFFFF) : const Color(0xFF18181B);

  /// Glass base for menus, dialogs, sheets, cards and panels. The transparency
  /// level (see [GlassSettings]) decides how much of the backdrop shows
  /// through; this is the solid colour behind it.
  static Color get glass =>
      _light ? const Color(0xFFFFFFFF) : const Color(0xFF191921);

  /// Frosted-glass rim, kept low so no hard edge shows.
  static Color get glassBorder =>
      (_light ? Colors.black : Colors.white).withValues(alpha: 0.10);

  /// Errors and destructive text.
  static Color get danger =>
      _light ? const Color(0xFFB3261E) : const Color(0xFFFF8A80);

  /// Soft shadow under floating panels: deep on dark, faint on light.
  static Color get shadow => Colors.black.withValues(alpha: _light ? 0.12 : 0.35);
}

/// Status/nav bar icons follow the palette: dark icons on the light one.
void applySystemUiOverlay() => SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            AppColors.isLight ? Brightness.dark : Brightness.light,
        statusBarBrightness:
            AppColors.isLight ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: AppColors.paper,
        systemNavigationBarIconBrightness:
            AppColors.isLight ? Brightness.dark : Brightness.light,
      ),
    );

/// `m:ss` clock shared by list rows (no leading zero on minutes).
String formatClock(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Press-highlight shape of a list row. Without a shape an `InkWell` paints
/// a sharp rectangle when held, so every row gets this rounded one.
const ShapeBorder kRowPressShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(20)),
);

/// Consistent motion: fast, natural, cheap on low-end hardware.
/// One shared curve with short semantic durations for pages, tabs, modals,
/// entrances, and touch feedback.
class AppMotion {
  static const curve = Curves.easeOutCubic;
  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const spring = Curves.easeOutBack;

  /// Full-player morph curve. The surface and the cover travel together, so a
  /// hard ease-out start snaps; this one eases in, glides, then settles.
  /// Shared by the reveal window, the Hero rect and the cover radius.
  static const player = Curves.fastOutSlowIn;
  static const page = Duration(milliseconds: 240);
  // Full player: long enough for the surface to grow out of the mini bar and
  // the cover to travel without feeling rushed (a short morph snapped and
  // read as a cut). These also set the Hero flight.
  static const playerOpen = Duration(milliseconds: 780);
  // Same length both ways: the Hero flight is driven by the route animation,
  // so a shorter close flew the cover back visibly faster than it opened.
  static const playerClose = playerOpen;

  static const modal = Duration(milliseconds: 220);
  static const micro = Duration(milliseconds: 180);
  static const entrance = Duration(milliseconds: 320);

  /// Per-item delay for staggered entrances.
  static const stagger = Duration(milliseconds: 40);

  /// OS "reduce motion" accessibility flag. When true, large movement and
  /// looping animations snap to their end state instead of animating.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// Collapses to zero when the user disabled animations, so callers can
  /// keep one duration constant and still respect the setting.
  static Duration dur(BuildContext context, Duration base) =>
      reduced(context) ? Duration.zero : base;
}

class AppTheme {
  /// The theme for the current palette. Rebuilt when the light/dark mode
  /// changes (the one app-wide rebuild); the glass level is read by the
  /// surfaces themselves, so changing it never restyles the whole app.
  static ThemeData build() {
    final light = AppColors.isLight;
    final base = ThemeData(
      brightness: light ? Brightness.light : Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.paper,
      colorScheme: light
          ? ColorScheme.light(
              primary: AppColors.action,
              onPrimary: AppColors.charcoal,
              secondary: AppColors.inkSoft,
              onSecondary: AppColors.charcoal,
              surface: AppColors.card,
              onSurface: AppColors.ink,
              error: AppColors.danger,
            )
          : ColorScheme.dark(
              primary: AppColors.action,
              onPrimary: AppColors.charcoal,
              secondary: AppColors.inkSoft,
              onSecondary: AppColors.charcoal,
              surface: AppColors.card,
              onSurface: AppColors.ink,
              error: AppColors.danger,
            ),
    );
    // Plus Jakarta Sans: geometric, modern, multi-weight. Loaded once
    // here so screens never trigger per-build font fetches.
    final text = GoogleFonts.plusJakartaSansTextTheme(base.textTheme);
    return base.copyWith(
      textTheme: text
          .copyWith(
            displayLarge: text.displayLarge
                ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
            displayMedium: text.displayMedium
                ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
            titleLarge: text.titleLarge
                ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0),
            titleMedium: text.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.1),
            titleSmall: text.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.2),
            bodyLarge: text.bodyLarge
                ?.copyWith(fontWeight: FontWeight.w500, letterSpacing: 0),
            bodyMedium: text.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w400, letterSpacing: 0),
            bodySmall: text.bodySmall?.copyWith(
                fontWeight: FontWeight.w400,
                letterSpacing: 0,
                color: AppColors.inkSoft),
            labelSmall: text.labelSmall?.copyWith(
                fontWeight: FontWeight.w400,
                letterSpacing: 0.4,
                color: AppColors.inkSoft),
          )
          .apply(
            bodyColor: AppColors.ink,
            displayColor: AppColors.ink,
            decoration: TextDecoration.none,
          ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.ink,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: AppColors.ink),
      ),
      // Every screen transition: subtle fade + short slide + tiny scale.
      // Framework-driven (no controllers), GPU-cheap, same on all platforms.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: AppPageTransitionsBuilder(),
          TargetPlatform.iOS: AppPageTransitionsBuilder(),
          TargetPlatform.macOS: AppPageTransitionsBuilder(),
          TargetPlatform.linux: AppPageTransitionsBuilder(),
          TargetPlatform.windows: AppPageTransitionsBuilder(),
        },
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.glass,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(20)),
          side: BorderSide(color: AppColors.line),
        ),
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: AppColors.ink,
        ),
        contentTextStyle: TextStyle(
          fontSize: 14,
          color: AppColors.inkSoft,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: AppColors.glass,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          side: BorderSide(color: AppColors.line),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xFF26262E),
        contentTextStyle: TextStyle(color: Colors.white, fontSize: 13),
        actionTextColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: AppColors.inkSoft,
        textColor: AppColors.ink,
        // The tile's shape is the press-highlight and ripple clip. Without it
        // a held row paints a sharp rectangle; with it the highlight follows
        // the row's rounded shape.
        shape: kRowPressShape,
      ),
      iconTheme: IconThemeData(color: AppColors.inkSoft),
      dividerTheme: DividerThemeData(
        color: AppColors.line,
        thickness: 1,
        space: 1,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.glass,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(14)),
          side: BorderSide(color: AppColors.line),
        ),
        textStyle: TextStyle(color: AppColors.ink, fontSize: 14),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: AppColors.action,
        inactiveTrackColor: AppColors.ink.withValues(alpha: 0.16),
        thumbColor: AppColors.action,
        overlayColor: AppColors.ink.withValues(alpha: 0.12),
        trackHeight: 4,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: AppColors.ink,
        linearTrackColor: AppColors.ink.withValues(alpha: 0.14),
        circularTrackColor: AppColors.ink.withValues(alpha: 0.14),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.charcoal
                : AppColors.mute),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.action
                : AppColors.ink.withValues(alpha: 0.16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.action,
          foregroundColor: AppColors.charcoal,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.action,
          foregroundColor: AppColors.charcoal,
          shadowColor: AppColors.shadow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          side: BorderSide(color: AppColors.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AppColors.ink),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.mist,
        hintStyle: TextStyle(color: AppColors.mute, fontSize: 14),
        prefixIconColor: AppColors.mute,
        suffixIconColor: AppColors.inkSoft,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: AppColors.inkSoft, width: 1.2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      cardTheme: CardThemeData(
        color: AppColors.glass,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black38,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: AppColors.line),
        ),
      ),
    );
  }
}

/// One route-motion implementation shared by the explicit [AppPageRoute]
/// (app_transitions.dart) and the global [AppPageTransitionsBuilder], so the
/// two can never drift. Incoming page: fade + short upward slide + 0.98
/// scale. The outgoing page is left in place (no parallax): shifting a page
/// that sits behind the fixed acrylic nav read as a mirrored smear.
/// Framework-driven (no controllers), so it can not stack, leak, or block
/// input; back gesture stays interactive. Respects reduce-motion.
Widget buildAppTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  if (AppMotion.reduced(context)) return child;
  // drive() instead of a CurvedAnimation: the latter registers a status
  // listener on the route controller and is never disposed when built in
  // build(), leaking one listener per frame of every transition.
  final curved = animation.drive(CurveTween(curve: AppMotion.curve));
  return FadeTransition(
    opacity: curved,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.04),
        end: Offset.zero,
      ).animate(curved),
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
        child: child,
      ),
    ),
  );
}

/// Hero tag shared by the mini bar that opened the player and the full player's
/// cover. Hero tags are matched per route, so the tag has to identify the bar
/// that was tapped: with one global tag every MiniPlayer in the stack matched
/// every full player, and pushing a screen that mounts a MiniPlayer (an artist
/// page) flew the big cover down into the 42 px thumb.
String playerHeroTag = 'player_cover';

/// Full-player route motion: the page cross-fades while the artwork flies
/// between the mini thumb and the big cover via a [Hero] (see MiniPlayer /
/// PlayerScreen). Nothing else moves — growing and collapsing a surface
/// around the content dragged the header and the transport row up and down
/// with the cover.
///
/// [AppMotion.player] is shared with the Hero's rect tween ([PlayerRectTween])
/// so the cover and the page fade stay in step. Respects reduce-motion.
Widget buildPlayerTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  if (AppMotion.reduced(context)) return child;
  return FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: AppMotion.player),
    child: child,
  );
}

class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (route.settings.name == Navigator.defaultRouteName) return child;
    return buildAppTransition(context, animation, secondaryAnimation, child);
  }
}
