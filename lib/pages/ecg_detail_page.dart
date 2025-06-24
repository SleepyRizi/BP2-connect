// ──────────────────────────────────────────────
// EcgDetailPage – v1.0  (with FlChart waveform)
// ──────────────────────────────────────────────
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/ecg_record.dart';
import '../services/bp2_protocol.dart';   // for decodeEcg()

class EcgDetailPage extends StatelessWidget {
  final EcgRecord record;
  const EcgDetailPage({super.key, required this.record});

  @override
  Widget build(BuildContext context) {
    final samples = decodeEcg(record.wave);
    final spots   = <FlSpot>[
      for (var i = 0; i < samples.length; ++i)
        FlSpot(i / 250.0, samples[i]),        // 250 Hz
    ];

    /* auto-scale nicely */
    final minY = spots.map((e) => e.y).reduce(math.min);
    final maxY = spots.map((e) => e.y).reduce(math.max);

    return Scaffold(
      appBar: AppBar(title: const Text('ECG Detail')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: DefaultTextStyle.merge(
              style: Theme.of(context).textTheme.bodyMedium,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Start:     ${record.start.toLocal()}'),
                  Text('Duration:  ${(record.duration / 1000).round()} s'),
                  Text('Heart Rate: ${record.hr} bpm'),
                ],
              ),
            ),
          ),
          const Divider(height: 0),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: LineChart(
                LineChartData(
                  titlesData: FlTitlesData(show: false),
                  gridData  : FlGridData(show: false),
                  borderData: FlBorderData(show: true),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isStrokeCapRound: true,
                      dotData: FlDotData(show: false),
                      barWidth: 1.2,
                    ),
                  ],
                  minX: 0,
                  maxX: record.duration / 1000,
                  minY: minY - 0.3,
                  maxY: maxY + 0.3,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
