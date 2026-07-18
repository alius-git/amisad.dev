// AmisAd buyer app - POC skeleton.
// Placeholder screen using the AmisAd brand palette (components/art).
// The vault, needs list, and delegate mode arrive with the scenarios.

import 'package:flutter/material.dart';

const amisadNavy = Color(0xFF2B3A67);
const amisadTerracotta = Color(0xFFE2725B);

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
      home: const PlaceholderScreen(),
    );
  }
}

class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: amisadNavy,
        foregroundColor: Colors.white,
        title: const Text('AmisAd'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/icon-64.png', width: 64, height: 64),
            const SizedBox(height: 16),
            const Text(
              'My needs and wants',
              style: TextStyle(fontSize: 20, color: amisadNavy),
            ),
            const SizedBox(height: 8),
            const Text('POC skeleton - nothing about you leaves this device.'),
          ],
        ),
      ),
    );
  }
}
