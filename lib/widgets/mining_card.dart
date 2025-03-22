import 'package:flutter/material.dart';
import 'create_mining_job_dialog.dart';

class MiningCard extends StatelessWidget {
  final String jobId;
  final double progress;
  final double hashRate;
  final double remainingTime;
  final bool isPaused;
  final double speedMultiplier;
  final VoidCallback onPauseResume;
  final VoidCallback onStop;
  final Function(double) onSpeedChange;

  const MiningCard({
    Key? key,
    required this.jobId,
    required this.progress,
    required this.hashRate,
    required this.remainingTime,
    required this.isPaused,
    required this.speedMultiplier,
    required this.onPauseResume,
    required this.onStop,
    required this.onSpeedChange,
  }) : super(key: key);

  String _formatHashRate(double rate) {
    if (rate >= 1000000) {
      return '${(rate / 1000000).toStringAsFixed(2)} MH/s';
    } else if (rate >= 1000) {
      return '${(rate / 1000).toStringAsFixed(2)} KH/s';
    }
    return '${rate.toStringAsFixed(2)} H/s';
  }

  String _formatDuration(double seconds) {
    if (seconds.isInfinite || seconds.isNaN) return '--:--:--';
    
    final Duration duration = Duration(seconds: seconds.round());
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final secs = duration.inSeconds.remainder(60);
    
    return '${hours.toString().padLeft(2, '0')}:'
           '${minutes.toString().padLeft(2, '0')}:'
           '${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // Display only first 8 chars of job ID for UI cleanliness
    final displayJobId = jobId.length > 8 ? '${jobId.substring(0, 8)}...' : jobId;
    
    return Card(
      elevation: 4,
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Job: $displayJobId',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Row(
                  children: [
                    // Pause/Resume button with clear visual indicator and tooltip
                    IconButton(
                      icon: Icon(
                        isPaused ? Icons.play_arrow : Icons.pause,
                        color: isPaused ? Colors.green : Colors.orange,
                      ),
                      onPressed: () {
                        debugPrint('Pause/Resume pressed for job: $jobId');
                        onPauseResume();
                      },
                      tooltip: isPaused ? 'Resume Mining' : 'Pause Mining',
                    ),
                    // Stop button with tooltip
                    IconButton(
                      icon: const Icon(Icons.stop, color: Colors.red),
                      onPressed: () {
                        debugPrint('Stop pressed for job: $jobId');
                        onStop();
                      },
                      tooltip: 'Stop Mining',
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress / 100,
                minHeight: 10,
                backgroundColor: Colors.grey[200],
                valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(context).primaryColor,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${progress.toStringAsFixed(1)}%'),
                Text('ETA: ${_formatDuration(remainingTime)}'),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Hash Rate: ${_formatHashRate(hashRate)}',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                Row(
                  children: [
                    const Text('Speed: '),
                    DropdownButton<double>(
                      value: speedMultiplier,
                      items: [0.5, 1.0, 2.0, 4.0].map((speed) {
                        return DropdownMenuItem<double>(
                          value: speed,
                          child: Text('${speed}x'),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) onSpeedChange(value);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
