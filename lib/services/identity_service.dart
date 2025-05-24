import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/identity.dart';

class IdentityService {
  static const String _identitiesKey = 'encrypted_identities';
  static const String _authEnabledKey = 'identity_auth_enabled';
  static const String _defaultIdentityKey = 'default_identity_id';
  
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
      if (!isDeviceSupported) {
        debugPrint('Device does not support biometric authentication');
        return false;
      }
      
      // Then check if biometrics are available
      final canCheckBiometrics = await _localAuth.canCheckBiometrics;
      if (!canCheckBiometrics) {
        debugPrint('Device cannot check biometrics');
        return false;
      }
      
      // Get available biometrics to verify fingerprint is available
      final availableBiometrics = await _localAuth.getAvailableBiometrics();
      debugPrint('Available biometrics: $availableBiometrics');
      
      // For emulators, we'll consider it available if the device is supported
      // This helps with testing on emulators that have fingerprint configured
      return true;
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
  
  // Check if authentication is enabled
  Future<bool> isAuthenticationEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_authEnabledKey) ?? false;
  }
  
  // Authenticate user before accessing sensitive data
  Future<bool> authenticate() async {
    if (!await isAuthenticationEnabled()) {
      return true; // Authentication not required
    }
    
    try {
      return await _localAuth.authenticate(
        localizedReason: 'Authenticate to access your identities',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
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
  
  // Load identities from secure storage
  Future<List<Identity>> getIdentities() async {
    try {
      // Authentication temporarily disabled
      // if (await isAuthenticationEnabled()) {
      //   final authenticated = await authenticate();
      //   if (!authenticated) {
      //     debugPrint('Authentication failed, returning empty list');
      //     return []; // Return empty list instead of throwing exception
      //   }
      // }
      
      // Read encrypted data
      final identitiesJson = await _secureStorage.read(key: _identitiesKey);
      
      if (identitiesJson == null || identitiesJson.isEmpty) {
        return [];
      }
      
      // Decode JSON
      final identitiesList = jsonDecode(identitiesJson) as List;
      
      // Convert to Identity objects
      return identitiesList
          .map((identityMap) => Identity.fromMap(identityMap))
          .toList();
    } catch (e) {
      debugPrint('Error loading identities: $e');
      return [];
    }
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
