import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/offers_screen.dart';

void main() {
  runApp(const BitshadaApp());
}

/// Same font trio as the web app (assets/css/app.css): Source Serif 4 for
/// headings, Public Sans for body/UI, IBM Plex Mono for anything that's
/// genuinely data (amounts, hashes, addresses) so it reads as an exact
/// value rather than prose. Keeps the two surfaces looking like one
/// product instead of two different apps.
TextTheme _bitshadaTextTheme(ColorScheme scheme) {
  final base = GoogleFonts.publicSansTextTheme().apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  final display = GoogleFonts.sourceSerif4TextTheme();
  return base.copyWith(
    headlineLarge: display.headlineLarge?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w700),
    headlineMedium: display.headlineMedium?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w700),
    headlineSmall: display.headlineSmall?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w700),
    titleLarge: display.titleLarge?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w700),
    titleMedium: display.titleMedium?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600),
  );
}

/// Style for tx hashes, addresses, and amounts -- the mono data style,
/// mirroring the web app's `.font-mono`/`.mono` convention.
TextStyle bitshadaMono(BuildContext context, {double? fontSize, FontWeight? fontWeight, Color? color}) {
  return GoogleFonts.ibmPlexMono(
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color ?? Theme.of(context).colorScheme.onSurface,
  );
}

class BitshadaApp extends StatelessWidget {
  const BitshadaApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Exact same palette as web's daisyUI themes (assets/css/app.css):
    // teal-green primary (the escrow/trust color), warm amber secondary
    // (the KES/money color), deep teal accent -- so semantic colors are
    // theme-derived here too, instead of hardcoded Colors.green/orange.
    const lightPrimary = Color(0xFF1E8F6F);
    const lightSecondary = Color(0xFFA86A26);
    const lightTertiary = Color(0xFF146A51);
    const darkPrimary = Color(0xFF3FC491);
    const darkSecondary = Color(0xFFDD9D51);
    const darkTertiary = Color(0xFF7FE0B8);

    final lightScheme = ColorScheme.fromSeed(
      seedColor: lightPrimary,
      primary: lightPrimary,
      brightness: Brightness.light,
    ).copyWith(secondary: lightSecondary, tertiary: lightTertiary);

    final darkScheme = ColorScheme.fromSeed(
      seedColor: darkPrimary,
      primary: darkPrimary,
      brightness: Brightness.dark,
    ).copyWith(secondary: darkSecondary, tertiary: darkTertiary);

    return MaterialApp(
      title: 'Bitshada',
      theme: ThemeData(
        colorScheme: lightScheme,
        useMaterial3: true,
        textTheme: _bitshadaTextTheme(lightScheme),
        cardTheme: const CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: darkScheme,
        useMaterial3: true,
        textTheme: _bitshadaTextTheme(darkScheme),
        cardTheme: const CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ),
      ),
      home: const OffersScreen(),
    );
  }
}
