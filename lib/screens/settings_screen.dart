import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/node_settings.dart';
import '../services/identity_service.dart';
import '../services/mining_service.dart';
import 'identity_screen.dart';

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
  bool _obscureAuthPassword = true;
  
  // Security settings
  final IdentityService _identityService = IdentityService();
  bool _isAuthEnabled = false;
  bool _isBiometricAvailable = false;
  String _authMethod = 'biometric';
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadSecuritySettings();
  }
  
  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    _settings = await NodeSettings.load();
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }
  
  Future<void> _loadSecuritySettings() async {
    final isBiometricAvailable = await _identityService.isBiometricAvailable();
    final isAuthEnabled = await _identityService.isAuthenticationEnabled();
    final authMethod = await _identityService.getAuthMethod();
    
    if (mounted) {
      setState(() {
        _isBiometricAvailable = isBiometricAvailable;
        _isAuthEnabled = isAuthEnabled;
        _authMethod = authMethod;
      });
    }
  }

  Future<void> _saveSettings(BuildContext context) async {
    if (_formKey.currentState?.validate() ?? false) {
      _formKey.currentState?.save();
      await _settings.save();
      
      // Update mining service with new CPU cores setting
      // This ensures the change takes effect immediately without app restart
      final miningService = MiningService(); // Using the singleton instance
      await miningService.updateCpuCores(_settings.cpuCores);
      
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
            onPressed: () => _saveSettings(context),
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
                'Kbunet Node Connection',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Host',
                  helperText: 'e.g., localhost or rpc.kbunet.net',
                  border: OutlineInputBorder(),
                ),
                initialValue: _settings.host,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter host';
                  }
                  return null;
                },
                onSaved: (value) => _settings.host = value ?? 'rpc.kbunet.net',
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Port',
                  helperText: 'Default: 443',
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
                onSaved: (value) => _settings.port = int.tryParse(value ?? '') ?? 443,
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
                    _settings.useSSL = value ?? true;
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
              ListTile(
                leading: const Icon(Icons.people),
                title: const Text('Identity Management'),
                subtitle: const Text('Create and manage Kbunet identities for mining rewards'),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const IdentityScreen()),
                  );
                },
                tileColor: Colors.blue.withOpacity(0.05),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: Colors.blue.withOpacity(0.3)),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
              const SizedBox(height: 24),
              const Text(
                'Security Settings',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Card(
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.blue.withOpacity(0.2)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                        title: const Text('Enable Authentication'),
                        subtitle: const Text('Protect your identities with authentication'),
                        value: _isAuthEnabled,
                        onChanged: (value) async {
                          if (!value) {
                            // Disabling authentication requires confirmation
                            if (await _showAuthConfirmationDialog()) {
                              setState(() {
                                _isAuthEnabled = value;
                              });
                              await _identityService.setAuthenticationEnabled(value);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Authentication disabled')),
                              );
                            }
                          } else {
                            // Enabling authentication
                            bool canEnable = true;
                            
                            if (_authMethod == 'biometric') {
                              // First check if biometrics are available on the device
                              final isBiometricAvailable = await _identityService.isBiometricAvailable();
                              if (!isBiometricAvailable) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Biometric authentication is not available on this device. Please use password authentication instead.'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                                canEnable = false;
                              } else {
                                // Show a dialog explaining what will happen
                                final shouldContinue = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Biometric Authentication'),
                                    content: const Text('You will be prompted to authenticate with your fingerprint. This is to verify that biometric authentication works on your device.'),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.of(context).pop(false),
                                        child: const Text('Cancel'),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.of(context).pop(true),
                                        child: const Text('Continue'),
                                      ),
                                    ],
                                  ),
                                ) ?? false;
                                
                                if (shouldContinue) {
                                  // Test biometric authentication
                                  canEnable = await _identityService.authenticate();
                                  if (!canEnable) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Biometric authentication failed. Please try again or use password authentication.'),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                  }
                                } else {
                                  canEnable = false;
                                }
                              }
                            } else if (_authMethod == 'password' && !await _identityService.hasPasswordSet()) {
                              // If password is selected but not set, prompt to set it
                              canEnable = await _showSetPasswordDialog();
                              if (!canEnable) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('You must set a password to enable password authentication'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }
                            
                            if (canEnable) {
                              setState(() {
                                _isAuthEnabled = value;
                              });
                              await _identityService.setAuthenticationEnabled(value);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Authentication enabled')),
                              );
                            }
                          }
                        },
                      ),
                      // Authentication method selection
                      const Divider(),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                        child: Text(
                          'Authentication Method',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      
                      // Fingerprint authentication option
                      Card(
                        margin: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.fingerprint, size: 24),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Flexible(
                                              child: Text(
                                                'Fingerprint Authentication',
                                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (_isAuthEnabled && _authMethod == 'biometric')
                                              const Padding(
                                                padding: EdgeInsets.only(left: 8.0),
                                                child: Icon(Icons.check_circle, color: Colors.green, size: 16),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        _isBiometricAvailable 
                                          ? const Text('Use fingerprint to access identities')
                                          : const Text('Fingerprint not available on this device', 
                                              style: TextStyle(color: Colors.red)),
                                      ],
                                    ),
                                  ),
                                  Switch(
                                    value: _isAuthEnabled && _authMethod == 'biometric',
                                    activeColor: Colors.blue,
                                    onChanged: _isBiometricAvailable ? (bool value) async {
                                      if (value) {
                                        // Show confirmation dialog before enabling biometric auth
                                        final confirmed = await showDialog<bool>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: const Text('Enable Fingerprint Authentication'),
                                            content: const Text(
                                              'You will be prompted to verify your fingerprint. ' 
                                              'This will be required to access your identities.'),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.of(context).pop(false),
                                                child: const Text('CANCEL'),
                                              ),
                                              TextButton(
                                                onPressed: () => Navigator.of(context).pop(true),
                                                child: const Text('CONTINUE'),
                                              ),
                                            ],
                                          ),
                                        ) ?? false;
                                        
                                        if (!confirmed) {
                                          // If user cancels, revert the switch
                                          setState(() {});
                                          return;
                                        }
                                        
                                        // Show a message to prepare the user
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('Prepare to scan your fingerprint...')),
                                          );
                                        }
                                        
                                        // Wait a moment before triggering the fingerprint scanner
                                        await Future.delayed(const Duration(seconds: 1));
                                        
                                        // Test biometric authentication before enabling it
                                        final success = await _identityService.testBiometricAuth();
                                        if (success) {
                                          await _identityService.setAuthMethod('biometric');
                                          await _identityService.setAuthenticationEnabled(true);
                                          setState(() {
                                            _isAuthEnabled = true;
                                            _authMethod = 'biometric';
                                          });
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('Fingerprint authentication enabled')),
                                            );
                                          }
                                        } else {
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(
                                                content: Text('Fingerprint authentication failed - please try again'),
                                                backgroundColor: Colors.red,
                                              ),
                                            );
                                          }
                                          // If authentication fails, revert the switch
                                          setState(() {});
                                        }
                                      } else if (_isAuthEnabled) {
                                        // Disable authentication
                                        final confirmed = await _showAuthConfirmationDialog();
                                        if (confirmed) {
                                          await _identityService.setAuthenticationEnabled(false);
                                          setState(() {
                                            _isAuthEnabled = false;
                                          });
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('Authentication disabled')),
                                            );
                                          }
                                        } else {
                                          // If user cancels, revert the switch
                                          setState(() {});
                                        }
                                      }
                                    } : null,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Password authentication option
                      Card(
                        margin: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.password, size: 24),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Flexible(
                                              child: Text(
                                                'Password Authentication',
                                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (_isAuthEnabled && _authMethod == 'password')
                                              const Padding(
                                                padding: EdgeInsets.only(left: 8.0),
                                                child: Icon(Icons.check_circle, color: Colors.green, size: 16),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        const Text('Use a password to protect your identities'),
                                      ],
                                    ),
                                  ),
                                  Switch(
                                    value: _isAuthEnabled && _authMethod == 'password',
                                    activeColor: Colors.blue,
                                    onChanged: (bool value) async {
                                      if (value) {
                                        bool hasPassword = await _identityService.hasPasswordSet();
                                        bool success = hasPassword;
                                        
                                        if (!hasPassword) {
                                          // Show set password dialog if no password is set
                                          success = await _showSetPasswordDialog();
                                        }
                                        
                                        if (success) {
                                          await _identityService.setAuthMethod('password');
                                          await _identityService.setAuthenticationEnabled(true);
                                          setState(() {
                                            _isAuthEnabled = true;
                                            _authMethod = 'password';
                                          });
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('Password authentication enabled')),
                                            );
                                          }
                                        } else {
                                          // If setting password fails, revert the switch
                                          setState(() {});
                                        }
                                      } else if (_isAuthEnabled) {
                                        // Disable authentication
                                        final confirmed = await _showAuthConfirmationDialog();
                                        if (confirmed) {
                                          await _identityService.setAuthenticationEnabled(false);
                                          setState(() {
                                            _isAuthEnabled = false;
                                          });
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('Authentication disabled')),
                                            );
                                          }
                                        } else {
                                          // If user cancels, revert the switch
                                          setState(() {});
                                        }
                                      }
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      
                      // Change password button (only shown when password auth is enabled)
                      if (_authMethod == 'password' && _isAuthEnabled)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              // First verify current password
                              final passwordVerified = await showDialog<bool>(
                                context: context,
                                builder: (context) {
                                  final passwordController = TextEditingController();
                                  bool obscurePassword = true;
                                  
                                  return StatefulBuilder(
                                    builder: (context, setState) {
                                      return AlertDialog(
                                        title: const Text('Verify Current Password'),
                                        content: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Text('Please enter your current password to continue'),
                                            const SizedBox(height: 16),
                                            TextField(
                                              controller: passwordController,
                                              obscureText: obscurePassword,
                                              decoration: InputDecoration(
                                                labelText: 'Current Password',
                                                border: const OutlineInputBorder(),
                                                suffixIcon: IconButton(
                                                  icon: Icon(obscurePassword ? Icons.visibility : Icons.visibility_off),
                                                  onPressed: () {
                                                    setState(() {
                                                      obscurePassword = !obscurePassword;
                                                    });
                                                  },
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.of(context).pop(false),
                                            child: const Text('CANCEL'),
                                          ),
                                          TextButton(
                                            onPressed: () async {
                                              final verified = await _identityService.verifyPassword(passwordController.text);
                                              if (verified) {
                                                Navigator.of(context).pop(true);
                                              } else {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  const SnackBar(
                                                    content: Text('Incorrect password'),
                                                    backgroundColor: Colors.red,
                                                  ),
                                                );
                                              }
                                            },
                                            child: const Text('VERIFY'),
                                          ),
                                        ],
                                      );
                                    },
                                  );
                                },
                              ) ?? false;
                              
                              // Only show the set password dialog if current password was verified
                              if (passwordVerified) {
                                await _showSetPasswordDialog();
                              }
                            },
                            icon: const Icon(Icons.password),
                            label: const Text('Change Password'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.grey.shade200,
                              foregroundColor: Colors.black87,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              
              const SizedBox(height: 24),
              const Text(
                'Application Behavior',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('Auto-start Mining Jobs'),
                subtitle: const Text('Automatically resume mining jobs when the app opens'),
                value: _settings.autoStartJobs,
                onChanged: (value) {
                  setState(() {
                    _settings.autoStartJobs = value;
                  });
                },
              ),

            ],
          ),
        ),
      ),
    );
  }
  
  Future<bool> _showAuthConfirmationDialog() async {
    if (!_isAuthEnabled) return true; // No need to confirm when enabling
    
    // When disabling, we need to verify the user is authorized
    final authMethod = await _identityService.getAuthMethod();
    if (authMethod == 'biometric') {
      return await _identityService.authenticate();
    } else {
      // Show password verification dialog
      return await showDialog<bool>(context: context, builder: (context) {
        final passwordController = TextEditingController();
        bool obscurePassword = true;
        
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Verify Password'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Enter your password to disable authentication'),
                  const SizedBox(height: 16),
                  TextField(
                    controller: passwordController,
                    obscureText: obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(obscurePassword ? Icons.visibility : Icons.visibility_off),
                        onPressed: () {
                          setState(() {
                            obscurePassword = !obscurePassword;
                          });
                        },
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    final verified = await _identityService.verifyPassword(passwordController.text);
                    if (verified) {
                      Navigator.of(context).pop(true);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Incorrect password')),
                      );
                    }
                  },
                  child: const Text('Verify'),
                ),
              ],
            );
          },
        );
      }) ?? false;
    }
  }
  
  Future<bool> _showSetPasswordDialog() async {
    _passwordController.clear();
    _confirmPasswordController.clear();
    
    return await showDialog<bool>(context: context, builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Set Password'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Create a password to protect your identities'),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscureAuthPassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscureAuthPassword ? Icons.visibility : Icons.visibility_off),
                      onPressed: () {
                        setState(() {
                          _obscureAuthPassword = !_obscureAuthPassword;
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _confirmPasswordController,
                  obscureText: _obscureAuthPassword,
                  decoration: InputDecoration(
                    labelText: 'Confirm Password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_obscureAuthPassword ? Icons.visibility : Icons.visibility_off),
                      onPressed: () {
                        setState(() {
                          _obscureAuthPassword = !_obscureAuthPassword;
                        });
                      },
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  if (_passwordController.text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Password cannot be empty')),
                    );
                    return;
                  }
                  
                  if (_passwordController.text != _confirmPasswordController.text) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Passwords do not match')),
                    );
                    return;
                  }
                  
                  final success = await _identityService.setPassword(_passwordController.text);
                  if (success) {
                    Navigator.of(context).pop(true);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Failed to set password')),
                    );
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    }) ?? false;
  }
}
