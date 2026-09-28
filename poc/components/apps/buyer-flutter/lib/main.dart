// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd buyer app - s001.fulfillment manual demo.
// The needs-list screen drives the same APIs as the automated buyer-client:
// obtain a token, submit the need as an opaque envelope, show the match, and
// follow the pseudonymous order status. UI automation is out of scope; the
// automated sequence uses buyer-client instead.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

const amisadNavy = Color(0xFF2B3A67);
const amisadTerracotta = Color(0xFFE2725B);

// 10.0.2.2 is the Android emulator's alias for the host machine; the ports
// are the NodePorts the scenario deploy exposes. Override at build time:
//   flutter build apk --dart-define=COORDINATOR_URL=http://<vm-ip>:30080 ...
const coordinatorUrl =
    String.fromEnvironment('COORDINATOR_URL', defaultValue: 'http://10.0.2.2:30080');
const identityUrl =
    String.fromEnvironment('IDENTITY_URL', defaultValue: 'http://10.0.2.2:30084');

Future<Map<String, dynamic>> postJson(String url, Map<String, dynamic> body) =>
    requestJson(url, body: body);

Future<Map<String, dynamic>> getJson(String url) => requestJson(url);

Future<Map<String, dynamic>> requestJson(String url,
    {Map<String, dynamic>? body, Duration timeout = const Duration(seconds: 20)}) async {
  final client = HttpClient();
  try {
    return await (() async {
      final request = await client.openUrl(body == null ? 'GET' : 'POST', Uri.parse(url));
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 300) {
        throw HttpException('$url -> ${response.statusCode}: $text');
      }
      return jsonDecode(text) as Map<String, dynamic>;
    })().timeout(timeout);
  } finally {
    // Also abort the transport when the total deadline expires mid-body.
    client.close(force: true);
  }
}

void main() {
  runApp(const AmisAdBuyerApp());
}

class AmisAdBuyerApp extends StatelessWidget {
  const AmisAdBuyerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AmisAd',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: amisadNavy,
          secondary: amisadTerracotta,
        ),
        useMaterial3: true,
      ),
      home: const NeedsScreen(),
    );
  }
}

class NeedsScreen extends StatefulWidget {
  const NeedsScreen({super.key, this.post = postJson, this.get = getJson});

  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) post;
  final Future<Map<String, dynamic>> Function(String) get;

  @override
  State<NeedsScreen> createState() => _NeedsScreenState();
}

class _NeedsScreenState extends State<NeedsScreen> {
  final _contextController = TextEditingController(
    text: "Wedding gift from the couple's wish list, deliver to their city",
  );
  final _budgetController = TextEditingController(text: '120.00');

  int _generation = 0;
  bool _busy = false;
  String? _error;
  String? _handle;
  String? _offerTitle;
  int? _priceCents;
  String _status = '-';

  @override
  void dispose() {
    _generation++;
    _contextController.dispose();
    _budgetController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final generation = ++_generation;
    final contextText = _contextController.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final budgetCents =
          (double.parse(_budgetController.text.trim()) * 100).round();
      final tokenReply = await widget.post('$identityUrl/v1/tokens',
          {'actor': 'maya', 'class': 'person'});
      if (!mounted || generation != _generation) return;
      final need = {
        'category': 'housewares',
        'budget_cents': budgetCents,
        'region': 'region-a',
        'deadline_days': 14,
        'auto_close': true,
        'context': contextText,
      };
      final result = await widget.post('$coordinatorUrl/v1/needs', {
        'token': tokenReply['token'],
        'jurisdiction': 'region-a',
        // Opaque envelope: only the sealed environment opens it.
        'envelope': jsonEncode(need),
      });
      if (!mounted || generation != _generation) return;
      final offer = result['offer'] as Map<String, dynamic>? ?? {};
      setState(() {
        _handle = result['handle'] as String?;
        _offerTitle = offer['title'] as String?;
        _priceCents = (offer['price_cents'] as num?)?.toInt();
        _status = 'matched';
      });
    } catch (e) {
      if (mounted && generation == _generation) setState(() => _error = '$e');
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final handle = _handle;
    if (handle == null || _busy) return;
    final generation = ++_generation;
    try {
      final order = await widget.get('$coordinatorUrl/v1/orders/$handle');
      if (!mounted || generation != _generation || handle != _handle) return;
      setState(() => _status = order['status'] as String? ?? 'unknown');
    } catch (e) {
      if (mounted && generation == _generation) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: amisadNavy,
        foregroundColor: Colors.white,
        title: const Text('AmisAd - my needs and wants'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Image.asset('assets/icon-64.png', width: 40, height: 40),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Say what you need once, in private. Nothing about you leaves this device.',
                  style: TextStyle(color: amisadNavy),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _contextController,
            decoration: const InputDecoration(
              labelText: 'What do you need?',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _budgetController,
            decoration: const InputDecoration(
              labelText: 'Budget',
              prefixText: r'$ ',
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: amisadTerracotta),
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Matching privately...' : 'State the need'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          if (_handle != null) ...[
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _offerTitle ?? 'Matched offer',
                      style: const TextStyle(
                        fontSize: 18,
                        color: amisadNavy,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_priceCents != null)
                      Text('\$${(_priceCents! / 100).toStringAsFixed(2)}'),
                    const SizedBox(height: 8),
                    Text('Order status: $_status'),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _busy ? null : _refresh,
                      child: const Text('Refresh status'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
