import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/utils/constants.dart';

/// The system pink of the Monogatari apps; the default accent.
const Color monogatariPink = Color(0xFFFF2D55);

/// Neutral colours of the Monogatari look that Material's scheme has no role
/// for: the grey of grouped pages, filled fields and hairlines.
@immutable
class MonoPalette extends ThemeExtension<MonoPalette> {
  const MonoPalette({
    required this.groupedBackground,
    required this.groupedCell,
    required this.fill,
    required this.chip,
    required this.sheetGroup,
    required this.menu,
    required this.menuSectionBreak,
    required this.hairline,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.success,
  });

  /// Background behind inset groups (settings pages).
  final Color groupedBackground;

  /// Background of an inset group on [groupedBackground].
  final Color groupedCell;

  /// Search fields.
  final Color fill;

  /// Unselected chips; visible on pages, cells and sheets alike.
  final Color chip;

  /// Groups and chips inside sheets and dialogs.
  final Color sheetGroup;

  /// Pull-down menus.
  final Color menu;

  /// The thick band between menu sections.
  final Color menuSectionBreak;

  final Color hairline;
  final Color secondaryLabel;
  final Color tertiaryLabel;
  final Color success;

  static const light = MonoPalette(
    groupedBackground: Color(0xFFF2F2F7),
    groupedCell: Colors.white,
    fill: Color(0xFFEEEEF0),
    chip: Color(0xFFE9E9EB),
    sheetGroup: Color(0xFFF2F2F7),
    menu: Colors.white,
    menuSectionBreak: Color(0xFFEEEEF0),
    hairline: Color(0xFFD1D1D6),
    secondaryLabel: Color(0xFF8E8E93),
    tertiaryLabel: Color(0xFFC7C7CC),
    success: Color(0xFF34C759),
  );

  static const dark = MonoPalette(
    groupedBackground: Colors.black,
    groupedCell: Color(0xFF1C1C1E),
    fill: Color(0xFF2C2C2E),
    chip: Color(0xFF3A3A3C),
    sheetGroup: Color(0xFF2C2C2E),
    menu: Color(0xFF2C2C2E),
    menuSectionBreak: Color(0xFF1C1C1E),
    hairline: Color(0xFF48484A),
    secondaryLabel: Color(0xFFAEAEB2),
    tertiaryLabel: Color(0xFF636366),
    success: Color(0xFF30D158),
  );

  static MonoPalette of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<MonoPalette>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  MonoPalette copyWith({
    Color? groupedBackground,
    Color? groupedCell,
    Color? fill,
    Color? chip,
    Color? sheetGroup,
    Color? menu,
    Color? menuSectionBreak,
    Color? hairline,
    Color? secondaryLabel,
    Color? tertiaryLabel,
    Color? success,
  }) {
    return MonoPalette(
      groupedBackground: groupedBackground ?? this.groupedBackground,
      groupedCell: groupedCell ?? this.groupedCell,
      fill: fill ?? this.fill,
      chip: chip ?? this.chip,
      sheetGroup: sheetGroup ?? this.sheetGroup,
      menu: menu ?? this.menu,
      menuSectionBreak: menuSectionBreak ?? this.menuSectionBreak,
      hairline: hairline ?? this.hairline,
      secondaryLabel: secondaryLabel ?? this.secondaryLabel,
      tertiaryLabel: tertiaryLabel ?? this.tertiaryLabel,
      success: success ?? this.success,
    );
  }

