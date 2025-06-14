// live_page.dart – Release 21 Jun 2025
//
//  • Wrap-layout prevents overflow on small screens.
//  • ECG chart sits in an InteractiveViewer so you can pan/zoom after a run.
//  • Logical width grows with recording length (≤60 s history).

import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/device_controller.dart';

class LivePage extends StatelessWidget {
  const LivePage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.find<DeviceController>();

    return Scaffold(
      appBar: AppBar(title: const Text('Live monitor')),
      body: Obx(() => Column(
        children: [
          /* ───── battery & status ───── */
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              const Icon(Icons.battery_charging_full, size: 18),
              const SizedBox(width: 4),
              Text('${c.batteryPercent.value}%'),
              const Spacer(),
              Flexible(
                  child:
                  Text(c.statusText.value, textAlign: TextAlign.end)),
            ]),
          ),

          /* ───── controls (no overflow) ───── */
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.start,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.favorite),
                  label: const Text('Start ECG'),
                  onPressed: c.startEcg,
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.bloodtype),
                  label: const Text('Start BP'),
                  onPressed: c.startBp,
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.stop_circle),
                  label: const Text('Stop'),
                  onPressed: c.stopEcg,
                ),
                Obx(() => ElevatedButton.icon(
                  icon: const Icon(Icons.speed),
                  label: Text('${c.speedLbl} mm/s'),
                  onPressed: c.cycleSpeed,
                )),
              ],
            ),
          ),
          const SizedBox(height: 6),

          /* ───── read-outs ───── */
          Obx(() => Text(
            c.bpmNow.value == 0
                ? 'Contact electrodes…'
                : 'BP ${c.sysNow.value}/${c.diaNow.value}  •  HR ${c.bpmNow.value}',
            style: const TextStyle(fontSize: 16),
          )),
          Obx(() => Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${c.yScale.value.toStringAsFixed(1)} mV/div',
                style:
                const TextStyle(fontSize: 12, color: Colors.grey)),
          )),

          /* ───── ECG chart ───── */
          Expanded(
            child: Obx(() {
              final spots = c.ecg;
              if (spots.isEmpty) {
                return const Center(child: Text('Waiting for data…'));
              }

              // chart logical width grows with recording (max 60 s)
              const pxPerSec = 75.0;
              final totalSec = math.max(spots.last.x, c.windowSec);
              final chartW   = totalSec * pxPerSec;

              final lastX = spots.last.x;
              final window = c.windowSec;

              return InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                panEnabled: true,
                scaleEnabled: true,
                child: SizedBox(
                  width: chartW,
                  child: GestureDetector(
                    onTap: c.cycleYScale,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: LineChart(
                        LineChartData(
                          minX: lastX - window,
                          maxX: lastX,
                          minY: -c.yScale.value,
                          maxY: c.yScale.value,
                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                reservedSize: 32,
                                showTitles: true,
                                interval: c.yScale.value / 2,
                                getTitlesWidget: (v, _) => Text(
                                    v.toStringAsFixed(1),
                                    style:
                                    const TextStyle(fontSize: 10)),
                              ),
                            ),
                            rightTitles: const AxisTitles(
                                sideTitles:
                                SideTitles(showTitles: false)),
                            topTitles: const AxisTitles(
                                sideTitles:
                                SideTitles(showTitles: false)),
                            bottomTitles: const AxisTitles(
                                sideTitles:
                                SideTitles(showTitles: false)),
                          ),
                          gridData: FlGridData(
                            drawVerticalLine: false,
                            horizontalInterval: c.yScale.value / 2,
                            getDrawingHorizontalLine: (_) =>
                                FlLine(strokeWidth: .4, dashArray: [4, 4]),
                          ),
                          borderData: FlBorderData(show: false),
                          lineBarsData: [
                            LineChartBarData(
                              spots: spots,
                              isCurved: false,
                              dotData: const FlDotData(show: false),
                              barWidth: 1.4,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      )),
    );
  }
}
