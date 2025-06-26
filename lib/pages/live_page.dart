/*──────────────────────────────────────────────────────────────────────────────
  live_page.dart – BP + ECG live monitor
  28 Jun 2025
──────────────────────────────────────────────────────────────────────────────*/
import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/device_controller.dart';
import '../controllers/history_controller.dart';

class LivePage extends StatelessWidget {
  const LivePage({super.key});

  @override
  Widget build(BuildContext context) {
    final c  = Get.find<DeviceController>();
    final hc = Get.find<HistoryController>();   // for pull buttons

    return Scaffold(
      appBar: AppBar(title: const Text('Live monitor')),
      body: Obx(() => Column(
        children: [
          /* ───── battery & connection status ───── */
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              const Icon(Icons.battery_charging_full, size: 18),
              const SizedBox(width: 4),
              Text('${c.batteryPercent.value}%'),
              const Spacer(),
              Flexible(
                child: Text(c.statusText.value,
                    textAlign: TextAlign.end),
              ),
            ]),
          ),

          /* ───── control buttons ───── */
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                /* ECG */
                ElevatedButton.icon(
                  icon: const Icon(Icons.favorite),
                  label: const Text('Start ECG'),
                  onPressed: c.startEcg,
                ),
                /* BP */
                ElevatedButton.icon(
                  icon: const Icon(Icons.bloodtype),
                  label: const Text('Start BP'),
                  onPressed: () => c.startBp(),   // pass custom target if you wish
                ),
                /* STOP (closes realtime) */
                ElevatedButton.icon(
                  icon: const Icon(Icons.stop_circle),
                  label: const Text('Stop BP/ECG'),
                  onPressed: c.stopEcg,
                ),

                /* pull/save buttons */
                ElevatedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Pull ECG'),
                  onPressed: () => hc.syncLatestEcg(),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.download_for_offline),
                  label: const Text('Pull BP'),
                  onPressed: () => Get.find<HistoryController>().syncLatestBp(),
                ),
                /* speed toggle */
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
          Obx(() => Column(children: [
            /* cuff pressure while running BP */
            if (c.statusText.value.startsWith('BP'))
              Text('Cuff ${c.pressureNow.value} mmHg',
                  style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 2),
            /* results */
            Text(
              c.sysNow.value == 0
                  ? 'HR ${c.bpmNow.value == 0 ? '--' : c.bpmNow.value}'
                  : '${c.sysNow.value}/${c.diaNow.value}  '
                  'MAP ${c.meanNow.value}  '
                  'HR ${c.pulseNow.value}',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 2),
            Text(
              '${c.yScale.value.toStringAsFixed(1)} mV/div',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ])),

          /* ───── ECG / oscillogram chart ───── */
          Expanded(
            child: Obx(() {
              final spots = c.ecg;
              if (spots.isEmpty) {
                return const Center(child: Text('Waiting for data…'));
              }

              const pxPerSec = 75.0;            // logical width scale
              final totalSec = math.max(spots.last.x, c.windowSec);
              final chartW   = totalSec * pxPerSec;
              final lastX    = spots.last.x;
              final window   = c.windowSec;

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
                          maxY:  c.yScale.value,
                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                reservedSize: 32,
                                showTitles: true,
                                interval: c.yScale.value / 2,
                                getTitlesWidget: (v, _) => Text(
                                  v.toStringAsFixed(1),
                                  style: const TextStyle(fontSize: 10),
                                ),
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
