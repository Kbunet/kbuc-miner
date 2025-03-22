import 'package:flutter/material.dart';
import '../models/mining_job.dart';
import '../services/mining_service.dart';
import '../widgets/mining_job_details.dart';

class HistoryScreen extends StatefulWidget {
  final MiningService miningService;

  const HistoryScreen({super.key, required this.miningService});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<MiningJob> _jobs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadJobs();
  }

  Future<void> _loadJobs() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final jobs = await widget.miningService.getAllJobs();
      setState(() {
        _jobs = jobs;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading jobs: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      setState(() {
        _isLoading = false;
      });
    }
  }

  List<MiningJob> _getFilteredJobs(int tabIndex) {
    switch (tabIndex) {
      case 0: // All
        return _jobs;
      case 1: // Active
        return _jobs.where((job) => !job.completed).toList();
      case 2: // Completed
        return _jobs.where((job) => job.completed).toList();
      case 3: // Successful
        return _jobs.where((job) => job.successful).toList();
      default:
        return [];
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mining History'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'All'),
            Tab(text: 'Active'),
            Tab(text: 'Completed'),
            Tab(text: 'Successful'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: List.generate(4, (index) {
                final filteredJobs = _getFilteredJobs(index);
                if (filteredJobs.isEmpty) {
                  return const Center(
                    child: Text('No jobs found'),
                  );
                }
                return RefreshIndicator(
                  onRefresh: _loadJobs,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16.0),
                    itemCount: filteredJobs.length,
                    itemBuilder: (context, i) {
                      return MiningJobDetails(job: filteredJobs[i]);
                    },
                  ),
                );
              }),
            ),
    );
  }
}
