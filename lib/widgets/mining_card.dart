import 'package:flutter/material.dart';
import 'package:miner_app/models/mining_job.dart';
import 'create_mining_job_dialog.dart';

class MiningCard extends StatefulWidget {
  final String jobId;
  final double progress;
  final double hashRate;
  final double remainingTime;
  final bool isPaused;
  final double speedMultiplier;
  final int lastTriedNonce;
  final int activeWorkers;
  final List<Map<String, dynamic>> workerDetails; 
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;
  final Function(double) onSpeedChange;
  final MiningJob? job;

  const MiningCard({
    Key? key,
    required this.jobId,
    required this.progress,
    required this.hashRate,
    required this.remainingTime,
    required this.isPaused,
    required this.speedMultiplier,
    required this.lastTriedNonce,
    this.activeWorkers = 0,
    this.workerDetails = const [], 
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onSpeedChange,
    this.job,
  }) : super(key: key);

  @override
  State<MiningCard> createState() => _MiningCardState();
}

class _MiningCardState extends State<MiningCard> {
  double _speedMultiplier = 1.0;
  
  @override
  void initState() {
    super.initState();
    _speedMultiplier = widget.speedMultiplier;
  }
  
  Widget _buildStatItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12.0,
          ),
        ),
        const SizedBox(height: 4.0),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14.0,
          ),
        ),
      ],
    );
  }
  
  String _formatHashRate(double rate) {
    if (rate < 1) {
      return '${(rate * 1000).toStringAsFixed(2)} H/s';
    } else if (rate < 1000) {
      return '${rate.toStringAsFixed(2)} KH/s';
    } else {
      return '${(rate / 1000).toStringAsFixed(2)} MH/s';
    }
  }
  
  String _formatDuration(double seconds) {
    if (seconds.isInfinite || seconds.isNaN || seconds <= 0) {
      return 'Unknown';
    }
    
    final duration = Duration(seconds: seconds.round());
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final secs = duration.inSeconds.remainder(60);
    
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m ${secs}s';
    } else {
      return '${secs}s';
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final hashRate = widget.hashRate;
    final remainingTime = widget.remainingTime;
    final lastTriedNonce = widget.lastTriedNonce;
    final workerDetails = widget.workerDetails;
    final hasEndNonce = widget.job?.endNonce != null && 
                        widget.job!.endNonce > 0 && 
                        widget.job!.endNonce != 0x7FFFFFFF;
    
    return Card(
      margin: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Job header with controls
          Container(
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: Colors.blue.shade100,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4.0),
                topRight: Radius.circular(4.0),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Job: ${widget.jobId}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16.0,
                    ),
                  ),
                ),
                // Pause/Resume button
                IconButton(
                  icon: Icon(
                    widget.isPaused ? Icons.play_arrow : Icons.pause,
                    color: widget.isPaused ? Colors.green : Colors.orange,
                  ),
                  onPressed: () {
                    if (widget.isPaused) {
                      widget.onResume();
                    } else {
                      widget.onPause();
                    }
                  },
                ),
                // Stop button
                IconButton(
                  icon: const Icon(
                    Icons.stop,
                    color: Colors.red,
                  ),
                  onPressed: widget.onStop,
                ),
              ],
            ),
          ),
          
          // Job progress and stats
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Progress bar (only show if there's an end nonce)
                if (hasEndNonce) ...[
                  Row(
                    children: [
                      Text('${progress.toStringAsFixed(1)}%'),
                      const SizedBox(width: 8.0),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: progress / 100,
                          backgroundColor: Colors.grey.shade200,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            widget.isPaused ? Colors.orange : Colors.blue,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16.0),
                ],
                
                // Stats grid
                Row(
                  children: [
                    Expanded(
                      child: _buildStatItem(
                        'Hash Rate',
                        _formatHashRate(hashRate),
                      ),
                    ),
                    if (hasEndNonce)
                      Expanded(
                        child: _buildStatItem(
                          'Remaining',
                          _formatDuration(remainingTime),
                        ),
                      ),
                    Expanded(
                      child: _buildStatItem(
                        'Current Nonce',
                        lastTriedNonce.toString(),
                      ),
                    ),
                    Expanded(
                      child: _buildStatItem(
                        'Workers',
                        widget.activeWorkers.toString(),
                      ),
                    ),
                  ],
                ),
                
                // Speed control slider
                Row(
                  children: [
                    const Text('Speed:'),
                    Expanded(
                      child: Slider(
                        value: _speedMultiplier,
                        min: 0.5,
                        max: 5.0,
                        divisions: 9,
                        label: '${_speedMultiplier.toStringAsFixed(1)}x',
                        onChanged: (value) {
                          setState(() {
                            _speedMultiplier = value;
                          });
                          widget.onSpeedChange(value);
                        },
                      ),
                    ),
                    Text('${_speedMultiplier.toStringAsFixed(1)}x'),
                  ],
                ),
              ],
            ),
          ),
          
          if (workerDetails.isNotEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 16.0, top: 16.0, bottom: 8.0),
                  child: Text(
                    'Worker Details',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16.0,
                    ),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16.0),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 1,
                              child: Text(
                                'Worker',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                'Last Nonce',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text(
                                'Hash Rate',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text(
                                'Status',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      ...workerDetails.map((worker) {
                        final workerId = worker['workerId'] as int? ?? 0;
                        final lastNonce = worker['lastNonce'] as int? ?? 0;
                        final workerHashRate = worker['hashRate'] as double? ?? 0.0;
                        final status = worker['status'] as String? ?? 'Idle';
                        
                        Color statusColor = Colors.grey;
                        if (status == 'mining') {
                          statusColor = Colors.green;
                        } else if (status == 'paused') {
                          statusColor = Colors.orange;
                        } else if (status == 'completed') {
                          statusColor = Colors.blue;
                        }
                        
                        return Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 1,
                                child: Text('#$workerId'),
                              ),
                              Expanded(
                                flex: 2,
                                child: Text('$lastNonce'),
                              ),
                              Expanded(
                                flex: 1,
                                child: Text('${workerHashRate.toStringAsFixed(2)} KH/s'),
                              ),
                              Expanded(
                                flex: 1,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
                                  decoration: BoxDecoration(
                                    color: statusColor.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(4.0),
                                  ),
                                  child: Text(
                                    status,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: statusColor),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ],
                  ),
                ),
                const SizedBox(height: 16.0),
              ],
            ),
        ],
      ),
    );
  }
}
