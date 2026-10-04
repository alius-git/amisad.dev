// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:amisad_buyer/main.dart';

void main() {
  testWidgets('late submit cannot update a disposed screen', (tester) async {
    final token = Completer<Map<String, dynamic>>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: NeedsScreen(post: (url, body) {
      calls++;
      return token.future;
    })));
    await tester.tap(find.text('State the need'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    token.complete({'token': 't'});
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(calls, 1);
  });

  testWidgets('old order refresh cannot overwrite a newer match', (tester) async {
    final old = Completer<Map<String, dynamic>>();
    var matches = 0;
    await tester.pumpWidget(MaterialApp(home: NeedsScreen(
      post: (url, body) async => url.endsWith('/tokens') ? {'token': 't'}
        : {'handle': 'h${++matches}', 'offer': {'title': 'Offer $matches'}},
      get: (url) => old.future,
    )));
    await tester.tap(find.text('State the need'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Refresh status'));
    await tester.tap(find.text('Refresh status'));
    await tester.ensureVisible(find.text('State the need'));
    await tester.tap(find.text('State the need'));
    await tester.pumpAndSettle();
    old.complete({'status': 'stale order'});
    await tester.pumpAndSettle();
    expect(find.text('Order status: matched'), findsOneWidget);
    expect(find.text('Order status: stale order'), findsNothing);
  });
}
