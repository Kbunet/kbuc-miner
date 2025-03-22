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
          'startNonce': job.foundNonce != null ? job.foundNonce! + 1 : job.startNonce,
          'endNonce': job.endNonce,
          'progress': 0.0,
          'hashRate': 0.0,
          'remainingTime': 0.0,
          'speedMultiplier': 1.0,
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

  @override
  void dispose() {
    _miningService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Bitcoin Miner'),
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
      body: _jobs.isEmpty
          ? const Center(
              child: Text(
                'No active mining jobs\nTap the + button to start mining',
                textAlign: TextAlign.center,
              ),
            )
          : ListView.builder(
              itemCount: _jobs.length,
              itemBuilder: (context, index) {
                final jobId = _jobs.keys.elementAt(index);
                final job = _jobs[jobId]!;
                return MiningCard(
                  jobId: jobId,
                  progress: job['progress'] as double,
                  hashRate: job['hashRate'] as double,
                  remainingTime: job['remainingTime'] as double,
                  speedMultiplier: job['speedMultiplier'] as double,
                  isPaused: _pausedJobs[jobId] ?? false,
                  onPauseResume: () => _togglePause(jobId),
                  onSpeedChange: (value) => _updateSpeed(jobId, value),
                  onStop: () => _stopMining(jobId),
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
