import 'package:flutter/material.dart';
import 'package:miner_app/models/mining_job.dart';

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
  bool _isDetailsExpanded = true; // Track if details are expanded
  bool _isWorkersExpanded = true; // Track if worker details are expanded
  
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
    
    // Calculate completion percentage for display
    final completionPercentage = (progress * 100).toStringAsFixed(2);
    
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
                  onPressed: widget.isPaused ? widget.onResume : widget.onPause,
                  tooltip: widget.isPaused ? 'Resume Mining' : 'Pause Mining',
                ),
                // Stop button
                IconButton(
                  icon: const Icon(
                    Icons.stop,
                    color: Colors.red,
                  ),
                  onPressed: widget.onStop,
                  tooltip: 'Stop Mining',
                ),
              ],
            ),
          ),
          
          // Progress bar - only show if the job has an end nonce
          if (hasEndNonce) ...[  
            LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(
                widget.isPaused ? Colors.orange : Colors.green,
              ),
            ),
          ],
          
          // Summary stats (always visible)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Nonce: $lastTriedNonce',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  'Hash Rate: ${_formatHashRate(hashRate)}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  'Workers: ${widget.activeWorkers}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          
          // Expandable details section header
          InkWell(
            onTap: () {
              setState(() {
                _isDetailsExpanded = !_isDetailsExpanded;
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: Row(
                children: [
                  const Text('Mining Details', style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Icon(_isDetailsExpanded ? Icons.expand_less : Icons.expand_more, size: 20),
                ],
              ),
            ),
          ),
          
          // Divider
          const Divider(height: 1),
          
          // Details section (collapsible)
          if (_isDetailsExpanded)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Job details
                  Row(
                    children: [
                      Expanded(
                        child: _buildStatItem('Current Nonce', '$lastTriedNonce'),
                      ),
                      if (hasEndNonce)
                        Expanded(
                          child: _buildStatItem('Est. Time', _formatDuration(remainingTime)),
                        ),
                    ],
                  ),
                  
                  // Progress info (only if end nonce is set)
                  if (hasEndNonce) ...[  
                    const SizedBox(height: 12.0),
                    Row(
                      children: [
                        Text('Progress: $completionPercentage%'),
                        const SizedBox(width: 8.0),
                        Expanded(
                          child: LinearProgressIndicator(
                            value: progress,
                            backgroundColor: Colors.grey.shade200,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              widget.isPaused ? Colors.orange : Colors.blue,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16.0),
                  
                  // Speed control
                  Row(
                    children: [
                      const Text('Mining Speed: '),
                      Expanded(
                        child: Slider(
                          value: _speedMultiplier,
                          min: 0.5,
                          max: 5.0,
                          divisions: 9,
                          label: '${_speedMultiplier}x',
                          onChanged: (value) {
                            setState(() {
                              _speedMultiplier = value;
                            });
                            widget.onSpeedChange(value);
                          },
                        ),
                      ),
                      Text('${_speedMultiplier}x'),
                    ],
                  ),
                  
                  // Job info
                  if (widget.job != null) ...[
                    const SizedBox(height: 16.0),
                    Text('Content: ${widget.job!.content.length > 20 ? widget.job!.content.substring(0, 20) + "..." : widget.job!.content}'),
                    const SizedBox(height: 8.0),
                    Text('Owner: ${widget.job!.owner}'),
                    const SizedBox(height: 8.0),
                    Text('Height: ${widget.job!.height}'),
                    const SizedBox(height: 8.0),
                    Text('Difficulty: ${widget.job!.difficulty}'),
                    const SizedBox(height: 8.0),
                    Text('Reward Type: ${widget.job!.rewardType == "1" ? "Coins" : "Reputation Points"}'),
                    if (hasEndNonce) ...[
                      const SizedBox(height: 8.0),
                      Text('Range: ${widget.job!.startNonce} - ${widget.job!.endNonce}'),
                    ],
                  ],
                ],
              ),
            ),
          
          // Worker details section header
          if (workerDetails.isNotEmpty) ...[
            InkWell(
              onTap: () {
                setState(() {
                  _isWorkersExpanded = !_isWorkersExpanded;
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                child: Row(
                  children: [
                    const Text('Worker Details', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Icon(_isWorkersExpanded ? Icons.expand_less : Icons.expand_more, size: 20),
                  ],
                ),
              ),
            ),
            
            // Divider
            const Divider(height: 1),
            
            // Worker details (collapsible)
            if (_isWorkersExpanded)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Table header
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
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
          ],
        ],
      ),
    );
  }
}
