import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/safe_wakelock.dart';
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
    // Background task started
    
    try {
      // Tell SafeWakelock we're in a background context to avoid wakelock errors
      SafeWakelock.setBackgroundContext(true);
      
      // Try to enable wakelock, but it will be a no-op in background
      await SafeWakelock.enable(); // This is a no-op since wakelock is disabled
      
      switch (taskName) {
        case kForegroundServiceTask:
          // This task runs as a foreground service with a persistent notification
          
          // Return true to indicate the task should run as a foreground service
          return true;
          
        case kBackgroundMiningTask:
          // Get mining service instance
          final miningService = MiningService();
          
          // Check for active jobs
          final activeJobs = await miningService.getActiveJobs();
          
          if (activeJobs.isNotEmpty) {
            // Process each active job
            for (final job in activeJobs) {
              if (!job.completed) {
                // Get the current speed multiplier for this job if it exists
                final speedMultiplier = await miningService.getJobSpeedMultiplier(job.id);
                
                // Resume mining job with the existing speed multiplier
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
                  speedMultiplier: speedMultiplier, // Pass the speed multiplier directly
                  onUpdate: (update) {
                    // No logging in background mode
                  },
                );
              }
            }
            
            // Task completed successfully
            return true;
          } else {
            // Task completed successfully (even though there's nothing to do)
            return true;
          }
        
        case 'completionNotificationTask':
          // This task is specifically for showing a completion notification
          if (inputData != null) {
            final String title = inputData['title'] as String? ?? 'Mining Notification';
            final String message = inputData['message'] as String? ?? 'A mining task has completed';
            
            // Wait for a while to let the mining job run
            await Future.delayed(const Duration(minutes: 10));
            
            // Save the job state before exiting
            // Get mining service instance first
            final miningService = MiningService();
            await miningService.saveJobState();
          }
          
          // Always return success to avoid failure notifications
          return Future.value(true);
        default:
          // Always return success to avoid failure notifications
          return true;
      }
    } catch (e) {
      // Still return success to avoid failure notifications
      return Future.value(true);
    } finally {
      // Disable wakelock when done
      await SafeWakelock.disable();
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
    
    // Only initialize Workmanager on supported platforms (not on Windows or Web)
    bool isWorkmanagerSupported = !kIsWeb && !Platform.isWindows;
    
    if (isWorkmanagerSupported) {
      try {
        // Initialize Workmanager with custom configuration
        await Workmanager().initialize(
          callbackDispatcher,
          isInDebugMode: false, // Set to false to reduce debug notifications
        );
      } catch (e) {
        debugPrint('Error initializing Workmanager in BackgroundMiningService: $e');
      }
    } else {
      debugPrint('Workmanager not supported on this platform, skipping initialization');
    }
  }

  // Request necessary permissions
  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      // Request notification permission
      await Permission.notification.request();
      
      // Request ignore battery optimizations
      final batteryOptStatus = await Permission.ignoreBatteryOptimizations.request();
      
      // Request foreground service permission for Android 9+
      if (Platform.isAndroid) {
        final deviceInfo = DeviceInfoPlugin();
        final androidInfo = await deviceInfo.androidInfo;
        
        if (androidInfo.version.sdkInt >= 28) { // Android 9 (Pie) or higher
          final foregroundStatus = await Permission.systemAlertWindow.request();
        }
      }
    }
  }

  // Start the background service
  Future<bool> startService() async {
    if (!_isServiceRunning) {
      // Only use workmanager on supported platforms (not on Windows or Web)
      bool isWorkmanagerSupported = !kIsWeb && !Platform.isWindows;
      
      if (isWorkmanagerSupported) {
        try {
          // Check if this is Android and request battery optimization exemption
          if (Platform.isAndroid) {
            final deviceInfo = DeviceInfoPlugin();
            final androidInfo = await deviceInfo.androidInfo;
            
            // Check if this is a real device
            final isRealDevice = androidInfo.isPhysicalDevice;
            
            if (isRealDevice) {
              final hasPermission = await Permission.ignoreBatteryOptimizations.isGranted;
              
              if (!hasPermission) {
                final status = await Permission.ignoreBatteryOptimizations.request();
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
        } catch (e) {
          debugPrint('Error registering workmanager tasks: $e');
        }
      } else {
        debugPrint('Workmanager not supported on this platform, skipping task registration');
      }
      
      _isServiceRunning = true;
      
      // Use SafeWakelock which will handle wakelock operations safely
      SafeWakelock.setBackgroundContext(false); // We're in foreground when starting the service
      await SafeWakelock.enable(); // This will only work in foreground context
      
      return true;
    }
    
    return false;
  }

  // Stop the background service
  Future<bool> stopService() async {
    if (_isServiceRunning) {
      // Only use workmanager on supported platforms (not on Windows or Web)
      bool isWorkmanagerSupported = !kIsWeb && !Platform.isWindows;
      
      if (isWorkmanagerSupported) {
        try {
          // Cancel all tasks
          await Workmanager().cancelAll();
        } catch (e) {
          debugPrint('Error canceling workmanager tasks: $e');
        }
      } else {
        debugPrint('Workmanager not supported on this platform, skipping task cancellation');
      }
      
      _isServiceRunning = false;
      
      // Use SafeWakelock which will handle wakelock operations safely
      SafeWakelock.setBackgroundContext(false); // We're in foreground when stopping the service
      await SafeWakelock.disable(); // This will only work in foreground context
      
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
  }
  
  // Method removed - formatting logic moved inline to callback
}
