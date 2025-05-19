import 'package:flutter/material.dart';
import 'package:miner_app/services/mining_service.dart';
import 'package:miner_app/services/background_service.dart';
import 'package:miner_app/services/notification_service.dart';
import 'package:miner_app/widgets/create_mining_job_dialog.dart';
import 'package:miner_app/widgets/mining_card.dart';
import 'package:miner_app/screens/settings_screen.dart';
import 'package:miner_app/screens/history_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:workmanager/workmanager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize notification service
  final notificationService = NotificationService();
  await notificationService.init();
  
  // Initialize Workmanager with custom configuration
  await Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: false, // Set to false to reduce debug notifications
  );
  
  // Register periodic task for background mining
  await Workmanager().registerPeriodicTask(
    'background-mining-task',
    kBackgroundMiningTask,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(
      networkType: NetworkType.not_required,
      requiresBatteryNotLow: false,
      requiresCharging: false,
      requiresDeviceIdle: false,
      requiresStorageNotLow: false,
    ),
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );
  
  // Initialize background service
  final backgroundService = BackgroundMiningService();
  await backgroundService.init();
  
  // Request notification permission
  await Permission.notification.request();
  
  runApp(const MinerApp());
}

class MinerApp extends StatelessWidget {
  const MinerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bitcoin Miner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MinerAppHome(),
    );
  }
}

class MinerAppHome extends StatefulWidget {
  const MinerAppHome({super.key});

  @override
  State<MinerAppHome> createState() => _MinerAppHomeState();
}

class _MinerAppHomeState extends State<MinerAppHome> with WidgetsBindingObserver {
  // Map to store active jobs with their details
  final Map<String, Map<String, dynamic>> _jobs = {};
  
  // Map to track paused state of jobs
  final Map<String, bool> _pausedJobs = {};
  
  // Service for mining operations
  final MiningService _miningService = MiningService();
  
  // Background service for background processing
  final BackgroundMiningService _backgroundService = BackgroundMiningService();
  
  // Track if background service is running
  bool _isBackgroundServiceRunning = false;

  @override
  void initState() {
    super.initState();
    _loadActiveJobs();
    
    // Register app lifecycle listener to save job state when app is paused or stopped
    WidgetsBinding.instance.addObserver(this);
    
    // Listen to job updates from the mining service
    _miningService.jobUpdates.listen(_handleStreamUpdate);
    _miningService.jobCompleted.listen(_handleJobCompleted);
    
    // Check background service status
    _checkBackgroundServiceStatus();
    
    // Request necessary permissions
    _requestPermissions();
  }
  
  // Handle updates from the mining service stream
  void _handleStreamUpdate(Map<String, dynamic> update) {
    if (!mounted) return;
    
    final jobId = update['jobId'] as String;
    
    // Check if this job is still in our list
    if (!_jobs.containsKey(jobId)) {
      // If not, we might need to add it (for newly created jobs)
      if (update['status'] == 'progress' || update['status'] == 'paused') {
        // We'll add it to our tracking
        setState(() {
          _jobs[jobId] = {
            'progress': _safeDoubleValue(update['progress']),
            'hashRate': _safeDoubleValue(update['hashRate']),
            'remainingTime': _safeDoubleValue(update['remainingTime']),
            'currentNonce': update['currentNonce'] as int? ?? 0,
            'speedMultiplier': 1.0,
            'activeWorkers': _miningService.getActiveWorkerCount(jobId),
            'workerDetails': update['workerDetails'] != null 
              ? (update['workerDetails'] as List).cast<Map<String, dynamic>>() 
              : <Map<String, dynamic>>[],
          };
          _pausedJobs[jobId] = update['isPaused'] as bool? ?? false;
        });
      }
      return;
    }
    
    setState(() {
      // Get the existing job data
      final job = Map<String, dynamic>.from(_jobs[jobId]!);
      
      // Update job properties from the update
      if (update.containsKey('progress')) {
        job['progress'] = _safeDoubleValue(update['progress']);
      }
      if (update.containsKey('hashRate')) {
        job['hashRate'] = _safeDoubleValue(update['hashRate']);
      }
      if (update.containsKey('remainingTime')) {
        job['remainingTime'] = _safeDoubleValue(update['remainingTime']);
      }
      if (update.containsKey('currentNonce')) {
        job['currentNonce'] = update['currentNonce'] as int;
      }
      
      // Update the active workers count
      job['activeWorkers'] = _miningService.getActiveWorkerCount(jobId);
      
      if (update.containsKey('workerDetails')) {
        job['workerDetails'] = update['workerDetails'] != null 
          ? (update['workerDetails'] as List).cast<Map<String, dynamic>>() 
          : <Map<String, dynamic>>[];
      }
      
      _jobs[jobId] = job;
      
      // Make sure UI pause state matches the mining service state
      if (update.containsKey('isPaused')) {
        _pausedJobs[jobId] = update['isPaused'] as bool;
      }
    });
  }
  
