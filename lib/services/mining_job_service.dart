import '../models/mining_job.dart';

class MiningJobService {
  List<MiningJob> _jobs = [];
  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      _jobs = await MiningJob.loadAll();
      _initialized = true;
    }
  }

  Future<List<MiningJob>> getAllJobs() async {
    await _ensureInitialized();
    return List.unmodifiable(_jobs);
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
    _jobs.add(job);
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
    return _jobs.where((job) => !job.completed).toList();
  }

  Future<List<MiningJob>> getSuccessfulJobs() async {
    await _ensureInitialized();
    return _jobs.where((job) => job.successful).toList();
  }
}
