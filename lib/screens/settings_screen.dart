import 'package:flutter/material.dart';
import '../models/node_settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late NodeSettings _settings;
  bool _isLoading = true;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _settings = await NodeSettings.load();
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _saveSettings() async {
    if (_formKey.currentState?.validate() ?? false) {
      _formKey.currentState?.save();
      await _settings.save();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved successfully')),
        );
      }
    }
  }

  String _getConnectionPreview() {
    if (!mounted) return '';
    final protocol = _settings.useSSL ? 'https' : 'http';
    final auth = _settings.username.isNotEmpty ? '${_settings.username}:${_settings.password}@' : '';
    return '$protocol://$auth${_settings.host}:${_settings.port}';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Node Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveSettings,
            tooltip: 'Save Settings',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Bitcoin Node Connection',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Host',
                  helperText: 'e.g., localhost or node.example.com',
                  border: OutlineInputBorder(),
                ),
                initialValue: _settings.host,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter host';
                  }
                  return null;
                },
                onSaved: (value) => _settings.host = value ?? 'localhost',
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Port',
                  helperText: 'Default: 8332',
                  border: OutlineInputBorder(),
                ),
                initialValue: _settings.port.toString(),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter port';
                  }
                  final port = int.tryParse(value);
                  if (port == null || port <= 0 || port > 65535) {
                    return 'Please enter a valid port number (1-65535)';
                  }
                  return null;
                },
                onSaved: (value) => _settings.port = int.tryParse(value ?? '') ?? 8332,
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Username (Optional)',
                  helperText: 'RPC username if authentication is required',
                  border: OutlineInputBorder(),
                ),
                initialValue: _settings.username,
                onSaved: (value) => _settings.username = value ?? '',
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: InputDecoration(
                  labelText: 'Password (Optional)',
                  helperText: 'RPC password if authentication is required',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                    },
                  ),
                ),
                initialValue: _settings.password,
                obscureText: _obscurePassword,
                onSaved: (value) => _settings.password = value ?? '',
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('Use SSL'),
                subtitle: const Text('Enable for HTTPS connection'),
                value: _settings.useSSL,
                onChanged: (value) {
                  setState(() {
                    _settings.useSSL = value;
                  });
                },
              ),
              const SizedBox(height: 24),
              const Text(
                'Connection Preview',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _getConnectionPreview(),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Mining Settings',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Default Ticket Owner',
                  helperText: 'Default owner address for new mining tickets',
                  border: OutlineInputBorder(),
                ),
                initialValue: _settings.defaultTicketOwner,
                onSaved: (value) => _settings.defaultTicketOwner = value ?? '',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'CPU Cores for Mining: ${_settings.cpuCores}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Text('Max: ${NodeSettings.getMaxCpuCores()}'),
                ],
              ),
              Slider(
                value: _settings.cpuCores.toDouble(),
                min: 1,
                max: NodeSettings.getMaxCpuCores().toDouble(),
                divisions: NodeSettings.getMaxCpuCores() - 1,
                label: _settings.cpuCores.toString(),
                onChanged: (value) {
                  setState(() {
                    _settings.cpuCores = value.round();
                  });
                },
              ),
              const SizedBox(height: 8),
              const Text(
                'Higher values use more CPU resources but may increase mining speed.',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
