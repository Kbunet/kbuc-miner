import 'dart:io';
import 'package:flutter/foundation.dart';

/// A service that provides platform-specific authentication capabilities
/// and disables biometric auth on Windows to avoid NuGet package issues
class PlatformAuthService {
  /// Check if biometric authentication should be available on this platform
  static bool isBiometricAvailable() {
    // Disable biometric auth on Windows to avoid build issues
    if (kIsWeb || Platform.isWindows) {
      debugPrint('Biometric authentication disabled on Windows platform');
      return false;
    }
    
    // Enable on other platforms
    return true;
  }
  
  /// Alias for isBiometricAvailable to maintain compatibility
  static bool get isBiometricSupported => isBiometricAvailable();
  
  /// Get a platform-appropriate authentication message
  static String getAuthMessage() {
    if (kIsWeb || Platform.isWindows) {
      return 'Authentication via password only on Windows';
    } else {
      return 'Please authenticate to access your identities';
    }
  }
  
  /// Check if we should fall back to password authentication
  static bool shouldUsePasswordFallback() {
    // Always use password fallback on Windows
    return kIsWeb || Platform.isWindows;
  }
}
