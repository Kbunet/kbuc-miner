import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'node_service.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:miner_app/models/blockchain_stats.dart';
import 'package:flutter/material.dart';

// Class to represent an owned profile from the API response
class OwnedProfile {
  final String id;
  final String creator;
  final String owner;
  final String name;
  final String link;
  final int rps;
  final int height;
  final int balance;
  final bool isCandidate;
  final bool isBanned;
  final bool isDomain;
  final int generatedRPs;
  final int ownedProfilesNo;
  final String? ownerId; // Owner ID of the identity
  
  OwnedProfile({
    required this.id,
    required this.creator,
    required this.owner,
    this.name = '',
    this.link = '',
    this.rps = 0,
    this.height = 0,
    this.balance = 0,
    this.isCandidate = false,
    this.isBanned = false,
    this.isDomain = false,
    this.generatedRPs = 0,
    this.ownedProfilesNo = 0,
    this.ownerId,
  });
  
  factory OwnedProfile.fromJson(Map<String, dynamic> json) {
    return OwnedProfile(
      id: json['id'] ?? '',
      creator: json['creator'] ?? '',
      owner: json['owner'] ?? '',
      name: json['name'] ?? '',
      link: json['link'] ?? '',
      rps: json['rps'] ?? 0,
      height: json['height'] ?? 0,
      balance: json['balance'] ?? 0,
      isCandidate: json['isCandidate'] ?? false,
      isBanned: json['isBanned'] ?? false,
      isDomain: json['isDomain'] ?? false,
      generatedRPs: json['generatedRPs'] ?? 0,
      ownedProfilesNo: json['ownedProfilesCount'] ?? json['ownedProfilesNo'] ?? 0,
      ownerId: json['ownerId'] ?? json['owner'] ?? null,
    );
  }
}

class ProfileInfo {
  final int rps;
  final int balance;
  final String name;
  final String link;
  final bool isRented;
  final bool isCandidate;
  final bool isBanned;
  final int height;

  final int generatedRPs;
  final int ownedProfilesNo;
  
  // Identity type properties
  final String? ownerId; // Owner ID of the identity
  final bool isDomain; // Whether this is a domain identity
  final List<OwnedProfile> ownedProfiles; // Owned profiles list

  ProfileInfo({
    required this.rps,
    required this.balance,
    this.name = '',
    this.link = '',
    this.isRented = false,
    this.isCandidate = false,
    this.isBanned = false,
    this.height = 0,
    this.generatedRPs = 0,
    this.ownedProfilesNo = 0,
    this.ownerId,
    this.isDomain = false,
    this.ownedProfiles = const [],
  });

  factory ProfileInfo.fromJson(Map<String, dynamic> json) {
    // Parse owned profiles if available
    List<OwnedProfile> ownedProfiles = [];
    if (json.containsKey('ownedProfiles') && json['ownedProfiles'] != null) {
      final ownedProfilesList = json['ownedProfiles'] as List<dynamic>;
      ownedProfiles = ownedProfilesList
          .map((profileData) => OwnedProfile.fromJson(profileData as Map<String, dynamic>))
          .toList();
    }
    
    return ProfileInfo(
      rps: json['rps'] ?? 0,
      balance: json['balance'] ?? 0,
      name: json['name'] ?? '',
      link: json['link'] ?? '',
      isRented: json['isRented'] ?? false,
      isCandidate: json['isCandidate'] ?? false,
      isBanned: json['isBanned'] ?? false,
      height: json['height'] ?? 0,
      generatedRPs: json['generatedRPs'] ?? 0,
      ownedProfilesNo: json['ownedProfilesCount'] ?? json['ownedProfilesNo'] ?? 0,
      ownerId: json['ownerId'] ?? json['owner'] ?? null, // Extract ownerId from API response
      isDomain: json['isDomain'] ?? false, // Extract isDomain from API response
      ownedProfiles: ownedProfiles,
    );
  }

  factory ProfileInfo.empty() {
    return ProfileInfo(rps: 0, balance: 0, ownerId: null, isDomain: false, ownedProfiles: []);
  }
}

class ProfileService {
  static final ProfileService _instance = ProfileService._internal();
  final NodeService _nodeService = NodeService();
  
  // Store the latest blockchain stats
  BlockchainStats? _blockchainStats;
  Timer? _statsTimer;
  
  factory ProfileService() {
    return _instance;
  }
  
  ProfileService._internal() {
    // Initialize blockchain stats and start periodic updates
    _initBlockchainStats();
  }
  
