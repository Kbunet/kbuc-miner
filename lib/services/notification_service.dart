import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';
import 'package:uuid/uuid.dart';

class NotificationService {
  // Singleton instance
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  
  // Internal constructor
  NotificationService._internal();
  
  // Channel for communicating with native code
  static const platform = MethodChannel('net.kbunet.miner/notifications');
  
  // Initialize the notification service
  Future<void> init() async {
    try {
      // Create notification channels on Android
      if (Platform.isAndroid) {
        await platform.invokeMethod('createNotificationChannels');
      }
      
      debugPrint('Notification service initialized');
    } catch (e) {
      debugPrint('Error initializing notification service: $e');
    }
  }
  
  // Show mining job completion notification
  void showJobCompletionNotification({
    required String jobId,
    required bool successful,
    String? foundNonce,
    String? foundHash,
  }) {
    try {
      // Notification title and body based on success status
      final String title = successful
          ? 'Solution Found!'
          : 'Mining Job Completed';
      
      final String body = successful
          ? 'Solution found for job $jobId${foundNonce != null ? ' with nonce: $foundNonce' : ''}'
          : 'Job $jobId completed without finding a solution';
      
      // Try to show notification directly via method channel first
      _showDirectNotification(title, body, jobId.hashCode);
      
      // Also register a task with Workmanager as a backup
      final taskId = const Uuid().v4().toString().substring(0, 20);
      Workmanager().registerOneOffTask(
        taskId,
        'completionNotificationTask',
        inputData: {
          'title': title,
          'message': body,
        },
        initialDelay: const Duration(seconds: 1),
        existingWorkPolicy: ExistingWorkPolicy.append,
      );
      
      debugPrint('Scheduled job completion notification for job $jobId with task ID: $taskId');
    } catch (e) {
      debugPrint('Error scheduling notification: $e');
    }
  }
  
  // Show notification directly via method channel
  Future<void> _showDirectNotification(String title, String message, int notificationId) async {
    try {
      await platform.invokeMethod('showNotification', {
        'title': title,
        'message': message,
        'notificationId': notificationId,
      });
      debugPrint('Direct notification sent: $title');
    } catch (e) {
      debugPrint('Error showing direct notification: $e');
    }
  }
  
  // Show mining progress notification (can be used for significant milestones)
  void showProgressNotification({
    required String jobId,
    required double progress,
    required double hashRate,
  }) {
    try {
      // Only show progress notifications at significant milestones (25%, 50%, 75%)
      final int progressPercent = (progress * 100).round();
      if (progressPercent % 25 != 0 || progressPercent == 0 || progressPercent == 100) {
        return;
      }
      
      final String title = 'Mining Progress: $progressPercent%';
      final String message = 'Job $jobId is $progressPercent% complete with hash rate ${hashRate.toStringAsFixed(2)} H/s';
      
      // Try to show notification directly via method channel first
      _showDirectNotification(title, message, jobId.hashCode + progressPercent);
      
      // Also register a task with Workmanager as a backup
      final taskId = const Uuid().v4().toString().substring(0, 20);
      Workmanager().registerOneOffTask(
        taskId,
        'completionNotificationTask',
        inputData: {
          'title': title,
          'message': message,
        },
        initialDelay: const Duration(seconds: 1),
        existingWorkPolicy: ExistingWorkPolicy.keep,
      );
      
      debugPrint('Scheduled progress notification for job $jobId: $progressPercent% with task ID: $taskId');
    } catch (e) {
      debugPrint('Error scheduling progress notification: $e');
    }
  }
}
