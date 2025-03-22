import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

class NodeSettings {
  String host;
  int port;
  String username;
  String password;
  bool useSSL;
  String defaultTicketOwner;
  int cpuCores;

  NodeSettings({
    this.host = 'localhost',
    this.port = 8332,
    this.username = '',
    this.password = '',
    this.useSSL = false,
    this.defaultTicketOwner = '',
    this.cpuCores = 1,
  });

  // Get the maximum number of available CPU cores
  static int getMaxCpuCores() {
    try {
      return Platform.numberOfProcessors;
    } catch (e) {
      // Default to 1 if we can't determine the number of cores
      return 1;
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setString('node_host', host),
        prefs.setInt('node_port', port),
        prefs.setString('node_username', username),
        prefs.setString('node_password', password),
        prefs.setBool('node_use_ssl', useSSL),
        prefs.setString('default_ticket_owner', defaultTicketOwner),
        prefs.setInt('cpu_cores', cpuCores),
      ]);
    } catch (e) {
      // Handle any potential storage errors
      print('Error saving settings: $e');
      rethrow;
    }
  }

  static Future<NodeSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Default to 1 CPU core if not set, but cap at max available cores
      final savedCores = prefs.getInt('cpu_cores') ?? 1;
      final maxCores = getMaxCpuCores();
      final actualCores = savedCores > maxCores ? maxCores : savedCores;
      
      return NodeSettings(
        host: prefs.getString('node_host') ?? 'localhost',
        port: prefs.getInt('node_port') ?? 8332,
        username: prefs.getString('node_username') ?? '',
        password: prefs.getString('node_password') ?? '',
        useSSL: prefs.getBool('node_use_ssl') ?? false,
        defaultTicketOwner: prefs.getString('default_ticket_owner') ?? '',
        cpuCores: actualCores,
      );
    } catch (e) {
      // Return default settings if there's an error
      print('Error loading settings: $e');
      return NodeSettings();
    }
  }

  String get connectionString {
    final protocol = useSSL ? 'https' : 'http';
    final auth = username.isNotEmpty ? '$username:$password@' : '';
    return '$protocol://$auth$host:$port';
  }
}
