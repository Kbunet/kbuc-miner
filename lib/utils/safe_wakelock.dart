import 'package:flutter/foundation.dart';
import 'dart:async';

// Import wakelock but handle it safely
import 'package:wakelock_plus/wakelock_plus.dart' as wakelock_plus;

/// A utility class that safely handles wakelock operations
/// This is a temporary solution to avoid wakelock errors in background tasks
class SafeWakelock {
  /// Flag to completely disable wakelock functionality
  static bool _wakelockDisabled = true;
  
  /// Flag to track if we're in a background context
  static bool _isInBackgroundContext = false;

  /// Enable wakelock functionality app-wide
  static void enableWakelockFunctionality() {
    _wakelockDisabled = false;
    debugPrint('Wakelock functionality enabled app-wide');
  }

  /// Disable wakelock functionality app-wide
  static void disableWakelockFunctionality() {
    _wakelockDisabled = true;
    debugPrint('Wakelock functionality disabled app-wide');
  }
  
  /// Set the background context flag
  static void setBackgroundContext(bool isBackground) {
    _isInBackgroundContext = isBackground;
    debugPrint('SafeWakelock: Background context set to $_isInBackgroundContext');
  }

  /// Safely try to enable wakelock, with no-op if disabled
  static Future<void> enable() async {
    if (_wakelockDisabled) {
      debugPrint('Wakelock enable request ignored - functionality is disabled');
      return;
    }
    
    if (_isInBackgroundContext) {
      debugPrint('Wakelock enable skipped - in background context');
      return;
    }
    
    try {
      // Only try to enable wakelock with a timeout to prevent hanging
      await _timeoutOperation(() async {
        await wakelock_plus.WakelockPlus.enable();
        debugPrint('Wakelock enabled successfully');
      });
    } catch (e) {
      debugPrint('Error enabling wakelock (safely handled): $e');
    }
  }

  /// Safely try to disable wakelock, with no-op if disabled
  static Future<void> disable() async {
    if (_wakelockDisabled) {
      debugPrint('Wakelock disable request ignored - functionality is disabled');
      return;
    }
    
    if (_isInBackgroundContext) {
      debugPrint('Wakelock disable skipped - in background context');
      return;
    }
    
    try {
      // Only try to disable wakelock with a timeout to prevent hanging
      await _timeoutOperation(() async {
        await wakelock_plus.WakelockPlus.disable();
        debugPrint('Wakelock disabled successfully');
      });
    } catch (e) {
      debugPrint('Error disabling wakelock (safely handled): $e');
    }
  }
  
  /// Helper method to run an operation with a timeout
  static Future<void> _timeoutOperation(Future<void> Function() operation) async {
    try {
      await operation().timeout(const Duration(seconds: 1));
    } catch (e) {
      debugPrint('Operation timed out: $e');
      // We don't rethrow the error - just log it
    }
  }
}
