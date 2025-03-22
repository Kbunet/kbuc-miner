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

class _MinerAppHomeState extends State<MinerAppHome> {
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
  }

  Future<void> _loadActiveJobs() async {
    final activeJobs = await _miningService.getActiveJobs();
    debugPrint('Found ${activeJobs.length} active jobs');
    
    for (final job in activeJobs) {
      debugPrint('Loading active job: ${job.id}');
      // Store all job details needed for resuming mining
      setState(() {
        _jobs[job.id] = {
          'content': job.content,
          'leader': job.leader,
          'owner': job.owner,
          'height': job.height,
          'rewardType': job.rewardType, // Keep as string '0' or '1' per memory requirement
          'difficulty': job.difficulty,
          'startNonce': job.lastTriedNonce > job.startNonce ? job.lastTriedNonce : job.startNonce,
          'endNonce': job.endNonce,
          'progress': 0.0,
          'hashRate': 0.0,
          'remainingTime': 0.0,
          'speedMultiplier': 1.0,
          'currentNonce': job.lastTriedNonce, // Initialize with the last tried nonce
        };
        // Initialize all loaded jobs as paused
        _pausedJobs[job.id] = true;
      });
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
    final jobId = update['jobId'] as String;
    
    setState(() {
      // Update job state
      if (_jobs.containsKey(jobId)) {
        final job = Map<String, dynamic>.from(_jobs[jobId]!);
        
        // Update job properties from the update
        if (update.containsKey('progress')) {
          job['progress'] = update['progress'] as double;
        }
        if (update.containsKey('hashRate')) {
          job['hashRate'] = update['hashRate'] as double;
        }
        if (update.containsKey('remainingTime')) {
          job['remainingTime'] = update['remainingTime'] as double;
        }
        if (update.containsKey('currentNonce')) {
          job['currentNonce'] = update['currentNonce'] as int;
        }
        
        _jobs[jobId] = job;
      }
      
      // Make sure UI pause state matches the mining service state
      if (update.containsKey('isPaused')) {
        _pausedJobs[jobId] = update['isPaused'] as bool;
      }

      if (update['status'] == 'found') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Solution found for job $jobId!'),
            backgroundColor: Colors.green,
          ),
        );
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
    _miningService.dispose();
    super.dispose();
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
