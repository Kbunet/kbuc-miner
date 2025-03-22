import 'package:flutter/material.dart';
import '../models/mining_job.dart';
import '../services/mining_service.dart';
import '../services/mining_job_service.dart';
import '../widgets/mining_job_details.dart';
import '../widgets/job_filter_panel.dart';

class HistoryScreen extends StatefulWidget {
  final MiningService miningService;

  const HistoryScreen({super.key, required this.miningService});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<MiningJob> _jobs = [];
  List<MiningJob> _filteredJobs = [];
  bool _isLoading = true;
  Map<String, dynamic> _filterOptions = {};
  Map<String, dynamic> _currentFilters = {
    'sortBy': JobSortOption.creationTimeDesc,
    'statusFilter': JobStatusFilter.all,
  };

  @override
  void initState() {
    super.initState();
    _loadJobs();
    _loadFilterOptions();
  }

  Future<void> _loadFilterOptions() async {
    try {
      final options = await widget.miningService.getFilterOptions();
      setState(() {
        _filterOptions = options;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading filter options: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _loadJobs() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Use the new filtered jobs method
      final jobs = await widget.miningService.getFilteredJobs(
        sortBy: _currentFilters['sortBy'],
        statusFilter: _currentFilters['statusFilter'],
        difficultyRange: _currentFilters['difficultyRange'],
        owner: _currentFilters['owner'],
        leader: _currentFilters['leader'],
        height: _currentFilters['height'],
        content: _currentFilters['content'],
      );
      
      setState(() {
        _jobs = jobs;
        _filteredJobs = jobs;
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

  void _applyFilters(Map<String, dynamic> filters) {
    setState(() {
      _currentFilters = filters;
    });
    _loadJobs();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mining Jobs'),
      ),
      body: Column(
        children: [
          // Filter panel
          JobFilterPanel(
            onFilterChanged: _applyFilters,
            filterOptions: _filterOptions,
            currentFilters: _currentFilters,
          ),
          
          // Jobs list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredJobs.isEmpty
                    ? const Center(child: Text('No jobs found'))
                    : RefreshIndicator(
                        onRefresh: _loadJobs,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(16.0),
                          itemCount: _filteredJobs.length,
                          itemBuilder: (context, i) {
                            return MiningJobDetails(job: _filteredJobs[i]);
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