  // Initialize blockchain stats
  Future<void> _initBlockchainStats() async {
    // Load cached stats from storage if available
    await _loadCachedStats();
    
    // Fetch fresh stats
    await fetchBlockchainStats();
    
    // Set up periodic updates every 5 minutes
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      fetchBlockchainStats();
    });
  }
  
  // Load cached stats from SharedPreferences
  Future<void> _loadCachedStats() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final statsJson = prefs.getString('blockchain_stats');
      
      if (statsJson != null) {
        final Map<String, dynamic> statsMap = jsonDecode(statsJson);
        final lastUpdatedMs = statsMap['last_updated'] as int?;
        
        if (lastUpdatedMs != null) {
          final lastUpdated = DateTime.fromMillisecondsSinceEpoch(lastUpdatedMs);
          _blockchainStats = BlockchainStats.fromJson(statsMap);
          
          debugPrint('📊 Loaded cached blockchain stats from ${lastUpdated.toString()}');
        }
      }
    } catch (e) {
      debugPrint('❌ Error loading cached blockchain stats: $e');
    }
  }
  
  // Save stats to SharedPreferences
  Future<void> _saveStatsToCache(BlockchainStats stats) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final statsJson = jsonEncode(stats.toJson());
      await prefs.setString('blockchain_stats', statsJson);
      debugPrint('💾 Saved blockchain stats to cache');
    } catch (e) {
      debugPrint('❌ Error saving blockchain stats to cache: $e');
    }
  }
  
  // Fetch blockchain stats from the node
  Future<BlockchainStats> fetchBlockchainStats() async {
    try {
      debugPrint('🔍 Fetching blockchain stats...');
      final response = await _nodeService.makeRpcRequest('getgeneralstats', []);
      
      if (response.containsKey('error') && response['error'] != null) {
        debugPrint('❌ Error fetching blockchain stats: ${response['error']}');
        return _blockchainStats ?? BlockchainStats.empty();
      }
      
      final Map<String, dynamic> statsData = response['result'] as Map<String, dynamic>;
      final stats = BlockchainStats.fromJson(statsData);
      
      // Update the cached stats
      _blockchainStats = stats;
      
      // Save to persistent storage
      await _saveStatsToCache(stats);
      
      debugPrint('✅ Blockchain stats updated: height=${stats.currentHeight}, supply=${stats.currentSupply}');
      return stats;
    } catch (e) {
      debugPrint('❌ Exception fetching blockchain stats: $e');
      return _blockchainStats ?? BlockchainStats.empty();
    }
  }
  
  // Get the current blockchain stats (fetch if stale)
  Future<BlockchainStats> getBlockchainStats() async {
    // If we don't have stats or they're stale (older than 5 minutes), fetch new ones
    if (_blockchainStats == null || _blockchainStats!.isStale) {
      return await fetchBlockchainStats();
    }
    return _blockchainStats!;
  }
  
  // Calculate identity durability based on current height and identity height
  // Returns a value between 0.0 (danger) and 1.0 (safe)
  Future<double> calculateIdentityDurability(int identityHeight) async {
    final stats = await getBlockchainStats();
    final heightDifference = stats.currentHeight - identityHeight;
    
    // If height difference is 10000 or more, identity is fully safe (1.0)
    // If height difference is 0 or negative, identity is in full danger (0.0)
    // Otherwise, it's a value between 0.0 and 1.0
    final durability = heightDifference / 10000.0;
    return durability.clamp(0.0, 1.0);
  }
  
  // Get color based on identity durability
  Color getIdentityDurabilityColor(double durability) {
    if (durability >= 0.7) {
      // Safe - green
      return Colors.green;
    } else if (durability >= 0.3) {
      // Warning - orange
      return Colors.orange;
    } else {
      // Danger - red
      return Colors.red;
    }
  }
  
  // Calculate available NFT slots
  int calculateNftSlots(int rps, int generatedRPs, int ownedProfilesNo) {
    // Formula: slots = (rps + generatedRPs) / 20000000 - ownedProfilesNo
    final totalRps = rps + generatedRPs;
    final totalSlots = totalRps / 20000000;
    final availableSlots = totalSlots.floor() - ownedProfilesNo;
    
    // Return the result, ensuring it's not negative
    return availableSlots > 0 ? availableSlots : 0;
  }
  
  // Format NFT slots for display
  String formatNftSlots(int slots) {
    if (slots <= 0) {
      return 'No slots available';
    } else if (slots == 1) {
      return '1 slot available';
    } else {
      return '$slots slots available';
    }
  }
  
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
  
  // Get owned profiles for a given profile ID
  Future<List<OwnedProfile>> getOwnedProfiles(String profileId) async {
    try {
      debugPrint('🔍 Fetching owned profiles for: $profileId');
      
      // Get the profile info which includes owned profiles
      final profileInfo = await getProfileInfo(profileId);
      
      // Return the owned profiles directly from the profile info
      debugPrint('📊 Found ${profileInfo.ownedProfiles.length} owned profiles');
      return profileInfo.ownedProfiles;
    } catch (e) {
      debugPrint('❌ Exception fetching owned profiles: $e');
      return [];
    }
  }
}
