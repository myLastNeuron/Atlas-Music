import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Dark translucent-glass mono system. Single source of truth so Home /
/// Search / Library / Profile share one premium look: deep neutral backdrop,
/// frosted-glass floating surfaces, white ink, one light primary action.
///
class AppColors {
  // Core mono tokens (dark glass).
  static const paper = Color(0xFF0E0E12);
  static const mist = Color(0xFF17171C);
  static const card = Color(0xFF1A1A20);
  static const line = Color(0x24FFFFFF);
  static const ink = Color(0xFFFFFFFF);
  static const inkSoft = Color(0xFFC6C6CE);
  static const mute = Color(0xFF9A9AA3);
  static const charcoal = Color(0xFF18181B);

  /// Translucent glass base for menus, dialogs, sheets, cards and panels.
  /// One shared value so every surface reads as the same material.
  static const glass = Color(0x99191921);

  /// Frosted-glass rim/highlight tints, kept low so no hard white edge shows.
  static Color get glassBorder => Colors.white.withValues(alpha: 0.10);
  static Color get glassHighlight => Colors.white.withValues(alpha: 0.04);
}

/// `m:ss` clock shared by list rows (no leading zero on minutes).
String formatClock(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Consistent motion: fast, natural, cheap on low-end hardware.
/// One shared curve with short semantic durations for pages, tabs, modals,
/// entrances, and touch feedback.
class AppMotion {
  static const curve = Curves.easeOutCubic;
  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const spring = Curves.easeOutBack;
  static const page = Duration(milliseconds: 240);
  // Full player: the cover Hero and the page ease own the motion together.
  // Longer and eased so the player materialises smoothly rather than
  // snapping; these also set how long the cover flight takes.
  static const playerOpen = Duration(milliseconds: 480);
  static const playerClose = Duration(milliseconds: 420);
  static const modal = Duration(milliseconds: 220);
  static const micro = Duration(milliseconds: 180);
  static const entrance = Duration(milliseconds: 320);

  /// Slow ambient loop for the background washes.
  static const ambient = Duration(milliseconds: 18000);

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
  static ThemeData light() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.paper,
      colorScheme: const ColorScheme.dark(
        primary: Colors.white,
        onPrimary: AppColors.charcoal,
        secondary: AppColors.inkSoft,
        onSecondary: AppColors.charcoal,
        surface: AppColors.card,
        onSurface: AppColors.ink,
        error: Color(0xFFFF8A80),
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
      appBarTheme: const AppBarTheme(
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
      dialogTheme: const DialogThemeData(
        backgroundColor: AppColors.glass,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
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
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.glass,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.inkSoft,
        textColor: AppColors.ink,
      ),
      iconTheme: const IconThemeData(color: AppColors.inkSoft),
      dividerTheme: const DividerThemeData(
        color: AppColors.line,
        thickness: 1,
        space: 1,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.glass,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.line),
        ),
        textStyle: const TextStyle(color: AppColors.ink, fontSize: 14),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: Colors.white,
        inactiveTrackColor: Colors.white.withValues(alpha: 0.16),
        thumbColor: Colors.white,
        overlayColor: Colors.white.withValues(alpha: 0.12),
        trackHeight: 4,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: Colors.white,
        linearTrackColor: Colors.white.withValues(alpha: 0.14),
        circularTrackColor: Colors.white.withValues(alpha: 0.14),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? AppColors.charcoal
                : AppColors.mute),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? Colors.white
                : Colors.white.withValues(alpha: 0.16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: AppColors.charcoal,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: AppColors.charcoal,
          shadowColor: Colors.black.withValues(alpha: 0.35),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          side: const BorderSide(color: AppColors.line),
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
        hintStyle: const TextStyle(color: AppColors.mute, fontSize: 14),
        prefixIconColor: AppColors.mute,
        suffixIconColor: AppColors.inkSoft,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.inkSoft, width: 1.2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      cardTheme: const CardThemeData(
        color: AppColors.glass,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black38,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
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
  final curved = CurvedAnimation(parent: animation, curve: AppMotion.curve);
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

/// Full-player route motion. The mini-player cover flies into the full
/// player via a [Hero] (see MiniPlayer/PlayerScreen), while the page itself
/// eases in behind it with a gentle rise. A slower, eased movement is what
/// reads as "smooth"; the previous instant/short version felt like a jump.
/// Respects reduce-motion.
Widget buildPlayerTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  if (AppMotion.reduced(context)) return child;
  final curved =
      CurvedAnimation(parent: animation, curve: AppMotion.emphasized);
  return FadeTransition(
    opacity: curved,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.06),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    ),
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
