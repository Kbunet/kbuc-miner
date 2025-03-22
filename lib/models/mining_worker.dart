import 'dart:isolate';

class MiningWorker {
  final int id;
  final String jobId;
  Isolate? isolate;
  ReceivePort? receivePort;
  int lastProcessedNonce;
  int currentBatchStart;
  int currentBatchEnd;
  bool isPaused;
  bool isActive;
  DateTime startTime;
  String status;
  double _hashRate = 0.0;

  // Add getter for hashRate
  double get hashRate => _hashRate;

  MiningWorker({
    required this.id,
    required this.jobId,
    this.isolate,
    this.receivePort,
    required this.lastProcessedNonce,
    required this.currentBatchStart,
    required this.currentBatchEnd,
    this.isPaused = false,
    this.isActive = true,
    DateTime? startTime,
    this.status = 'initializing',
  }) : startTime = startTime ?? DateTime.now();

  // Calculate how many hashes this worker has processed
  int get hashesProcessed {
    if (lastProcessedNonce <= currentBatchStart) return 0;
    return lastProcessedNonce - currentBatchStart;
  }

  // Calculate hash rate for this worker
  double getHashRate() {
    final duration = DateTime.now().difference(startTime).inSeconds;
    if (duration <= 0) return 0;
    _hashRate = hashesProcessed / duration;
    return _hashRate;
  }

  // Create a copy of this worker with updated properties
  MiningWorker copyWith({
    int? id,
    String? jobId,
    Isolate? isolate,
    ReceivePort? receivePort,
    int? lastProcessedNonce,
    int? currentBatchStart,
    int? currentBatchEnd,
    bool? isPaused,
    bool? isActive,
    DateTime? startTime,
    String? status,
    double? hashRate,
  }) {
    final worker = MiningWorker(
      id: id ?? this.id,
      jobId: jobId ?? this.jobId,
      isolate: isolate ?? this.isolate,
      receivePort: receivePort ?? this.receivePort,
      lastProcessedNonce: lastProcessedNonce ?? this.lastProcessedNonce,
      currentBatchStart: currentBatchStart ?? this.currentBatchStart,
      currentBatchEnd: currentBatchEnd ?? this.currentBatchEnd,
      isPaused: isPaused ?? this.isPaused,
      isActive: isActive ?? this.isActive,
      startTime: startTime ?? this.startTime,
      status: status ?? this.status,
    );
    
    if (hashRate != null) {
      worker._hashRate = hashRate;
    } else {
      worker._hashRate = this._hashRate;
    }
    
    return worker;
  }
}
