import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';
import '../models/mining_job.dart';
import '../models/mining_worker.dart';
import '../services/mining_job_service.dart';
import '../services/node_service.dart';
import '../utils/hash_utils.dart';
import '../models/node_settings.dart'; // Import NodeSettings

class MiningService {
  static final MiningService _instance = MiningService._internal();
  final MiningJobService _jobService = MiningJobService();
  final NodeService _nodeService = NodeService();
  
  // Maps to track jobs and workers
  final Map<String, List<MiningWorker>> _jobWorkers = {}; // Maps jobId to its workers
  final Map<String, StreamSubscription<dynamic>> _receiveStreams = {};
  final Map<String, bool> _pausedJobs = {};
  final Map<String, double> _speedMultipliers = {};
  final Map<String, MiningJob> _activeJobs = {};
  final Map<String, List<double>> _hashRateHistory = {};
  final Map<String, double> _lastRemainingTimes = {};
  
  // Batch size configuration
  static const int _baseBatchSize = 5000; // Base number of nonces per batch
  static const int _minBatchSize = 1000;  // Minimum batch size
  
  final _lock = Lock();
  int _maxConcurrentJobs = 1;  // Default to 1 core

  factory MiningService() {
    return _instance;
  }

  MiningService._internal() {
    // Initialize the service
    _initializeService();
  }

  Future<void> _initializeService() async {
    // Load settings to get the number of CPU cores to use
    final settings = await NodeSettings.load();
    _maxConcurrentJobs = settings.cpuCores;
    debugPrint('Mining service initialized with $_maxConcurrentJobs CPU cores');
  }

  // Method to update CPU cores setting when it changes
  Future<void> updateCpuCores(int cores) async {
    _maxConcurrentJobs = cores;
    debugPrint('Updated mining service to use $cores CPU cores');
  }

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

