import 'dart:io';
import 'package:flutter/foundation.dart';

// Import shared_preferences for all platforms
import 'package:shared_preferences/shared_preferences.dart';

// Import flutter_secure_storage for supported platforms only
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A platform-aware storage service that handles secure storage differently based on platform
/// For Windows, it falls back to SharedPreferences with a simple encryption
class PlatformStorageService {
  // Singleton pattern
  static final PlatformStorageService _instance = PlatformStorageService._internal();
  factory PlatformStorageService() => _instance;
  PlatformStorageService._internal();
  
  // Create secure storage instance
  // On Windows and Web, we'll use our fallback methods instead
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  
  // Flag to determine if we should use secure storage or fallback
  final bool _useSecureStorage = !kIsWeb && !Platform.isWindows;
  
  // Simple encryption key for Windows platform (not truly secure, but better than plaintext)
  static const String _encryptionKey = 'kbuc_miner_app_key';
  
  /// Write a value securely
  Future<void> write({required String key, required String? value}) async {
    if (!_useSecureStorage) {
      // On Windows or Web, use SharedPreferences with simple encryption
      if (value == null) {
        // Handle null value (deletion)
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(key);
      } else {
        // Simple XOR encryption (not truly secure but better than plaintext)
        final encrypted = _simpleEncrypt(value);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(key, encrypted);
      }
    } else {
      // On supported platforms, use secure storage
      await _secureStorage.write(key: key, value: value);
    }
  }
  
  /// Read a value securely
  Future<String?> read({required String key}) async {
    if (!_useSecureStorage) {
      // On Windows or Web, use SharedPreferences with simple decryption
      final prefs = await SharedPreferences.getInstance();
      final encrypted = prefs.getString(key);
      if (encrypted == null) return null;
      return _simpleDecrypt(encrypted);
    } else {
      // On supported platforms, use secure storage
      return await _secureStorage.read(key: key);
    }
  }
  
  /// Delete a value
  Future<void> delete({required String key}) async {
    if (!_useSecureStorage) {
      // On Windows or Web, use SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } else {
      // On supported platforms, use secure storage
      await _secureStorage.delete(key: key);
    }
  }
  
  /// Delete all values
  Future<void> deleteAll() async {
    if (!_useSecureStorage) {
      // On Windows or Web, use SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      // Only remove keys that start with our prefix to avoid clearing other app data
      final keys = prefs.getKeys().where((key) => key.startsWith('encrypted_'));
      for (final key in keys) {
        await prefs.remove(key);
      }
    } else {
      // On supported platforms, use secure storage
      await _secureStorage.deleteAll();
    }
  }
  
  /// Very simple XOR encryption (not secure, just to avoid plaintext)
  String _simpleEncrypt(String text) {
    final result = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      final keyChar = _encryptionKey[i % _encryptionKey.length];
      final encryptedChar = String.fromCharCode(
        text.codeUnitAt(i) ^ keyChar.codeUnitAt(0)
      );
      result.write(encryptedChar);
    }
    return 'encrypted_${result.toString()}';
  }
  
  /// Simple XOR decryption
  String _simpleDecrypt(String encrypted) {
    if (!encrypted.startsWith('encrypted_')) {
      return encrypted; // Not encrypted with our method
    }
    
    final text = encrypted.substring(10); // Remove 'encrypted_' prefix
    final result = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      final keyChar = _encryptionKey[i % _encryptionKey.length];
      final decryptedChar = String.fromCharCode(
        text.codeUnitAt(i) ^ keyChar.codeUnitAt(0)
      );
      result.write(decryptedChar);
    }
    return result.toString();
  }
}
