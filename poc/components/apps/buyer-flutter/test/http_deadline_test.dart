// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:amisad_buyer/main.dart';

void main() {
  test('total deadline aborts a response that never finishes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<void>();
    server.listen((request) {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{');
      request.response.flush();
      if (!received.isCompleted) received.complete();
    });
    try {
      final watch = Stopwatch()..start();
      await expectLater(requestJson('http://127.0.0.1:${server.port}',
        timeout: const Duration(milliseconds: 150)), throwsA(isA<TimeoutException>()));
      await received.future.timeout(const Duration(seconds: 1));
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    } finally { await server.close(force: true); }
  });

}
