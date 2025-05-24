import 'package:flutter/foundation.dart';
import '../models/mining_job.dart';

// Sorting options
enum JobSortOption {
  creationTimeDesc, // Default - recent first
  creationTimeAsc,
  difficultyDesc,
  difficultyAsc,
}

// Status filter options
enum JobStatusFilter {
  all,
  active,
  completed,
  successful,
  failed,
}

class MiningJobService {
  List<MiningJob> _jobs = [];
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      // Load all jobs from storage
      final allJobs = await MiningJob.loadAll();
      
      // Deduplicate jobs by ID - keep only the most recent version of each job
      final Map<String, MiningJob> uniqueJobs = {};
      
      // Process jobs in reverse order (newest first) to ensure we keep the most recent version
      // when there are duplicates
      for (final job in allJobs.reversed) {
        uniqueJobs[job.id] = job;
      }
      
      // Convert back to a list
      _jobs = uniqueJobs.values.toList();
      
      // Log the deduplication results
      final duplicatesRemoved = allJobs.length - _jobs.length;
      if (duplicatesRemoved > 0) {
        debugPrint('Removed $duplicatesRemoved duplicate job(s) during initialization');
        
        // Save the deduplicated jobs back to storage
        await MiningJob.saveAll(_jobs);
        debugPrint('Saved deduplicated jobs to storage');
      }
      
      _initialized = true;
    }
  }

  Future<List<MiningJob>> getAllJobs() async {
    await _ensureInitialized();
    return List.unmodifiable(_jobs);
  }

  /// Get jobs with sorting and filtering options
  /// 
  /// Parameters:
  /// - sortBy: How to sort the jobs (default: creationTimeDesc - recent first)
  /// - statusFilter: Filter by job status
  /// - difficultyRange: Filter by difficulty range [min, max], null means no limit
  /// - owner: Filter by owner
  /// - leader: Filter by leader
  /// - height: Filter by height
  /// - content: Filter by content (partial match)
  Future<List<MiningJob>> getFilteredJobs({
    JobSortOption sortBy = JobSortOption.creationTimeDesc,
    JobStatusFilter statusFilter = JobStatusFilter.all,
    List<int>? difficultyRange,
    String? owner,
    String? leader,
    int? height,
    String? content,
  }) async {
    await _ensureInitialized();
    
    // Start with all jobs
    List<MiningJob> filteredJobs = List.from(_jobs);
    
    // Apply status filter
    switch (statusFilter) {
      case JobStatusFilter.active:
        filteredJobs = filteredJobs.where((job) => !job.completed && !job.successful).toList();
        break;
      case JobStatusFilter.completed:
        filteredJobs = filteredJobs.where((job) => job.completed).toList();
        break;
      case JobStatusFilter.successful:
        filteredJobs = filteredJobs.where((job) => job.successful).toList();
        break;
      case JobStatusFilter.failed:
        filteredJobs = filteredJobs.where((job) => job.completed && !job.successful).toList();
        break;
      case JobStatusFilter.all:
        // No filtering needed
        break;
    }
    
    // Apply difficulty filter
    if (difficultyRange != null && difficultyRange.length == 2) {
      final minDifficulty = difficultyRange[0];
      final maxDifficulty = difficultyRange[1];
      filteredJobs = filteredJobs.where((job) => 
        job.difficulty >= minDifficulty && job.difficulty <= maxDifficulty
      ).toList();
    }
    
    // Apply owner filter
    if (owner != null && owner.isNotEmpty) {
      filteredJobs = filteredJobs.where((job) => job.owner == owner).toList();
    }
    
    // Apply leader filter
    if (leader != null && leader.isNotEmpty) {
      filteredJobs = filteredJobs.where((job) => job.leader == leader).toList();
    }
    
    // Apply height filter
    if (height != null) {
      filteredJobs = filteredJobs.where((job) => job.height == height).toList();
    }
    
    // Apply content filter (partial match)
    if (content != null && content.isNotEmpty) {
      filteredJobs = filteredJobs.where((job) => 
        job.content.toLowerCase().contains(content.toLowerCase())
      ).toList();
    }
    
    // Apply sorting
    switch (sortBy) {
      case JobSortOption.creationTimeDesc:
        filteredJobs.sort((a, b) => b.startTime.compareTo(a.startTime));
        break;
      case JobSortOption.creationTimeAsc:
        filteredJobs.sort((a, b) => a.startTime.compareTo(b.startTime));
        break;
      case JobSortOption.difficultyDesc:
        filteredJobs.sort((a, b) => b.difficulty.compareTo(a.difficulty));
        break;
      case JobSortOption.difficultyAsc:
        filteredJobs.sort((a, b) => a.difficulty.compareTo(b.difficulty));
        break;
    }
    
    return filteredJobs;
  }

  Future<MiningJob?> getJob(String id) async {
    await _ensureInitialized();
    try {
      return _jobs.firstWhere((job) => job.id == id);
    } catch (e) {
      // Job not found
      return null;
    }
  }

  Future<void> addJob(MiningJob job) async {
    await _ensureInitialized();
  
    // Check if a job with this ID already exists
    final existingIndex = _jobs.indexWhere((existingJob) => existingJob.id == job.id);
  
    if (existingIndex != -1) {
      // Update the existing job instead of adding a duplicate
      _jobs[existingIndex] = job;
      debugPrint('Updated existing job ${job.id} instead of adding duplicate');
    } else {
      // This is a new job, add it
      _jobs.add(job);
      debugPrint('Added new job ${job.id}');
    }
  
    await MiningJob.saveAll(_jobs);
  }

  Future<void> updateJob(MiningJob updatedJob) async {
    await _ensureInitialized();
    final index = _jobs.indexWhere((job) => job.id == updatedJob.id);
    if (index != -1) {
      _jobs[index] = updatedJob;
      await MiningJob.saveAll(_jobs);
    }
  }

  Future<void> deleteJob(String id) async {
    await _ensureInitialized();
    _jobs.removeWhere((job) => job.id == id);
    await MiningJob.saveAll(_jobs);
  }

  Future<void> clearAllJobs() async {
    await _ensureInitialized();
    _jobs.clear();
    await MiningJob.saveAll(_jobs);
  }

  Future<List<MiningJob>> getCompletedJobs() async {
    await _ensureInitialized();
    return _jobs.where((job) => job.completed).toList();
  }

  Future<List<MiningJob>> getActiveJobs() async {
    await _ensureInitialized();
    // Return only jobs that are neither completed nor successful
    return _jobs.where((job) => 
      !job.completed && 
      !job.successful
    ).toList();
  }

  Future<List<MiningJob>> getSuccessfulJobs() async {
    await _ensureInitialized();
    // Return only jobs that are marked as successful
    return _jobs.where((job) => job.successful).toList();
  }

  Future<List<MiningJob>> getNonSuccessfulActiveJobs() async {
    await _ensureInitialized();
    // Return only jobs that are neither completed nor successful
    return _jobs.where((job) => 
      !job.completed && 
      !job.successful
    ).toList();
  }
}
