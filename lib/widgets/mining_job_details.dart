import 'package:flutter/material.dart';
import '../models/mining_job.dart';
import '../services/mining_service.dart';
import '../main.dart'; // Import for MinerAppHome
import 'package:provider/provider.dart'; // Re-add provider import

class MiningJobDetails extends StatefulWidget {
  final MiningJob job;
  final bool showActions;

  // Static method to notify the main screen about job updates without context
  static void _notifyMainScreenOfJob(Map<String, dynamic> jobData) {
    // Use the static callback in MinerAppHome to send the update
    // This avoids context issues when the widget is unmounted
    debugPrint('Sending job update to main screen: ${jobData['jobId']}');
    MinerAppHome.sendJobUpdate(jobData);
  }

  const MiningJobDetails({
    Key? key,
    required this.job,
    this.showActions = true,
  }) : super(key: key);

  @override
  State<MiningJobDetails> createState() => _MiningJobDetailsState();
}

class _MiningJobDetailsState extends State<MiningJobDetails> {
  bool _isRebroadcasting = false;
  bool _isContinuing = false;
  final _miningService = MiningService();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Job ${widget.job.id}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            _buildDetailRow('Status', _getStatusText()),
            _buildDetailRow('Duration', widget.job.duration?.toString() ?? 'In Progress'),
            _buildDetailRow('Content', widget.job.content),
            _buildDetailRow('Leader', widget.job.leader),
            _buildDetailRow('Owner', widget.job.owner),
            _buildDetailRow('Height', widget.job.height.toString()),
            _buildDetailRow('Reward Type', _getRewardTypeText(widget.job.rewardType)),
            _buildDetailRow('Difficulty', widget.job.difficulty.toString()),
            _buildDetailRow('Nonce Range', '${widget.job.startNonce} - ${widget.job.endNonce}'),
            if (widget.job.foundNonce != null) _buildDetailRow('Found Nonce', widget.job.foundNonce.toString()),
            if (widget.job.foundHash != null) _buildDetailRow('Found Hash', widget.job.foundHash!),
            if (widget.job.broadcastSuccessful && widget.job.broadcastHash != null)
              _buildDetailRow('Broadcast Hash', widget.job.broadcastHash!),
            if (widget.job.broadcastError != null)
              _buildDetailRow('Broadcast Error', widget.job.broadcastError!, isError: true),
            if (widget.job.error != null)
              _buildDetailRow('Error', widget.job.error!, isError: true),
              
            // Action buttons section
            Padding(
              padding: const EdgeInsets.only(top: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  // Continue button for incomplete jobs
                  if (!widget.job.completed)
                    Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: ElevatedButton.icon(
                        onPressed: _isContinuing ? null : _continueJob,
                        icon: _isContinuing 
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                        label: Text(_isContinuing ? 'Continuing...' : 'Continue Job'),
                      ),
                    ),
                    
                  // Re-broadcast button for completed successful jobs
                  if (widget.job.completed && widget.job.successful && widget.job.foundNonce != null)
                    ElevatedButton.icon(
                      onPressed: _isRebroadcasting ? null : _reBroadcast,
                      icon: _isRebroadcasting 
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                      label: Text(_isRebroadcasting ? 'Re-Broadcasting...' : 'Re-Broadcast Ticket'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _reBroadcast() async {
    try {
      setState(() {
        _isRebroadcasting = true;
      });

      await _miningService.reBroadcastTicket(widget.job.id);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ticket re-broadcast successful'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to re-broadcast: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isRebroadcasting = false;
        });
      }
    }
  }
  
