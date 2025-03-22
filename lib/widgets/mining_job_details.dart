import 'package:flutter/material.dart';
import '../models/mining_job.dart';
import '../services/mining_service.dart';

class MiningJobDetails extends StatefulWidget {
  final MiningJob job;

  const MiningJobDetails({super.key, required this.job});

  @override
  State<MiningJobDetails> createState() => _MiningJobDetailsState();
}

class _MiningJobDetailsState extends State<MiningJobDetails> {
  bool _isRebroadcasting = false;
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
            if (widget.job.completed && widget.job.successful && widget.job.foundNonce != null)
              Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: ElevatedButton.icon(
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
