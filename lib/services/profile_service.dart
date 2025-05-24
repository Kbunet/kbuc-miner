import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'node_service.dart';

class ProfileInfo {
  final int rps;
  final int balance;
  final String name;
  final String link;
  final bool isRented;
  final bool isCandidate;
  final bool isBanned;

  ProfileInfo({
    required this.rps,
    required this.balance,
    this.name = '',
    this.link = '',
    this.isRented = false,
    this.isCandidate = false,
    this.isBanned = false,
  });

  factory ProfileInfo.fromJson(Map<String, dynamic> json) {
    return ProfileInfo(
      rps: json['rps'] ?? 0,
      balance: json['balance'] ?? 0,
      name: json['name'] ?? '',
      link: json['link'] ?? '',
      isRented: json['isRented'] ?? false,
      isCandidate: json['isCandidate'] ?? false,
      isBanned: json['isBanned'] ?? false,
    );
  }

  factory ProfileInfo.empty() {
    return ProfileInfo(rps: 0, balance: 0);
  }
}

class ProfileService {
  static final ProfileService _instance = ProfileService._internal();
  final NodeService _nodeService = NodeService();
  
  factory ProfileService() {
    return _instance;
  }
  
  ProfileService._internal();
  
  Future<ProfileInfo> getProfileInfo(String profileId) async {
    try {
      // Use NodeService to make the RPC call
      debugPrint('🔍 Fetching profile info for: $profileId');
      
      // Make the RPC request
      final response = await _nodeService.makeRpcRequest('getprofile', [profileId]);
      
      if (response.containsKey('error') && response['error'] != null) {
        debugPrint('❌ Error fetching profile info: ${response['error']}');
        return ProfileInfo.empty();
      }
      
      // Parse the result
      final Map<String, dynamic> profileData = response['result'] as Map<String, dynamic>;
      
      // Debug the received data
      debugPrint('💾 Profile data received: rps=${profileData['rps']}, balance=${profileData['balance']}');
      
      return ProfileInfo.fromJson(profileData);
    } catch (e) {
      debugPrint('❌ Exception fetching profile info: $e');
      return ProfileInfo.empty();
    }
  }
  
  // Format RPS value for display (e.g., "341.18M" for 341,176,241)
  String formatRps(int rps) {
    if (rps >= 1000000000) {
      return '${(rps / 1000000000).toStringAsFixed(2)}B';
    } else if (rps >= 1000000) {
      return '${(rps / 1000000).toStringAsFixed(2)}M';
    } else if (rps >= 1000) {
      return '${(rps / 1000).toStringAsFixed(2)}K';
    } else {
      return rps.toString();
    }
  }
  
  // Format balance for display
  String formatBalance(int balance) {
    if (balance >= 1000000000) {
      return '${(balance / 1000000000).toStringAsFixed(2)}B';
    } else if (balance >= 1000000) {
      return '${(balance / 1000000).toStringAsFixed(2)}M';
    } else if (balance >= 1000) {
      return '${(balance / 1000).toStringAsFixed(2)}K';
    } else {
      return balance.toString();
    }
  }
}
