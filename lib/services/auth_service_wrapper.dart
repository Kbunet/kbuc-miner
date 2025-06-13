import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter/services.dart';

/// A wrapper for LocalAuthentication that handles platform-specific implementations
/// and provides fallbacks for platforms where biometric auth isn't available
class AuthServiceWrapper {
  final LocalAuthentication _localAuth = LocalAuthentication();
  
  /// Check if biometric authentication is available on this device
  Future<bool> isBiometricAvailable() async {
    // Skip biometric checks on Windows or Web to avoid package issues
    if (kIsWeb || Platform.isWindows) {
      return false;
    }
    
    try {
      // Check if device has biometrics
      final canAuthenticateWithBiometrics = await _localAuth.canCheckBiometrics;
      final canAuthenticate = await _localAuth.isDeviceSupported();
      
      return canAuthenticateWithBiometrics && canAuthenticate;
    } on PlatformException catch (e) {
      debugPrint('Error checking biometric availability: $e');
      return false;
    }
  }

  /// Authenticate the user with biometrics
  Future<bool> authenticate({String reason = 'Please authenticate to access your identities'}) async {
    // Skip biometric auth on Windows or Web to avoid package issues
    if (kIsWeb || Platform.isWindows) {
      // Return true for development purposes on Windows/Web
      // In a production app, you might want to show a password dialog instead
      return true;
    }
    
    try {
      return await _localAuth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
    } on PlatformException catch (e) {
      debugPrint('Error during authentication: $e');
      return false;
    }
  }

  /// Get available biometric types
  Future<List<BiometricType>> getAvailableBiometrics() async {
    // Skip biometric checks on Windows or Web to avoid package issues
    if (kIsWeb || Platform.isWindows) {
      return [];
    }
    
    try {
      return await _localAuth.getAvailableBiometrics();
    } on PlatformException catch (e) {
      debugPrint('Error getting available biometrics: $e');
      return [];
    }
  }
}
