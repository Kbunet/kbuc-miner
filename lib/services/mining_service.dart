import 'dart:async';
import 'dart:isolate';
import 'dart:math'; // Added math library import
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
  // Singleton instance
  static final MiningService _instance = MiningService._internal();
  
  // Factory constructor
  factory MiningService() => _instance;
  
  // Internal constructor
  MiningService._internal() {
    _initializeService();
  }
  
  // Private fields
  final Map<String, MiningJob> _activeJobs = {};
  final Map<String, List<MiningWorker>> _jobWorkers = {};
  final Map<String, Map<int, Isolate>> _workerIsolates = {};
  final Map<String, Map<int, ReceivePort>> _workerPorts = {};
  final Map<String, Map<int, SendPort?>> _workerSendPorts = {};
  final Map<String, MiningJob> _pausedJobs = {};
  final Map<String, double> _speedMultipliers = {};
  final Map<String, Map<String, dynamic>> _jobStats = {};
  final Map<String, List<double>> _hashRateHistory = {};
  final Map<String, double> _lastRemainingTimes = {};
  
  // Isolate management (legacy fields to be removed)
  final Map<String, List<Isolate>> _isolates = {};
  final Map<String, List<ReceivePort>> _receivePorts = {};
  final Map<String, List<StreamSubscription>> _receiveStreams = {};
  final Map<int, double> _workerHashRates = {};
  final Map<String, MiningJob> _completedJobs = {}; // Added to store completed jobs
  
  // Track the next available nonce for each job
  final Map<String, int> _nextAvailableNonce = {};

  // Track the current batch end for each job
  final Map<String, int> _currentBatchEnd = {};
  
  final StreamController<Map<String, dynamic>> _jobUpdateController = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _jobCompletedController = StreamController<Map<String, dynamic>>.broadcast();
  
  // Map to store job callbacks
  final Map<String, Function(Map<String, dynamic>)> _jobCallbacks = {};
  
  Stream<Map<String, dynamic>> get jobUpdates => _jobUpdateController.stream;
  Stream<Map<String, dynamic>> get jobCompleted => _jobCompletedController.stream;
  
  final Lock _lock = Lock();
  Timer? _broadcastTimer;
  
  int _maxConcurrentJobs = 4;
  
  // Job service for persistence
  final MiningJobService _jobService = MiningJobService();
  final NodeService _nodeService = NodeService();
  
  // Batch size configuration
  static const int _baseBatchSize = 5000; // Base number of nonces per batch
  static const int _minBatchSize = 10000;  // Minimum batch size
  
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

  // Start mining a job
  Future<void> startMining({
    required String jobId,
    required String content,
    required String leader,
    required String owner,
    required int height,
    required String rewardType, // Kept as string '0' or '1' per memory requirement
    required int difficulty,
    required int startNonce,
    required int endNonce,
    required Function(Map<String, dynamic>) onUpdate,
    int? resumeFromNonce,
    Map<int, int>? workerLastNonces,
    double? speedMultiplier,
  }) async {
    await _lock.synchronized(() async {
      // Check if the job is already running
      if (_activeJobs.containsKey(jobId)) {
        debugPrint('Job $jobId is already running');
        return;
      }
      
      // Store the callback for this job
      _jobCallbacks[jobId] = onUpdate;
      
      // Create a new job
      final job = MiningJob(
        id: jobId,
        content: content,
        leader: leader,
        owner: owner,
        height: height,
        rewardType: rewardType, // Store as string '0' or '1'
        difficulty: difficulty,
        startNonce: startNonce,
        endNonce: endNonce,
        startTime: DateTime.now(),
        lastTriedNonce: resumeFromNonce ?? startNonce,
        completed: false,
        successful: false,
        workerLastNonces: workerLastNonces ?? {}, // Initialize with provided worker nonces or empty map
        speedMultiplier: speedMultiplier, // Store the provided speed multiplier
      );
      
      // Initialize speed multiplier from parameter, stored job, or default to 1.0
      if (speedMultiplier != null) {
        _speedMultipliers[jobId] = speedMultiplier;
      } else if (job.speedMultiplier != null) {
        _speedMultipliers[jobId] = job.speedMultiplier!;
      } else if (!_speedMultipliers.containsKey(jobId)) {
        _speedMultipliers[jobId] = 1.0;
      }
      
      // Add to active jobs
      _activeJobs[jobId] = job;
      _hashRateHistory[jobId] = [];
      _jobWorkers[jobId] = [];
      
      // Initialize job stats
      _jobStats[jobId] = {
        'progress': 0.0,
        'hashRate': 0.0,
        'remainingTime': 0.0,
        'activeWorkers': 0,
        'currentNonce': job.startNonce,
      };
      
      // Initialize the next available nonce for this job
      _nextAvailableNonce[jobId] = resumeFromNonce ?? startNonce;
      
      // Define the batch size for sequential processing
      final sequentialBatchSize = 10000000; // 10 million nonces per sequential batch
      
      // Calculate the initial batch end
      _currentBatchEnd[jobId] = min(
        endNonce,
        _nextAvailableNonce[jobId]! + sequentialBatchSize - 1
      );
      
      // Calculate how many workers to create
      final int workerCount = _maxConcurrentJobs;
      debugPrint('Creating $workerCount workers for job $jobId');
      
      // Create workers with small, evenly distributed batches within the current sequential batch
      final batchSize = 10000; // Each worker gets 10,000 nonces at a time
      
      for (int i = 0; i < workerCount; i++) {
        // Calculate worker's initial batch
        int workerBatchStart;
        int workerBatchEnd;
        
        if (resumeFromNonce == null && (workerLastNonces == null || workerLastNonces.isEmpty)) {
          // For a new job, distribute workers evenly across the first sequential batch
          workerBatchStart = _nextAvailableNonce[jobId]! + (i * batchSize);
          workerBatchEnd = min(workerBatchStart + batchSize - 1, _currentBatchEnd[jobId]!);
        } else {
          // For resumed jobs, use saved state if available
          if (workerLastNonces != null && workerLastNonces.containsKey(i)) {
            workerBatchStart = workerLastNonces[i]! + 1;
          } else {
            workerBatchStart = _nextAvailableNonce[jobId]! + (i * batchSize);
          }
          
          workerBatchEnd = min(workerBatchStart + batchSize - 1, _currentBatchEnd[jobId]!);
        }
        
        // Make sure we don't exceed the job's end nonce
        if (workerBatchStart > endNonce) {
          // No more work for this worker
          continue;
        }
        
        // Update the next available nonce
        _nextAvailableNonce[jobId] = max(_nextAvailableNonce[jobId]!, workerBatchEnd + 1);
        
        // Create the worker
        final worker = MiningWorker(
          id: i,
          jobId: jobId,
          currentBatchStart: workerBatchStart,
          currentBatchEnd: workerBatchEnd,
          lastProcessedNonce: workerBatchStart - 1,
          status: 'initializing',
          isActive: true,
          startTime: DateTime.now(),
        );
        
        // Add to job workers
        _jobWorkers[jobId]!.add(worker);
        
        // Create the worker isolate
        _createWorker(
          jobId: jobId,
          workerId: i,
          content: content,
          leader: leader,
          height: height,
          owner: owner,
          rewardType: rewardType, // Pass as string '0' or '1'
          difficulty: difficulty,
          startNonce: workerBatchStart,
          endNonce: workerBatchEnd,
          onUpdate: onUpdate,
        );
      }
      
      // Save the job state to persist it
      if (_activeJobs[jobId] != null) {
        // Make sure the job has the current speed multiplier before saving
        final jobWithSpeed = _activeJobs[jobId]!.copyWith(
          speedMultiplier: _speedMultipliers[jobId],
        );
        _activeJobs[jobId] = jobWithSpeed;
        
        // Check if the job already exists in storage
        final existingJob = await _jobService.getJob(jobId);
        if (existingJob != null) {
          // Update the existing job instead of adding a new one
          await _jobService.updateJob(jobWithSpeed);
          debugPrint('Updated existing job $jobId in storage with speed multiplier ${_speedMultipliers[jobId]}');
        } else {
          // This is a new job, add it
          await _jobService.addJob(jobWithSpeed);
          debugPrint('Added new job $jobId to storage with speed multiplier ${_speedMultipliers[jobId]}');
        }
      }
    });
  }

  // Assign a new batch of nonces to a worker that has completed its previous batch
  void _assignNextBatch(String jobId, int workerId) {
    if (!_activeJobs.containsKey(jobId) || !_jobWorkers.containsKey(jobId)) {
      debugPrint('Job $jobId not found when trying to assign new batch to worker $workerId');
      return;
    }
    
    final job = _activeJobs[jobId]!;
    
    // If the job is completed, don't assign a new batch
    if (job.completed) {
      debugPrint('Job $jobId is already completed, not assigning new batch to worker $workerId');
      return;
    }
    
    // If the job is paused, don't assign a new batch
    if (_pausedJobs.containsKey(jobId)) {
      debugPrint('Job $jobId is paused, not assigning new batch to worker $workerId');
      return;
    }
    
    // Find the worker
    final workerIndex = _jobWorkers[jobId]!.indexWhere((w) => w.id == workerId);
    if (workerIndex < 0) {
      debugPrint('Worker $workerId not found for job $jobId');
      return;
    }
    
    final worker = _jobWorkers[jobId]![workerIndex];
    
    // Update the job's last tried nonce to track progress
    if (worker.lastProcessedNonce > job.lastTriedNonce) {
      _activeJobs[jobId] = job.copyWith(
        lastTriedNonce: worker.lastProcessedNonce
      );
    }
    
    // Define batch size
    final batchSize = 10000; // Each worker gets 10,000 nonces at a time
    
    // Calculate the next batch for this worker
    int newStart = _nextAvailableNonce[jobId] ?? job.startNonce;
    
    // Check if we've reached the end of the current sequential batch
    if (newStart > _currentBatchEnd[jobId]!) {
      // Move to the next sequential batch
      final sequentialBatchSize = 10000000; // 10 million nonces per sequential batch
      _currentBatchEnd[jobId] = min(
        job.endNonce,
        newStart + sequentialBatchSize - 1
      );
    }
    
    // If we've reached the end of the job's range, mark the worker as completed
    if (newStart > job.endNonce) {
      debugPrint('Worker $workerId has completed all available nonces for job $jobId');
      
      // Mark the worker as inactive
      _jobWorkers[jobId]![workerIndex] = worker.copyWith(
        status: 'completed',
        isActive: false,
      );
      
      // Check if all workers have completed their ranges
      bool allWorkersCompleted = true;
      for (final w in _jobWorkers[jobId]!) {
        if (w.isActive || w.status == 'mining') {
          allWorkersCompleted = false;
          break;
        }
      }
      
      // If all workers have completed their ranges, mark the job as complete
      if (allWorkersCompleted) {
        debugPrint('All workers have completed all available nonces for job $jobId');
        if (_activeJobs[jobId] != null) {
          _activeJobs[jobId] = _activeJobs[jobId]!.copyWith(
            completed: true,
            successful: false,
          );
        }
        
        // Notify the callback that the job is complete but unsuccessful
        final onUpdate = _jobCallbacks[jobId];
        if (onUpdate != null) {
          onUpdate({
            'status': 'completed',
            'successful': false,
            'message': 'All nonce ranges exhausted without finding a solution',
          });
        }
        
        // Save the job state to persist it
        if (_activeJobs[jobId] != null) {
          _jobService.addJob(_activeJobs[jobId]!);
        }
      }
      
      return;
    }
    
    // Calculate the new batch end
    int newEnd = min(newStart + batchSize - 1, _currentBatchEnd[jobId]!);
    
    // Make sure we don't exceed the job's end nonce
    if (newEnd > job.endNonce) {
      newEnd = job.endNonce;
    }
    
    // Double-check that the range is valid
    if (newEnd < newStart) {
      debugPrint('Invalid range calculated: $newStart to $newEnd for job $jobId');
      return;
    }
    
    // debugPrint('Assigned new batch to worker $workerId for job $jobId: $newStart to $newEnd (within sequential batch: ${job.startNonce} to ${_currentBatchEnd[jobId]})');
    
    // Update the worker
    _jobWorkers[jobId]![workerIndex] = worker.copyWith(
      currentBatchStart: newStart,
      currentBatchEnd: newEnd,
      lastProcessedNonce: newStart - 1, 
      status: 'mining',
      isActive: true,
    );
    
    // Update the next available nonce for this job
    _nextAvailableNonce[jobId] = newEnd + 1;
    
    // Update job's worker nonce state
    Map<int, int> updatedWorkerNonces = Map.from(job.workerLastNonces);
    updatedWorkerNonces[workerId] = newStart - 1;
    if (_activeJobs[jobId] != null) {
      _activeJobs[jobId] = _activeJobs[jobId]!.copyWith(
        workerLastNonces: updatedWorkerNonces
      );
    }
    
    // Send the new batch to the worker
    if (_workerSendPorts.containsKey(jobId) && 
        _workerSendPorts[jobId]!.containsKey(workerId) && 
        _workerSendPorts[jobId]![workerId] != null) {
      
      _workerSendPorts[jobId]![workerId]!.send({
        'command': 'newBatch', // Changed from 'processBatch' to 'newBatch' to match worker isolate code
        'startNonce': newStart,
        'endNonce': newEnd,
        'speedMultiplier': _speedMultipliers[jobId] ?? 1.0,
      });
    } else {
      debugPrint('No send port available for worker $workerId for job $jobId');
    }
  }

  // Stop all workers for a job except the one that found the solution
  Future<void> _stopAllWorkersExcept(String jobId, int exceptWorkerId) async {
    if (!_jobWorkers.containsKey(jobId)) return;
    
    // Get all workers for the job
    final workers = _jobWorkers[jobId]!;
    
    // Stop each worker except the one that found a solution
    for (final worker in workers) {
      if (worker.id == exceptWorkerId) continue;
      
      // Mark the worker as inactive
      final workerIndex = workers.indexWhere((w) => w.id == worker.id);
      if (workerIndex >= 0) {
        _jobWorkers[jobId]![workerIndex] = worker.copyWith(
          status: 'stopped',
          isActive: false,
        );
      }
      
      // Send stop command to the worker
      if (_workerSendPorts.containsKey(jobId) && 
          _workerSendPorts[jobId]!.containsKey(worker.id) && 
          _workerSendPorts[jobId]![worker.id] != null) {
        
        _workerSendPorts[jobId]![worker.id]!.send({
          'command': 'stop',
        });
      }
      
      // Kill the isolate
      if (_workerIsolates.containsKey(jobId) && 
          _workerIsolates[jobId]!.containsKey(worker.id)) {
        
        _workerIsolates[jobId]![worker.id]!.kill(priority: Isolate.immediate);
      }
      
      // Close the receive port
      if (_workerPorts.containsKey(jobId) && 
          _workerPorts[jobId]!.containsKey(worker.id)) {
        
        _workerPorts[jobId]![worker.id]!.close();
      }
    }
    
    // Mark the solution worker as completed
    final solutionWorkerIndex = workers.indexWhere((w) => w.id == exceptWorkerId);
    if (solutionWorkerIndex >= 0) {
      _jobWorkers[jobId]![solutionWorkerIndex] = workers[solutionWorkerIndex].copyWith(
        status: 'solution',
        isActive: false,
      );
    }
    
    // Update job stats
    _updateJobStats(jobId);
    
    // Broadcast job update
    _broadcastJobUpdate(jobId);
  }

  // Toggle mining job pause state
  Future<bool> togglePause(String jobId) async {
    await _lock.synchronized(() async {
      if (!_activeJobs.containsKey(jobId)) {
        debugPrint('Cannot toggle pause: Job $jobId not found');
        return false;
      }
      
      final workers = _jobWorkers[jobId];
      if (workers == null || workers.isEmpty) {
        debugPrint('Cannot toggle pause: No workers for job $jobId');
        return false;
      }
    });
    
    // Toggle the pause state
    final wasPaused = _pausedJobs[jobId] != null; // Corrected condition
    final newState = !wasPaused;
    if (newState) {
      final activeJob = _activeJobs[jobId];
      if (activeJob != null) {
        _pausedJobs[jobId] = activeJob; // Only assign if not null
      }
    } else {
      _pausedJobs.remove(jobId);
    }
    
    // Send the new state to the isolate
    debugPrint('Toggling pause state to: ${newState ? 'PAUSED' : 'RUNNING'} for job: $jobId');
    _sendCommandToWorkers(jobId, newState ? 'pause' : 'resume');
    
    return true;
  }

  void stopMining(String jobId) {
    final workers = _jobWorkers[jobId];
    final job = _activeJobs[jobId];
    final isPaused = _pausedJobs[jobId] != null; // Corrected condition

    if (workers != null) {
      debugPrint('Stopping mining job: $jobId (isPaused: $isPaused)');
      
      // Stop all workers
      workers.forEach((worker) {
        _workerSendPorts[jobId]![worker.id]?.send({'command': 'stop'});
        worker.isolate?.kill(priority: Isolate.immediate);
        worker.receivePort?.close();
      });
      
      // Clean up worker resources
      _cleanupJob(jobId);
      
      // If the job is paused, we don't want to mark it as completed
      // Instead, we just save its current state so it can be resumed later
      if (isPaused && job != null) {
        debugPrint('Job $jobId is paused, saving state without marking as completed');
        
        // Save the job state but don't mark as completed
        _lock.synchronized(() async {
          try {
            final storedJob = await _jobService.getJob(jobId);
            if (storedJob != null) {
              // Update the job with the latest nonce but don't mark as completed
              final updatedJob = storedJob.copyWith(
                lastTriedNonce: job.lastTriedNonce,
              );
              
              await _jobService.updateJob(updatedJob);
              debugPrint('Saved paused state for job $jobId at nonce ${job.lastTriedNonce}');
            }
          } catch (e) {
            debugPrint('Error saving paused state for job $jobId: $e');
          }
        });
      } else if (job != null) {
        // If the job is not paused, mark it as completed without a solution
        debugPrint('Job $jobId is not paused, marking as completed without solution');
        _completeJob(jobId, false, null, null, (update) {
          debugPrint('Job $jobId marked as completed without solution');
        });
      }
      
      // Remove from active jobs and paused jobs
      _activeJobs.remove(jobId);
      _pausedJobs.remove(jobId);
    }
  }

  void dispose() {
    for (final jobId in _jobWorkers.keys.toList()) {
      stopMining(jobId);
    }
  }

  Future<void> updateSpeed(String jobId, double multiplier) async {
    if (_activeJobs.containsKey(jobId)) {
      _speedMultipliers[jobId] = multiplier;
      
      // Update the job with the new speed multiplier
      final updatedJob = _activeJobs[jobId]!.copyWith(
        speedMultiplier: multiplier,
      );
      _activeJobs[jobId] = updatedJob;
      
      // Save the updated job to storage to persist the speed multiplier
      await _jobService.updateJob(updatedJob);
      
      // Send speed update to all workers
      if (_workerSendPorts.containsKey(jobId)) {
        for (final workerId in _workerSendPorts[jobId]!.keys) {
          _workerSendPorts[jobId]![workerId]?.send({
            'command': 'speed',
            'value': multiplier,
          });
        }
      }
      
      debugPrint('Updated speed multiplier for job $jobId to $multiplier');
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
  }) async {
    // Create a receive port for communication with the worker
    final receivePort = ReceivePort();
    
    // Store the receive port
    _workerPorts[jobId] ??= {};
    _workerPorts[jobId]![workerId] = receivePort;
    
    // Initialize the send port map
    _workerSendPorts[jobId] ??= {};
    
    // Initialize the receive streams map
    _receiveStreams[jobId] ??= [];
    
    // Create the worker isolate
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
      },
    );
    
    // Store the isolate
    _workerIsolates[jobId] ??= {};
    _workerIsolates[jobId]![workerId] = isolate;
    
    // Listen for messages from the worker
    final stream = receivePort.asBroadcastStream();
    
    // Store the subscription
    final subscription = stream.listen((message) {
      if (message is Map<String, dynamic> && message.containsKey('port')) {
        // Store the worker's send port
        _workerSendPorts[jobId]![workerId] = message['port'] as SendPort;
        
        // Send the initial speed multiplier to the worker
        _workerSendPorts[jobId]![workerId]!.send({
          'command': 'speed',
          'value': _speedMultipliers[jobId] ?? 1.0,
        });
        
        // Start mining
        _workerSendPorts[jobId]![workerId]!.send({
          'command': 'newBatch',
          'startNonce': startNonce,
          'endNonce': endNonce,
        });
      } else if (message is Map<String, dynamic>) {
        // Process worker update
        message['workerId'] = workerId;
        message['jobId'] = jobId;
        
        // Handle worker updates
        _handleWorkerUpdate(message);
        
        // Forward update to the UI callback
        onUpdate({
          'jobId': jobId,
          'progress': _jobStats[jobId]?['progress'] ?? 0.0,
          'hashRate': _jobStats[jobId]?['hashRate'] ?? 0.0,
          'remainingTime': _jobStats[jobId]?['remainingTime'] ?? 0.0,
          'currentNonce': _jobStats[jobId]?['currentNonce'] ?? 0,
          'activeWorkers': _jobStats[jobId]?['activeWorkers'] ?? 0,
        });
      }
    });
    
    // Add the subscription to the list
    _receiveStreams[jobId]!.add(subscription);
  }
  
  // Handle worker update
  void _handleWorkerUpdate(Map<String, dynamic> update) {
    final workerId = update['workerId'] as int;
    final jobId = update['jobId'] as String;
    final status = update['status'] as String;
    
    // Check if the job exists
    if (!_activeJobs.containsKey(jobId)) {
      debugPrint('Job $jobId not found for worker update');
      return;
    }
    
    // Check if the worker exists
    if (!_jobWorkers.containsKey(jobId)) {
      debugPrint('No workers found for job $jobId');
      return;
    }
    
    // Find the worker
    final workerIndex = _jobWorkers[jobId]!.indexWhere((w) => w.id == workerId);
    if (workerIndex < 0) {
      debugPrint('Worker $workerId not found for job $jobId');
      return;
    }
    
    final worker = _jobWorkers[jobId]![workerIndex];
    final job = _activeJobs[jobId]!;
    
    // Handle the update based on status
    switch (status) {
      case 'initializing':
        // Worker is initializing
        _jobWorkers[jobId]![workerIndex] = worker.copyWith(
          status: 'initializing',
          isActive: true,
        );
        break;
        
      case 'ready':
        // Worker is ready
        _jobWorkers[jobId]![workerIndex] = worker.copyWith(
          status: 'ready',
          isActive: true,
        );
        break;
        
      case 'mining':
        // Worker is actively mining
        _jobWorkers[jobId]![workerIndex] = worker.copyWith(
          status: 'mining',
          isActive: true,
        );
        break;
        
      case 'paused':
        // Worker is paused
        _jobWorkers[jobId]![workerIndex] = worker.copyWith(
          status: 'paused',
          isActive: false,
        );
        break;
        
      case 'progress':
        // Worker is reporting progress
        final lastProcessedNonce = update['lastProcessedNonce'] as int;
        final hashesProcessed = update['hashesProcessed'] as int;
        
        // Calculate hash rate (hashes per second)
        final hashRate = hashesProcessed.toDouble();
        
        // Update worker
        _jobWorkers[jobId]![workerIndex] = worker.copyWith(
          status: 'mining',
          isActive: true,
          lastProcessedNonce: lastProcessedNonce,
          hashRate: hashRate,
        );
        
        // Update job's worker nonce state
        Map<int, int> updatedWorkerNonces = Map.from(job.workerLastNonces);
        updatedWorkerNonces[workerId] = lastProcessedNonce;
        if (_activeJobs[jobId] != null) {
          _activeJobs[jobId] = _activeJobs[jobId]!.copyWith(
            workerLastNonces: updatedWorkerNonces
          );
        }
        
        // Update job stats
        _updateJobStats(jobId);
        
        // Broadcast job update
        _broadcastJobUpdate(jobId);
        break;
        
      case 'batchComplete':
        // Worker has completed its batch
        final lastProcessedNonce = update['lastProcessedNonce'] as int;
        
        // Update worker
        _jobWorkers[jobId]![workerIndex] = worker.copyWith(
          status: 'completed',
          isActive: false,
          lastProcessedNonce: lastProcessedNonce,
        );
        
        // Update job's worker nonce state
        Map<int, int> updatedWorkerNonces = Map.from(job.workerLastNonces);
        updatedWorkerNonces[workerId] = lastProcessedNonce;
        if (_activeJobs[jobId] != null) {
          _activeJobs[jobId] = _activeJobs[jobId]!.copyWith(
            workerLastNonces: updatedWorkerNonces
          );
        }
        
        // Update job stats
        _updateJobStats(jobId);
        
        // Broadcast job update
        _broadcastJobUpdate(jobId);
        
        // Assign a new batch to the worker
        _assignNextBatch(jobId, workerId);
        break;
        
      case 'solutionFound':
        // Worker has found a solution
        final nonce = update['nonce'] as int;
        final hash = update['hash'] as String;
        
        // Update worker status to solution
        _jobWorkers[jobId]![workerIndex] = worker.copyWith(
          status: 'solution',
          isActive: false,
          lastProcessedNonce: nonce,
        );
        
        // Stop all other workers
        _stopAllWorkersExcept(jobId, workerId);
        
        // Handle the solution (this will broadcast the ticket)
        _handleSolution(update, jobId, job, (solutionUpdate) {
          // This callback will be called after the solution is handled
          debugPrint('Solution handled for job $jobId');
        });
        
        break;
    }
  }

  void _updateJobStats(String jobId) {
    if (!_activeJobs.containsKey(jobId) || !_jobWorkers.containsKey(jobId)) {
      return;
    }
    
    // Get job and workers
    final job = _activeJobs[jobId]!;
    final workers = _jobWorkers[jobId]!;
    
    // Calculate total hash rate
    double totalHashRate = 0.0;
    int activeWorkers = 0;
    int currentNonce = job.startNonce;
    
    for (final worker in workers) {
      if (worker.isActive) {
        totalHashRate += worker.hashRate;
        activeWorkers++;
        currentNonce = max(currentNonce, worker.lastProcessedNonce);
      }
    }
    
    // Calculate progress
    final totalNonces = job.endNonce - job.startNonce;
    final processedNonces = currentNonce - job.startNonce;
    final progress = totalNonces > 0 ? processedNonces / totalNonces : 0.0;
    
    // Get hash rate history
    _hashRateHistory[jobId] ??= [];
    
    // Calculate remaining time
    final remainingTime = _calculateStableRemainingTime(
      currentNonce,
      job.startNonce,
      job.endNonce,
      processedNonces,
      job.startTime,
      _hashRateHistory[jobId]!,
    );
    
    // Store last remaining time
    _lastRemainingTimes[jobId] = remainingTime;
    
    // Update job stats
    _jobStats[jobId] = {
      'progress': progress,
      'hashRate': totalHashRate,
      'remainingTime': remainingTime,
      'activeWorkers': activeWorkers,
      'currentNonce': currentNonce,
    };
  }

  Future<void> _handleSolution(Map<String, dynamic> update, String jobId, MiningJob job, Function(Map<String, dynamic>) callback) async {
    // Use a lock to prevent race conditions when multiple workers find solutions at nearly the same time
    return await _lock.synchronized(() async {
      // Check if the job is already completed (another worker might have found a solution)
      if (job.completed || !_activeJobs.containsKey(jobId)) {
        debugPrint('Job $jobId is already completed or no longer active, ignoring solution');
        return;
      }
      
      final workerId = update['workerId'] as int;
      final nonce = update['nonce'] as int;
      final hash = update['hash'] as String;
      
      debugPrint('Solution found by worker $workerId for job $jobId with nonce $nonce');
      
      // Immediately stop all other workers to prevent them from finding another solution
      await _stopAllWorkersExcept(jobId, workerId);
      
      // Update job's worker nonce state
      Map<int, int> updatedWorkerNonces = Map.from(job.workerLastNonces);
      updatedWorkerNonces[workerId] = nonce;
      
      // Update the job with the solution
      final updatedJob = job.copyWith(
        completed: true,
        successful: true,
        endTime: DateTime.now(),
        foundNonce: nonce,
        foundHash: hash,
        workerLastNonces: updatedWorkerNonces,
        speedMultiplier: _speedMultipliers[jobId] // Preserve the speed multiplier
      );
      
      if (_activeJobs[jobId] != null) {
        _activeJobs[jobId] = updatedJob;
      }
      
      // Move to completed jobs
      _completedJobs[jobId] = updatedJob;
      
      // Save the job state to persistent storage
      try {
        await _jobService.updateJob(updatedJob);
        debugPrint('Solution found for job $jobId saved to persistent storage');
      } catch (error) {
        debugPrint('Error saving solution for job $jobId to persistent storage: $error');
      }
      
      // Save the job state
      await saveJobState();
      
      // Broadcast the ticket to the node
      try {
        await _broadcastTicket(jobId, updatedJob, nonce);
        debugPrint('Ticket for job $jobId broadcast successfully');
        
        // Update job stats - only if the job is still in active jobs
        if (_activeJobs.containsKey(jobId)) {
          _updateJobStats(jobId);
        }
        
        // Notify listeners through the stream controller directly
        _jobUpdateController.add({
          'jobId': jobId,
          'progress': 100.0,
          'hashRate': 0.0,
          'remainingTime': 0.0,
          'currentNonce': nonce,
          'workerDetails': _jobWorkers[jobId]?.map((worker) => {
            'workerId': worker.id,
            'lastNonce': worker.lastProcessedNonce,
            'status': worker.status,
            'hashRate': worker.hashRate,
            'startNonce': worker.currentBatchStart,
            'endNonce': worker.currentBatchEnd,
            'isActive': worker.isActive,
          }).toList() ?? [],
          'isPaused': false,
          'isCompleted': true,
          'isSuccessful': true,
        });
      } catch (error) {
        debugPrint('Error broadcasting ticket for job $jobId: $error');
        
        // Even if broadcasting fails, update the UI directly
        _jobUpdateController.add({
          'jobId': jobId,
          'progress': 100.0,
          'hashRate': 0.0,
          'remainingTime': 0.0,
          'currentNonce': nonce,
          'workerDetails': _jobWorkers[jobId]?.map((worker) => {
            'workerId': worker.id,
            'lastNonce': worker.lastProcessedNonce,
            'status': worker.status,
            'hashRate': worker.hashRate,
            'startNonce': worker.currentBatchStart,
            'endNonce': worker.currentBatchEnd,
            'isActive': worker.isActive,
          }).toList() ?? [],
          'isPaused': false,
          'isCompleted': true,
          'isSuccessful': true,
          'broadcastError': error.toString(),
        });
      }
      
      // Notify listeners
      _jobCompletedController.add({
        'jobId': jobId,
        'status': 'found',
        'job': updatedJob.toJson(),
        'nonce': nonce,
        'hash': hash,
        'foundNonce': nonce,
        'foundHash': hash,
      });
      
      // Call the callback
      callback({
        'jobId': jobId,
        'status': 'found',
        'job': updatedJob.toJson(),
        'nonce': nonce,
        'hash': hash,
        'foundNonce': nonce,
        'foundHash': hash,
      });
    });
  }

  // Complete a job with success/failure status and optional nonce/hash
  Future<void> _completeJob(String jobId, bool successful, int? foundNonce, String? foundHash, Function(Map<String, dynamic>) onUpdate) async {
    if (!_activeJobs.containsKey(jobId)) {
      debugPrint('Job $jobId not found for completion');
      return;
    }
    
    final job = _activeJobs[jobId]!;
    final updatedJob = job.copyWith(
      completed: true,
      successful: successful,
      foundNonce: foundNonce,
      foundHash: foundHash,
      endTime: DateTime.now(), // Ensure we set the end time
      speedMultiplier: _speedMultipliers[jobId], // Preserve the speed multiplier
    );
    
    _activeJobs[jobId] = updatedJob;
    
    // Move to completed jobs
    _completedJobs[jobId] = updatedJob;
    _activeJobs.remove(jobId);
    _pausedJobs.remove(jobId);
    
    // Save the job to persistent storage
    _jobService.updateJob(updatedJob).then((_) {
      debugPrint('Job $jobId saved to persistent storage');
    }).catchError((error) {
      debugPrint('Error saving job $jobId to persistent storage: $error');
    });
    
    // Notify listeners
    final status = successful ? 'found' : 'completed';
    
    // Notify through the job completed stream
    _jobCompletedController.add({
      'jobId': jobId,
      'status': status,
      'foundNonce': foundNonce,
      'foundHash': foundHash,
    });
    
    // Also notify through the callback for backward compatibility
    onUpdate({
      'jobId': jobId,
      'status': status,
      'foundNonce': foundNonce,
      'foundHash': foundHash,
    });
  }

  // Broadcast job updates to listeners
  void _broadcastJobUpdates() {
    // Update all active jobs
    for (final jobId in _activeJobs.keys) {
      final job = _activeJobs[jobId];
      if (job == null) continue;
      
      final workers = _jobWorkers[jobId] ?? [];
      
      // Calculate aggregate stats
      int totalHashesChecked = 0;
      int highestNonce = job.startNonce;
      bool allWorkersCompleted = workers.isNotEmpty;
      
      for (final worker in workers) {
        totalHashesChecked += worker.hashesProcessed;
        if (worker.lastProcessedNonce > highestNonce) {
          highestNonce = worker.lastProcessedNonce;
        }
        
        // Check if all workers are completed
        if (worker.isActive && worker.status != 'completed') {
          allWorkersCompleted = false;
        }
      }
      
      // Calculate progress
      final totalRange = job.endNonce - job.startNonce;
      final progress = totalRange > 0
          ? ((highestNonce - job.startNonce) / totalRange * 100).clamp(0.0, 100.0)
          : 0.0;
      
      // Calculate hash rate and remaining time
      final hashRate = _calculateStableHashRate(totalHashesChecked, job.startTime, _hashRateHistory[jobId] ?? []);
      final remainingHashes = job.endNonce - highestNonce;
      final remainingTime = _calculateStableRemainingTime(
        highestNonce, job.startNonce, job.endNonce, totalHashesChecked, job.startTime, _hashRateHistory[jobId] ?? []);
      
      // If all workers are completed and the job is not marked as completed, mark it as completed
      if (allWorkersCompleted && !job.completed) {
        if (_activeJobs[jobId] != null) {
          _activeJobs[jobId] = _activeJobs[jobId]!.copyWith(
            completed: true,
            successful: false,
          );
        }
      }
      
      // Update job stats
      _jobStats[jobId] = {
        'progress': progress,
        'hashRate': hashRate,
        'remainingTime': remainingTime,
        'activeWorkers': workers.where((w) => w.isActive).length,
        'currentNonce': highestNonce,
      };
      
      // Broadcast job update
      _jobUpdateController.add({
        'jobId': jobId,
        'progress': progress,
        'hashRate': hashRate,
        'remainingTime': remainingTime,
        'currentNonce': highestNonce,
        'activeWorkers': workers.where((w) => w.isActive).length,
      });
    }
  }

  void _broadcastAllJobUpdates() {
    for (final jobId in _activeJobs.keys) {
      _broadcastJobUpdate(jobId);
    }
  }

  void _broadcastJobUpdate(String jobId) {
    // Check if the job exists in active jobs
    final job = _activeJobs[jobId];
    if (job == null) {
      // Job might have been moved to completed jobs
      debugPrint('Job $jobId not found in active jobs for broadcast update');
      return;
    }
    
    final workers = _jobWorkers[jobId] ?? [];
    
    // Calculate aggregate stats
    double totalHashRate = 0.0;
    int highestNonce = job.startNonce;
    bool allWorkersCompleted = workers.isNotEmpty;
    
    for (final worker in workers) {
      totalHashRate += worker.hashRate; 
      if (worker.lastProcessedNonce > highestNonce) {
        highestNonce = worker.lastProcessedNonce;
      }
      
      // Check if any worker is still active
      if (worker.isActive) {
        allWorkersCompleted = false;
      }
    }
    
    // Calculate progress
    final totalRange = job.endNonce - job.startNonce;
    final progress = totalRange > 0 
        ? ((highestNonce - job.startNonce) / totalRange * 100).clamp(0.0, 100.0) 
        : 0.0;
    
    // Calculate remaining time
    double remainingTime = 0.0;
    if (totalHashRate > 0 && totalRange > 0) {
      final remainingHashes = job.endNonce - highestNonce;
      remainingTime = remainingHashes / (totalHashRate * 1000); // Convert to seconds
    }
    
    // Notify listeners through the stream controller
    _jobUpdateController.add({
      'jobId': jobId,
      'progress': progress,
      'hashRate': totalHashRate,
      'remainingTime': remainingTime,
      'currentNonce': highestNonce,
      'workerDetails': workers.map((worker) => {
        'workerId': worker.id,
        'lastNonce': worker.lastProcessedNonce,
        'status': worker.status,
        'hashRate': worker.hashRate,
        'startNonce': worker.currentBatchStart,
        'endNonce': worker.currentBatchEnd,
        'isActive': worker.isActive,
      }).toList(),
      'isPaused': _pausedJobs.containsKey(jobId),
      'isCompleted': job.completed,
      'isSuccessful': job.successful,
    });
  }

  // Expose job retrieval from the job service
  Future<MiningJob?> getJob(String jobId) async {
    return await _jobService.getJob(jobId);
  }

  // Get all active jobs
  Future<List<MiningJob>> getActiveJobs() async {
    return await _jobService.getActiveJobs();
  }
  
  // Get the speed multiplier for a job
  Future<double> getJobSpeedMultiplier(String jobId) async {
    // First check if we have the speed multiplier in memory
    if (_speedMultipliers.containsKey(jobId)) {
      return _speedMultipliers[jobId]!;
    }
    
    // If not in memory, try to get it from the stored job
    final job = await _jobService.getJob(jobId);
    if (job != null && job.speedMultiplier != null) {
      return job.speedMultiplier!;
    }
    
    // Default to 1.0 if not found
    return 1.0;
  }

  /// Returns only the jobs that are currently active in memory
  /// This doesn't load jobs from storage, only returns what's already running
  List<MiningJob> getCurrentlyActiveJobs() {
    // Return only the jobs that are currently active in the mining service
    // This doesn't load from storage, only returns what's already in memory
    final List<MiningJob> activeJobs = [];
    
    // Convert the active jobs from the internal format to MiningJob objects
    _activeJobs.forEach((jobId, jobData) {
      // Only include jobs that are actually running or paused, not completed ones
      if (!jobData.completed) {
        activeJobs.add(MiningJob(
          id: jobId,
          content: jobData.content,
          leader: jobData.leader,
          owner: jobData.owner,
          height: jobData.height,
          rewardType: jobData.rewardType, // Already stored as string '0' or '1'
          difficulty: jobData.difficulty,
          startNonce: jobData.startNonce,
          endNonce: jobData.endNonce,
          startTime: jobData.startTime,
          lastTriedNonce: jobData.lastTriedNonce,
        ));
      }
    });
    
    return activeJobs;
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
  
  // Get job statistics for a specific job ID
  Map<String, dynamic> getJobStats(String jobId) {
    if (_jobStats.containsKey(jobId)) {
      return Map<String, dynamic>.from(_jobStats[jobId]!);
    }
    return {
      'progress': 0.0,
      'hashRate': 0.0,
      'remainingTime': 0.0,
      'activeWorkers': 0,
      'currentNonce': 0,
    };
  }

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

      // Re-throw the error for the caller to handle
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
    debugPrint('Saving state for all active and completed jobs');
    
    // For each active job, update its last tried nonce
    for (final jobId in _activeJobs.keys) {
      final job = _activeJobs[jobId];
      final isPaused = _pausedJobs[jobId] != null;
      
      if (job != null) {
        // Get the highest nonce processed by any worker
        int highestNonce = job.lastTriedNonce;
        
        // Update worker nonce states
        Map<int, int> updatedWorkerNonces = Map.from(job.workerLastNonces);
        
        for (final worker in _jobWorkers[jobId] ?? []) {
          if (worker.lastProcessedNonce > highestNonce) {
            highestNonce = worker.lastProcessedNonce;
          }
          
          // Update the worker's last nonce in the job state
          updatedWorkerNonces[worker.id] = worker.lastProcessedNonce;
        }
        
        // Create an updated job with the latest nonce information and speed multiplier
        final updatedJob = job.copyWith(
          lastTriedNonce: highestNonce,
          workerLastNonces: updatedWorkerNonces,
          speedMultiplier: _speedMultipliers[jobId],
        );
        
        // Update the job in the service
        await _jobService.updateJob(updatedJob);
      }
    }
    
    // Also save completed jobs
    for (final jobId in _completedJobs.keys) {
      final job = _completedJobs[jobId];
      if (job != null) {
        await _jobService.updateJob(job);
      }
    }
  }

  // Get a job by ID (synchronous version)
  MiningJob? getJobSync(String jobId) {
    if (_activeJobs.containsKey(jobId)) {
      return _activeJobs[jobId];
    }
    
    final pausedJob = _pausedJobs[jobId]; // Corrected access
    
    return pausedJob;
  }

  // Helper method to send commands to all workers for a job
  void _sendCommandToWorkers(String jobId, String command, [Map<String, dynamic>? data]) {
    final workers = _jobWorkers[jobId];
    if (workers == null || workers.isEmpty) {
      debugPrint('No workers found for job $jobId');
      return;
    }
    
    final Map<String, dynamic> message = <String, dynamic>{'command': command};
    if (data != null) {
      message.addAll(data);
    }
    
    for (final worker in workers) {
      _workerSendPorts[jobId]![worker.id]?.send(message);
    }
  }

  // Clean up resources for a job
  void _cleanupJob(String jobId) {
    // Cancel receive streams
    if (_receiveStreams.containsKey(jobId)) {
      for (final stream in _receiveStreams[jobId]!) {
        stream.cancel();
      }
      _receiveStreams.remove(jobId);
    }
    
    // Close receive ports
    if (_workerPorts.containsKey(jobId)) {
      for (final workerId in _workerPorts[jobId]!.keys) {
        _workerPorts[jobId]![workerId]!.close();
      }
      _workerPorts.remove(jobId);
    }
    
    // Kill isolates
    if (_workerIsolates.containsKey(jobId)) {
      for (final workerId in _workerIsolates[jobId]!.keys) {
        _workerIsolates[jobId]![workerId]!.kill(priority: Isolate.immediate);
      }
      _workerIsolates.remove(jobId);
    }
    
    // Clean up send ports
    if (_workerSendPorts.containsKey(jobId)) {
      _workerSendPorts.remove(jobId);
    }
    
    // Clean up job workers
    if (_jobWorkers.containsKey(jobId)) {
      _jobWorkers.remove(jobId);
    }
    
    // Clean up job stats
    if (_jobStats.containsKey(jobId)) {
      _jobStats.remove(jobId);
    }
    
    // Clean up hash rate history
    if (_hashRateHistory.containsKey(jobId)) {
      _hashRateHistory.remove(jobId);
    }
    
    // Clean up last remaining times
    if (_lastRemainingTimes.containsKey(jobId)) {
      _lastRemainingTimes.remove(jobId);
    }
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
    final rewardType = params['rewardType'] as String; // Received as string '0' or '1'
    final difficulty = params['difficulty'] as int;
    int startNonce = params['startNonce'] as int;
    int endNonce = params['endNonce'] as int;
    
    // Create a receive port for communication with the main isolate
    final receivePort = ReceivePort();
    
    // Send the receive port to the main isolate
    sendPort.send({
      'port': receivePort.sendPort,
    });
    
    // Variables for tracking mining progress
    bool isMining = false;
    int lastProcessedNonce = startNonce - 1;
    int hashesProcessed = 0;
    int lastReportTime = DateTime.now().millisecondsSinceEpoch;
    double speedMultiplier = 1.0; // Default speed multiplier
    
    // Function to start mining
    void startMining() {
      isMining = true;
      
      // Send status update
      sendPort.send({
        'status': 'mining',
        'workerId': workerId,
        'jobId': jobId,
        'lastProcessedNonce': lastProcessedNonce,
        'hashesProcessed': hashesProcessed,
      });
      
      // Start mining loop
      Timer.periodic(const Duration(milliseconds: 10), (timer) {
        if (!isMining) {
          timer.cancel();
          return;
        }
        
        // Process a batch of nonces - use speedMultiplier to adjust batch size
        final batchSize = (100 * speedMultiplier).round();
        for (int i = 0; i < batchSize; i++) {
          // Check if we've reached the end of our range
          if (lastProcessedNonce >= endNonce) {
            timer.cancel();
            isMining = false;
            
            // Send batch complete status
            sendPort.send({
              'status': 'batchComplete',
              'workerId': workerId,
              'jobId': jobId,
              'lastProcessedNonce': lastProcessedNonce,
              'hashesProcessed': hashesProcessed,
            });
            return;
          }
          
          // Increment the nonce
          lastProcessedNonce++;
          hashesProcessed++;
          
          // Convert rewardType from string to int for HashUtils.createTicket
          final rewardTypeInt = int.parse(rewardType);
          final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          
          // Check if we've found a solution
          final hash = HashUtils.createTicket(
            content,
            leader,
            height,
            owner,
            rewardTypeInt, // Pass as int to HashUtils
            timestamp,
            lastProcessedNonce,
          );
          
          // Check if the hash meets the difficulty requirement
          final targetPrefix = '0' * difficulty;
          if (hash.startsWith(targetPrefix)) {
            timer.cancel();
            isMining = false;
            
            // Send solution found status
            sendPort.send({
              'status': 'solutionFound',
              'workerId': workerId,
              'jobId': jobId,
              'lastProcessedNonce': lastProcessedNonce,
              'hashesProcessed': hashesProcessed,
              'nonce': lastProcessedNonce,
              'hash': hash,
            });
            return;
          }
        }
        
        // Send progress update every second
        final currentTime = DateTime.now().millisecondsSinceEpoch;
        if (currentTime - lastReportTime >= 1000) {
          sendPort.send({
            'status': 'progress',
            'workerId': workerId,
            'jobId': jobId,
            'lastProcessedNonce': lastProcessedNonce,
            'hashesProcessed': hashesProcessed,
          });
          
          // Reset the hashes processed counter for the next report
          // but keep the total for this batch
          hashesProcessed = 0;
          lastReportTime = currentTime;
        }
      });
    }
    
    // Listen for commands from the main isolate
    receivePort.listen((message) {
      if (message is Map<String, dynamic>) {
        final command = message['command'] as String;
        
        switch (command) {
          case 'pause':
            isMining = false;
            sendPort.send({
              'status': 'paused',
              'workerId': workerId,
              'jobId': jobId,
              'lastProcessedNonce': lastProcessedNonce,
              'hashesProcessed': hashesProcessed,
            });
            break;
            
          case 'resume':
            if (!isMining) {
              startMining();
            }
            break;
            
          case 'stop':
            isMining = false;
            // Close the receive port
            receivePort.close();
            break;
            
          case 'newBatch':
            // Update the nonce range
            startNonce = message['startNonce'] as int;
            endNonce = message['endNonce'] as int;
            lastProcessedNonce = startNonce - 1;
            hashesProcessed = 0;
            
            // If we were mining, stop the current mining process
            isMining = false;
            
            // Start mining with the new batch after a short delay
            // to ensure any existing mining loops are canceled
            Future.delayed(Duration(milliseconds: 50), () {
              startMining();
            });
            break;
            
          case 'speed':
            // Update the speed multiplier
            speedMultiplier = message['value'] as double;
            debugPrint('Worker $workerId speed updated to $speedMultiplier');
            break;
        }
      }
    });
    
    // Send initial status
    sendPort.send({
      'status': 'ready',
      'workerId': workerId,
      'jobId': jobId,
      'lastProcessedNonce': lastProcessedNonce,
      'hashesProcessed': hashesProcessed,
    });
    
    // Start mining automatically after sending ready status
    startMining();
  }
  
  // Calculate stable hash rate with moving average
  static double _calculateStableHashRate(int hashesChecked, DateTime startTime, List<double> history) {
    final duration = DateTime.now().difference(startTime).inMilliseconds / 1000.0;
    if (duration <= 0) return 0.0;
    
    final currentRate = hashesChecked / duration; // Calculate hashes per second
    
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
  
  // Resume a previously paused job
  Future<void> resumeJob(String jobId) async {
    await _lock.synchronized(() async {
      // Check if the job is paused
      if (!_pausedJobs.containsKey(jobId)) {
        debugPrint('Job $jobId is not paused');
        return;
      }
      
      // Get the paused job
      final pausedJob = _pausedJobs[jobId]!;
      
      // Remove from paused jobs
      _pausedJobs.remove(jobId);
      
      // Start mining with the job's parameters
      await startMining(
        jobId: pausedJob.id,
        content: pausedJob.content,
        leader: pausedJob.leader,
        owner: pausedJob.owner,
        height: pausedJob.height,
        rewardType: pausedJob.rewardType, // Pass as string per memory requirement
        difficulty: pausedJob.difficulty,
        startNonce: pausedJob.startNonce,
        endNonce: pausedJob.endNonce,
        resumeFromNonce: pausedJob.lastTriedNonce,
        workerLastNonces: pausedJob.workerLastNonces, // Pass saved worker nonce state
        onUpdate: (update) {
          // Forward updates to any listeners
          _jobUpdateController.add({
            'jobId': jobId,
            'update': update,
          });
        },
      );
      
      debugPrint('Resumed job $jobId from nonce ${pausedJob.lastTriedNonce}');
    });
  }

  // Broadcast a ticket to the node
  Future<void> _broadcastTicket(String jobId, MiningJob job, int nonce) async {
    try {
      debugPrint(' Broadcasting ticket:');
      debugPrint('  Content: ${job.content}');
      debugPrint('  Leader: ${job.leader}');
      debugPrint('  Height: ${job.height}');
      debugPrint('  Owner: ${job.owner}');
      debugPrint('  Reward Type: ${job.rewardType}');
      debugPrint('  Nonce: $nonce');
      
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      debugPrint('  Timestamp: $timestamp');

      final ticketHex = HashUtils.ticketToHex(
        job.content,
        job.leader,
        job.height,
        job.owner,
        int.parse(job.rewardType), // Convert to int for HashUtils
        timestamp,
        nonce,
      );
      debugPrint('  Generated Ticket Hex: $ticketHex');

      final broadcastResponse = await _nodeService.broadcastRawSupportTicket(ticketHex);
      
      // Update the job with broadcast information
      final updatedJob = job.copyWith(
        broadcastSuccessful: true,
        broadcastHash: broadcastResponse.hash,
        completed: true,     // Ensure job is marked as completed
        successful: true,    // Ensure job is marked as successful
      );
      
      // Update in memory - both active and completed collections
      if (_activeJobs[jobId] != null) {
        _activeJobs[jobId] = updatedJob;
      }
      _completedJobs[jobId] = updatedJob;
      
      // Remove from active jobs if it's still there
      if (_activeJobs.containsKey(jobId)) {
        _activeJobs.remove(jobId);
      }
      
      // Update in persistent storage
      await _jobService.updateJob(updatedJob);

      debugPrint(' Broadcast successful:');
      debugPrint('  Job ID: $jobId');
      debugPrint('  Broadcast Hash: ${broadcastResponse.hash}');
      
      return;
    } catch (e) {
      debugPrint(' Error broadcasting solution:');
      debugPrint('  Error: $e');

      // Update the job with broadcast error
      final updatedJob = job.copyWith(
        broadcastSuccessful: false,
        broadcastError: e.toString(),
        completed: true,     // Still mark as completed even if broadcast failed
        successful: true,    // Still mark as successful even if broadcast failed
      );
      
      // Update in memory - both active and completed collections
      if (_activeJobs.containsKey(jobId)) {
        _activeJobs[jobId] = updatedJob;
      }
      _completedJobs[jobId] = updatedJob;
      
      // Remove from active jobs if it's still there
      if (_activeJobs.containsKey(jobId)) {
        _activeJobs.remove(jobId);
      }
      
      // Update in persistent storage
      await _jobService.updateJob(updatedJob);

      // Re-throw the error for the caller to handle
      throw e;
    }
  }

  Future<List<MiningJob>> getFilteredJobs({
    JobSortOption sortBy = JobSortOption.creationTimeDesc,
    JobStatusFilter statusFilter = JobStatusFilter.all,
    List<int>? difficultyRange,
    String? owner,
    String? leader,
    int? height,
    String? content,
  }) {
    return _jobService.getFilteredJobs(
      sortBy: sortBy,
      statusFilter: statusFilter,
      difficultyRange: difficultyRange,
      owner: owner,
      leader: leader,
      height: height,
      content: content,
    );
  }

  Future<Map<String, dynamic>> getFilterOptions() async {
    final allJobs = await _jobService.getAllJobs();
    
    // Extract unique values for each filterable field
    final Set<String> owners = {};
    final Set<String> leaders = {};
    final Set<int> heights = {};
    final Set<int> difficulties = {};
    
    for (final job in allJobs) {
      owners.add(job.owner);
      leaders.add(job.leader);
      heights.add(job.height);
      difficulties.add(job.difficulty);
    }
    
    return {
      'owners': owners.toList()..sort(),
      'leaders': leaders.toList()..sort(),
      'heights': heights.toList()..sort(),
      'difficulties': difficulties.toList()..sort(),
      'statusOptions': JobStatusFilter.values,
      'sortOptions': JobSortOption.values,
    };
  }
  
  // The getJobSpeedMultiplier method is already defined earlier in this class
}
