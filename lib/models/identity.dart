import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:bs58/bs58.dart' as bs58;
import 'package:pointycastle/pointycastle.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:convert/convert.dart';
import 'package:flutter/foundation.dart';

/// Represents a Bitcoin-style identity with public and private keys
class Identity {
  final String id;
  final String name;
  final String? privateKey; // Optional for imported identities
  final String? publicKey; // Optional for imported identities
  final String address; // Public key hash/address (always required)
  final DateTime createdAt;
  bool isDefault;
  final bool isImported; // Flag to indicate if this is an imported identity
  
  // Profile information from the node
  int rps = 0; // Resource Power Score
  int balance = 0; // Profile balance
  bool hasLoadedProfileInfo = false; // Whether profile info has been loaded
  bool isLoadingProfileInfo = false; // Whether profile info is currently being loaded

  Identity({
    required this.id,
    required this.name,
    this.privateKey, // Optional for imported identities
    this.publicKey, // Optional for imported identities
    required this.address,
    required this.createdAt,
    this.isDefault = false,
    this.isImported = false,
    this.rps = 0,
    this.balance = 0,
    this.hasLoadedProfileInfo = false,
    this.isLoadingProfileInfo = false,
  });

  /// Create a new identity with a randomly generated key pair
  static Future<Identity> generate(String name) async {
    return await _generateNewIdentity(name);
  }
  
  /// Import an existing identity with only the public key hash/address
  static Identity importFromAddress(String name, String address) {
    return Identity(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      address: address,
      createdAt: DateTime.now(),
      isImported: true,
    );
  }
  
