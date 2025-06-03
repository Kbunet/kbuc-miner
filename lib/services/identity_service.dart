import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import '../models/identity.dart';

class IdentityService {
  static const String _identitiesKey = 'encrypted_identities';
  static const String _authEnabledKey = 'identity_auth_enabled';
  static const String _defaultIdentityKey = 'default_identity_id';
  static const String _passwordHashKey = 'identity_password_hash';
  static const String _authMethodKey = 'identity_auth_method';
  
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final LocalAuthentication _localAuth = LocalAuthentication();
  
  // Singleton instance
  static final IdentityService _instance = IdentityService._internal();
  
  // Private constructor
  IdentityService._internal();
  
  // Factory constructor to return the singleton instance
  factory IdentityService() {
    return _instance;
  }
  
  // Check if biometric authentication is available
  Future<bool> isBiometricAvailable() async {
    try {
      // First check if the device supports biometrics
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      debugPrint('Device supports biometrics: $isDeviceSupported');
      if (!isDeviceSupported) {
        debugPrint('Device does not support biometric authentication');
        return false;
      }
      
      // Then check if biometrics are available
      final canCheckBiometrics = await _localAuth.canCheckBiometrics;
      debugPrint('Can check biometrics: $canCheckBiometrics');
      
      // Get available biometrics to verify fingerprint is available
      final availableBiometrics = await _localAuth.getAvailableBiometrics();
      debugPrint('Available biometrics: $availableBiometrics');
      
      // Check for specific biometric types
      final hasFingerprintOrFace = availableBiometrics.contains(BiometricType.fingerprint) || 
                                  availableBiometrics.contains(BiometricType.face) ||
                                  availableBiometrics.contains(BiometricType.strong);
      
      debugPrint('Has fingerprint or face: $hasFingerprintOrFace');
      
      // For real devices, we'll consider it available if the device supports it
      // and has at least one biometric type available
      return isDeviceSupported && (availableBiometrics.isNotEmpty || canCheckBiometrics);
    } catch (e) {
      debugPrint('Error checking biometric availability: $e');
      return false;
    }
  }
  
