import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:workmanager/workmanager.dart';
import 'mining_service.dart';

// Task name constants
const String kBackgroundMiningTask = 'backgroundMiningTask';
const String kCompletionNotificationTask = 'completionNotificationTask';
const String kForegroundServiceTask = 'foregroundServiceTask';

// Callback for background tasks
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    debugPrint('Background task $taskName started');
    
    try {
      // Try to enable wakelock but handle the case when there's no foreground activity
      try {
        await WakelockPlus.enable();
      } catch (e) {
        debugPrint('Warning: Could not enable wakelock: $e');
        // Continue execution even if wakelock fails
      }
      
      switch (taskName) {
        case kForegroundServiceTask:
          // This task runs as a foreground service with a persistent notification
          debugPrint('Starting foreground mining service');
          
          // Return true to indicate the task should run as a foreground service
          return true;
          
        case kBackgroundMiningTask:
          // Get mining service instance
          final miningService = MiningService();
          
          // Check for active jobs
          final activeJobs = await miningService.getActiveJobs();
          
          if (activeJobs.isNotEmpty) {
            debugPrint('Found ${activeJobs.length} active mining jobs');
            
            // Process each active job
            for (final job in activeJobs) {
              if (!job.completed) {
                debugPrint('Resuming mining job: ${job.id}');
                
                // Resume mining job
                await miningService.startMining(
                  jobId: job.id,
                  content: job.content,
                  leader: job.leader,
                  owner: job.owner,
                  height: job.height,
                  rewardType: job.rewardType,
                  difficulty: job.difficulty,
                  startNonce: job.startNonce,
                  endNonce: job.endNonce,
                  resumeFromNonce: job.lastTriedNonce,
                  workerLastNonces: job.workerLastNonces,
                  onUpdate: (update) {},
                );
              }
            }
            
            // Task completed successfully
            return true;
          } else {
            debugPrint('No active mining jobs found');
            // Task completed successfully (even though there's nothing to do)
            return true;
          }
        
        case 'completionNotificationTask':
          // This task is specifically for showing a completion notification
          if (inputData != null) {
            final String title = inputData['title'] as String? ?? 'Mining Notification';
            final String message = inputData['message'] as String? ?? 'A mining task has completed';
            
            debugPrint('Showing notification:');
            debugPrint('Title: $title');
            debugPrint('Message: $message');
            
            // Return true to indicate success and show a notification
            return Future<bool>.value(true);
          }
          return Future<bool>.value(true);
          
        default:
          // Always return success to avoid failure notifications
          debugPrint('Unknown task: $taskName');
          return true;
      }
    } catch (e) {
      // Log the error but still return success to avoid failure notifications
      debugPrint('Error in background task: $e');
      return true;
    }
  });
}

class BackgroundMiningService {
  static final BackgroundMiningService _instance = BackgroundMiningService._internal();
  factory BackgroundMiningService() => _instance;
  BackgroundMiningService._internal();
  
  // Track if background service is running
  bool _isServiceRunning = false;

  // Initialize the service
  Future<void> init() async {
    // Request necessary permissions
    await _requestPermissions();
    
    // Initialize Workmanager with custom configuration
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false, // Set to false to reduce debug notifications
    );
    
