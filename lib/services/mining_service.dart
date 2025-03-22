import 'dart:async';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';
import '../models/mining_job.dart';
import '../services/mining_job_service.dart';
import '../services/node_service.dart';
import '../utils/hash_utils.dart';

class MiningService {
  final Map<String, Isolate> _isolates = {};
  final Map<String, SendPort> _sendPorts = {};
  final Map<String, ReceivePort> _receivePorts = {};
  final Map<String, StreamSubscription> _receiveStreams = {};
  final Map<String, bool> _pausedJobs = {};
  final Map<String, double> _speedMultipliers = {};
  final Map<String, MiningJob> _activeJobs = {};
  final _nodeService = NodeService();
  final _jobService = MiningJobService();

  static double _calculateHashRate(int hashesChecked, DateTime startTime) {
    final duration = DateTime.now().difference(startTime).inSeconds;
    return duration > 0 ? hashesChecked / duration : 0;
  }

  static double _calculateProgress(int currentNonce, int startNonce, int endNonce) {
    if (endNonce == -1) return 0.0;
    return (currentNonce - startNonce) / (endNonce - startNonce).toDouble();
  }

  static double _calculateRemainingTime(
    int currentNonce, int startNonce, int endNonce, int hashesChecked, DateTime startTime) {
    if (endNonce == -1) return double.infinity;
    final hashRate = _calculateHashRate(hashesChecked, startTime);
    return (endNonce - currentNonce) / (hashRate > 0 ? hashRate : 1);
  }

  // This method will directly start or resume a mining job
  // We'll use a simpler approach without isolates to ensure reliable pause/resume
  Future<void> startMining({
    required String jobId,
    required String content,
    required String leader,
    required String owner,
    required int height,
    required String rewardType, // Kept as string '0' or '1' per memory requirement
    required int difficulty,
    required List<int> nonceRange,
    required Function(Map<String, dynamic>) onUpdate,
  }) async {
    debugPrint('Creating new mining job: $jobId');
    
    // Stop any existing job with this ID first
    stopMining(jobId);
    
    // Check if job already exists in storage
    int startNonce = nonceRange[0];
    final existingJob = await _jobService.getJob(jobId);
    
    // If the job exists and has a lastTriedNonce, use that as the starting point
    if (existingJob != null && existingJob.lastTriedNonce > startNonce) {
      debugPrint('Resuming from last tried nonce: ${existingJob.lastTriedNonce}');
      startNonce = existingJob.lastTriedNonce;
    }
    
    // Create a job for the database
    final job = MiningJob(
      id: jobId,
      content: content,
      leader: leader,
      owner: owner,
      height: height,
      rewardType: rewardType, // Store as string '0' or '1' per memory requirement
      difficulty: difficulty,
      startNonce: nonceRange[0],
      endNonce: nonceRange.length > 1 ? nonceRange[1] : -1,
      startTime: DateTime.now(),
      lastTriedNonce: startNonce, // Initialize with the start nonce
    );

    // Save to database
    await _jobService.addJob(job);
    _activeJobs[jobId] = job;
    
    // Create communication channels
    final receivePort = ReceivePort();
    final completer = Completer<void>();
    
    // Start the mining isolate
    final isolate = await Isolate.spawn(
      _miningIsolate,
      {
        'sendPort': receivePort.sendPort,
        'jobId': jobId,
        'content': content,
        'leader': leader,
        'height': height,
        'owner': owner,
        'rewardType': rewardType, // Keep as string '0' or '1' per memory requirement
        'difficulty': difficulty,
        'startNonce': startNonce, // Use the potentially updated start nonce
        'endNonce': nonceRange.length > 1 ? nonceRange[1] : -1,
        'startPaused': false, // Start UNPAUSED by default
      },
    );
    
    // Store references
    _isolates[jobId] = isolate;
    _receivePorts[jobId] = receivePort;
    _pausedJobs[jobId] = false;
    _speedMultipliers[jobId] = 1.0;

    debugPrint('Mining started for job: $jobId');
    debugPrint('- Content: $content');
    debugPrint('- Leader: $leader');
    debugPrint('- Height: $height');
    debugPrint('- Owner: $owner');
    debugPrint('- Reward Type: $rewardType');
    debugPrint('- Difficulty: $difficulty');
    debugPrint('- Start Nonce: $startNonce'); // Log the actual start nonce
    debugPrint('- End Nonce: ${nonceRange.length > 1 ? nonceRange[1] : "Unlimited"}');

    // Set up communication with the isolate
    final subscription = receivePort.listen((message) async {
      if (message is Map<String, dynamic> && message.containsKey('port')) {
        _sendPorts[jobId] = message['port'] as SendPort;
        completer.complete();
      }

      // Forward updates to the callback
      if (message is Map<String, dynamic> && message.containsKey('status')) {
        // Add job ID to the message
        message['jobId'] = jobId;
        
        // Update the last tried nonce if present
        if (message.containsKey('currentNonce')) {
          final currentNonce = message['currentNonce'] as int;
          final updatedJob = _activeJobs[jobId]?.copyWith(
            lastTriedNonce: currentNonce,
          );
          
          if (updatedJob != null) {
            _activeJobs[jobId] = updatedJob;
            // Periodically save the last tried nonce (e.g., every 1000 nonces)
            if (currentNonce % 1000 == 0) {
              await _jobService.updateJob(updatedJob);
            }
          }
        }
        
        onUpdate(message);

        // For 'found' or 'completed' status, update the job in storage
        if (message['status'] == 'found' || message['status'] == 'completed') {
          // Update job status in storage
          _jobService.getJob(jobId).then((storedJob) {
            if (storedJob != null) {
              final updatedJob = storedJob.copyWith(
                endTime: DateTime.now(),
                lastTriedNonce: message.containsKey('currentNonce') ? 
                    message['currentNonce'] as int : storedJob.lastTriedNonce,
                completed: true, // Mark as completed
                successful: message['status'] == 'found', // Mark as successful if solution found
              );
              _jobService.updateJob(updatedJob);
              
              // Remove from active jobs
              _activeJobs.remove(jobId);
            }
          });

          // For 'found' status, broadcast the solution
          if (message['status'] == 'found' && message.containsKey('solution')) {
            final solution = message['solution'] as Map<String, dynamic>;
            final nonce = solution['nonce'] as int;
            final hash = solution['hash'] as String;
            
            // Get the existing job first
            final existingJob = await _jobService.getJob(jobId);
            if (existingJob != null) {
              // Update the job with the found solution
              final updatedJob = existingJob.copyWith(
                foundNonce: nonce,
                foundHash: hash,
                successful: true,
                completed: true,
                endTime: DateTime.now(),
                lastTriedNonce: nonce,
              );
              
              await _jobService.updateJob(updatedJob);
              
              // Remove from active jobs
              _activeJobs.remove(jobId);
              
              final ticket = HashUtils.ticketToHex(
                existingJob.content,
                existingJob.leader,
                existingJob.height,
                existingJob.owner,
                int.parse(existingJob.rewardType), // Convert string to int for HashUtils per memory requirement
                DateTime.now().millisecondsSinceEpoch ~/ 1000,
                nonce,
              );

              _nodeService.broadcastRawSupportTicket(ticket);
            }
          }
        }
      }
    });

    _receiveStreams[jobId] = subscription;
    
    // Wait for the isolate to initialize before returning
    await completer.future;
  }