  // Handle job completion events
  void _handleJobCompleted(Map<String, dynamic> update) {
    if (!mounted) return;
    
    // Debug log the entire update map
    debugPrint('Job completion update received:');
    update.forEach((key, value) {
      debugPrint('  $key: $value (${value?.runtimeType})'); 
    });
    
    final jobId = update['jobId'] as String;
    final String status = update['status'] as String? ?? 'completed';
    final dynamic foundNonce = update['foundNonce'];
    final String? foundHash = update['foundHash'] as String?;
    
    // Determine if the job was successful based on the status
    final bool successful = status == 'found';
    debugPrint('Job completion status: $status, successful: $successful');
    
    // Remove job from active jobs
    setState(() {
      _jobs.remove(jobId);
      _pausedJobs.remove(jobId);
    });
    
    // Show a snackbar with the result
    final message = successful
        ? 'Mining job $jobId completed successfully! Found nonce: ${foundNonce?.toString() ?? 'unknown'}'
        : 'Mining job $jobId completed without finding a solution';
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: successful ? Colors.green : Colors.orange,
        duration: const Duration(seconds: 5),
      ),
    );
    
    // Show notification
    NotificationService().showJobCompletionNotification(
      jobId: jobId,
      successful: successful,
      foundNonce: foundNonce?.toString(),
      foundHash: foundHash,
    );
    
    // Save the job state
    _saveJobState();
  }

  Future<void> _loadActiveJobs() async {
    try {
      final activeJobs = await _miningService.getActiveJobs();
      
      setState(() {
        for (final job in activeJobs) {
          // Get the number of active workers for this job
          final activeWorkers = _miningService.getActiveWorkerCount(job.id);
          
          _jobs[job.id] = {
            'content': job.content,
            'leader': job.leader,
            'owner': job.owner,
            'height': job.height,
            'rewardType': job.rewardType, // Already stored as string '0' or '1'
            'difficulty': job.difficulty,
            'startNonce': job.startNonce,
            'endNonce': job.endNonce,
            'progress': 0.0, // Will be updated by mining service
            'hashRate': 0.0, // Will be updated by mining service
            'remainingTime': 0.0, // Will be updated by mining service
            'currentNonce': job.lastTriedNonce,
            'speedMultiplier': 1.0, // Default speed multiplier
            'activeWorkers': activeWorkers, // Add active workers count
            'workerDetails': [], // Initialize worker details
          };
          
          // Initialize as not paused
          _pausedJobs[job.id] = false;
        }
      });
      
      // Start listening for updates for each job
      for (final jobId in _jobs.keys) {
        _miningService.startMining(
          jobId: jobId,
          content: _jobs[jobId]!['content'] as String,
          leader: _jobs[jobId]!['leader'] as String,
          owner: _jobs[jobId]!['owner'] as String,
          height: _jobs[jobId]!['height'] as int,
          rewardType: _jobs[jobId]!['rewardType'] as String, // Pass as string '0' or '1' per memory requirement
          difficulty: _jobs[jobId]!['difficulty'] as int,
          startNonce: _jobs[jobId]!['startNonce'] as int,
          endNonce: _jobs[jobId]!['endNonce'] as int,
          onUpdate: (_) {}, // Empty callback as we're using streams now
        );
      }
    } catch (e) {
      debugPrint('Error loading active jobs: $e');
    }
  }

  void _stopMining(String jobId) {
    debugPrint('Stopping mining for job: $jobId');
    _miningService.stopMining(jobId);
    setState(() {
      _jobs.remove(jobId);
      _pausedJobs.remove(jobId);
    });
    
    // If no more jobs, stop background service
    if (_jobs.isEmpty && _isBackgroundServiceRunning) {
      _stopBackgroundService();
    }
  }

  void _togglePause(String jobId) {
    // Log the job ID for debugging
    debugPrint('Toggling pause for job ID: $jobId');
    
    // Check if the job exists in our UI state
    if (!_jobs.containsKey(jobId)) {
      debugPrint('Warning: Job not found in UI state: $jobId');
      return;
    }
    
    // Toggle the UI state first
    final newPausedState = !(_pausedJobs[jobId] ?? false);
    setState(() {
      _pausedJobs[jobId] = newPausedState;
    });
    
    // Then try to toggle in the service
    _miningService.togglePause(jobId).then((success) {
      if (!success) {
        debugPrint('Failed to toggle pause in service, attempting to restart job');
        // If toggle failed, try to restart the job
        final job = _jobs[jobId]!;
        _miningService.startMining(
          jobId: jobId,
          content: job['content'] as String,
          leader: job['leader'] as String,
          owner: job['owner'] as String,
          height: job['height'] as int,
          rewardType: job['rewardType'] as String, // Already a string '0' or '1' per memory requirement
          difficulty: job['difficulty'] as int,
          startNonce: job['startNonce'] as int,
          endNonce: job['endNonce'] as int,
          onUpdate: _handleMiningUpdate,
        ).then((_) {
          // If we're restarting a job that should be paused, pause it immediately
          if (newPausedState) {
            debugPrint('Job restarted, now pausing it as requested');
            _miningService.togglePause(jobId);
          }
        });
      }
    });
  }

  void _updateSpeed(String jobId, double value) {
    _miningService.updateSpeed(jobId, value);
    setState(() {
      if (_jobs.containsKey(jobId)) {
        final job = Map<String, dynamic>.from(_jobs[jobId]!);
        job['speedMultiplier'] = value;
        _jobs[jobId] = job;
      }
    });
  }

  void _handleMiningUpdate(Map<String, dynamic> update) {
    // Run on UI thread
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      
      final jobId = update['jobId'] as String;
      final status = update['status'] as String?;
      
      // Handle different update types
      switch (status) {
        case 'progress':
          // Update job progress
          setState(() {
            if (!_jobs.containsKey(jobId)) {
              // Add new job if it doesn't exist yet
              _jobs[jobId] = {
                'progress': _safeDoubleValue(update['progress']),
                'hashRate': _safeDoubleValue(update['hashRate']),
                'remainingTime': _safeDoubleValue(update['remainingTime']),
                'currentNonce': update['currentNonce'] as int? ?? 0,
                'speedMultiplier': 1.0,
                'activeWorkers': update['activeWorkers'] as int? ?? 0,
                'workerDetails': update['workerDetails'] != null 
                  ? (update['workerDetails'] as List).cast<Map<String, dynamic>>() 
                  : <Map<String, dynamic>>[],
              };
              _pausedJobs[jobId] = false;
            } else {
              // Update existing job
              final job = _jobs[jobId]!;
              job['progress'] = _safeDoubleValue(update['progress']);
              job['hashRate'] = _safeDoubleValue(update['hashRate']);
              job['remainingTime'] = _safeDoubleValue(update['remainingTime']);
              job['currentNonce'] = update['currentNonce'] as int? ?? job['currentNonce'] as int? ?? 0;
              job['activeWorkers'] = update['activeWorkers'] as int? ?? job['activeWorkers'] as int? ?? 0;
              
              if (update['workerDetails'] != null) {
                job['workerDetails'] = (update['workerDetails'] as List).cast<Map<String, dynamic>>();
              }
              
              // Show progress notification at significant milestones (25%, 50%, 75%)
              final double progress = _safeDoubleValue(update['progress']);
              final int progressPercent = (progress * 100).round();
              
              // Only show progress notifications at significant milestones
              if (progressPercent % 25 == 0 && progressPercent > 0 && progressPercent < 100 && _isBackgroundServiceRunning) {
                // Schedule a notification for progress milestone
                Workmanager().registerOneOffTask(
                  'progress-notification-$jobId-$progressPercent',
                  kCompletionNotificationTask,
                  inputData: {
                    'title': 'Mining Progress: $progressPercent%',
                    'message': 'Job $jobId is $progressPercent% complete with hash rate ${job['hashRate'].toStringAsFixed(2)} H/s',
                  },
                  initialDelay: const Duration(seconds: 1),
                  existingWorkPolicy: ExistingWorkPolicy.keep,
                );
              }
            }
          });
          break;
        case 'found':
          // Solution found
          // Show a success notification (in-app)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Solution found for job $jobId!'),
              backgroundColor: Colors.green,
            ),
          );
          
          // Schedule a notification task for solution found
          Workmanager().registerOneOffTask(
            'completion-notification-${DateTime.now().millisecondsSinceEpoch}',
            kCompletionNotificationTask,
            inputData: {
              'title': 'Solution Found!',
              'message': 'Solution found for job $jobId!',
            },
            initialDelay: const Duration(seconds: 1),
          );
          
          // Remove job from active jobs
          setState(() {
            _jobs.remove(jobId);
            _pausedJobs.remove(jobId);
          });
          break;
        case 'completed':
          // Show in-app notification
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Job $jobId completed without finding solution'),
              backgroundColor: Colors.orange,
            ),
          );
          
          // Schedule a notification task for completion
          Workmanager().registerOneOffTask(
            'completion-notification-${DateTime.now().millisecondsSinceEpoch}',
            kCompletionNotificationTask,
            inputData: {
              'title': 'Mining Job Completed',
              'message': 'Job $jobId completed without finding a solution',
            },
            initialDelay: const Duration(seconds: 1),
          );
          
          // Remove job from active jobs
          setState(() {
            _jobs.remove(jobId);
            _pausedJobs.remove(jobId);
          });
          break;
      }
      
      // Make sure UI pause state matches the mining service state
      if (update.containsKey('isPaused')) {
        _pausedJobs[jobId] = update['isPaused'] as bool;
        // Show a success notification
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Solution found for job $jobId!'),
            backgroundColor: Colors.green,
          ),
        );
        
        // Remove the job from the active jobs list in the UI
        _jobs.remove(jobId);
        _pausedJobs.remove(jobId);
      } else if (update['status'] == 'completed') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Job $jobId completed without finding solution'),
            backgroundColor: Colors.orange,
          ),
        );
        _jobs.remove(jobId);
        _pausedJobs.remove(jobId);
      } else if (update['status'] == 'error') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${update['message']}'),
            backgroundColor: Colors.red,
          ),
        );
        _jobs.remove(jobId);
        _pausedJobs.remove(jobId);
      }
    });
  }
  
  // Helper method to safely convert values to double
  double _safeDoubleValue(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    try {
      return double.parse(value.toString());
    } catch (e) {
      return 0.0;
    }
  }

  void _showCreateMiningJobDialog() {
    showDialog(
      context: context,
      builder: (context) => CreateMiningJobDialog(
        onSubmit: (
          String content,
          String leader,
          String owner,
          int height,
          String rewardType, // Already a string '0' or '1' per memory requirement
          int difficulty,
          int startNonce,
          int endNonce,
        ) {
          // Generate a unique job ID
          final jobId = DateTime.now().millisecondsSinceEpoch.toString();
          
          // Add job to UI state
          setState(() {
            _jobs[jobId] = {
              'content': content,
              'leader': leader,
              'owner': owner,
              'height': height,
              'rewardType': rewardType, // Store as string '0' or '1' per memory requirement
              'difficulty': difficulty,
              'startNonce': startNonce,
              'endNonce': endNonce,
              'progress': 0.0,
              'hashRate': 0.0,
              'remainingTime': 0.0,
              'currentNonce': startNonce,
              'speedMultiplier': 1.0,
              'activeWorkers': 0,
              'workerDetails': <Map<String, dynamic>>[],
            };
            _pausedJobs[jobId] = false;
          });
          
          // Start mining
          _miningService.startMining(
            jobId: jobId,
            content: content,
            leader: leader,
            owner: owner,
            height: height,
            rewardType: rewardType, // Pass as string '0' or '1' per memory requirement
            difficulty: difficulty,
            startNonce: startNonce,
            endNonce: endNonce,
            onUpdate: (_) {}, // Empty callback as we're using streams now
          );
          
          // If this is the first job, start background service
          if (_jobs.length == 1) {
            _startBackgroundService();
          }
        },
      ),
    );
  }

  Future<void> _clearAllJobs() async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Mining History'),
        content: const Text(
          'Are you sure you want to clear all mining history? '
          'This will stop all active mining jobs and delete all job records. '
          'This action cannot be undone.'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    ) ?? false;

    if (confirmed) {
      // Clear all jobs
      await _miningService.clearAllJobs();
      
      // Update UI
      setState(() {
        _jobs.clear();
        _pausedJobs.clear();
      });
      
      // Show confirmation
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mining history cleared'),
            backgroundColor: Colors.blue,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    // Save job state and unregister observer when widget is disposed
    _saveJobState();
    WidgetsBinding.instance.removeObserver(this);
    _miningService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Save job state when app is paused or inactive
    if (state == AppLifecycleState.paused || 
        state == AppLifecycleState.inactive || 
        state == AppLifecycleState.detached) {
      _saveJobState();
      
      // Start background service if we have active jobs
      if (_jobs.isNotEmpty && !_isBackgroundServiceRunning) {
        _startBackgroundService();
      }
    } else if (state == AppLifecycleState.resumed) {
      // Check background service status when app is resumed
      _checkBackgroundServiceStatus();
    }
  }
  
  // Save the current state of all active jobs
  Future<void> _saveJobState() async {
    await _miningService.saveJobState();
  }
  
  // Request necessary permissions
  Future<void> _requestPermissions() async {
    // Request notification permission
    final notificationStatus = await Permission.notification.request();
    debugPrint('Notification permission status: $notificationStatus');
    await Permission.ignoreBatteryOptimizations.request();
  }
  
  // Check background service status
  Future<void> _checkBackgroundServiceStatus() async {
    _isBackgroundServiceRunning = await _backgroundService.isServiceRunning();
  }
  
  // Start background service
  Future<void> _startBackgroundService() async {
    if (!_isBackgroundServiceRunning) {
      final started = await _backgroundService.startService();
      if (started) {
        setState(() {
          _isBackgroundServiceRunning = true;
        });
        
        // The background task will read the latest state from MiningService
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Background mining enabled'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }
  
  // Stop background service
  Future<void> _stopBackgroundService() async {
    if (_isBackgroundServiceRunning) {
      final stopped = await _backgroundService.stopService();
      if (stopped) {
        setState(() {
          _isBackgroundServiceRunning = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('KBUC Miner'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => HistoryScreen(miningService: _miningService),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SettingsScreen(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: _clearAllJobs,
          ),
        ],
      ),
      body: _jobs.isEmpty
          ? const Center(
              child: Text('No active mining jobs'),
            )
          : ListView.builder(
              itemCount: _jobs.length,
              itemBuilder: (context, index) {
                final jobId = _jobs.keys.elementAt(index);
                final jobData = _jobs[jobId]!;
                
                // Get the job from the mining service for additional details
                final job = _miningService.getJobSync(jobId);
                
                return MiningCard(
                  jobId: jobId,
                  progress: jobData['progress'] as double? ?? 0.0,
                  hashRate: jobData['hashRate'] as double? ?? 0.0,
                  remainingTime: jobData['remainingTime'] as double? ?? 0.0,
                  isPaused: _pausedJobs[jobId] ?? false,
                  speedMultiplier: jobData['speedMultiplier'] as double? ?? 1.0,
                  lastTriedNonce: jobData['currentNonce'] as int? ?? 0,
                  activeWorkers: jobData['activeWorkers'] as int? ?? 0,
                  workerDetails: (jobData['workerDetails'] as List<dynamic>?)
                      ?.cast<Map<String, dynamic>>() ?? [],
                  onPause: () => _togglePause(jobId),
                  onResume: () => _togglePause(jobId),
                  onStop: () => _stopMining(jobId),
                  onSpeedChange: (value) => _updateSpeed(jobId, value),
                  job: job,
                );
              },
            ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Background service toggle button
          if (_jobs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16.0),
              child: FloatingActionButton.small(
                onPressed: _isBackgroundServiceRunning 
                  ? _stopBackgroundService 
                  : _startBackgroundService,
                backgroundColor: _isBackgroundServiceRunning ? Colors.green : Colors.grey,
                child: Icon(_isBackgroundServiceRunning 
                  ? Icons.notifications_active 
                  : Icons.notifications_off),
              ),
            ),
          // Add new mining job button
          FloatingActionButton(
            onPressed: _showCreateMiningJobDialog,
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