  /// Continue an incomplete job from history
  Future<void> _continueJob() async {
    try {
      setState(() {
        _isContinuing = true;
      });
      
      // Get the job from storage to ensure we have the latest state
      final job = await _miningService.getJob(widget.job.id);
      
      if (job == null) {
        throw Exception('Job not found');
      }
      
      if (job.completed) {
        throw Exception('Cannot continue a completed job');
      }
      
      // Start the job with the same parameters, resuming from the last tried nonce
      await _miningService.startMining(
        jobId: job.id,
        content: job.content,
        leader: job.leader,
        owner: job.owner,
        height: job.height,
        rewardType: job.rewardType,
        difficulty: job.difficulty,
        startNonce: job.startNonce,
        endNonce: job.endNonce,
        resumeFromNonce: job.lastTriedNonce,
        onUpdate: (update) {
          // This callback will be called with updates from the mining service
          debugPrint('Job ${job.id} update: ${update['status']}');
          
          // Only send valid updates to the main screen
          // Null updates or updates without a status should be ignored
          if (update != null && update['status'] != null) {
            // Store the job information for the main screen to use later
            // We'll use a static method to avoid context issues after widget is unmounted
            MiningJobDetails._notifyMainScreenOfJob({
              'jobId': job.id,
              'status': update['status'],
              'content': job.content,
              'leader': job.leader,
              'owner': job.owner,
              'height': job.height,
              'rewardType': job.rewardType,
              'difficulty': job.difficulty,
              'startNonce': job.startNonce,
              'endNonce': job.endNonce,
              'currentNonce': update['currentNonce'] ?? job.lastTriedNonce,
              'progress': update['progress'] ?? 0.0,
              'hashRate': update['hashRate'] ?? 0.0,
              'remainingTime': update['remainingTime'] ?? 0.0,
              // Use a fixed number of workers to avoid instability
              'activeWorkers': job.workerLastNonces?.length ?? 1,
            });
          }
        },
      );
      
      if (!mounted) return;
      
      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Job ${job.id} continued successfully'),
          backgroundColor: Colors.green,
        ),
      );
      
      // Create a manual job update to ensure it appears in the main screen immediately
      final jobUpdate = {
        'jobId': job.id,
        'status': 'progress',
        'content': job.content,
        'leader': job.leader,
        'owner': job.owner,
        'height': job.height,
        'rewardType': job.rewardType,
        'difficulty': job.difficulty,
        'startNonce': job.startNonce,
        'endNonce': job.endNonce,
        'currentNonce': job.lastTriedNonce,
        'progress': 0.0,
        'hashRate': 0.0,
        'remainingTime': 0.0,
        'activeWorkers': job.workerLastNonces?.length ?? 1,
      };
      
      // Send the update directly to the main screen
      MinerAppHome.sendJobUpdate(jobUpdate);
      
      // Navigate back to the home screen to see the job in progress
      Navigator.of(context).popUntil((route) => route.isFirst);
      
      // Refresh the main screen's job list to show the continued job
      // This is critical to ensure the job appears in the main screen
      final homeState = MinerAppHome.of(context);
      if (homeState != null) {
        debugPrint('Refreshing main screen job list after continuing job ${job.id}');
        homeState.refreshActiveJobs();
      } else {
        debugPrint('Warning: Could not find MinerAppHome state to refresh jobs');
      }
      
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to continue job: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isContinuing = false;
        });
      }
    }
  }

  String _getStatusText() {
    if (!widget.job.completed) return 'In Progress';
    if (widget.job.successful) {
      if (widget.job.broadcastSuccessful) return 'Completed - Solution Found and Broadcast';
      if (widget.job.broadcastError != null) return 'Completed - Solution Found but Broadcast Failed';
      return 'Completed - Solution Found';
    }
    if (widget.job.error != null) return 'Failed';
    return 'Completed - No Solution Found';
  }

  String _getRewardTypeText(String rewardType) {
    // Per memory requirement: '0' for Reputation Points, '1' for Coins
    switch (rewardType) {
      case '0':
        return 'Reputation Points';
      case '1':
        return 'Coins';
      default:
        return 'Unknown';
    }
  }

  Widget _buildDetailRow(String label, String value, {bool isError = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: isError ? const TextStyle(color: Colors.red) : null,
            ),
          ),
        ],
      ),
    );
  }
}