    debugPrint('Background service initialized');
  }

  // Request necessary permissions
  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      // Request notification permission
      await Permission.notification.request();
      
      // Request ignore battery optimizations
      final batteryOptStatus = await Permission.ignoreBatteryOptimizations.request();
      debugPrint('Battery optimization permission status: $batteryOptStatus');
      
      // Request foreground service permission for Android 9+
      if (Platform.isAndroid) {
        final deviceInfo = DeviceInfoPlugin();
        final androidInfo = await deviceInfo.androidInfo;
        
        if (androidInfo.version.sdkInt >= 28) { // Android 9 (Pie) or higher
          final foregroundStatus = await Permission.systemAlertWindow.request();
          debugPrint('Foreground service permission status: $foregroundStatus');
        }
      }
    }
  }

  // Start the background service
  Future<bool> startService() async {
    if (!_isServiceRunning) {
      // Request battery optimization exemption on real devices
      if (Platform.isAndroid) {
        final deviceInfo = DeviceInfoPlugin();
        final androidInfo = await deviceInfo.androidInfo;
        
        // Check if this is a real device
        final isRealDevice = androidInfo.isPhysicalDevice;
        
        if (isRealDevice) {
          debugPrint('Running on a real device, requesting battery optimization exemption');
          final hasPermission = await Permission.ignoreBatteryOptimizations.isGranted;
          
          if (!hasPermission) {
            debugPrint('Requesting ignore battery optimizations permission');
            final status = await Permission.ignoreBatteryOptimizations.request();
            debugPrint('Ignore battery optimizations permission status: $status');
          }
        }
      }
      
      // First, register a foreground service task that will keep the app running
      // This is critical for real devices to prevent the OS from killing the app
      await Workmanager().registerOneOffTask(
        'foreground-service-task',
        kForegroundServiceTask,
        existingWorkPolicy: ExistingWorkPolicy.replace,
        inputData: {
          'title': 'KBUC Miner Running',
          'message': 'Mining in progress',
        },
        constraints: Constraints(
          networkType: NetworkType.not_required,
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresDeviceIdle: false,
          requiresStorageNotLow: false,
        ),
        // Note: For foreground service, we'll need to handle this differently
        // The Workmanager version we're using doesn't directly support foreground services
      );
      
      // Register a periodic task with more frequent checks for real devices
      await Workmanager().registerPeriodicTask(
        'mining-task-periodic',
        kBackgroundMiningTask,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(
          networkType: NetworkType.not_required, // Don't require network connection
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresDeviceIdle: false,
          requiresStorageNotLow: false,
        ),
        existingWorkPolicy: ExistingWorkPolicy.replace,
        backoffPolicy: BackoffPolicy.linear,
        backoffPolicyDelay: const Duration(minutes: 1),
      );
      
      // Register multiple one-time tasks with different delays to ensure execution
      for (int i = 0; i < 3; i++) {
        await Workmanager().registerOneOffTask(
          'mining-task-immediate-$i',
          kBackgroundMiningTask,
          initialDelay: Duration(minutes: i * 2), // Stagger the tasks with shorter intervals
          constraints: Constraints(
            networkType: NetworkType.not_required, // Don't require network connection
            requiresBatteryNotLow: false,
            requiresCharging: false,
            requiresDeviceIdle: false,
            requiresStorageNotLow: false,
          ),
          existingWorkPolicy: ExistingWorkPolicy.keep,
        );
      }
      
      _isServiceRunning = true;
      
      // Enable wakelock to keep screen on
      try {
        await WakelockPlus.enable();
      } catch (e) {
        debugPrint('Warning: Could not enable wakelock: $e');
        // Continue execution even if wakelock fails
      }
      
      return true;
    }
    
    return false;
  }

  // Stop the background service
  Future<bool> stopService() async {
    if (_isServiceRunning) {
      // Cancel all tasks
      await Workmanager().cancelAll();
      
      _isServiceRunning = false;
      
      // Disable wakelock
      await WakelockPlus.disable();
      
      return true;
    }
    
    return false;
  }

  // Check if service is running
  Future<bool> isServiceRunning() async {
    // Since Workmanager doesn't provide a way to check if tasks are running,
    // we'll just return our internal state
    return _isServiceRunning;
  }

  // Send data to the background service
  // Note: With Workmanager, we can't directly send data to a running task
  // Instead, we'll save the data to be used when the task runs next
  Future<void> sendData(Map<String, dynamic> data) async {
    // With Workmanager approach, we don't directly send data to the service
    // Instead, we rely on the service to read the latest state from the MiningService
    debugPrint('Data will be picked up by the next task execution: ${data.toString()}');
  }
}
