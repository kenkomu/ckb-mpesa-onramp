import 'package:flutter/material.dart';
import 'screens/offers_screen.dart';

void main() {
  runApp(const BitshadaApp());
}

class BitshadaApp extends StatelessWidget {
  const BitshadaApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Same teal-green accent as the web app and grant/pilot pages, for
    // one consistent Bitshada identity across every touchpoint.
    const accent = Color(0xFF1E8F6F);
    return MaterialApp(
      title: 'Bitshada',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: accent, primary: accent, brightness: Brightness.light),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3FC491), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const OffersScreen(),
    );
  }
}
