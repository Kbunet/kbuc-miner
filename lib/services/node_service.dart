import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/node_settings.dart';

class BroadcastResponse {
  final String hash;
  final bool success;

  BroadcastResponse({required this.hash, required this.success});

  factory BroadcastResponse.fromJson(Map<String, dynamic> json) {
    final result = json['result'] as Map<String, dynamic>;
    // The node response only includes hash, but no success field
    // We consider it successful if there's a hash and no error
    return BroadcastResponse(
      hash: result['hash'] as String,
      success: json['error'] == null,
    );
  }
}

class NodeService {
  void _logRequest(String method, dynamic params, Map<String, String> headers) {
    debugPrint('🌐 Sending RPC request:');
    debugPrint('  Method: $method');
    debugPrint('  Params: $params');
    debugPrint('  Headers: ${headers.map((k, v) => MapEntry(k, k == 'Authorization' ? '[REDACTED]' : v))}');
  }

  void _logResponse(http.Response response, dynamic decodedBody) {
    debugPrint('📥 Received response:');
    debugPrint('  Status code: ${response.statusCode}');
    debugPrint('  Headers: ${response.headers}');
    debugPrint('  Body: ${const JsonEncoder.withIndent('  ').convert(decodedBody)}');
  }

  Future<Map<String, dynamic>> getSupportableLeader() async {
    final settings = await NodeSettings.load();
    final url = Uri.parse(settings.connectionString);
    
    final headers = {
      'Content-Type': 'application/json',
    };

    if (settings.username.isNotEmpty) {
      final basicAuth = base64Encode(utf8.encode('${settings.username}:${settings.password}'));
      headers['Authorization'] = 'Basic $basicAuth';
    }

    try {
      _logRequest('getsupportableleader', [], headers);

      final response = await http.post(
        url,
        headers: headers,
        body: json.encode({
          'method': 'getsupportableleader',
          'params': [],
          'id': 1,
        }),
      );

      final data = json.decode(response.body);
      _logResponse(response, data);

      if (response.statusCode == 200) {
        if (data['error'] != null) {
          throw Exception(data['error']['message']);
        }
        return data['result'] as Map<String, dynamic>;
      } else {
        throw Exception('Failed to fetch leader: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('❌ Error in getSupportableLeader: $e');
      rethrow;
    }
  }

  Future<BroadcastResponse> broadcastRawSupportTicket(String ticketHex) async {
    final settings = await NodeSettings.load();
    final url = Uri.parse(settings.connectionString);
    
    final headers = {
      'Content-Type': 'application/json',
    };

    if (settings.username.isNotEmpty) {
      final basicAuth = base64Encode(utf8.encode('${settings.username}:${settings.password}'));
      headers['Authorization'] = 'Basic $basicAuth';
    }

    try {
      debugPrint('🎫 Broadcasting ticket:');
      debugPrint('  Ticket hex: $ticketHex');
      _logRequest('broadcastsupportticket', [ticketHex], headers);

      final response = await http.post(
        url,
        headers: headers,
        body: json.encode({
          'method': 'broadcastsupportticket',
          'params': [ticketHex],
          'id': 'curltest',
        }),
      );

      final data = json.decode(response.body);
      _logResponse(response, data);

      if (response.statusCode == 200) {
        if (data['error'] != null) {
          debugPrint('❌ Error from node: ${data['error']}');
          throw Exception('Node error: ${data['error']}');
        }
        
        try {
          return BroadcastResponse.fromJson(data);
        } catch (parseError) {
          debugPrint('❌ Error parsing broadcast response:');
          debugPrint('  Error: $parseError');
          debugPrint('  Response data: $data');
          throw Exception('Failed to parse broadcast response: $parseError');
        }
      } else {
        debugPrint('❌ HTTP error: ${response.statusCode}');
        throw Exception('Failed to broadcast ticket: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('❌ Error in broadcastRawSupportTicket: $e');
      rethrow;
    }
  }
}
