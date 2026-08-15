import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class HisabFlowColors {
  HisabFlowColors._();

  // HisabFlow AI brand colors.
  static const Color primary = Color(0xFF2563EB);
  static const Color primaryLight = Color(0xFF60A5FA);
  static const Color secondary = Color(0xFF0F766E);
  static const Color cyan = Color(0xFF0EA5E9);
  static const Color green = Color(0xFF16A34A);
  static const Color orange = Color(0xFFF59E0B);
  static const Color red = Color(0xFFEF4444);

  static const Color darkBackground = Color(0xFF070A10);
  static const Color darkSurface = Color(0xFF10141E);
  static const Color darkSurface2 = Color(0xFF1C1C1E);
  static const Color darkSurface3 = Color(0xFF202636);
  static const Color darkBorder = Color(0xFF293144);

  static const Color lightBackground = Color(0xFFF4F4F5);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurface2 = Color(0xFFF2F2F7);
  static const Color lightSurface3 = Color(0xFFE7ECF5);
  static const Color lightBorder = Color(0xFFE1E1E6);

  static const Color darkText = Color(0xFFF7F8FC);
  static const Color darkMuted = Color(0xFFA8B0C0);
  static const Color lightText = Color(0xFF111827);
  static const Color lightMuted = Color(0xFF667085);

  static const LinearGradient brandGradient = LinearGradient(
    colors: [primary, secondary, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient operatorGradient = LinearGradient(
    colors: [Color(0xFF6D5DFB), Color(0xFF4D7CFE)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient equalGradient = LinearGradient(
    colors: [Color(0xFF14B8A6), Color(0xFF22D3EE)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

class HisabFlowTheme {
  HisabFlowTheme._();

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: HisabFlowColors.primary,
      brightness: brightness,
      primary: dark ? HisabFlowColors.primaryLight : HisabFlowColors.primary,
      secondary: HisabFlowColors.secondary,
      tertiary: HisabFlowColors.cyan,
      surface: dark
          ? HisabFlowColors.darkSurface
          : HisabFlowColors.lightSurface,
      error: HisabFlowColors.red,
    );

    final mainText = dark
        ? HisabFlowColors.darkText
        : HisabFlowColors.lightText;
    final muted = dark ? HisabFlowColors.darkMuted : HisabFlowColors.lightMuted;
    final surface = dark
        ? HisabFlowColors.darkSurface
        : HisabFlowColors.lightSurface;
    final surface2 = dark
        ? HisabFlowColors.darkSurface2
        : HisabFlowColors.lightSurface2;
    final border = dark
        ? HisabFlowColors.darkBorder
        : HisabFlowColors.lightBorder;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark
          ? HisabFlowColors.darkBackground
          : HisabFlowColors.lightBackground,
      fontFamilyFallback: const ['Noto Sans Bengali', 'Noto Sans', 'Roboto'],
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.adaptivePlatformDensity,

      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: Colors.transparent,
        foregroundColor: mainText,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: mainText,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.25,
        ),
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: border),
        ),
      ),

      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface2,
        hintStyle: TextStyle(color: muted, fontWeight: FontWeight.w500),
        labelStyle: TextStyle(color: muted, fontWeight: FontWeight.w600),
        helperStyle: TextStyle(color: muted, fontWeight: FontWeight.w500),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: HisabFlowColors.red),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: scheme.primary,
          minimumSize: const Size(44, 50),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: scheme.primary,
          minimumSize: const Size(44, 50),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: mainText,
          minimumSize: const Size(44, 50),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: mainText,
          backgroundColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 2,
        highlightElevation: 4,
        foregroundColor: Colors.white,
        backgroundColor: scheme.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? Colors.white : muted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? scheme.primary
              : surface2;
        }),
      ),

      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        textColor: mainText,
        titleTextStyle: TextStyle(
          color: mainText,
          fontWeight: FontWeight.w800,
          fontSize: 15,
        ),
        subtitleTextStyle: TextStyle(
          color: muted,
          fontWeight: FontWeight.w500,
          height: 1.3,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),

      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        height: 68,
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(color: mainText, fontSize: 11, fontWeight: FontWeight.w700),
        ),
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: border),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark
            ? HisabFlowColors.darkSurface3
            : HisabFlowColors.lightText,
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: muted.withValues(alpha: 0.45),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: dark
              ? HisabFlowColors.darkSurface3
              : HisabFlowColors.lightText,
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: surface2,
      ),
    );
  }
}

class HisabFlowResponsive {
  HisabFlowResponsive._();

  static double width(BuildContext context) => MediaQuery.sizeOf(context).width;
  static double height(BuildContext context) =>
      MediaQuery.sizeOf(context).height;