  // Simple toggle pause that ensures the state is synchronized
  // Returns true if successful, false if the job was not found
  Future<bool> togglePause(String jobId) async {
    // Debug all active jobs and isolates
    debugPrint('Active isolates: ${_isolates.keys.join(', ')}');
    debugPrint('Active jobs: ${_activeJobs.keys.join(', ')}');
    
    if (!_isolates.containsKey(jobId)) {
      debugPrint('Cannot toggle pause: Mining job not found: $jobId');
      return false;
    }
    
    // Toggle the pause state
    final wasPaused = _pausedJobs[jobId] ?? false;
    final newState = !wasPaused;
    _pausedJobs[jobId] = newState;
    
    // Send the new state to the isolate
    debugPrint('Toggling pause state to: ${newState ? 'PAUSED' : 'RUNNING'} for job: $jobId');
    _sendPorts[jobId]?.send({'command': newState ? 'pause' : 'resume'});
    
    return true;
  }

  void stopMining(String jobId) {
    final isolate = _isolates[jobId];
    final sendPort = _sendPorts[jobId];

    if (isolate != null && sendPort != null) {
      debugPrint('Stopping mining job: $jobId');
      sendPort.send({'command': 'stop'});
      isolate.kill(priority: Isolate.immediate);
      _isolates.remove(jobId);
      _sendPorts.remove(jobId);
      _receiveStreams[jobId]?.cancel();
      _receiveStreams.remove(jobId);
      _pausedJobs.remove(jobId);
      _speedMultipliers.remove(jobId);
      _activeJobs.remove(jobId);
    }
  }

