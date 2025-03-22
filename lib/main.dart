import 'package:flutter/material.dart';
import 'package:miner_app/services/mining_service.dart';
import 'package:miner_app/widgets/create_mining_job_dialog.dart';
import 'package:miner_app/widgets/mining_card.dart';
import 'package:miner_app/screens/settings_screen.dart';
import 'package:miner_app/screens/history_screen.dart';

void main() {
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

  @override
  void initState() {
    super.initState();
    _loadActiveJobs();
    
    // Register app lifecycle listener to save job state when app is paused or stopped
    WidgetsBinding.instance.addObserver(this);
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
          rewardType: _jobs[jobId]!['rewardType'] as String, // Pass as string '0' or '1'
          difficulty: _jobs[jobId]!['difficulty'] as int,
          nonceRange: [
            _jobs[jobId]!['startNonce'] as int,
            _jobs[jobId]!['endNonce'] as int,
          ],
          onUpdate: _handleMiningUpdate,
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
          nonceRange: [job['startNonce'] as int, job['endNonce'] as int],
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
      
      // Check if this job is still in our list
      if (!_jobs.containsKey(jobId)) {
        // If not, we might need to add it (for newly created jobs)
        if (update['status'] == 'running' || update['status'] == 'paused') {
          // We'll add it to our tracking
          setState(() {
            _jobs[jobId] = {
              'progress': _safeDoubleValue(update['progress']),
              'hashRate': _safeDoubleValue(update['hashRate']),
              'remainingTime': _safeDoubleValue(update['remainingTime']),
              'currentNonce': update['currentNonce'] as int? ?? 0,
              'speedMultiplier': 1.0,
              'activeWorkers': _miningService.getActiveWorkerCount(jobId),
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
        
        _jobs[jobId] = job;
      });
      
      // Make sure UI pause state matches the mining service state
      if (update.containsKey('isPaused')) {
        _pausedJobs[jobId] = update['isPaused'] as bool;
      }

      if (update['status'] == 'found') {
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

  Future<void> _showCreateMiningJobDialog() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const CreateMiningJobDialog(),
    );

    if (result != null) {
      final jobId = DateTime.now().millisecondsSinceEpoch.toString();
      debugPrint('Creating new job with ID: $jobId');
      
      setState(() {
        _jobs[jobId] = {
          'content': result['supportedHash'],
          'leader': result['leader'],
          'owner': result['jobOwner'],
          'height': result['height'],
          'rewardType': result['rewardType'].toString(), // Ensure reward type is a string
          'difficulty': result['difficulty'],
          'startNonce': result['nonceRange'][0],
          'endNonce': result['nonceRange'][1],
          'progress': 0.0,
          'hashRate': 0.0,
          'remainingTime': 0.0,
          'speedMultiplier': 1.0,
          'activeWorkers': 0, // Initialize active workers count
        };
        // Initialize as not paused
        _pausedJobs[jobId] = false;
      });

      await _miningService.startMining(
        jobId: jobId,
        content: result['supportedHash'],
        leader: result['leader'],
        owner: result['jobOwner'],
        height: result['height'],
        rewardType: result['rewardType'].toString(), // Ensure reward type is a string
        difficulty: result['difficulty'],
        nonceRange: result['nonceRange'],
        onUpdate: _handleMiningUpdate,
      );
    }
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
    }
  }
  
  // Save the current state of all active jobs
  Future<void> _saveJobState() async {
    await _miningService.saveJobState();
  }

  @override
  Widget build(BuildContext context) {
    final activeJobs = _jobs.entries.toList();
    
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Bitcoin Miner'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: _clearAllJobs,
            tooltip: 'Clear Mining History',
          ),
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
            tooltip: 'Mining History',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
            tooltip: 'Settings',
          ),
        ],
      ),
      body: activeJobs.isEmpty
          ? const Center(
              child: Text(
                'No active mining jobs\nTap the + button to start mining',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
              itemCount: activeJobs.length,
              itemBuilder: (context, index) {
                final job = activeJobs[index];
                final jobId = job.key;
                final jobData = job.value;
                final isPaused = _pausedJobs[jobId] ?? false;
                
                return MiningCard(
                  jobId: jobId,
                  progress: jobData['progress'] as double? ?? 0.0,
                  hashRate: jobData['hashRate'] as double? ?? 0.0,
                  remainingTime: jobData['remainingTime'] as double? ?? 0.0,
                  isPaused: isPaused,
                  speedMultiplier: jobData['speedMultiplier'] as double? ?? 1.0,
                  lastTriedNonce: jobData['currentNonce'] as int? ?? jobData['startNonce'] as int, 
                  activeWorkers: jobData['activeWorkers'] as int? ?? 0,
                  onPauseResume: () => _togglePause(jobId),
                  onStop: () => _stopMining(jobId),
                  onSpeedChange: (value) => _updateSpeed(jobId, value),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateMiningJobDialog,
        tooltip: 'Add Mining Job',
        child: const Icon(Icons.add),
      ),
    );
  }
}