  @override
  MonoPalette lerp(MonoPalette? other, double t) {
    if (other == null) return this;
    return MonoPalette(
      groupedBackground:
          Color.lerp(groupedBackground, other.groupedBackground, t)!,
      groupedCell: Color.lerp(groupedCell, other.groupedCell, t)!,
      fill: Color.lerp(fill, other.fill, t)!,
      chip: Color.lerp(chip, other.chip, t)!,
      sheetGroup: Color.lerp(sheetGroup, other.sheetGroup, t)!,
      menu: Color.lerp(menu, other.menu, t)!,
      menuSectionBreak:
          Color.lerp(menuSectionBreak, other.menuSectionBreak, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      secondaryLabel: Color.lerp(secondaryLabel, other.secondaryLabel, t)!,
      tertiaryLabel: Color.lerp(tertiaryLabel, other.tertiaryLabel, t)!,
      success: Color.lerp(success, other.success, t)!,
    );
  }
}

/// iOS system backgrounds with [accent] as the only tint, including the
/// derived surfaces Material widgets read.
ColorScheme monoColorScheme(Brightness brightness, Color accent) {
  final dark = brightness == Brightness.dark;
  final isPink = accent.toARGB32() == monogatariPink.toARGB32();
  final onAccent =
      accent.computeLuminance() > 0.55 ? Colors.black : Colors.white;
  final hsl = HSLColor.fromColor(accent);
  final Color container;
  final Color onContainer;
  if (isPink) {
    container = dark ? const Color(0xFF4C1524) : const Color(0xFFFFE5EC);
    onContainer = dark ? const Color(0xFFFFD9E2) : const Color(0xFF8F1734);
  } else if (dark) {
    container = Color.alphaBlend(accent.withValues(alpha: 0.3), Colors.black);
    onContainer = hsl.withLightness(0.88).toColor();
  } else {
    container = Color.alphaBlend(accent.withValues(alpha: 0.12), Colors.white);
    onContainer = hsl.withLightness(hsl.lightness.clamp(0.0, 0.3)).toColor();
  }

  if (dark) {
    return ColorScheme(
      brightness: Brightness.dark,
      primary: accent,
      onPrimary: onAccent,
      primaryContainer: container,
      onPrimaryContainer: onContainer,
      inversePrimary: accent,
      secondary: accent,
      onSecondary: onAccent,
      secondaryContainer: container,
      onSecondaryContainer: onContainer,
      tertiary: accent,
      onTertiary: onAccent,
      tertiaryContainer: container,
      onTertiaryContainer: onContainer,
      surface: const Color(0xFF1C1C1E),
      onSurface: Colors.white,
      onSurfaceVariant: const Color(0xFFAEAEB2),
      surfaceTint: Colors.transparent,
      inverseSurface: const Color(0xFFF2F2F7),
      onInverseSurface: Colors.black,
      surfaceDim: const Color(0xFF1C1C1E),
      surfaceBright: const Color(0xFF3A3A3C),
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xFF1C1C1E),
      surfaceContainer: const Color(0xFF1C1C1E),
      surfaceContainerHigh: const Color(0xFF2C2C2E),
      surfaceContainerHighest: const Color(0xFF2C2C2E),
      outline: const Color(0xFF636366),
      outlineVariant: const Color(0xFF48484A),
      error: const Color(0xFFFF453A),
      onError: Colors.white,
      errorContainer: const Color(0xFF561D1A),
      onErrorContainer: const Color(0xFFFFDAD6),
      scrim: Colors.black,
      shadow: Colors.black,
    );
  }
  return ColorScheme(
    brightness: Brightness.light,
    primary: accent,
    onPrimary: onAccent,
    primaryContainer: container,
    onPrimaryContainer: onContainer,
    inversePrimary: accent,
    secondary: accent,
    onSecondary: onAccent,
    secondaryContainer: container,
    onSecondaryContainer: onContainer,
    tertiary: accent,
    onTertiary: onAccent,
    tertiaryContainer: container,
    onTertiaryContainer: onContainer,
    surface: Colors.white,
    onSurface: Colors.black,
    onSurfaceVariant: const Color(0xFF8E8E93),
    surfaceTint: Colors.transparent,
    inverseSurface: const Color(0xFF2C2C2E),
    onInverseSurface: Colors.white,
    surfaceDim: const Color(0xFFE5E5EA),
    surfaceBright: Colors.white,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFF9F9FB),
    surfaceContainer: const Color(0xFFF2F2F7),
    surfaceContainerHigh: const Color(0xFFF2F2F7),
    surfaceContainerHighest: const Color(0xFFEEEEF0),
    outline: const Color(0xFFC7C7CC),
    outlineVariant: const Color(0xFFD1D1D6),
    error: const Color(0xFFFF3B30),
    onError: Colors.white,
    errorContainer: const Color(0xFFFFDAD6),
    onErrorContainer: const Color(0xFF7D1710),
    scrim: Colors.black,
    shadow: Colors.black,
  );
}

