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
  bool autoStartJobs; // Whether to automatically start mining jobs when the app opens

  NodeSettings({
    this.host = 'rpc.kbunet.net',
    this.port = 443,
    this.username = '',
    this.password = '',
    this.useSSL = true,
    this.defaultTicketOwner = '',
    this.cpuCores = 1,
    this.autoStartJobs = false, // Default to not auto-starting jobs
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
        prefs.setBool('auto_start_jobs', autoStartJobs),
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
        host: prefs.getString('node_host') ?? 'rpc.kbunet.net',
        port: prefs.getInt('node_port') ?? 443,
        username: prefs.getString('node_username') ?? '',
        password: prefs.getString('node_password') ?? '',
        useSSL: prefs.getBool('node_use_ssl') ?? true,
        defaultTicketOwner: prefs.getString('default_ticket_owner') ?? '',
        cpuCores: actualCores,
        autoStartJobs: prefs.getBool('auto_start_jobs') ?? false, // Default to not auto-starting jobs
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
