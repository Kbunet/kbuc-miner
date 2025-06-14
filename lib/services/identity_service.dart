import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import '../models/identity.dart';
import 'auth_service_wrapper.dart';
import 'platform_auth_service.dart';
import 'platform_storage_service.dart';

class IdentityService {
  static const String _identitiesKey = 'encrypted_identities';
  static const String _authEnabledKey = 'identity_auth_enabled';
  static const String _defaultIdentityKey = 'default_identity_id';
  static const String _passwordHashKey = 'identity_password_hash';
  static const String _authMethodKey = 'identity_auth_method';

  final PlatformStorageService _secureStorage = PlatformStorageService();
  final AuthServiceWrapper _authService = AuthServiceWrapper();

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
    // First check if we should disable biometrics on this platform
    if (!PlatformAuthService.isBiometricSupported) {
      debugPrint('Biometrics not supported on this platform');
      return false;
    }

    try {
      // Use our wrapper to check if biometrics are available
      // This will handle platform-specific checks and fallbacks
      final isAvailable = await _authService.isBiometricAvailable();
      debugPrint('Biometric authentication available: $isAvailable');
      
      // Get available biometrics for logging
      final availableBiometrics = await _authService.getAvailableBiometrics();
      debugPrint('Available biometrics: $availableBiometrics');
      
      return isAvailable;
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

  // Tests if biometric authentication works without checking current auth method
  // This is used for initial setup of biometric authentication
  Future<bool> testBiometricAuth() async {
    // First check if we should disable biometrics on this platform
    if (!PlatformAuthService.isBiometricSupported) {
      debugPrint('Biometrics not supported on this platform');
      return false;
    }

    try {
      // Use our wrapper to authenticate with biometrics
      final authenticated = await _authService.authenticate(
        reason: PlatformAuthService.getAuthMessage(),
      );
      
      debugPrint('Biometric test result: $authenticated');
      return authenticated;
    } catch (e) {
      debugPrint('Error testing biometric auth: $e');
      return false;
    }
  }

  Future<bool> authenticate() async {
    // Check if authentication is enabled
    final authEnabled = await isAuthenticationEnabled();
    if (!authEnabled) {
      debugPrint('Authentication is disabled');
      return true; // No authentication needed
    }

    // Get the auth method
    final authMethod = await getAuthMethod();
    debugPrint('Using auth method: $authMethod');

    if (authMethod == 'biometric') {
      // First check if we should disable biometrics on this platform
      if (!PlatformAuthService.isBiometricSupported) {
        debugPrint('Biometrics not supported on this platform, falling back to password');
        // Fall back to password authentication
        return await _passwordAuthentication();
      }

      try {
        // Use our wrapper to authenticate with biometrics
        final authenticated = await _authService.authenticate(
          reason: PlatformAuthService.getAuthMessage(),
        );
        
        if (!authenticated) {
          debugPrint('Biometric authentication failed');
          // Fall back to password authentication
          return await _passwordAuthentication();
        }
        
        return true;
      } catch (e) {
        debugPrint('Error during biometric authentication: $e');
        // Fall back to password authentication
        return await _passwordAuthentication();
      }
    } else {
      // Password authentication
      return await _passwordAuthentication();
    }
  }

  // Helper method for password authentication
  Future<bool> _passwordAuthentication() async {
    // This would typically show a password dialog in the UI
    // For now, we'll just return false to indicate authentication failed
    debugPrint('Password authentication not implemented in this method');
    return false;
  }

  // Save identities to secure storage
  Future<void> saveIdentities(List<Identity> identities) async {
    try {
      // Convert identities to JSON
      final List<Map<String, dynamic>> identitiesJson = identities.map((identity) => identity.toMap()).toList();
      
      // Convert to JSON string
      final String jsonString = jsonEncode(identitiesJson);
      
      // Encrypt and save
      await _secureStorage.write(key: _identitiesKey, value: jsonString);
      
      // Also save the default identity ID in shared preferences for quick access
      Identity? defaultIdentity;
      try {
        defaultIdentity = identities.firstWhere(
          (identity) => identity.isDefault,
        );
      } catch (e) {
        // No default identity found, use first if available
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
      // Check if authentication is enabled
      final authEnabled = await isAuthenticationEnabled();
      
      if (authEnabled) {
        // Authenticate before returning identities
        final authenticated = await authenticate();
        if (!authenticated) {
          throw Exception('Authentication failed');
        }
      }
      
      return await _getIdentitiesFromStorage();
    } catch (e) {
      debugPrint('Error getting identities: $e');
      rethrow;
    }
  }

  // Get identities after password verification
  // This is used when the user has already verified their password
  Future<List<Identity>> getIdentitiesAfterPasswordVerification() async {
    try {
      // Skip authentication and directly get identities
      return await _getIdentitiesFromStorage();
    } catch (e) {
      debugPrint('Error getting identities after password verification: $e');
      rethrow;
    }
  }

  // Helper method to get identities from storage
  Future<List<Identity>> _getIdentitiesFromStorage() async {
    try {
      // Get encrypted identities from secure storage
      final jsonString = await _secureStorage.read(key: _identitiesKey);
      
      if (jsonString == null || jsonString.isEmpty) {
        return []; // No identities found
      }
      
      // Decrypt and parse JSON
      final List<dynamic> decodedJson = jsonDecode(jsonString);
      
      // Convert to Identity objects
      final List<Identity> identities = decodedJson.map((json) => Identity.fromMap(json)).toList();
      
      return identities;
    } catch (e) {
      debugPrint('Error reading identities from storage: $e');
      return []; // Return empty list on error
    }
  }

  // Get the default identity
  Future<Identity?> getDefaultIdentity() async {
    try {
      // First try to get the default identity ID from shared preferences
      final prefs = await SharedPreferences.getInstance();
      final defaultId = prefs.getString(_defaultIdentityKey);
      
      // Get all identities
      final identities = await getIdentities();
      
      if (identities.isEmpty) {
        return null; // No identities available
      }
      
      if (defaultId != null) {
        // Try to find the identity with the default ID
        final defaultIdentity = identities.firstWhere(
          (identity) => identity.id == defaultId,
          orElse: () => identities.first, // Fall back to first identity if default not found
        );
        
        return defaultIdentity;
      } else {
        // No default ID stored, use the first identity marked as default
        final defaultIdentity = identities.firstWhere(
          (identity) => identity.isDefault,
          orElse: () => identities.first, // Fall back to first identity if none marked as default
        );
        
        return defaultIdentity;
      }
    } catch (e) {
      debugPrint('Error getting default identity: $e');
      return null;
    }
  }

  // Set an identity as the default
  Future<void> setDefaultIdentity(String identityId) async {
    try {
      // Get all identities
      final identities = await getIdentities();
      
      // Update isDefault flag for all identities
      final updatedIdentities = identities.map((identity) {
        if (identity.id == identityId) {
          return identity.copyWith(isDefault: true);
        } else {
          return identity.copyWith(isDefault: false);
        }
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
    
    // Accept any valid hex string with a reasonable length
    // This covers all common formats:
    // - 32-character (SHA-256 hash)
    // - 40-character (RIPEMD-160 hash)
    // - 64/66-character (compressed public key with/without prefix)
    // - Other valid formats used in the Kbunet ecosystem
    return RegExp(r'^[0-9a-fA-F]{32,70}$').hasMatch(cleanAddress);
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
  
  // Export identities to JSON (excluding private keys)
  Future<String> exportIdentitiesAsJson() async {
    try {
      // Get existing identities
      final identities = await getIdentities();
      
      // Create a list of maps with only the necessary fields
      final exportData = identities.map((identity) => {
        'name': identity.name,
        'address': identity.address,
        'isDefault': identity.isDefault,
        'isImported': true, // Always mark as imported when exporting
      }).toList();
      
      // Convert to JSON
      final jsonData = jsonEncode({
        'identities': exportData,
        'exportDate': DateTime.now().toIso8601String(),
        'version': '1.0',
      });
      
      return jsonData;
    } catch (e) {
      debugPrint('Error exporting identities: $e');
      rethrow;
    }
  }
  
  // Import identities from JSON
  Future<List<Identity>> importIdentitiesFromJson(String jsonData) async {
    try {
      // Parse the JSON data
      final Map<String, dynamic> data = jsonDecode(jsonData);
      
      // Validate the data structure
      if (!data.containsKey('identities') || data['identities'] is! List) {
        throw Exception('Invalid JSON format: missing or invalid identities list');
      }
      
      // Get the list of identity data
      final List<dynamic> identitiesData = data['identities'];
      
      // Get existing identities to avoid duplicates
      final existingIdentities = await getIdentities();
      final existingAddresses = existingIdentities.map((e) => e.address).toSet();
      
      // Process each identity
      final importedIdentities = <Identity>[];
      for (final identityData in identitiesData) {
        // Validate required fields
        if (identityData is! Map<String, dynamic> ||
            !identityData.containsKey('name') ||
            !identityData.containsKey('address')) {
          debugPrint('Skipping invalid identity data: $identityData');
          continue;
        }
        
        final String name = identityData['name'];
        final String address = identityData['address'];
        
        // Skip if address is invalid
        if (!_isValidAddress(address)) {
          debugPrint('Skipping identity with invalid address: $address');
          continue;
        }
        
        // Skip if address already exists
        if (existingAddresses.contains(address)) {
          debugPrint('Skipping duplicate identity with address: $address');
          continue;
        }
        
        // Import the identity
        final importedIdentity = Identity.importFromAddress(name, address);
        importedIdentities.add(importedIdentity);
        existingAddresses.add(address); // Prevent duplicates within the import
      }
      
      // If any identities were imported, save them
      if (importedIdentities.isNotEmpty) {
        final allIdentities = [...existingIdentities, ...importedIdentities];
        await saveIdentities(allIdentities);
      }
      
      return importedIdentities;
    } catch (e) {
      debugPrint('Error importing identities: $e');
      rethrow;
    }
  }
}