  static bool isVerySmallPhone(BuildContext context) => width(context) < 340;
  static bool isSmallPhone(BuildContext context) => width(context) < 380;
  static bool isLargePhone(BuildContext context) => width(context) >= 430;
  static bool isTablet(BuildContext context) => width(context) >= 600;

  static double horizontalPadding(BuildContext context) {
    final w = width(context);
    if (w < 340) return 10;
    if (w < 380) return 12;
    if (w < 430) return 14;
    if (w < 600) return 16;
    return 20;
  }

  static double sectionGap(BuildContext context) {
    final w = width(context);
    if (w < 340) return 10;
    if (w < 380) return 12;
    if (w < 430) return 14;
    return 16;
  }

  static double radius(BuildContext context) {
    final w = width(context);
    if (w < 340) return 16;
    if (w < 380) return 18;
    return 22;
  }

  static double calculatorButtonHeight(BuildContext context) {
    final h = height(context);
    final w = width(context);
    if (h < 620 || w < 340) return 47;
    if (h < 700 || w < 380) return 51;
    if (h < 780) return 55;
    return 59;
  }

  static double calculatorButtonFont(BuildContext context) {
    final w = width(context);
    if (w < 340) return 17;
    if (w < 380) return 18;
    if (w < 430) return 19;
    return 20;
  }

  static double displayResultFont(BuildContext context) {
    final w = width(context);
    if (w < 340) return 30;
    if (w < 380) return 34;
    if (w < 430) return 38;
    return 42;
  }

  static double displayExpressionFont(BuildContext context) {
    final w = width(context);
    if (w < 340) return 16;
    if (w < 380) return 17;
    return 18;
  }

  static int dashboardColumns(BuildContext context) {
    final w = width(context);
    if (w < 330) return 1;
    if (w < 600) return 2;
    if (w < 900) return 3;
    return 4;
  }

  static double contentMaxWidth(BuildContext context) {
    final w = width(context);
    if (w < 600) return double.infinity;
    if (w < 900) return 680;
    return 820;
  }
}

class HisabFlowSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final Color? color;

  const HisabFlowSurface({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = HisabFlowResponsive.radius(context);

    final content = Container(
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:
            color ??
            (dark ? HisabFlowColors.darkSurface : HisabFlowColors.lightSurface),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: dark
              ? HisabFlowColors.darkBorder
              : HisabFlowColors.lightBorder,
        ),
      ),
      child: child,
    );

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: content,
      ),
    );
  }
}

class HisabFlowPage extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final bool scrollable;

  const HisabFlowPage({
    super.key,
    required this.child,
    this.padding,
    this.scrollable = true,
  });

  @override
  Widget build(BuildContext context) {
    final content = Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: HisabFlowResponsive.contentMaxWidth(context),
        ),
        child: Padding(
          padding:
              padding ??
              EdgeInsets.symmetric(
                horizontal: HisabFlowResponsive.horizontalPadding(context),
              ),
          child: child,
        ),
      ),
    );

    if (!scrollable) return content;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: content,
    );
  }
}

/// Compact premium theme switch used in the calculator header.
class HisabFlowThemeToggle extends StatelessWidget {
  final bool darkMode;
  final ValueChanged<bool> onChanged;
  final bool compact;

  const HisabFlowThemeToggle({
    super.key,
    required this.darkMode,
    required this.onChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final width = compact ? 38.0 : 66.0;
    final height = compact ? 34.0 : 36.0;

    return Semantics(
      button: true,
      label: darkMode ? 'Switch to light mode' : 'Switch to dark mode',
      child: Tooltip(
        message: darkMode ? 'Light mode' : 'Dark mode',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              HapticFeedback.lightImpact();
              onChanged(!darkMode);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: width,
              height: height,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                gradient: darkMode
                    ? const LinearGradient(
                        colors: [Color(0xFF242B3B), Color(0xFF151925)],
                      )
                    : const LinearGradient(
                        colors: [Color(0xFFFFF2BF), Color(0xFFFFD97A)],
                      ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: dark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06),
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (!compact)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Icon(
                          Icons.dark_mode_rounded,
                          size: 14,
                          color: darkMode ? Colors.white70 : Colors.black38,
                        ),
                        Icon(
                          Icons.light_mode_rounded,
                          size: 14,
                          color: darkMode
                              ? Colors.white38
                              : const Color(0xFF8A5B00),
                        ),
                      ],
                    ),
                  AnimatedAlign(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutBack,
                    alignment: darkMode
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: darkMode
                            ? const Color(0xFF5B7CFF)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.16),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Icon(
                        darkMode
                            ? Icons.dark_mode_rounded
                            : Icons.light_mode_rounded,
                        size: 16,
                        color: darkMode
                            ? Colors.white
                            : const Color(0xFFF59E0B),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
