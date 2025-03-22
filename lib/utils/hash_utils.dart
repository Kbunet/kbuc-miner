import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'byte_extensions.dart';

class HashUtils {
  /// Writes a 32-bit unsigned integer in little-endian format
  static Uint8List _writeUint32LE(int value) {
    final byteData = ByteData(4);
    byteData.setUint32(0, value, Endian.little);
    return byteData.buffer.asUint8List();
  }

  static Uint8List reverseBytes(List<int> input) {
    final reversed = Uint8List(input.length);
    for (var i = 0; i < input.length; i++) {
      reversed[i] = input[input.length - 1 - i];
    }
    return reversed;
  }

  static Uint8List doubleSha256(List<int> input) {
    final firstHash = sha256.convert(input);
    final secondHash = sha256.convert(firstHash.bytes);
    return reverseBytes(secondHash.bytes);
  }

  static String bytesToHexString(List<int> bytes) {
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Function to write a compact size integer
  static Uint8List writeCompactSize(int value) {
    final bytes = BytesBuilder();
    if (value < 0xfd) {
      bytes.addByte(value);
    } else if (value <= 0xffff) {
      bytes.addByte(0xfd);
      bytes.addByte(value & 0xff);
      bytes.addByte((value >> 8) & 0xff);
    } else if (value <= 0xffffffff) {
      bytes.addByte(0xfe);
      bytes.addByte(value & 0xff);
      bytes.addByte((value >> 8) & 0xff);
      bytes.addByte((value >> 16) & 0xff);
      bytes.addByte((value >> 24) & 0xff);
    } else {
      bytes.addByte(0xff);
      for (int i = 0; i < 8; i++) {
        bytes.addByte((value >> (8 * i)) & 0xff);
      }
    }
    return bytes.toBytes();
  }

  static Uint8List serializeHexStrings(String hexString) {
    // Remove '0x' prefix if present
    if (hexString.startsWith('0x')) {
      hexString = hexString.substring(2);
    }
    final buffer = BytesBuilder();
    final hexBytes = Uint8List.fromList(hex.decode(hexString));
    buffer.add(writeCompactSize(hexBytes.length));
    buffer.add(hexBytes);
    return buffer.toBytes();
  }

  static String createTicket(
    String content,
    String leader,
    int height,
    String owner,
    int rewardType,
    int timestamp,
    int nonce,
  ) {
    // debugPrint('🎫 Creating ticket hash with parameters:');
    // debugPrint('  Content: $content');
    // debugPrint('  Leader: $leader');
    // debugPrint('  Height: $height');
    // debugPrint('  Owner: $owner');
    // debugPrint('  Reward Type: $rewardType');
    // debugPrint('  Timestamp: $timestamp');
    // debugPrint('  Nonce: $nonce');

    final contentBytes = hexToBytes(content.replaceAll('0x', ''));
    final leaderBytes = hexToBytes(leader.replaceAll('0x', ''));
    final ownerBytes = hexToBytes(owner.replaceAll('0x', ''));

    // debugPrint('  Content bytes length: ${contentBytes.length}');
    // debugPrint('  Leader bytes length: ${leaderBytes.length}');
    // debugPrint('  Owner bytes length: ${ownerBytes.length}');

    final buffer = BytesBuilder();
    buffer.add(HashUtils.serializeHexStrings(content));
    buffer.add(HashUtils.serializeHexStrings(leader));
    buffer.add(height.toBytes(size: 4, endian: Endian.little));
    buffer.add(HashUtils.serializeHexStrings(owner));
    buffer.add(rewardType.toBytes(size: 1, endian: Endian.little));
    buffer.add(timestamp.toBytes(size: 4, endian: Endian.little));
    buffer.add(nonce.toBytes(size: 4, endian: Endian.little));

    final hash = HashUtils.doubleSha256(buffer.toBytes());
    final hashHex = HashUtils.bytesToHexString(hash);
    // debugPrint('  Generated hash: $hashHex');
    return hashHex;
  }

  static String ticketToHex(
    String content,
    String leader,
    int height,
    String owner,
    int rewardType,
    int timestamp,
    int nonce,
  ) {
    debugPrint('🔄 Converting ticket to hex with parameters:');
    debugPrint('  Content: $content');
    debugPrint('  Leader: $leader');
    debugPrint('  Height: $height');
    debugPrint('  Owner: $owner');
    debugPrint('  Reward Type: $rewardType');
    debugPrint('  Timestamp: $timestamp');
    debugPrint('  Nonce: $nonce');

    final contentBytes = hexToBytes(content.replaceAll('0x', ''));
    final leaderBytes = hexToBytes(leader.replaceAll('0x', ''));
    final ownerBytes = hexToBytes(owner.replaceAll('0x', ''));

    debugPrint('  Content bytes length: ${contentBytes.length}');
    debugPrint('  Leader bytes length: ${leaderBytes.length}');
    debugPrint('  Owner bytes length: ${ownerBytes.length}');

    final buffer = BytesBuilder();
    buffer.add(HashUtils.serializeHexStrings(content));
    buffer.add(HashUtils.serializeHexStrings(leader));
    buffer.add(height.toBytes(size: 4, endian: Endian.little));
    buffer.add(HashUtils.serializeHexStrings(owner));
    buffer.add(rewardType.toBytes(size: 1, endian: Endian.little));
    buffer.add(timestamp.toBytes(size: 4, endian: Endian.little));
    buffer.add(nonce.toBytes(size: 4, endian: Endian.little));

    final ticketHex = HashUtils.bytesToHexString(buffer.toBytes());
    debugPrint('  Generated ticket hex: $ticketHex');
    return ticketHex;
  }

  static Uint8List hexToBytes(String hex) {
    var cleanHex = hex.replaceAll('0x', '');
    if (cleanHex.length % 2 != 0) {
      cleanHex = '0$cleanHex';
    }
    final bytes = Uint8List(cleanHex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      final byteHex = cleanHex.substring(i * 2, (i * 2) + 2);
      bytes[i] = int.parse(byteHex, radix: 16);
    }
    return bytes;
  }

  static String bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}