  // Enable or disable authentication for identity access
  Future<void> setAuthenticationEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_authEnabledKey, enabled);
  }
  
  // Set the authentication method (biometric or password)
  Future<void> setAuthMethod(String method) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_authMethodKey, method);
  }
  
  // Get the current authentication method
  Future<String> getAuthMethod() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_authMethodKey) ?? 'biometric';
  }
  
  // Check if authentication is enabled
  Future<bool> isAuthenticationEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_authEnabledKey) ?? false;
  }
  
  // Set a password for authentication
  Future<bool> setPassword(String password) async {
    try {
      // Generate a hash of the password
      final passwordHash = sha256.convert(utf8.encode(password)).toString();
      
      // Store the hash in secure storage
      await _secureStorage.write(key: _passwordHashKey, value: passwordHash);
      
      // Set the auth method to password
      await setAuthMethod('password');
      
      return true;
    } catch (e) {
      debugPrint('Error setting password: $e');
      return false;
    }
  }
  
  // Verify a password against the stored hash
  Future<bool> verifyPassword(String password) async {
    try {
      // Get the stored hash
      final storedHash = await _secureStorage.read(key: _passwordHashKey);
      if (storedHash == null) return false;
      
      // Generate a hash of the provided password
      final inputHash = sha256.convert(utf8.encode(password)).toString();
      
      // Compare the hashes
      return storedHash == inputHash;
    } catch (e) {
      debugPrint('Error verifying password: $e');
      return false;
    }
  }
  
  // Check if a password has been set
  Future<bool> hasPasswordSet() async {
    final storedHash = await _secureStorage.read(key: _passwordHashKey);
    return storedHash != null;
  }
  
  // Authenticate user before accessing sensitive data
  /// Tests if biometric authentication works without checking current auth method
  /// This is used for initial setup of biometric authentication
  Future<bool> testBiometricAuth() async {
    debugPrint('=== TESTING BIOMETRIC AUTHENTICATION ===');
    
    try {
      // First check if biometrics are available
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      debugPrint('Device supports biometrics: $isDeviceSupported');
      
      final canCheckBiometrics = await _localAuth.canCheckBiometrics;
      debugPrint('Can check biometrics: $canCheckBiometrics');
      
      final availableBiometrics = await _localAuth.getAvailableBiometrics();
      debugPrint('Available biometrics: $availableBiometrics');
      
      if (!isDeviceSupported) {
        debugPrint('Device does not support biometrics, returning false');
        return false;
      }
      
      // Try with the recommended approach from documentation
      try {
        debugPrint('Attempting biometric test with recommended settings');
        final result = await _localAuth.authenticate(
          localizedReason: 'Verify your fingerprint to enable biometric authentication',
          options: const AuthenticationOptions(
            biometricOnly: true,    // Only allow biometrics for this test
            stickyAuth: true,       // Prevent dialog from closing on app switch
            useErrorDialogs: true,  // Show system error dialogs
            sensitiveTransaction: true, // Treat as sensitive transaction
          ),
        );
        
        debugPrint('Biometric test result: $result');
        return result;
      } catch (e) {
        debugPrint('First biometric test failed with error: $e');
        debugPrint('Trying with minimal options as fallback');
        
        try {
          final result = await _localAuth.authenticate(
            localizedReason: 'Please scan your fingerprint to continue',
          );
          
          debugPrint('Fallback biometric test result: $result');
          return result;
        } catch (e2) {
          debugPrint('Fallback biometric test also failed: $e2');
          return false;
        }
      }
    } catch (e) {
      debugPrint('Biometric test error: $e');
      return false;
    }
  }

  Future<bool> authenticate() async {
    if (!await isAuthenticationEnabled()) {
      debugPrint('Authentication not enabled, returning true');
      return true; // Authentication not required
    }
    
    try {
      final authMethod = await getAuthMethod();
      debugPrint('Current auth method: $authMethod');
      
      // If using biometric authentication
      if (authMethod == 'biometric') {
        debugPrint('=== BIOMETRIC AUTHENTICATION ATTEMPT ===');
        
        // First check if biometrics are available
        final isDeviceSupported = await _localAuth.isDeviceSupported();
        debugPrint('Device supports biometrics: $isDeviceSupported');
        
        final canCheckBiometrics = await _localAuth.canCheckBiometrics;
        debugPrint('Can check biometrics: $canCheckBiometrics');
        
        final availableBiometrics = await _localAuth.getAvailableBiometrics();
        debugPrint('Available biometrics: $availableBiometrics');
        
        if (!isDeviceSupported) {
          debugPrint('Device does not support biometrics, returning false');
          return false;
        }
        
        // According to the documentation, we should try a simpler approach first
        try {
          // Try with the recommended approach from documentation
          // Use a clear message and minimal options
          debugPrint('Attempting authentication with recommended settings');
          
          // The most important parameters according to docs:
          // 1. localizedReason - must be clear and non-empty
          // 2. biometricOnly - set to false to allow PIN/pattern fallback
          // 3. stickyAuth - set to true to prevent authentication dialog from closing on app switch
          // 4. useErrorDialogs - set to true to show system error dialogs
          final result = await _localAuth.authenticate(
            localizedReason: 'Verify your identity to access your wallet',
            options: const AuthenticationOptions(
              biometricOnly: false,  // Allow PIN/pattern fallback
              stickyAuth: true,      // Prevent dialog from closing on app switch
              useErrorDialogs: true, // Show system error dialogs
              sensitiveTransaction: true, // Treat as sensitive transaction
            ),
          );
          
          debugPrint('Authentication result: $result');
          return result;
        } catch (e) {
          // If the first attempt fails with an exception (not just returning false),
          // try with minimal options as a fallback
          debugPrint('First authentication attempt failed with error: $e');
          debugPrint('Trying with minimal options as fallback');
          
          try {
            final result = await _localAuth.authenticate(
              localizedReason: 'Please scan your fingerprint',
            );
            
            debugPrint('Fallback authentication result: $result');
            return result;
          } catch (e2) {
            debugPrint('Fallback authentication also failed: $e2');
            return false;
          }
        }
      } else {
        debugPrint('Using password authentication, returning false for UI to handle');
        // Password authentication is handled by the UI
        return false;
      }
    } catch (e) {
      debugPrint('Authentication error: $e');
      return false;
    }
  }
  
  // Save identities to secure storage
  Future<void> saveIdentities(List<Identity> identities) async {
    try {
      // Convert identities to JSON
      final identitiesJson = jsonEncode(
        identities.map((identity) => identity.toMap()).toList(),
      );
      
      // Save encrypted data
      await _secureStorage.write(key: _identitiesKey, value: identitiesJson);
      
      // Save default identity ID separately
      Identity? defaultIdentity;
      try {
        defaultIdentity = identities.firstWhere(
          (identity) => identity.isDefault,
        );
      } catch (e) {
        // No identity marked as default, use the first one if available
        if (identities.isNotEmpty) {
          defaultIdentity = identities.first;
        }
      }
      
      if (defaultIdentity != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_defaultIdentityKey, defaultIdentity.id);
      }
    } catch (e) {
      debugPrint('Error saving identities: $e');
      rethrow;
    }
  }
  
  // Get identities from secure storage
  Future<List<Identity>> getIdentities() async {
    try {
      // Check if authentication is required
      final isAuthEnabled = await isAuthenticationEnabled();
      if (isAuthEnabled) {
        final authMethod = await getAuthMethod();
        
        if (authMethod == 'biometric') {
          // For biometric auth, we need to authenticate here
          final isAuthenticated = await authenticate();
          if (!isAuthenticated) {
            // Return empty list for failed biometric authentication
            debugPrint('Biometric authentication failed, returning empty list');
            return [];
          }
        } else if (authMethod == 'password') {
          // For password auth, we return empty list to trigger the password dialog in UI
          // The UI will handle password verification separately
          debugPrint('Password authentication needed, UI will handle it');
          // Return empty list to trigger the password dialog in UI
          // The UI will verify the password and then call this method again
          return [];
        }
      }
      
      return await _getIdentitiesFromStorage();
    } catch (e) {
      debugPrint('Error getting identities: $e');
      return []; // Return empty list on error instead of rethrowing
    }
  }
  
  // This method gets identities directly from storage without checking authentication
  // It should only be called after successful password verification
  Future<List<Identity>> getIdentitiesAfterPasswordVerification() async {
    debugPrint('Getting identities after password verification');
    try {
      final identities = await _getIdentitiesFromStorage();
      debugPrint('Retrieved ${identities.length} identities after password verification');
      return identities;
    } catch (e) {
      debugPrint('Error getting identities after password verification: $e');
      return [];
    }
  }
  
  // Helper method to get identities from secure storage
  Future<List<Identity>> _getIdentitiesFromStorage() async {
    // Get encrypted data
    final identitiesJson = await _secureStorage.read(key: _identitiesKey);
    if (identitiesJson == null) {
      return [];
    }
    
    // Decode JSON
    final List<dynamic> decodedJson = jsonDecode(identitiesJson);
    
    // Convert to Identity objects
    final identities = decodedJson
        .map((json) => Identity.fromMap(json))
        .toList();
    
    return identities;
  }
  
  // Get the default identity
  Future<Identity?> getDefaultIdentity() async {
    try {
      final identities = await getIdentities();
      
      if (identities.isEmpty) {
        return null;
      }
      
      // First check for any identity marked as default
      final defaultIdentity = identities.firstWhere(
        (identity) => identity.isDefault,
        orElse: () => identities.first,
      );
      
      return defaultIdentity;
    } catch (e) {
      debugPrint('Error getting default identity: $e');
      return null;
    }
  }
  
  // Set an identity as the default
  Future<void> setDefaultIdentity(String identityId) async {
    try {
      final identities = await getIdentities();
      
      if (identities.isEmpty) {
        return;
      }
      
      // Update isDefault flag for all identities
      final updatedIdentities = identities.map((identity) {
        return identity.copyWith(isDefault: identity.id == identityId);
      }).toList();
      
      // Save updated identities
      await saveIdentities(updatedIdentities);
      
      // Also save the default ID in shared preferences for quick access
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_defaultIdentityKey, identityId);
    } catch (e) {
      debugPrint('Error setting default identity: $e');
      rethrow;
    }
  }
  
  // Add a new identity
  Future<Identity> addIdentity(String name) async {
    try {
      // Generate a new identity
      final newIdentity = await Identity.generate(name);
      
      // Get existing identities
      final identities = await getIdentities();
      
      // If this is the first identity, make it the default
      if (identities.isEmpty) {
        newIdentity.isDefault = true;
      }
      
      // Add the new identity
      identities.add(newIdentity);
      
      // Save all identities
      await saveIdentities(identities);
      
      return newIdentity;
    } catch (e) {
      debugPrint('Error adding identity: $e');
      rethrow;
    }
  }
  
  // Import an identity with just an address (public key hash)
  Future<Identity> importIdentity(String name, String address) async {
    try {
      // Validate the address format (basic validation)
      if (!_isValidAddress(address)) {
        throw Exception('Invalid address format');
      }
      
      // Create a new imported identity
      final importedIdentity = Identity.importFromAddress(name, address);
      
      // Get existing identities
      final identities = await getIdentities();
      
      // If this is the first identity, make it the default
      if (identities.isEmpty) {
        importedIdentity.isDefault = true;
      }
      
      // Add the imported identity
      identities.add(importedIdentity);
      
      // Save all identities
      await saveIdentities(identities);
      
      return importedIdentity;
    } catch (e) {
      debugPrint('Error importing identity: $e');
      rethrow;
    }
  }
  
  // Basic validation for address format
  bool _isValidAddress(String address) {
    // Check if it's a valid hex string (allowing with or without 0x prefix)
    final cleanAddress = address.startsWith('0x') ? address.substring(2) : address;
    return RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(cleanAddress);
  }
  
  // Delete an identity
  Future<void> deleteIdentity(String identityId) async {
    try {
      // Get existing identities
      final identities = await getIdentities();
      
      // Find the identity to delete
      final identityToDelete = identities.firstWhere(
        (identity) => identity.id == identityId,
        orElse: () => throw Exception('Identity not found'),
      );
      
      // Remove the identity
      identities.removeWhere((identity) => identity.id == identityId);
      
      // If we deleted the default identity, set a new default if possible
      if (identityToDelete.isDefault && identities.isNotEmpty) {
        identities.first.isDefault = true;
      }
      
      // Save updated identities
      await saveIdentities(identities);
    } catch (e) {
      debugPrint('Error deleting identity: $e');
      rethrow;
    }
  }
  
  // Update an identity's name
  Future<void> updateIdentityName(String identityId, String newName) async {
    try {
      // Get existing identities
      final identities = await getIdentities();
      
      // Find and update the identity
      final updatedIdentities = identities.map((identity) {
        if (identity.id == identityId) {
          return identity.copyWith(name: newName);
        }
        return identity;
      }).toList();
      
      // Save updated identities
      await saveIdentities(updatedIdentities);
    } catch (e) {
      debugPrint('Error updating identity name: $e');
      rethrow;
    }
  }
}