  void dispose() {
    for (final jobId in _isolates.keys.toList()) {
      stopMining(jobId);
    }
  }

  void updateSpeed(String jobId, double multiplier) {
    _speedMultipliers[jobId] = multiplier;
    // Only send command if we have an active send port
    if (_sendPorts.containsKey(jobId)) {
      _sendPorts[jobId]?.send({'command': 'speed', 'value': multiplier});
    }
  }

  static void _miningIsolate(Map<String, dynamic> params) {
    final sendPort = params['sendPort'] as SendPort;
    final jobId = params['jobId'] as String;
    final content = params['content'] as String;
    final leader = params['leader'] as String;
    final height = params['height'] as int;
    final owner = params['owner'] as String;
    final rewardType = params['rewardType'] as String; // Keep as string '0' or '1'
    final difficulty = params['difficulty'] as int;
    final startNonce = params['startNonce'] as int;
    final endNonce = params['endNonce'] as int;
    final startPaused = params['startPaused'] as bool? ?? false;

    // Create a port for receiving commands
    final receivePort = ReceivePort();
    sendPort.send({'port': receivePort.sendPort});

    bool isPaused = startPaused;
    int currentNonce = startNonce;
    int hashesChecked = 0;
    final startTime = DateTime.now();
    bool shouldStop = false;

    // Send initial status update
    sendPort.send({
      'status': 'running',
      'progress': 0.0,
      'hashRate': 0.0,
      'remainingTime': 0.0,
      'isPaused': isPaused,
      'currentNonce': currentNonce, // Include current nonce in status updates
    });

    // Listen for commands
    receivePort.listen((message) {
      if (message is Map<String, dynamic> && message.containsKey('command')) {
        final command = message['command'] as String;
        
        if (command == 'pause') {
          debugPrint('Mining isolate received pause command for job: $jobId');
          isPaused = true;
          sendPort.send({
            'status': 'paused',
            'isPaused': true,
            'currentNonce': currentNonce, // Include current nonce in status updates
          });
        } else if (command == 'resume') {
          debugPrint('Mining isolate received resume command for job: $jobId');
          isPaused = false;
          sendPort.send({
            'status': 'running',
            'isPaused': false,
            'currentNonce': currentNonce, // Include current nonce in status updates
          });
        } else if (command == 'stop') {
          debugPrint('Mining isolate received stop command for job: $jobId');
          shouldStop = true;
        }
      }
    });

    // Mining loop
    Timer.periodic(const Duration(milliseconds: 100), (timer) async {
      if (shouldStop) {
        timer.cancel();
        receivePort.close();
        return;
      }

      if (isPaused) {
        // Skip processing while paused, but continue sending status updates
        sendPort.send({
          'status': 'running',
          'progress': _calculateProgress(currentNonce, startNonce, endNonce),
          'hashRate': _calculateHashRate(hashesChecked, startTime),
          'remainingTime': _calculateRemainingTime(
            currentNonce, startNonce, endNonce, hashesChecked, startTime),
          'isPaused': true,
          'currentNonce': currentNonce, // Include current nonce in status updates
        });
        return;
      }

      // Process a batch of nonces
      const batchSize = 1000;
      for (int i = 0; i < batchSize; i++) {
        if (shouldStop || isPaused) break;

        // Check if we've reached the end nonce
        if (endNonce != -1 && currentNonce > endNonce) {
          timer.cancel();
          receivePort.close();
          
          // Send completed status
          sendPort.send({
            'status': 'completed',
            'progress': 1.0,
            'hashRate': _calculateHashRate(hashesChecked, startTime),
            'remainingTime': 0.0,
            'currentNonce': currentNonce,
            'isPaused': false,
          });
          return;
        }

        // Try to create a ticket with the current nonce
        try {
          final rewardTypeInt = int.parse(rewardType); // Convert string to int for HashUtils
          final hash = HashUtils.createTicket(
            content,
            leader,
            height,
            owner,
            rewardTypeInt, // Pass as int to HashUtils per memory requirement
            DateTime.now().millisecondsSinceEpoch ~/ 1000,
            currentNonce,
          );

          // Check if the hash meets the difficulty requirement
          final targetPrefix = '0' * difficulty;
          final found = hash.startsWith(targetPrefix);

          if (found) {
            // Solution found
            timer.cancel();
            sendPort.send({
              'status': 'found',
              'solution': {
                'nonce': currentNonce,
                'hash': hash,
              },
              'isPaused': false,
              'currentNonce': currentNonce, // Include current nonce in status updates
            });
            receivePort.close();
            return;
          }
        } catch (e) {
          debugPrint('Error in mining isolate: $e');
        }

        currentNonce++;
        hashesChecked++;
      }

      // Send status update
      final progress = _calculateProgress(currentNonce, startNonce, endNonce);
      final hashRate = _calculateHashRate(hashesChecked, startTime);
      final remainingTime = _calculateRemainingTime(
        currentNonce, startNonce, endNonce, hashesChecked, startTime);

      sendPort.send({
        'status': 'running',
        'progress': progress,
        'hashRate': hashRate,
        'remainingTime': remainingTime,
        'hashesChecked': hashesChecked,
        'isPaused': false,
        'currentNonce': currentNonce, // Include current nonce in status updates
      });
    });
  }

