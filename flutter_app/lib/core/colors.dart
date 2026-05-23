import 'package:flutter/material.dart';

/// Semantic color tokens for the app, backed by MD3 [ColorScheme].
///
/// Use via `context.al` or `Theme.of(context).al`:
/// ```dart
/// final errorColor = context.al.error;
/// final successColor = context.al.success;
/// ```
///
/// MD3 does not define `success` / `warning` / `info` roles, so we use
/// opinionated defaults that work well with the generated seed colour scheme.
///
/// Reader-internal colours (background / text / night variants) are managed
/// by [ReaderSettings] and are NOT part of this palette.

extension AppColors on BuildContext {
  AppPalette get al => AppPalette.of(this);
}

extension AppColorsOnTheme on ThemeData {
  AppPalette get al => AppPalette._resolve(this);
}

class AppPalette {
  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;

  final Color secondary;
  final Color onSecondary;
  final Color secondaryContainer;
  final Color onSecondaryContainer;

  final Color tertiary;
  final Color onTertiary;
  final Color tertiaryContainer;
  final Color onTertiaryContainer;

  final Color error;
  final Color onError;
  final Color errorContainer;
  final Color onErrorContainer;

  final Color surface;
  final Color onSurface;
  final Color surfaceVariant;
  final Color onSurfaceVariant;

  final Color outline;
  final Color outlineVariant;

  final Color shadow;
  final Color scrim;

  final Color inverseSurface;
  final Color onInverseSurface;

  final Color inversePrimary;

  // ── Semantic extensions (not in MD3 spec) ────────────────────
  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;

  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;

  final Color info;
  final Color onInfo;
  final Color infoContainer;
  final Color onInfoContainer;

  final bool isDark;

  const AppPalette._({
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.secondary,
    required this.onSecondary,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.tertiary,
    required this.onTertiary,
    required this.tertiaryContainer,
    required this.onTertiaryContainer,
    required this.error,
    required this.onError,
    required this.errorContainer,
    required this.onErrorContainer,
    required this.surface,
    required this.onSurface,
    required this.surfaceVariant,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
    required this.shadow,
    required this.scrim,
    required this.inverseSurface,
    required this.onInverseSurface,
    required this.inversePrimary,
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.info,
    required this.onInfo,
    required this.infoContainer,
    required this.onInfoContainer,
    required this.isDark,
  });

  factory AppPalette.of(BuildContext context) =>
      _resolve(Theme.of(context));

  static AppPalette _resolve(ThemeData theme) {
    final cs = theme.colorScheme;
    final isDark = cs.brightness == Brightness.dark;

    // Success = green tones; Warning = orange; Info = blue.
    // Values chosen to harmonise with the seed-colour-derived scheme.
    final success = isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32);
    final onSuccess = isDark ? const Color(0xFF1B5E20) : const Color(0xFFFFFFFF);
    final successContainer =
        isDark ? const Color(0xFF2E4A2E) : const Color(0xFFC8E6C9);
    final onSuccessContainer =
        isDark ? const Color(0xFFC8E6C9) : const Color(0xFF1B5E20);

    final warning = isDark ? const Color(0xFFFFB74D) : const Color(0xFFE65100);
    final onWarning = isDark ? const Color(0xFF3E2723) : const Color(0xFFFFFFFF);
    final warningContainer =
        isDark ? const Color(0xFF4E342E) : const Color(0xFFFFE0B2);
    final onWarningContainer =
        isDark ? const Color(0xFFFFE0B2) : const Color(0xFF3E2723);

    final info = isDark ? const Color(0xFF64B5F6) : const Color(0xFF1565C0);
    final onInfo = isDark ? const Color(0xFF0D47A1) : const Color(0xFFFFFFFF);
    final infoContainer =
        isDark ? const Color(0xFF1A3A5C) : const Color(0xFFBBDEFB);
    final onInfoContainer =
        isDark ? const Color(0xFFBBDEFB) : const Color(0xFF0D47A1);

    return AppPalette._(
      primary: cs.primary,
      onPrimary: cs.onPrimary,
      primaryContainer: cs.primaryContainer,
      onPrimaryContainer: cs.onPrimaryContainer,
      secondary: cs.secondary,
      onSecondary: cs.onSecondary,
      secondaryContainer: cs.secondaryContainer,
      onSecondaryContainer: cs.onSecondaryContainer,
      tertiary: cs.tertiary,
      onTertiary: cs.onTertiary,
      tertiaryContainer: cs.tertiaryContainer,
      onTertiaryContainer: cs.onTertiaryContainer,
      error: cs.error,
      onError: cs.onError,
      errorContainer: cs.errorContainer,
      onErrorContainer: cs.onErrorContainer,
      surface: cs.surface,
      onSurface: cs.onSurface,
      surfaceVariant: cs.surfaceContainerHighest,
      onSurfaceVariant: cs.onSurfaceVariant,
      outline: cs.outline,
      outlineVariant: cs.outlineVariant,
      shadow: cs.shadow,
      scrim: cs.scrim,
      inverseSurface: cs.inverseSurface,
      onInverseSurface: cs.onInverseSurface,
      inversePrimary: cs.inversePrimary,
      success: success,
      onSuccess: onSuccess,
      successContainer: successContainer,
      onSuccessContainer: onSuccessContainer,
      warning: warning,
      onWarning: onWarning,
      warningContainer: warningContainer,
      onWarningContainer: onWarningContainer,
      info: info,
      onInfo: onInfo,
      infoContainer: infoContainer,
      onInfoContainer: onInfoContainer,
      isDark: isDark,
    );
  }

  // ── Semantic shortcuts ─────────────────────────────────────────

  /// Subtitle / secondary / hint text colour.
  Color get textSecondary => onSurfaceVariant;

  /// Destructive action colour (delete / remove).
  Color get destructive => error;

  /// Destructive action background in a filled context.
  Color get destructiveContainer => errorContainer;

  /// Disabled state colour.
  Color get disabled => onSurface.withAlpha(0x3D);

  /// Highlighted / selected background.
  Color get highlight => primary.withAlpha(0x14);

  /// Overlay background for loading states.
  Color get overlay => scrim.withAlpha(0x80);
}
