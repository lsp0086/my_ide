import 'package:flutter/material.dart';

/// Soft block palette inspired by Trae / Codex style IDEs.
@immutable
class IdeColors extends ThemeExtension<IdeColors> {
  const IdeColors({
    required this.canvas,
    required this.panel,
    required this.panelElevated,
    required this.panelHover,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentSoft,
    required this.accentMuted,
    required this.activityBar,
    required this.iconIdle,
    required this.iconActive,
    required this.inputFill,
    required this.divider,
    required this.shadow,
    required this.userBubbleBorder,
    required this.sendIcon,
  });

  final Color canvas;
  final Color panel;
  final Color panelElevated;
  final Color panelHover;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color accent;
  final Color accentSoft;
  final Color accentMuted;
  final Color activityBar;
  final Color iconIdle;
  final Color iconActive;
  final Color inputFill;
  final Color divider;
  final Color shadow;
  final Color userBubbleBorder;
  final Color sendIcon;

  static const dark = IdeColors(
    canvas: Color(0xFF0E0E10),
    panel: Color(0xFF161618),
    panelElevated: Color(0xFF1C1C1F),
    panelHover: Color(0xFF222226),
    border: Color(0x14FFFFFF),
    borderStrong: Color(0x22FFFFFF),
    textPrimary: Color(0xFFE8E8EA),
    textSecondary: Color(0xFF9A9AA0),
    textMuted: Color(0xFF6B6B72),
    accent: Color(0xFF6C8CFF),
    accentSoft: Color(0x286C8CFF),
    accentMuted: Color(0xFF4A5F99),
    activityBar: Color(0xFF121214),
    iconIdle: Color(0xFF7A7A82),
    iconActive: Color(0xFFE8E8EA),
    inputFill: Color(0xFF1A1A1D),
    divider: Color(0x12FFFFFF),
    shadow: Color(0x33000000),
    userBubbleBorder: Color(0x336C8CFF),
    sendIcon: Color(0xFFFFFFFF),
  );

  /// Trae-like light palette from the reference screenshot.
  static const light = IdeColors(
    canvas: Color(0xFFF2F2F4),
    panel: Color(0xFFF7F7F8),
    panelElevated: Color(0xFFFFFFFF),
    panelHover: Color(0xFFECECEF),
    border: Color(0x14000000),
    borderStrong: Color(0x1F000000),
    textPrimary: Color(0xFF1C1C1E),
    textSecondary: Color(0xFF6B6B70),
    textMuted: Color(0xFF9A9AA0),
    accent: Color(0xFF5B7CFF),
    accentSoft: Color(0x1F5B7CFF),
    accentMuted: Color(0xFF7A8FC9),
    activityBar: Color(0xFFF7F7F8),
    iconIdle: Color(0xFF8A8A90),
    iconActive: Color(0xFF1C1C1E),
    inputFill: Color(0xFFFFFFFF),
    divider: Color(0x14000000),
    shadow: Color(0x14000000),
    userBubbleBorder: Color(0x335B7CFF),
    sendIcon: Color(0xFFFFFFFF),
  );

  static IdeColors of(BuildContext context) {
    return Theme.of(context).extension<IdeColors>() ?? dark;
  }

  @override
  IdeColors copyWith({
    Color? canvas,
    Color? panel,
    Color? panelElevated,
    Color? panelHover,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? accent,
    Color? accentSoft,
    Color? accentMuted,
    Color? activityBar,
    Color? iconIdle,
    Color? iconActive,
    Color? inputFill,
    Color? divider,
    Color? shadow,
    Color? userBubbleBorder,
    Color? sendIcon,
  }) {
    return IdeColors(
      canvas: canvas ?? this.canvas,
      panel: panel ?? this.panel,
      panelElevated: panelElevated ?? this.panelElevated,
      panelHover: panelHover ?? this.panelHover,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      accentMuted: accentMuted ?? this.accentMuted,
      activityBar: activityBar ?? this.activityBar,
      iconIdle: iconIdle ?? this.iconIdle,
      iconActive: iconActive ?? this.iconActive,
      inputFill: inputFill ?? this.inputFill,
      divider: divider ?? this.divider,
      shadow: shadow ?? this.shadow,
      userBubbleBorder: userBubbleBorder ?? this.userBubbleBorder,
      sendIcon: sendIcon ?? this.sendIcon,
    );
  }

  @override
  IdeColors lerp(ThemeExtension<IdeColors>? other, double t) {
    if (other is! IdeColors) return this;
    return IdeColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      panelElevated: Color.lerp(panelElevated, other.panelElevated, t)!,
      panelHover: Color.lerp(panelHover, other.panelHover, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      accentMuted: Color.lerp(accentMuted, other.accentMuted, t)!,
      activityBar: Color.lerp(activityBar, other.activityBar, t)!,
      iconIdle: Color.lerp(iconIdle, other.iconIdle, t)!,
      iconActive: Color.lerp(iconActive, other.iconActive, t)!,
      inputFill: Color.lerp(inputFill, other.inputFill, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      userBubbleBorder: Color.lerp(userBubbleBorder, other.userBubbleBorder, t)!,
      sendIcon: Color.lerp(sendIcon, other.sendIcon, t)!,
    );
  }
}

ThemeData buildIdeTheme(Brightness brightness) {
  final colors = brightness == Brightness.dark ? IdeColors.dark : IdeColors.light;
  final base = brightness == Brightness.dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);

  return base.copyWith(
    brightness: brightness,
    scaffoldBackgroundColor: colors.canvas,
    colorScheme: base.colorScheme.copyWith(
      brightness: brightness,
      surface: colors.panel,
      primary: colors.accent,
    ),
    extensions: <ThemeExtension<dynamic>>[colors],
  );
}
