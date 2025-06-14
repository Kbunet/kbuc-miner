import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class MiningJob {
  final String id;
  final String content;
  final String leader;
  final String owner;
  final int height;
  final String rewardType; // Stored as string per memory requirement
  final int difficulty;
  final int startNonce;
  final int endNonce;
  final DateTime startTime;
  final DateTime? endTime;
  final int? foundNonce;
  final String? foundHash;
  final bool completed;
  final bool successful;
  final String? error;
  final bool broadcastSuccessful;
  final String? broadcastError;
  final String? broadcastHash;
  final int lastTriedNonce; // Added to track the last nonce that was tried
  final int? completedNonce;
  final String? completedHash;
  final Map<int, int> workerLastNonces; // Map of worker ID to last processed nonce
  final double? speedMultiplier; // Store the speed multiplier for background task resumption

  // Add getters for compatibility with new code
  bool get isCompleted => completed;
  bool get isSuccessful => successful;

  MiningJob({
    required this.id,
    required this.content,
    required this.leader,
    required this.owner,
    required this.height,
    required this.rewardType,
    required this.difficulty,
    required this.startNonce,
    required this.endNonce,
    required this.startTime,
    this.endTime,
    this.foundNonce,
    this.foundHash,
    this.completed = false,
    this.successful = false,
    this.error,
    this.broadcastSuccessful = false,
    this.broadcastError,
    this.broadcastHash,
    this.lastTriedNonce = 0, // Default to startNonce if not provided
    this.completedNonce,
    this.completedHash,
    Map<int, int>? workerLastNonces,
    this.speedMultiplier,
  }) : this.workerLastNonces = workerLastNonces ?? {};

  Duration? get duration {
    if (endTime == null) return null;
    return endTime!.difference(startTime);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'leader': leader,
    'owner': owner,
    'height': height,
    'rewardType': rewardType,
    'difficulty': difficulty,
    'startNonce': startNonce,
    'endNonce': endNonce,
    'startTime': startTime.toIso8601String(),
    'endTime': endTime?.toIso8601String(),
    'foundNonce': foundNonce,
    'foundHash': foundHash,
    'completed': completed,
    'successful': successful,
    'error': error,
    'broadcastSuccessful': broadcastSuccessful,
    'broadcastError': broadcastError,
    'broadcastHash': broadcastHash,
    'lastTriedNonce': lastTriedNonce, // Added to JSON serialization
    'completedNonce': completedNonce,
    'completedHash': completedHash,
    'workerLastNonces': workerLastNonces.map((key, value) => MapEntry(key.toString(), value)), // Convert int keys to strings for JSON serialization
    'speedMultiplier': speedMultiplier, // Store speed multiplier for background resumption
  };

  factory MiningJob.fromJson(Map<String, dynamic> json) {
    // Convert workerLastNonces from JSON
    Map<int, int> workerNonces = {};
    if (json['workerLastNonces'] != null) {
      final Map<String, dynamic> noncesMap = Map<String, dynamic>.from(json['workerLastNonces']);
      noncesMap.forEach((key, value) {
        workerNonces[int.parse(key)] = value as int;
      });
    }
    
    return MiningJob(
      id: json['id'],
      content: json['content'],
      leader: json['leader'],
      owner: json['owner'],
      height: json['height'],
      rewardType: json['rewardType'], // Keep as string per memory requirement
      difficulty: json['difficulty'],
      startNonce: json['startNonce'],
      endNonce: json['endNonce'],
      startTime: DateTime.parse(json['startTime']),
      endTime: json['endTime'] != null ? DateTime.parse(json['endTime']) : null,
      foundNonce: json['foundNonce'],
      foundHash: json['foundHash'],
      completed: json['completed'] ?? false,
      successful: json['successful'] ?? false,
      error: json['error'],
      broadcastSuccessful: json['broadcastSuccessful'] ?? false,
      broadcastError: json['broadcastError'],
      broadcastHash: json['broadcastHash'],
      lastTriedNonce: json['lastTriedNonce'] ?? json['startNonce'], // Use startNonce as fallback
      completedNonce: json['completedNonce'],
      completedHash: json['completedHash'],
      workerLastNonces: workerNonces,
      speedMultiplier: json['speedMultiplier'] != null ? (json['speedMultiplier'] as num).toDouble() : null,
    );
  }

  MiningJob copyWith({
    String? id,
    String? content,
    String? leader,
    String? owner,
    int? height,
    String? rewardType,  // Keep as string per memory requirement
    int? difficulty,
    int? startNonce,
    int? endNonce,
    DateTime? startTime,
    DateTime? endTime,
    int? foundNonce,
    String? foundHash,
    bool? completed,
    bool? successful,
    String? error,
    bool? broadcastSuccessful,
    String? broadcastError,
    String? broadcastHash,
    int? lastTriedNonce,
    int? completedNonce,
    String? completedHash,
    Map<int, int>? workerLastNonces,
    double? speedMultiplier,
  }) {
    return MiningJob(
      id: id ?? this.id,
      content: content ?? this.content,
      leader: leader ?? this.leader,
      owner: owner ?? this.owner,
      height: height ?? this.height,
      rewardType: rewardType ?? this.rewardType,  // Keep as string per memory requirement
      difficulty: difficulty ?? this.difficulty,
      startNonce: startNonce ?? this.startNonce,
      endNonce: endNonce ?? this.endNonce,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      foundNonce: foundNonce ?? this.foundNonce,
      foundHash: foundHash ?? this.foundHash,
      completed: completed ?? this.completed,
      successful: successful ?? this.successful,
      error: error ?? this.error,
      broadcastSuccessful: broadcastSuccessful ?? this.broadcastSuccessful,
      broadcastError: broadcastError ?? this.broadcastError,
      broadcastHash: broadcastHash ?? this.broadcastHash,
      lastTriedNonce: lastTriedNonce ?? this.lastTriedNonce,
      completedNonce: completedNonce ?? this.completedNonce,
      completedHash: completedHash ?? this.completedHash,
      workerLastNonces: workerLastNonces ?? this.workerLastNonces,
      speedMultiplier: speedMultiplier ?? this.speedMultiplier,
    );
  }

  static Future<List<MiningJob>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final jobsJson = prefs.getString('mining_jobs') ?? '[]';
    final List<dynamic> jobsList = json.decode(jobsJson);
    return jobsList.map((job) => MiningJob.fromJson(job)).toList();
  }

  static Future<void> saveAll(List<MiningJob> jobs) async {
    final prefs = await SharedPreferences.getInstance();
    final jobsJson = json.encode(jobs.map((job) => job.toJson()).toList());
    await prefs.setString('mining_jobs', jobsJson);
  }
}
