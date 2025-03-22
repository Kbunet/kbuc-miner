import 'package:flutter/material.dart';
import '../services/node_service.dart';
import '../models/node_settings.dart';

class CreateMiningJobDialog extends StatefulWidget {
  final Function(
    String content,
    String leader,
    String owner,
    int height,
    String rewardType,
    int difficulty,
    int startNonce,
    int endNonce,
  )? onSubmit;

  const CreateMiningJobDialog({Key? key, this.onSubmit}) : super(key: key);

  @override
  State<CreateMiningJobDialog> createState() => _CreateMiningJobDialogState();
}

class _CreateMiningJobDialogState extends State<CreateMiningJobDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nodeService = NodeService();
  bool _isLoading = false;

  final _supportedHashController = TextEditingController(text: '0x' + '0' * 64);
  final _leaderController = TextEditingController();
  final _heightController = TextEditingController();
  final _jobOwnerController = TextEditingController();
  final _difficultyController = TextEditingController(text: '4');
  final _startNonceController = TextEditingController();
  final _endNonceController = TextEditingController();
  String _rewardType = '0'; // Initialize as string '0' for Reputation Points

  @override
  void initState() {
    super.initState();
    _loadDefaultOwner();
  }

  Future<void> _loadDefaultOwner() async {
    final settings = await NodeSettings.load();
    if (settings.defaultTicketOwner.isNotEmpty && mounted) {
      setState(() {
        _jobOwnerController.text = settings.defaultTicketOwner;
      });
    }
  }

  Future<void> _fetchLeaderInfo() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final result = await _nodeService.getSupportableLeader();
      setState(() {
        _leaderController.text = result['leader'] as String;
        _heightController.text = (result['height'] as int).toString();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error fetching leader: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Create Mining Job',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _supportedHashController,
                decoration: const InputDecoration(
                  labelText: 'Supported Hash',
                  helperText: '64-character hex string with 0x prefix',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter supported hash';
                  }
                  if (!value.startsWith('0x')) {
                    return 'Hash must start with 0x';
                  }
                  if (value.length != 66) { // 64 chars + '0x'
                    return 'Hash must be 64 characters long (excluding 0x)';
                  }
                  if (!RegExp(r'^0x[0-9a-fA-F]{64}$').hasMatch(value)) {
                    return 'Invalid hex string';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _leaderController,
                      decoration: const InputDecoration(
                        labelText: 'Leader',
                        helperText: 'Hex string',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter leader';
                        }
                        if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
                          return 'Invalid hex string';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _isLoading ? null : _fetchLeaderInfo,
                    icon: _isLoading 
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                    label: const Text('Fetch'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _heightController,
                decoration: const InputDecoration(
                  labelText: 'Block Height',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter block height';
                  }
                  if (int.tryParse(value) == null) {
                    return 'Please enter a valid number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _jobOwnerController,
                decoration: const InputDecoration(
                  labelText: 'Job Owner',
                  helperText: 'Hex string',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter job owner';
                  }
                  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(value)) {
                    return 'Invalid hex string';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _rewardType,
                decoration: const InputDecoration(
                  labelText: 'Reward Type',
                  border: OutlineInputBorder(),
                  helperText: "'0' for Reputation Points, '1' for Coins",
                ),
                items: const [
                  DropdownMenuItem(
                    value: '0',
                    child: Text('Reputation Points'),
                  ),
                  DropdownMenuItem(
                    value: '1',
                    child: Text('Coins'),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    _rewardType = value!;
                  });
                },
                validator: (value) {
                  if (value == null) {
                    return 'Please select a reward type';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _difficultyController,
                decoration: const InputDecoration(
                  labelText: 'Difficulty (0-8)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter difficulty';
                  }
                  final difficulty = int.tryParse(value);
                  if (difficulty == null || difficulty < 0 || difficulty > 8) {
                    return 'Difficulty must be between 0 and 8';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _startNonceController,
                      decoration: const InputDecoration(
                        labelText: 'Start Nonce (Optional)',
                        helperText: 'Defaults to 0 if empty',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return null; // Optional field
                        }
                        final nonce = int.tryParse(value);
                        if (nonce == null || nonce < 0) {
                          return 'Please enter a valid positive number';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextFormField(
                      controller: _endNonceController,
                      decoration: const InputDecoration(
                        labelText: 'End Nonce (Optional)',
                        helperText: 'Mine until found if empty',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return null; // Optional field
                        }
                        final endNonce = int.tryParse(value);
                        if (endNonce == null || endNonce < 0) {
                          return 'Please enter a valid positive number';
                        }
                        final startNonceText = _startNonceController.text;
                        if (startNonceText.isNotEmpty) {
                          final startNonce = int.tryParse(startNonceText);
                          if (startNonce != null && endNonce <= startNonce) {
                            return 'Must be greater than start nonce';
                          }
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      if (_formKey.currentState?.validate() ?? false) {
                        final startNonceText = _startNonceController.text;
                        final endNonceText = _endNonceController.text;
                        
                        final startNonce = startNonceText.isEmpty ? 0 : int.parse(startNonceText);
                        final endNonce = endNonceText.isEmpty ? 0x7FFFFFFF : int.parse(endNonceText);
                        
                        if (widget.onSubmit != null) {
                          widget.onSubmit!(
                            _supportedHashController.text,
                            _leaderController.text,
                            _jobOwnerController.text,
                            int.parse(_heightController.text),
                            _rewardType, // Passing as string '0' or '1' per memory requirement
                            int.parse(_difficultyController.text),
                            startNonce,
                            endNonce,
                          );
                        } else {
                          // Fallback to old behavior for backward compatibility
                          Navigator.of(context).pop({
                            'supportedHash': _supportedHashController.text,
                            'leader': _leaderController.text,
                            'height': int.parse(_heightController.text),
                            'jobOwner': _jobOwnerController.text,
                            'rewardType': _rewardType, // Passing as string '0' or '1' per memory requirement
                            'difficulty': int.parse(_difficultyController.text),
                            'nonceRange': [
                              startNonce,
                              endNonce,
                            ],
                          });
                        }
                        
                        Navigator.of(context).pop();
                      }
                    },
                    child: const Text('Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _supportedHashController.dispose();
    _leaderController.dispose();
    _heightController.dispose();
    _jobOwnerController.dispose();
    _difficultyController.dispose();
    _startNonceController.dispose();
    _endNonceController.dispose();
    super.dispose();
  }
}