  // Expose job retrieval from the job service
  Future<MiningJob?> getJob(String jobId) async {
    return await _jobService.getJob(jobId);
  }

  // Get all active jobs that are not successful
  Future<List<MiningJob>> getActiveJobs() async {
    return await _jobService.getNonSuccessfulActiveJobs();
  }

  Future<List<MiningJob>> getAllJobs() => _jobService.getAllJobs();

  Future<void> updateJob(MiningJob job) => _jobService.updateJob(job);

  Future<void> reBroadcastTicket(String jobId) async {
    final job = await _jobService.getJob(jobId);
    if (job == null || !job.completed || !job.successful || job.foundNonce == null) {
      throw Exception('Cannot re-broadcast: Invalid job state');
    }

    try {
      debugPrint(' Re-broadcasting ticket:');
      debugPrint('  Content: ${job.content}');
      debugPrint('  Leader: ${job.leader}');
      debugPrint('  Height: ${job.height}');
      debugPrint('  Owner: ${job.owner}');
      debugPrint('  Reward Type: ${job.rewardType}');
      debugPrint('  Nonce: ${job.foundNonce!}'); // Force unwrap since we validated it's not null
      
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      debugPrint('  Timestamp: $timestamp');

      final ticketHex = HashUtils.ticketToHex(
        job.content,
        job.leader,
        job.height,
        job.owner,
        int.parse(job.rewardType), // Convert to int for HashUtils
        timestamp,
        job.foundNonce!, // Force unwrap since we validated it's not null
      );
      debugPrint('  Generated Ticket Hex: $ticketHex');

      final broadcastResponse = await _nodeService.broadcastRawSupportTicket(ticketHex);
      
      await _jobService.updateJob(MiningJob(
        id: job.id,
        content: job.content,
        leader: job.leader,
        owner: job.owner,
        height: job.height,
        rewardType: job.rewardType,
        difficulty: job.difficulty,
        startNonce: job.startNonce,
        endNonce: job.endNonce,
        startTime: job.startTime,
        endTime: job.endTime,
        foundNonce: job.foundNonce,
        foundHash: job.foundHash,
        completed: true,
        successful: true,
        broadcastSuccessful: true,
        broadcastHash: broadcastResponse.hash,
      ));

      debugPrint(' Re-broadcast successful:');
      debugPrint('  Job ID: $jobId');
      debugPrint('  Broadcast Hash: ${broadcastResponse.hash}');
    } catch (e) {
      debugPrint(' Error re-broadcasting solution:');
      debugPrint('  Error: $e');

      await _jobService.updateJob(MiningJob(
        id: job.id,
        content: job.content,
        leader: job.leader,
        owner: job.owner,
        height: job.height,
        rewardType: job.rewardType,
        difficulty: job.difficulty,
        startNonce: job.startNonce,
        endNonce: job.endNonce,
        startTime: job.startTime,
        endTime: job.endTime,
        foundNonce: job.foundNonce,
        foundHash: job.foundHash,
        completed: true,
        successful: true,
        broadcastSuccessful: false,
        broadcastError: e.toString(),
      ));

      throw e;
    }
  }

  // Stop all mining jobs and clear history
  Future<void> clearAllJobs() async {
    // First stop all active mining jobs
    final activeJobIds = List<String>.from(_activeJobs.keys);
    for (final jobId in activeJobIds) {
      stopMining(jobId);
    }
    
    // Clear all jobs from storage
    await _jobService.clearAllJobs();
    
    // Clear local state
    _activeJobs.clear();
    _pausedJobs.clear();
    _speedMultipliers.clear();
  }
}