/// The app theme in the Monogatari look. [oled] keeps every surface black in
/// dark mode instead of the raised #1C1C1E cards.
ThemeData buildMonoTheme({
  required Brightness brightness,
  Color accent = monogatariPink,
  String? fontFamily,
  bool oled = false,
}) {
  final dark = brightness == Brightness.dark;
  var scheme = monoColorScheme(brightness, accent);
  var palette = dark ? MonoPalette.dark : MonoPalette.light;
  if (dark && oled) {
    scheme = scheme.copyWith(
      surface: Colors.black,
      surfaceDim: Colors.black,
      surfaceContainerLow: const Color(0xFF0E0E0F),
      surfaceContainer: const Color(0xFF111112),
    );
    palette = palette.copyWith(groupedCell: const Color(0xFF111112));
  }
  final background = dark ? Colors.black : Colors.white;
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: fontFamily,
  );
  final text = base.textTheme;

  return base.copyWith(
    scaffoldBackgroundColor: background,
    canvasColor: background,
    dividerColor: palette.hairline,
    splashFactory: InkRipple.splashFactory,
    extensions: [palette],
    progressIndicatorTheme: progressIndicatorTheme2024.copyWith(
      color: accent,
      linearTrackColor: palette.fill,
      circularTrackColor: Colors.transparent,
    ),
    sliderTheme: sliderTheme2024,
    pageTransitionsTheme: pageTransitionsTheme2024,
    textTheme: text.copyWith(
      headlineLarge: text.headlineLarge?.copyWith(fontWeight: FontWeight.w700),
      headlineMedium:
          text.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: accent),
      actionsIconTheme: IconThemeData(color: accent),
      titleTextStyle: text.titleLarge?.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 61,
      elevation: 0,
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelPadding: const EdgeInsets.only(top: 3),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 25,
          color: states.contains(WidgetState.selected)
              ? accent
              : scheme.onSurfaceVariant,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: fontFamily,
          fontSize: 10,
          color: states.contains(WidgetState.selected)
              ? accent
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: palette.groupedBackground,
      elevation: 0,
      indicatorColor: accent.withValues(alpha: 0.12),
      indicatorShape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      selectedIconTheme: IconThemeData(color: accent, size: 24),
      unselectedIconTheme:
          IconThemeData(color: scheme.onSurfaceVariant, size: 24),
      selectedLabelTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: accent,
      ),
      unselectedLabelTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 11,
        color: scheme.onSurfaceVariant,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: palette.sheetGroup,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: accent,
      selectedColor: accent,
      titleTextStyle: text.bodyLarge?.copyWith(color: scheme.onSurface),
      subtitleTextStyle: text.bodySmall?.copyWith(
        fontSize: 12,
        color: scheme.onSurfaceVariant,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: palette.hairline,
      thickness: 0.5,
      space: 0.5,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: palette.chip,
      selectedColor: accent.withValues(alpha: 0.12),
      disabledColor: palette.chip.withValues(alpha: 0.5),
      checkmarkColor: accent,
      deleteIconColor: scheme.onSurfaceVariant,
      showCheckmark: true,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      shape: const StadiumBorder(),
      side: WidgetStateBorderSide.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? BorderSide(color: accent.withValues(alpha: 0.6))
            : BorderSide.none,
      ),
      labelStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 14,
        color: scheme.onSurface,
      ),
      secondaryLabelStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: accent,
      ),
      iconTheme: IconThemeData(color: accent, size: 16),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.fill,
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      prefixIconColor: scheme.onSurfaceVariant,
      suffixIconColor: scheme.onSurfaceVariant,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accent.withValues(alpha: 0.6)),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent,
      selectionColor: accent.withValues(alpha: 0.25),
      selectionHandleColor: accent,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: accent,
      foregroundColor: scheme.onPrimary,
      elevation: 2,
      focusElevation: 2,
      hoverElevation: 3,
      highlightElevation: 2,
      shape: const StadiumBorder(),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      modalBackgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: scheme.outlineVariant,
      dragHandleSize: const Size(36, 4),
      showDragHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? const Color(0xFF2C2C2E) : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titleTextStyle: text.titleLarge?.copyWith(
        fontSize: 19,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.menu,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: text.bodyLarge?.copyWith(color: scheme.onSurface),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(palette.menu),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(12),
        shadowColor:
            WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.35)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        padding:
            const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(palette.menu),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: accent,
      unselectedLabelColor: scheme.onSurfaceVariant,
      indicatorColor: accent,
      dividerColor: palette.hairline,
      dividerHeight: 0.5,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      labelStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 15,
        fontWeight: FontWeight.w400,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primaryContainer
              : Colors.transparent,
        ),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outline)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      actionTextColor: accent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: accent,
      textColor: scheme.onPrimary,
    ),
    cupertinoOverrideTheme: NoDefaultCupertinoThemeData(
      brightness: brightness,
      primaryColor: accent,
    ),
  );
}
