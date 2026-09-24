// Basic smoke test: the app boots and shows the marketplace shell
// without needing a live network call to complete first.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobile/main.dart';

void main() {
  testWidgets('App boots and shows the Bitshada marketplace shell', (WidgetTester tester) async {
    await tester.pumpWidget(const BitshadaApp());

    expect(find.text('Bitshada'), findsOneWidget);
    expect(find.text('Open offers'), findsOneWidget);
    // The API call is still in flight at this point (no real network in
    // a widget test), so the loading spinner should be showing.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