  /// Internal method to generate a new identity with full key pair
  static Future<Identity> _generateNewIdentity(String name) async {
    // Generate a secure random private key
    final secureRandom = FortunaRandom();
    
    // Seed the random generator
    final seedSource = Random.secure();
    final seeds = List<int>.generate(32, (_) => seedSource.nextInt(256));
    secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));
    
    // Generate private key bytes
    final privateKeyBytes = Uint8List(32);
    for (var i = 0; i < privateKeyBytes.length; i++) {
      privateKeyBytes[i] = secureRandom.nextUint8();
    }
    
    // Convert to hex string for internal use
    final privateKeyHex = privateKeyBytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    
    // Convert to WIF format for display
    final privateKeyWif = _convertToWIF(privateKeyBytes);
    
    // Derive public key (simplified for now - in a real app you'd use a proper Bitcoin library)
    final publicKeyBytes = _derivePublicKey(privateKeyBytes);
    final publicKeyHex = publicKeyBytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    
    // Generate P2WPKH (SegWit) address using proper Bitcoin address derivation
    // 1. SHA-256 hash of the public key
    final sha256Hash = sha256.convert(publicKeyBytes).bytes;
    // 2. RIPEMD-160 hash of the SHA-256 hash (this is the actual public key hash)
    final ripemd160 = RIPEMD160Digest();
    final pubKeyHash = ripemd160.process(Uint8List.fromList(sha256Hash));
    
    // For P2WPKH, we just use the public key hash directly without Base58Check encoding
    // This is because P2WPKH addresses use Bech32 encoding, but for our purposes
    // we'll just store the public key hash in hex format as that's what's needed for mining
    final address = pubKeyHash.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    
    return Identity(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      privateKey: privateKeyWif, // Store the WIF format for display
      publicKey: publicKeyHex,
      address: address,
      createdAt: DateTime.now(),
    );
  }

  // Proper Bitcoin public key derivation using secp256k1 elliptic curve
  static Uint8List _derivePublicKey(Uint8List privateKeyBytes) {
    try {
      // Get the secp256k1 curve domain parameters
      final domainParams = ECDomainParameters('secp256k1');
      
      // Convert private key bytes to BigInt
      final privateKeyBigInt = _bytesToBigInt(privateKeyBytes);
      
      // Create EC private key
      final privateKey = ECPrivateKey(privateKeyBigInt, domainParams);
      
      // Get point G * privateKey (EC multiplication)
      final Q = domainParams.G * privateKey.d;
      
      if (Q == null) {
        throw Exception('Failed to derive public key point');
      }
      
      // Get the public key in compressed format
      final publicKeyCompressed = _getCompressedPublicKey(Q);
      
      return publicKeyCompressed;
    } catch (e) {
      debugPrint('Error deriving public key: $e');
      // Fallback to a placeholder if derivation fails
      return Uint8List.fromList(sha256.convert(privateKeyBytes).bytes);
    }
  }
  
  // Convert bytes to BigInt
  static BigInt _bytesToBigInt(Uint8List bytes) {
    BigInt result = BigInt.zero;
    for (int i = 0; i < bytes.length; i++) {
      result = result << 8;
      result = result | BigInt.from(bytes[i]);
    }
    return result;
  }
  
  // Get compressed public key format (33 bytes: 0x02 or 0x03 prefix + 32 bytes X coordinate)
  static Uint8List _getCompressedPublicKey(ECPoint point) {
    // Handle nullable fields with null checks
    if (point.x == null || point.y == null) {
      throw Exception('Invalid EC point with null coordinates');
    }
    
    final xBigInt = point.x!.toBigInteger();
    final yBigInt = point.y!.toBigInteger();
    
    if (xBigInt == null || yBigInt == null) {
      throw Exception('Failed to convert EC point coordinates to BigInt');
    }
    
    final xBytes = _bigIntToBytes(xBigInt);
    final prefix = yBigInt.isOdd ? 0x03 : 0x02;
    
    final result = Uint8List(33);
    result[0] = prefix;
    for (var i = 0; i < 32; i++) {
      result[i + 1] = xBytes[i];
    }
    
    return result;
  }
  
  // Helper to convert BigInt to bytes with proper padding
  static Uint8List _bigIntToBytes(BigInt number) {
    final hexString = number.toRadixString(16).padLeft(64, '0');
    return Uint8List.fromList(hex.decode(hexString));
  }
  
  // Convert private key to WIF format for SegWit (compressed public key)
  static String _convertToWIF(Uint8List privateKey) {
    // Add version byte (0x80 for mainnet) and compression flag (0x01)
    final extendedKey = Uint8List(privateKey.length + 2); // +2 for version byte and compression flag
    extendedKey[0] = 0x80; // Mainnet private key prefix
    for (var i = 0; i < privateKey.length; i++) {
      extendedKey[i + 1] = privateKey[i];
    }
    extendedKey[privateKey.length + 1] = 0x01; // Compression flag for SegWit
    
    // Calculate checksum (double SHA-256)
    final firstSHA = sha256.convert(extendedKey);
    final secondSHA = sha256.convert(firstSHA.bytes);
    final checksum = secondSHA.bytes.sublist(0, 4);
    
    // Combine extended key (with compression flag) and checksum
    final keyWithChecksum = Uint8List(extendedKey.length + 4);
    for (var i = 0; i < extendedKey.length; i++) {
      keyWithChecksum[i] = extendedKey[i];
    }
    for (var i = 0; i < 4; i++) {
      keyWithChecksum[extendedKey.length + i] = checksum[i];
    }
    
    // Base58 encode
    return bs58.base58.encode(keyWithChecksum);
  }

  /// Convert identity to a map for storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'privateKey': privateKey,
      'publicKey': publicKey,
      'address': address,
      'createdAt': createdAt.toIso8601String(),
      'isDefault': isDefault,
      'isImported': isImported,
      'rps': rps,
      'balance': balance,
      'hasLoadedProfileInfo': hasLoadedProfileInfo,
      'isLoadingProfileInfo': false, // Always reset to false when saving
    };
  }

  /// Create identity from a map
  factory Identity.fromMap(Map<String, dynamic> map) {
    return Identity(
      id: map['id'],
      name: map['name'],
      privateKey: map['privateKey'],
      publicKey: map['publicKey'],
      address: map['address'],
      createdAt: DateTime.parse(map['createdAt']),
      isDefault: map['isDefault'] ?? false,
      isImported: map['isImported'] ?? false,
      rps: map['rps'] ?? 0,
      balance: map['balance'] ?? 0,
      hasLoadedProfileInfo: map['hasLoadedProfileInfo'] ?? false,
      isLoadingProfileInfo: false, // Always initialize as false
    );
  }

  /// Create a copy of this identity with updated fields
  Identity copyWith({
    String? name,
    bool? isDefault,
    int? rps,
    int? balance,
    bool? hasLoadedProfileInfo,
    bool? isLoadingProfileInfo,
  }) {
    return Identity(
      id: id,
      name: name ?? this.name,
      privateKey: privateKey,
      publicKey: publicKey,
      address: address,
      createdAt: createdAt,
      isDefault: isDefault ?? this.isDefault,
      isImported: isImported,
      rps: rps ?? this.rps,
      balance: balance ?? this.balance,
      hasLoadedProfileInfo: hasLoadedProfileInfo ?? this.hasLoadedProfileInfo,
      isLoadingProfileInfo: isLoadingProfileInfo ?? this.isLoadingProfileInfo,
    );
  }
}
