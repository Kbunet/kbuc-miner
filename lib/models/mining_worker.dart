import 'dart:isolate';

class MiningWorker {
  final int id;
  final String jobId;
  Isolate? isolate;
  SendPort? sendPort;
  ReceivePort? receivePort;
  int lastProcessedNonce;
  int currentBatchStart;
  int currentBatchEnd;
  bool isPaused;
  bool isActive;
  DateTime startTime;
  String status;

  MiningWorker({
    required this.id,
    required this.jobId,
    this.isolate,
    this.sendPort,
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
    return hashesProcessed / duration;
  }

  // Create a copy of this worker with updated properties
  MiningWorker copyWith({
    int? lastProcessedNonce,
    int? currentBatchStart,
    int? currentBatchEnd,
    bool? isPaused,
    bool? isActive,
    SendPort? sendPort,
    Isolate? isolate,
    String? status,
  }) {
    return MiningWorker(
      id: id,
      jobId: jobId,
      isolate: isolate ?? this.isolate,
      sendPort: sendPort ?? this.sendPort,
      receivePort: receivePort,
      lastProcessedNonce: lastProcessedNonce ?? this.lastProcessedNonce,
      currentBatchStart: currentBatchStart ?? this.currentBatchStart,
      currentBatchEnd: currentBatchEnd ?? this.currentBatchEnd,
      isPaused: isPaused ?? this.isPaused,
      isActive: isActive ?? this.isActive,
      startTime: startTime,
      status: status ?? this.status,
    );
  }
}
