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
    required this.danger,
    required this.dangerStrong,
    required this.statusError,
    required this.statusWarn,
    required this.statusOk,
    required this.statusInfo,
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

  /// 危险语义：danger 为实心危险底（白字按钮/红色回退气泡，亮暗两主题
  /// 均保白字可读）；dangerStrong 为更深的容器底（错误横幅，配白字）。
  final Color danger;
  final Color dangerStrong;

  /// E14：语义状态色（错误/警告/成功/信息）——此前散布 15+ 处裸 0xFF
  /// 字面量，仅错误红就有 4 种取值且 info/warn 不随亮暗切换。取值对齐
  /// GitHub Primer 语义色（亮暗两套各自保证可读对比度），回归断言要求
  /// 亮暗取值不同。豁免点（不改）：_ThemePreview、stats_panel 双色阶、
  /// diff_view 亮暗对。
  final Color statusError;
  final Color statusWarn;
  final Color statusOk;
  final Color statusInfo;

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
    danger: Color(0xFFE03131),
    dangerStrong: Color(0xFF5C2B2B),
    statusError: Color(0xFFF85149),
    statusWarn: Color(0xFFE3B341),
    statusOk: Color(0xFF3FB950),
    statusInfo: Color(0xFF539BF5),
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
    danger: Color(0xFFD03A3A),
    dangerStrong: Color(0xFF8A1F1F),
    statusError: Color(0xFFCF222E),
    statusWarn: Color(0xFF9A6700),
    statusOk: Color(0xFF1A7F37),
    statusInfo: Color(0xFF0969DA),
  );

  static IdeColors of(BuildContext context) {
    final colors = Theme.of(context).extension<IdeColors>();
    // F4：缺主题扩展属接线错误（ThemeData 必须经 buildIdeTheme 构建）。
    // 此前静默回落 dark 掩盖了裸 MaterialApp 宿主的漏配；测试/调试期
    // 直接断言暴露。生产（assert 关闭）仍回落 dark 保证不崩。
    assert(() {
      if (colors != null) return true;
      throw FlutterError(
        'IdeColors.of 找不到 IdeColors 主题扩展：请用 '
        'buildIdeTheme(brightness) 构建 ThemeData（或给测试宿主的 '
        'MaterialApp 传 theme: buildIdeTheme(...)）。',
      );
    }());
    return colors ?? dark;
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
    Color? danger,
    Color? dangerStrong,
    Color? statusError,
    Color? statusWarn,
    Color? statusOk,
    Color? statusInfo,
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
      danger: danger ?? this.danger,
      dangerStrong: dangerStrong ?? this.dangerStrong,
      statusError: statusError ?? this.statusError,
      statusWarn: statusWarn ?? this.statusWarn,
      statusOk: statusOk ?? this.statusOk,
      statusInfo: statusInfo ?? this.statusInfo,
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
      danger: Color.lerp(danger, other.danger, t)!,
      dangerStrong: Color.lerp(dangerStrong, other.dangerStrong, t)!,
      statusError: Color.lerp(statusError, other.statusError, t)!,
      statusWarn: Color.lerp(statusWarn, other.statusWarn, t)!,
      statusOk: Color.lerp(statusOk, other.statusOk, t)!,
      statusInfo: Color.lerp(statusInfo, other.statusInfo, t)!,
    );
  }
}

ThemeData buildIdeTheme(Brightness brightness) {
  final colors = brightness == Brightness.dark ? IdeColors.dark : IdeColors.light;
  final base = brightness == Brightness.dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);

  // F4：组件级主题一次性补齐。此前 Card/Dialog/Chip/Divider/选区等默认
  // 落到 Material 默认色（亮色灰卡、暗色刺眼空格/对话框），与 30+ 自绘
  // 面板割裂；这里统一走 IdeColors（亮暗两套同源）。
  final cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
    side: BorderSide(color: colors.border),
  );

  return base.copyWith(
    brightness: brightness,
    scaffoldBackgroundColor: colors.canvas,
    colorScheme: base.colorScheme.copyWith(
      brightness: brightness,
      surface: colors.panel,
      primary: colors.accent,
    ),
    extensions: <ThemeExtension<dynamic>>[colors],
    cardTheme: CardThemeData(
      color: colors.panelElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: cardShape,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.panelElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: colors.shadow,
      titleTextStyle: TextStyle(
        color: colors.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      contentTextStyle: TextStyle(
        color: colors.textSecondary,
        fontSize: 12.5,
        height: 1.45,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: colors.panelHover,
      selectedColor: colors.accentSoft,
      checkmarkColor: colors.accent,
      side: BorderSide(color: colors.border),
      labelStyle: TextStyle(color: colors.textPrimary, fontSize: 12),
      secondaryLabelStyle: TextStyle(color: colors.accent, fontSize: 12),
      iconTheme: IconThemeData(color: colors.textSecondary, size: 16),
    ),
    dividerTheme: DividerThemeData(color: colors.divider),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: colors.accent,
      inactiveTrackColor: colors.panelHover,
      thumbColor: colors.accent,
      overlayColor: colors.accentSoft,
      valueIndicatorColor: colors.panelElevated,
      valueIndicatorTextStyle: TextStyle(
        color: colors.textPrimary,
        fontSize: 11,
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: colors.accent,
      selectionColor: colors.accentSoft,
      selectionHandleColor: colors.accent,
    ),
  );
}