  // This method will start a mining job with multiple workers
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
    int? resumeFromNonce,
  }) async {
    await _lock.synchronized(() async {
      if (_jobWorkers.length >= _maxConcurrentJobs) {
        debugPrint('Maximum number of concurrent jobs ($_maxConcurrentJobs) reached. Cannot start new job.');
        return;
      }

      // Check if this job is already running
      if (_jobWorkers.containsKey(jobId)) {
        debugPrint('Job $jobId is already running');
        return;
      }

      final startNonce = nonceRange[0];
      final endNonce = nonceRange[1];
      
      // Determine the actual starting nonce based on resumeFromNonce or the job's last tried nonce
      int actualStartNonce = startNonce;
      
      // If resumeFromNonce is provided, use it
      if (resumeFromNonce != null && resumeFromNonce > startNonce) {
        actualStartNonce = resumeFromNonce;
        debugPrint('Resuming job $jobId from nonce $actualStartNonce');
      } else {
        // Otherwise, check if we have a saved job to resume from
        try {
          final savedJob = await _jobService.getJob(jobId);
          if (savedJob != null && savedJob.lastTriedNonce > startNonce) {
            actualStartNonce = savedJob.lastTriedNonce;
            debugPrint('Resuming job $jobId from saved nonce $actualStartNonce');
          }
        } catch (e) {
          debugPrint('Error checking for saved job state: $e');
        }
      }

      // Create a new job or update an existing one
      MiningJob job;
      try {
        final existingJob = await _jobService.getJob(jobId);
        if (existingJob != null) {
          // Update the existing job
          job = MiningJob(
            id: jobId,
            content: content,
            leader: leader,
            owner: owner,
            height: height,
            rewardType: rewardType, // Keep as string '0' or '1'
            difficulty: difficulty,
            startNonce: startNonce,
            endNonce: endNonce,
            startTime: existingJob.startTime,
            lastTriedNonce: actualStartNonce,
          );
          await _jobService.updateJob(job);
        } else {
          // Create a new job
          job = MiningJob(
            id: jobId,
            content: content,
            leader: leader,
            owner: owner,
            height: height,
            rewardType: rewardType, // Keep as string '0' or '1'
            difficulty: difficulty,
            startNonce: startNonce,
            endNonce: endNonce,
            startTime: DateTime.now(),
            lastTriedNonce: actualStartNonce,
          );
          await _jobService.addJob(job);
        }
      } catch (e) {
        debugPrint('Error creating or updating job: $e');
        onUpdate({
          'jobId': jobId,
          'status': 'error',
          'message': 'Failed to create or update job: $e',
        });
        return;
      }

      // Store the job in memory
      _activeJobs[jobId] = job;
      _pausedJobs[jobId] = false;
      _speedMultipliers[jobId] = 1.0;
      _hashRateHistory[jobId] = [];
      _lastRemainingTimes[jobId] = 0.0;

      // Initialize workers list for this job
      _jobWorkers[jobId] = [];

      // Determine the number of workers to create based on available cores
      final int numWorkers = Platform.numberOfProcessors > 1 
          ? _maxConcurrentJobs 
          : 1;
      
      debugPrint('Starting mining job $jobId with $numWorkers workers');
      debugPrint('  Content: $content');
      debugPrint('  Leader: $leader');
      debugPrint('  Owner: $owner');
      debugPrint('  Height: $height');
      debugPrint('  Reward Type: $rewardType'); // Log as string '0' or '1'
      debugPrint('  Difficulty: $difficulty');
      debugPrint('  Nonce Range: $actualStartNonce to $endNonce');

      // Create workers
      for (int i = 0; i < numWorkers; i++) {
        try {
          await _createWorker(
            jobId: jobId,
            workerId: i,
            content: content,
            leader: leader,
            height: height,
            owner: owner,
            rewardType: rewardType, // Pass as string '0' or '1'
            difficulty: difficulty,
            startNonce: actualStartNonce + (i * ((endNonce - actualStartNonce) ~/ numWorkers)),
            endNonce: i == numWorkers - 1 
                ? endNonce 
                : actualStartNonce + ((i + 1) * ((endNonce - actualStartNonce) ~/ numWorkers)) - 1,
            onUpdate: (workerUpdate) {
              _handleWorkerUpdate(workerUpdate, jobId, onUpdate);
            },
            onSolution: (solution) {
              _handleSolution(solution, jobId, job, onUpdate);
            },
          );
        } catch (e) {
          debugPrint('Error creating worker $i for job $jobId: $e');
        }
      }

      // Start periodic updates for the UI
      Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!_jobWorkers.containsKey(jobId)) {
          timer.cancel();
          return;
        }

        // Check if all workers have completed
        final workers = _jobWorkers[jobId]!;
        if (workers.isEmpty) {
          timer.cancel();
          return;
        }

        // Check if any worker is still active
        final anyActive = workers.any((w) => w.status == 'running');
        if (!anyActive) {
          timer.cancel();
          
          // Mark the job as completed if all workers are done
          _completeJob(jobId, false, null, null, onUpdate);
          return;
        }

        // Send aggregated update to the UI
        onUpdate({
          'jobId': jobId,
          'status': 'progress',
          ..._calculateAggregateStats(jobId),
          'isPaused': _pausedJobs[jobId] ?? false,
        });
      });
    });
  }

  // Assign a new batch of nonces to a worker that has completed its previous batch
  void _assignNextBatch(String jobId, int workerId) {
    if (!_jobWorkers.containsKey(jobId)) return;
    
    final workerIndex = _jobWorkers[jobId]!.indexWhere((w) => w.id == workerId);
    if (workerIndex < 0) return;
    
    final worker = _jobWorkers[jobId]![workerIndex];
    final job = _activeJobs[jobId];
    if (job == null) return;
    
    // Find the highest nonce processed by any worker
    final highestNonce = _jobWorkers[jobId]!.fold(
      job.startNonce, 
      (max, w) => w.lastProcessedNonce > max ? w.lastProcessedNonce : max
    );
    
    // Calculate a new batch for this worker
    final batchSize = (_baseBatchSize * (_speedMultipliers[jobId] ?? 1.0)).round();
    final newBatchStart = highestNonce + 1;
    final newBatchEnd = job.endNonce > 0 && newBatchStart + batchSize > job.endNonce 
        ? job.endNonce 
        : newBatchStart + batchSize;
    
    // If we've reached the end nonce, mark this worker as inactive
    if (job.endNonce > 0 && newBatchStart >= job.endNonce) {
      _jobWorkers[jobId]![workerIndex] = worker.copyWith(isActive: false);
      return;
    }
    
    // Update the worker with the new batch
    _jobWorkers[jobId]![workerIndex] = worker.copyWith(
      currentBatchStart: newBatchStart,
      currentBatchEnd: newBatchEnd,
      lastProcessedNonce: newBatchStart,
    );
    
    // Send the new batch to the worker
    worker.sendPort?.send({
      'command': 'newBatch',
      'startNonce': newBatchStart,
      'endNonce': newBatchEnd,
    });
  }

  // Stop all workers for a job except the one that found the solution
  void _stopAllWorkersExcept(String jobId, int exceptWorkerId) {
    if (!_jobWorkers.containsKey(jobId)) return;
    
    debugPrint('Stopping all workers for job $jobId except worker $exceptWorkerId');
    
    // Use a synchronized lock to ensure all workers are stopped properly
    _lock.synchronized(() {
      // First send stop command to all workers
      for (final worker in _jobWorkers[jobId]!) {
        if (worker.id != exceptWorkerId) {
          try {
            worker.sendPort?.send({'command': 'stop'});
            debugPrint('Sent stop command to worker ${worker.id} for job $jobId');
          } catch (e) {
            debugPrint('Error sending stop command to worker ${worker.id}: $e');
          }
        }
      }
      
      // Then kill all isolates immediately
      for (final worker in _jobWorkers[jobId]!) {
        if (worker.id != exceptWorkerId) {
          try {
            worker.isolate?.kill(priority: Isolate.immediate);
            debugPrint('Killed isolate for worker ${worker.id} for job $jobId');
          } catch (e) {
            debugPrint('Error killing isolate for worker ${worker.id}: $e');
          }
        }
      }
      
      // Close all receive ports immediately
      for (final worker in _jobWorkers[jobId]!) {
        if (worker.id != exceptWorkerId) {
          try {
            worker.receivePort?.close();
            debugPrint('Closed receive port for worker ${worker.id} for job $jobId');
          } catch (e) {
            debugPrint('Error closing receive port for worker ${worker.id}: $e');
          }
        }
      }
      
      // Remove all workers except the one that found the solution
      _jobWorkers[jobId]!.removeWhere((worker) => worker.id != exceptWorkerId);
      
      // Set remaining worker as inactive to prevent further processing
      final remainingWorkerIndex = _jobWorkers[jobId]!.indexWhere((w) => w.id == exceptWorkerId);
      if (remainingWorkerIndex >= 0) {
        _jobWorkers[jobId]![remainingWorkerIndex] = _jobWorkers[jobId]![remainingWorkerIndex].copyWith(
          isActive: false,
          status: 'completed',
        );
        debugPrint('Set worker $exceptWorkerId for job $jobId as completed');
      }
      
      // Clean up other resources immediately
      _receiveStreams[jobId]?.cancel();
      _receiveStreams.remove(jobId);
      _speedMultipliers.remove(jobId);
      _hashRateHistory.remove(jobId);
      _lastRemainingTimes.remove(jobId);
      
      debugPrint('All workers for job $jobId have been stopped except worker $exceptWorkerId');
    });
  }

  // Simple toggle pause that ensures the state is synchronized
  // Returns true if successful, false if the job was not found
  Future<bool> togglePause(String jobId) async {
    // Debug all active jobs and isolates
    debugPrint('Active isolates: ${_jobWorkers.keys.join(', ')}');
    debugPrint('Active jobs: ${_activeJobs.keys.join(', ')}');
    
    if (!_jobWorkers.containsKey(jobId)) {
      debugPrint('Cannot toggle pause: Mining job not found: $jobId');
      return false;
    }
    
    // Toggle the pause state
    final wasPaused = _pausedJobs[jobId] ?? false;
    final newState = !wasPaused;
    _pausedJobs[jobId] = newState;
    
    // Send the new state to the isolate
    debugPrint('Toggling pause state to: ${newState ? 'PAUSED' : 'RUNNING'} for job: $jobId');
    _jobWorkers[jobId]!.forEach((worker) {
      worker.sendPort?.send({'command': newState ? 'pause' : 'resume'});
    });
    
    return true;
  }

  void stopMining(String jobId) {
    final workers = _jobWorkers[jobId];

    if (workers != null) {
      debugPrint('Stopping mining job: $jobId');
      workers.forEach((worker) {
        worker.sendPort?.send({'command': 'stop'});
        worker.isolate?.kill(priority: Isolate.immediate);
      });
      _jobWorkers.remove(jobId);
      _pausedJobs.remove(jobId);
      _speedMultipliers.remove(jobId);
      _activeJobs.remove(jobId);
    }
  }

  void dispose() {
    for (final jobId in _jobWorkers.keys.toList()) {
      stopMining(jobId);
    }
  }

  void updateSpeed(String jobId, double multiplier) {
    _speedMultipliers[jobId] = multiplier;
    // Only send command if we have an active send port
    if (_jobWorkers.containsKey(jobId)) {
      _jobWorkers[jobId]!.forEach((worker) {
        worker.sendPort?.send({'command': 'speed', 'value': multiplier});
      });
    }
  }

  // Create a worker for a mining job
  Future<void> _createWorker({
    required String jobId,
    required int workerId,
    required String content,
    required String leader,
    required int height,
    required String owner,
    required String rewardType, // Keep as string '0' or '1' per memory requirement
    required int difficulty,
    required int startNonce,
    required int endNonce,
    required Function(Map<String, dynamic>) onUpdate,
    required Function(Map<String, dynamic>) onSolution,
  }) async {
    // Create a receive port for the worker
    final receivePort = ReceivePort();
    
    // Create the worker
    final worker = MiningWorker(
      id: workerId,
      jobId: jobId,
      lastProcessedNonce: startNonce,
      currentBatchStart: startNonce,
      currentBatchEnd: endNonce,
      receivePort: receivePort,
      status: 'initializing',
    );
    
    // Add the worker to the job's worker list
    _jobWorkers[jobId]!.add(worker);
    
    // Start the worker isolate
    final isolate = await Isolate.spawn(
      _workerIsolate,
      {
        'sendPort': receivePort.sendPort,
        'workerId': workerId,
        'jobId': jobId,
        'content': content,
        'leader': leader,
        'height': height,
        'owner': owner,
        'rewardType': rewardType, // Pass as string '0' or '1'
        'difficulty': difficulty,
        'startNonce': startNonce,
        'endNonce': endNonce,
        'startPaused': _pausedJobs[jobId] ?? false,
        'speedMultiplier': _speedMultipliers[jobId] ?? 1.0,
      },
    );
    
    // Update the worker with the isolate
    final workerIndex = _jobWorkers[jobId]!.indexWhere((w) => w.id == workerId);
    if (workerIndex >= 0) {
      _jobWorkers[jobId]![workerIndex] = worker.copyWith(
        isolate: isolate,
        isActive: true,
      );
    }
    
    // Listen for messages from the worker
    receivePort.listen((message) {
      if (message is Map<String, dynamic>) {
        // Handle worker initialization
        if (message.containsKey('status') && message['status'] == 'initialized') {
          final sendPort = message['port'] as SendPort;
          final workerIndex = _jobWorkers[jobId]!.indexWhere((w) => w.id == workerId);
          if (workerIndex >= 0) {
            _jobWorkers[jobId]![workerIndex] = _jobWorkers[jobId]![workerIndex].copyWith(
              sendPort: sendPort,
              status: 'running',
            );
          }
        }
        // Handle worker updates
        else if (message.containsKey('status')) {
          // Pass to the update handler
          onUpdate(message);
          
          // Update worker status
          final workerIndex = _jobWorkers[jobId]!.indexWhere((w) => w.id == workerId);
          if (workerIndex >= 0) {
            _jobWorkers[jobId]![workerIndex] = _jobWorkers[jobId]![workerIndex].copyWith(
              lastProcessedNonce: message['currentNonce'] as int,
              status: message['status'] as String,
            );
          }
          
          // Handle solution found
          if (message['status'] == 'found') {
            onSolution(message);
          }
        }
      }
    });
    
    debugPrint('Created worker $workerId for job $jobId');
    debugPrint('  Nonce range: $startNonce to $endNonce');
  }
  
  // Handle worker update
  void _handleWorkerUpdate(Map<String, dynamic> update, String jobId, Function(Map<String, dynamic>) onUpdate) {
    // Update the worker's status
    final workerId = update['workerId'] as int;
    final workerIndex = _jobWorkers[jobId]?.indexWhere((w) => w.id == workerId) ?? -1;
    
    if (workerIndex >= 0) {
      final worker = _jobWorkers[jobId]![workerIndex];
      _jobWorkers[jobId]![workerIndex] = worker.copyWith(
        lastProcessedNonce: update['currentNonce'] as int,
        status: update['status'] as String,
      );
      
      // Update the job's last tried nonce if this is the highest
      if (update['currentNonce'] > (_activeJobs[jobId]?.lastTriedNonce ?? 0)) {
        final updatedJob = _activeJobs[jobId]?.copyWith(
          lastTriedNonce: update['currentNonce'] as int,
        );
        
        if (updatedJob != null) {
          _activeJobs[jobId] = updatedJob;
        }
      }
    }
    
    // Forward the update to the UI
    onUpdate({
      'jobId': jobId,
      'status': update['status'],
      ..._calculateAggregateStats(jobId),
      'isPaused': _pausedJobs[jobId] ?? false,
    });
  }
  
  // Handle solution found
  void _handleSolution(Map<String, dynamic> solution, String jobId, MiningJob job, Function(Map<String, dynamic>) onUpdate) {
    // Get solution details
    final nonce = solution['solution']['nonce'] as int;
    final hash = solution['solution']['hash'] as String;
    
    debugPrint('Solution found for job $jobId with nonce $nonce and hash $hash');
    
    // Immediately stop all workers for this job
    _stopAllWorkersExcept(jobId, solution['workerId'] as int);
    
    // Immediately remove job from active jobs to prevent further processing
    _activeJobs.remove(jobId);
    _pausedJobs.remove(jobId);
    
    // Immediately notify UI about the solution
    onUpdate({
      'jobId': jobId,
      'status': 'found',
      'solution': {
        'nonce': nonce,
        'hash': hash,
      },
      'isPaused': false,
    });
    
    // Use a synchronized lock to ensure job update is completed before any other operations
    _lock.synchronized(() async {
      try {
        // Update job in storage
        final storedJob = await _jobService.getJob(jobId);
        if (storedJob != null) {
          final updatedJob = MiningJob(
            id: storedJob.id,
            content: storedJob.content,
            leader: storedJob.leader,
            owner: storedJob.owner,
            height: storedJob.height,
            rewardType: storedJob.rewardType, // Keep as string '0' or '1'
            difficulty: storedJob.difficulty,
            startNonce: storedJob.startNonce,
            endNonce: storedJob.endNonce,
            startTime: storedJob.startTime,
            endTime: DateTime.now(),
            foundNonce: nonce,
            foundHash: hash,
            completed: true,
            successful: true,
            error: storedJob.error,
            broadcastSuccessful: storedJob.broadcastSuccessful,
            broadcastError: storedJob.broadcastError,
            broadcastHash: storedJob.broadcastHash,
            lastTriedNonce: nonce,
          );
          
          // Update in storage
          await _jobService.updateJob(updatedJob);
          debugPrint('Job $jobId marked as completed in storage');
        }
      } catch (e) {
        debugPrint('Error updating job $jobId in storage: $e');
      }
    });
    
    // Convert rewardType from string to int for HashUtils per memory requirement
    final ticket = HashUtils.ticketToHex(
      job.content,
      job.leader,
      job.height,
      job.owner,
      int.parse(job.rewardType), // Convert string to int for HashUtils
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      nonce,
    );
    
    // Broadcast the ticket
    _nodeService.broadcastRawSupportTicket(ticket);
  }
  
  // Mark a job as completed
  void _completeJob(String jobId, bool successful, int? foundNonce, String? foundHash, Function(Map<String, dynamic>) onUpdate) {
    // Get the job from storage
    _jobService.getJob(jobId).then((storedJob) async {
      if (storedJob != null) {
        // Create updated job
        final updatedJob = MiningJob(
          id: storedJob.id,
          content: storedJob.content,
          leader: storedJob.leader,
          owner: storedJob.owner,
          height: storedJob.height,
          rewardType: storedJob.rewardType, // Keep as string '0' or '1'
          difficulty: storedJob.difficulty,
          startNonce: storedJob.startNonce,
          endNonce: storedJob.endNonce,
          startTime: storedJob.startTime,
          endTime: DateTime.now(),
          foundNonce: foundNonce,
          foundHash: foundHash,
          completed: true,
          successful: successful,
          error: storedJob.error,
          broadcastSuccessful: storedJob.broadcastSuccessful,
          broadcastError: storedJob.broadcastError,
          broadcastHash: storedJob.broadcastHash,
          lastTriedNonce: foundNonce ?? storedJob.lastTriedNonce,
        );
        
        // Update in storage
        await _jobService.updateJob(updatedJob);
        
        // Remove from active jobs
        _activeJobs.remove(jobId);
        
        // Notify UI
        onUpdate({
          'jobId': jobId,
          'status': successful ? 'found' : 'completed',
          'solution': successful ? {
            'nonce': foundNonce,
            'hash': foundHash,
          } : null,
        });
      }
    });
  }

  // Worker isolate function
  static void _workerIsolate(Map<String, dynamic> params) {
    final sendPort = params['sendPort'] as SendPort;
    final workerId = params['workerId'] as int;
    final jobId = params['jobId'] as String;
    final content = params['content'] as String;
    final leader = params['leader'] as String;
    final height = params['height'] as int;
    final owner = params['owner'] as String;
    final rewardType = params['rewardType'] as String; // Keep as string '0' or '1' per memory requirement
    final difficulty = params['difficulty'] as int;
    int startNonce = params['startNonce'] as int;
    final endNonce = params['endNonce'] as int;
    bool isPaused = params['startPaused'] as bool;
    double speedMultiplier = params['speedMultiplier'] as double;
    
    int currentNonce = startNonce;
    int hashesChecked = 0;
    bool shouldStop = false;
    final startTime = DateTime.now();
    
    // For stable reporting
    final List<double> hashRateHistory = [];
    double lastReportedProgress = 0.0;
    double lastReportedHashRate = 0.0;
    double lastReportedRemainingTime = 0.0;
    DateTime lastReportTime = DateTime.now();
    
    // Create a receive port for communication from the main isolate
    final receivePort = ReceivePort();
    
    // Send the receive port to the main isolate
    sendPort.send({
      'workerId': workerId,
      'jobId': jobId,
      'port': receivePort.sendPort,
      'status': 'initialized',
    });
    
    // Listen for commands from the main isolate
    receivePort.listen((message) {
      if (message is Map<String, dynamic>) {
        final command = message['command'] as String?;
        
        if (command == 'stop') {
          shouldStop = true;
          receivePort.close();
        } else if (command == 'pause') {
          isPaused = true;
          
          // Send paused status update
          sendPort.send({
            'workerId': workerId,
            'jobId': jobId,
            'status': 'paused',
            'progress': _calculateProgress(currentNonce, startNonce, endNonce) * 100.0, // Convert to percentage
            'hashRate': _calculateStableHashRate(hashesChecked, startTime, hashRateHistory),
            'remainingTime': _calculateStableRemainingTime(
              currentNonce, startNonce, endNonce, hashesChecked, startTime, hashRateHistory),
            'isPaused': true,
            'currentNonce': currentNonce,
          });
        } else if (command == 'resume') {
          isPaused = false;
          
          // Send resumed status update
          sendPort.send({
            'workerId': workerId,
            'jobId': jobId,
            'status': 'running',
            'progress': _calculateProgress(currentNonce, startNonce, endNonce) * 100.0, // Convert to percentage
            'hashRate': _calculateStableHashRate(hashesChecked, startTime, hashRateHistory),
            'remainingTime': _calculateStableRemainingTime(
              currentNonce, startNonce, endNonce, hashesChecked, startTime, hashRateHistory),
            'isPaused': false,
            'currentNonce': currentNonce,
          });
        } else if (command == 'setSpeed') {
          final newSpeedMultiplier = message['speed'] as double;
          speedMultiplier = newSpeedMultiplier;
        } else if (command == 'newBatch') {
          final newStartNonce = message['startNonce'] as int;
          final newEndNonce = message['endNonce'] as int;
          currentNonce = newStartNonce;
          startNonce = newStartNonce;
          hashesChecked = 0;
          sendPort.send({
            'workerId': workerId,
            'jobId': jobId,
            'status': 'running',
            'progress': 0.0,
            'hashRate': 0.0,
            'remainingTime': 0.0,
            'isPaused': isPaused,
            'currentNonce': currentNonce,
          });
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
        // Only send updates every second to avoid UI jitter
        final now = DateTime.now();
        if (now.difference(lastReportTime).inMilliseconds >= 1000) {
          lastReportTime = now;
          sendPort.send({
            'workerId': workerId,
            'jobId': jobId,
            'status': 'running',
            'progress': _calculateProgress(currentNonce, startNonce, endNonce) * 100.0, // Convert to percentage
            'hashRate': _calculateStableHashRate(hashesChecked, startTime, hashRateHistory),
            'remainingTime': _calculateStableRemainingTime(
              currentNonce, startNonce, endNonce, hashesChecked, startTime, hashRateHistory),
            'isPaused': true,
            'currentNonce': currentNonce,
          });
        }
        return;
      }

      // Process a batch of nonces
      // Adjust batch size based on speed multiplier
      final int batchSize = (_baseBatchSize * speedMultiplier).round().clamp(_minBatchSize, _baseBatchSize);
      
      for (int i = 0; i < batchSize; i++) {
        if (shouldStop || isPaused) break;

        // Check if we've reached the end nonce
        if (endNonce != -1 && currentNonce > endNonce) {
          timer.cancel();
          receivePort.close();
          
          // Send completed status
          sendPort.send({
            'workerId': workerId,
            'jobId': jobId,
            'status': 'completed',
            'progress': 100.0, // Convert to percentage
            'hashRate': _calculateStableHashRate(hashesChecked, startTime, hashRateHistory),
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
            // Solution found - immediately stop and report
            timer.cancel();
            
            // Send solution found message
            sendPort.send({
              'workerId': workerId,
              'jobId': jobId,
              'status': 'found',
              'solution': {
                'nonce': currentNonce,
                'hash': hash,
              },
              'isPaused': false,
              'currentNonce': currentNonce,
            });
            
            // Close the receive port and exit immediately
            receivePort.close();
            return;
          }

          // Increment nonce and hashes checked
          currentNonce++;
          hashesChecked++;
        } catch (e) {
          // Log error but continue with next nonce
          print('Error processing nonce $currentNonce: $e');
          currentNonce++;
        }
      }

      // Send status update (but limit updates to reduce UI jitter)
      final now = DateTime.now();
      final progress = _calculateProgress(currentNonce, startNonce, endNonce) * 100.0; // Convert to percentage
      final hashRate = _calculateStableHashRate(hashesChecked, startTime, hashRateHistory);
      final remainingTime = _calculateStableRemainingTime(
        currentNonce, startNonce, endNonce, hashesChecked, startTime, hashRateHistory);
        
      // Only send updates if:
      // 1. It's been at least 1 second since the last update, or
      // 2. Progress has changed by at least 0.5%, or
      // 3. Hash rate has changed by at least 5%, or
      // 4. Remaining time has changed by at least 5%
      final timeDiff = now.difference(lastReportTime).inMilliseconds;
      final progressDiff = (progress - lastReportedProgress).abs();
      final hashRateDiff = lastReportedHashRate > 0 
          ? ((hashRate - lastReportedHashRate) / lastReportedHashRate).abs() 
          : 1.0;
      final remainingTimeDiff = lastReportedRemainingTime > 0 
          ? ((remainingTime - lastReportedRemainingTime) / lastReportedRemainingTime).abs() 
          : 1.0;
          
      if (timeDiff >= 1000 || progressDiff >= 0.5 || hashRateDiff >= 0.05 || remainingTimeDiff >= 0.05) {
        lastReportTime = now;
        lastReportedProgress = progress;
        lastReportedHashRate = hashRate;
        lastReportedRemainingTime = remainingTime;
        
        sendPort.send({
          'workerId': workerId,
          'jobId': jobId,
          'status': 'running',
          'progress': progress,
          'hashRate': hashRate,
          'remainingTime': remainingTime,
          'isPaused': false,
          'currentNonce': currentNonce,
        });
      }
    });
  }
  
  // Calculate stable hash rate with moving average
  static double _calculateStableHashRate(int hashesChecked, DateTime startTime, List<double> history) {
    final duration = DateTime.now().difference(startTime).inMilliseconds / 1000.0;
    if (duration <= 0) return 0.0;
    
    final currentRate = hashesChecked / duration;
    
    // Add to history (limit to last 10 readings)
    history.add(currentRate);
    if (history.length > 10) {
      history.removeAt(0);
    }
    
    // Return moving average
    return history.isNotEmpty ? history.reduce((a, b) => a + b) / history.length : 0.0;
  }
  
  // Calculate stable remaining time with smoothing
  static double _calculateStableRemainingTime(
    int currentNonce, int startNonce, int endNonce, int hashesChecked, DateTime startTime, List<double> hashRateHistory) {
    if (endNonce == -1) {
      // If no end nonce is specified, we can't calculate remaining time
      return 0.0;
    }
    
    final hashRate = _calculateStableHashRate(hashesChecked, startTime, hashRateHistory);
    if (hashRate <= 0) return 0.0;
    
    return (endNonce - currentNonce) / hashRate;
  }

  // Calculate aggregate statistics for all workers in a job
  Map<String, dynamic> _calculateAggregateStats(String jobId) {
    if (!_jobWorkers.containsKey(jobId) || _jobWorkers[jobId]!.isEmpty) {
      return {
        'progress': 0.0,
        'hashRate': 0.0,
        'remainingTime': 0.0,
        'currentNonce': 0,
        'activeWorkers': 0,
      };
    }

    final job = _activeJobs[jobId];
    if (job == null) {
      return {
        'progress': 0.0,
        'hashRate': 0.0,
        'remainingTime': 0.0,
        'currentNonce': 0,
        'activeWorkers': _jobWorkers[jobId]!.length,
      };
    }

    // Get the start and end nonce for the job
    final startNonce = job.startNonce;
    final endNonce = job.endNonce;

    // Calculate total hashes processed across all workers
    final totalProcessed = _jobWorkers[jobId]!.fold(0, (sum, w) => sum + w.hashesProcessed);
    
    // Calculate progress as a percentage (0-100)
    double progress = 0.0;
    if (endNonce > 0) {
      final totalRange = endNonce - startNonce;
      progress = totalRange > 0 ? (totalProcessed / totalRange) * 100.0 : 0.0;
      // Clamp progress to 0-100 range
      progress = progress.clamp(0.0, 100.0);
    }
    
    // Calculate aggregate hash rate (use a moving average for stability)
    final totalHashRate = _jobWorkers[jobId]!
        .where((w) => w.isActive && !w.isPaused)
        .fold(0.0, (sum, w) => sum + w.getHashRate());
    
    // Store hash rate history for this job (for moving average calculation)
    if (!_hashRateHistory.containsKey(jobId)) {
      _hashRateHistory[jobId] = [];
    }
    
    // Add current hash rate to history (limit history to last 10 readings)
    _hashRateHistory[jobId]!.add(totalHashRate);
    if (_hashRateHistory[jobId]!.length > 10) {
      _hashRateHistory[jobId]!.removeAt(0);
    }
    
    // Calculate moving average hash rate for stability
    final avgHashRate = _hashRateHistory[jobId]!.isNotEmpty 
        ? _hashRateHistory[jobId]!.reduce((a, b) => a + b) / _hashRateHistory[jobId]!.length
        : 0.0;
    
    // Calculate remaining time based on average hash rate and remaining nonces
    double remainingTime = 0.0;
    if (avgHashRate > 0 && endNonce > 0) {
      // Find the highest nonce processed by any worker
      final highestNonce = _jobWorkers[jobId]!.fold(
        startNonce, 
        (highest, worker) => worker.lastProcessedNonce > highest ? worker.lastProcessedNonce : highest
      );
      
      final remainingNonces = endNonce - highestNonce;
      if (remainingNonces > 0) {
        remainingTime = remainingNonces / avgHashRate;
        // Apply some smoothing to remaining time to avoid jumps
        if (_lastRemainingTimes.containsKey(jobId)) {
          final lastTime = _lastRemainingTimes[jobId]!;
          // Use weighted average (70% new, 30% old) for smoother transitions
          remainingTime = (remainingTime * 0.7) + (lastTime * 0.3);
        }
        _lastRemainingTimes[jobId] = remainingTime;
      }
    }
    
    // Count active workers
    final activeWorkers = _jobWorkers[jobId]!.where((w) => w.isActive).length;
    
    // Find the highest nonce processed by any worker
    final currentNonce = _jobWorkers[jobId]!.fold(
      startNonce, 
      (highest, worker) => worker.lastProcessedNonce > highest ? worker.lastProcessedNonce : highest
    );
    
    return {
      'progress': progress,
      'hashRate': avgHashRate,
      'remainingTime': remainingTime,
      'currentNonce': currentNonce,
      'activeWorkers': activeWorkers,
    };
  }

  // Expose job retrieval from the job service
  Future<MiningJob?> getJob(String jobId) async {
    return await _jobService.getJob(jobId);
  }

  // Get a list of active jobs
  Future<List<MiningJob>> getActiveJobs() async {
    // Get active jobs from the job service instead of just in-memory jobs
    return await _jobService.getActiveJobs();
  }

  // Get the number of active workers for a job
  int getActiveWorkerCount(String jobId) {
    if (!_jobWorkers.containsKey(jobId)) return 0;
    return _jobWorkers[jobId]!.where((w) => w.isActive).length;
  }

  // Get the total number of active workers across all jobs
  int getTotalActiveWorkerCount() {
    int total = 0;
    for (final workers in _jobWorkers.values) {
      total += workers.where((w) => w.isActive).length;
    }
    return total;
  }

  // Get the maximum number of workers that can be used (based on CPU cores)
  int getMaxWorkerCount() {
    return _maxConcurrentJobs;
  }

  // Get all active jobs that are not successful
  Future<List<MiningJob>> getNonSuccessfulActiveJobs() async {
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
    final activeJobIds = List<String>.from(_jobWorkers.keys);
    for (final jobId in activeJobIds) {
      stopMining(jobId);
    }
    
    // Then clear the job history
    await _jobService.clearAllJobs();
  }

  // Save the current state of all active jobs
  Future<void> saveJobState() async {
    // For each active job, update its last tried nonce
    for (final jobId in _activeJobs.keys) {
      final job = _activeJobs[jobId];
      if (job != null) {
        // Find the highest nonce processed by any worker
        int highestNonce = job.lastTriedNonce;
        if (_jobWorkers.containsKey(jobId)) {
          for (final worker in _jobWorkers[jobId]!) {
            if (worker.lastProcessedNonce > highestNonce) {
              highestNonce = worker.lastProcessedNonce;
            }
          }
        }
        
        // Create an updated job with the latest nonce
        final updatedJob = MiningJob(
          id: job.id,
          content: job.content,
          leader: job.leader,
          owner: job.owner,
          height: job.height,
          rewardType: job.rewardType, // Keep as string '0' or '1'
          difficulty: job.difficulty,
          startNonce: job.startNonce,
          endNonce: job.endNonce,
          startTime: job.startTime,
          endTime: job.endTime,
          foundNonce: job.foundNonce,
          foundHash: job.foundHash,
          completed: job.completed,
          successful: job.successful,
          error: job.error,
          broadcastSuccessful: job.broadcastSuccessful,
          broadcastError: job.broadcastError,
          broadcastHash: job.broadcastHash,
          lastTriedNonce: highestNonce,
        );
        
        // Update the job in storage
        await _jobService.updateJob(updatedJob);
      }
    }
  }
}
