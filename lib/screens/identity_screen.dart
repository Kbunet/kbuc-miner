import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:bs58/bs58.dart' as bs58;
import 'package:convert/convert.dart';
import '../models/identity.dart';
import '../services/identity_service.dart';
import '../services/profile_service.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import 'package:file_saver/file_saver.dart';
import 'package:file_picker/file_picker.dart';

class IdentityScreen extends StatefulWidget {
  const IdentityScreen({Key? key}) : super(key: key);

  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  final ProfileService _profileService = ProfileService();
  final TextEditingController _passwordController = TextEditingController();
  
  // Helper method to get the appropriate color based on durability value
  Color _getDurabilityColor(double durability) {
    if (durability >= 0.7) {
      return Colors.green.shade700; // High durability
    } else if (durability >= 0.4) {
      return Colors.orange.shade700; // Medium durability
    } else {
      return Colors.red.shade700; // Low durability
    }
  }
  // Helper method to convert hex private key to WIF format if needed
  String? _getWIFPrivateKey(Identity identity) {
    final privateKey = identity.privateKey;
    if (privateKey == null) return null;
    
    // If it's already in WIF format for SegWit (starts with K, L) or legacy (starts with 5)
    // SegWit (P2WPKH) keys typically start with K or L, while legacy P2PKH start with 5
    if ((privateKey.startsWith('K') || privateKey.startsWith('L') || privateKey.startsWith('5')) && 
        privateKey.length >= 50 && privateKey.length <= 52) {
      return privateKey; // Already in WIF format
    }
    
    // Convert from hex to WIF
    try {
      // Convert hex to bytes
      // Convert hex to bytes
      final List<int> bytes = [];
      for (int i = 0; i < privateKey.length; i += 2) {
        bytes.add(int.parse(privateKey.substring(i, i + 2), radix: 16));
      }
      final privateKeyBytes = Uint8List.fromList(bytes);
      
      // Add version byte and compression flag for SegWit (P2WPKH)
      // 0x80 is the version byte for mainnet
      // 0x01 at the end indicates compressed public key for SegWit
      final extendedKey = Uint8List(privateKeyBytes.length + 2);
      extendedKey[0] = 0x80; // Mainnet private key prefix
      for (var i = 0; i < privateKeyBytes.length; i++) {
        extendedKey[i + 1] = privateKeyBytes[i];
      }
      extendedKey[privateKeyBytes.length + 1] = 0x01; // Compression flag for SegWit
      
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
    } catch (e) {
      debugPrint('Error converting to WIF: $e');
      return privateKey; // Return original if conversion fails
    }
  }
  final IdentityService _identityService = IdentityService();
  List<Identity> _identities = [];
  bool _isLoading = true;
  bool _isAuthEnabled = false;
  bool _isBiometricAvailable = false;
  bool _isAuthenticating = false;
  String _authMethod = 'biometric';

  @override
  void initState() {
    super.initState();
    _checkAuthSettings();
    _loadIdentities();
  }
  
  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _checkAuthSettings() async {
    final isBiometricAvailable = await _identityService.isBiometricAvailable();
    final isAuthEnabled = await _identityService.isAuthenticationEnabled();
    final authMethod = await _identityService.getAuthMethod();
    
    setState(() {
      _isBiometricAvailable = isBiometricAvailable;
      _isAuthEnabled = isAuthEnabled;
      _authMethod = authMethod;
    });
  }

  // Authenticate the user explicitly
  Future<bool> _authenticateUser() async {
    setState(() {
      _isAuthenticating = true;
    });
    
    try {
      final authMethod = await _identityService.getAuthMethod();
      debugPrint('Authentication method: $authMethod');
      
      if (authMethod == 'biometric') {
        // Show a message to prepare the user for fingerprint scan
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Prepare to scan your fingerprint...')),
          );
        }
        
        // Wait a moment before triggering the fingerprint scanner
        await Future.delayed(const Duration(seconds: 1));
        
        // Use biometric authentication
        debugPrint('Attempting biometric authentication...');
        final authenticated = await _identityService.authenticate();
        debugPrint('Biometric authentication result: $authenticated');
        
        if (!mounted) return false;
        
        setState(() {
          _isAuthenticating = false;
        });
        
        if (authenticated && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Biometric authentication successful'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );
        } else if (!authenticated && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Biometric authentication failed. Please try again.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
        
        return authenticated;
      } else {
        // Use password authentication
        debugPrint('Attempting password authentication...');
        final authenticated = await _showPasswordDialog();
        debugPrint('Password authentication result: $authenticated');
        
        if (!mounted) return false;
        
        setState(() {
          _isAuthenticating = false;
        });
        
        if (authenticated) {
          // If password verification was successful, load identities directly
          // using the special method that bypasses authentication checks
          debugPrint('Password verified, loading identities directly');
          final identities = await _identityService.getIdentitiesAfterPasswordVerification();
          debugPrint('Loaded ${identities.length} identities after password verification');
          
          if (mounted) {
            setState(() {
              _identities = identities;
            });
            
            // Show success message
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Password verified successfully'),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 2),
              ),
            );
          }
        } else if (!authenticated && mounted) {
          // If password verification failed, show error message
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Incorrect password'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
        
        return authenticated;
      }
    } catch (e) {
      debugPrint('Authentication error: $e');
      if (!mounted) return false;
      
      setState(() {
        _isAuthenticating = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Authentication error: $e')),
      );
      
      return false;
    }
  }
  
  Future<bool> _showPasswordDialog() async {
    _passwordController.clear();
    
    return await showDialog<bool>(context: context, builder: (context) {
      bool obscurePassword = true;
      
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Authentication Required'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Enter your password to access your identities'),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
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
                  onSubmitted: (_) async {
                    final verified = await _identityService.verifyPassword(_passwordController.text);
                    Navigator.of(context).pop(verified);
                  },
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
                  final verified = await _identityService.verifyPassword(_passwordController.text);
                  Navigator.of(context).pop(verified);
                },
                child: const Text('Verify'),
              ),
            ],
          );
        },
      );
    }) ?? false;
  }

  Future<void> _loadIdentities() async {
    setState(() {
      _isLoading = true;
    });
    
    try {
      // Check if authentication is required
      final isAuthEnabled = await _identityService.isAuthenticationEnabled();
      final authMethod = await _identityService.getAuthMethod();
      
      debugPrint('Loading identities - Auth enabled: $isAuthEnabled, Auth method: $authMethod');
      
      // Get identities from the service
      final identities = await _identityService.getIdentities();
      debugPrint('Initial identities load returned ${identities.length} identities');
      
      // If authentication is required and identities list is empty
      if (identities.isEmpty && isAuthEnabled) {
        debugPrint('No identities loaded and auth is enabled - handling authentication');
        
        // If using password auth and we haven't authenticated yet, try to authenticate
        if (authMethod == 'password' && !_isAuthenticating) {
          debugPrint('Using password auth - showing password dialog');
          
          setState(() {
            _isLoading = false;
            _identities = [];
          });
          
          // Show password dialog and try to authenticate
          final authenticated = await _authenticateUser();
          debugPrint('Password authentication result: $authenticated');
          
          // Note: We don't need to reload identities here because _authenticateUser
          // already loads identities on successful authentication
          return;
        } else {
          // For biometric auth or if we're already authenticating, just show the auth UI
          debugPrint('Using biometric auth or already authenticating - showing auth UI');
          
          setState(() {
            _isLoading = false;
            _identities = [];
          });
          return;
        }
      }
      
      debugPrint('Setting identities in state: ${identities.length} items');
      setState(() {
        _identities = identities;
        _isLoading = false;
      });
      
      // We no longer load profile info automatically
      // Profile info will be loaded on demand when the user requests it
    } catch (e) {
      debugPrint('Error loading identities: $e');
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading identities: $e')),
        );
      }
    }
  }

  Future<void> _loadProfileInfo(Identity identity) async {
    // Skip if already loading or already loaded
    if (identity.isLoadingProfileInfo) return;
    
    // Set loading state
    setState(() {
      final index = _identities.indexWhere((i) => i.id == identity.id);
      if (index != -1) {
        _identities[index] = _identities[index].copyWith(
          isLoadingProfileInfo: true,
        );
      }
    });
    
    try {
      // Show loading indicator in a snackbar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Fetching profile info for ${identity.name}...'),
          duration: Duration(seconds: 1),
        ),
      );
      
      // Make sure we're using the correct format for the profile ID
      // For imported identities, the address is already in the correct format
      // For generated identities, we need to ensure it's in the correct format
      final profileId = identity.address;
      
      // Fetch profile info
      debugPrint('🔍 Fetching profile info using ID: $profileId');
      final profileInfo = await _profileService.getProfileInfo(profileId);
      
      // Calculate NFT slots
      final nftSlots = _profileService.calculateNftSlots(
        profileInfo.rps, 
        profileInfo.generatedRPs, 
        profileInfo.ownedProfilesNo
      );
      
      // Get current blockchain stats to calculate durability
      final blockchainStats = await _profileService.getBlockchainStats();
      final currentBlockHeight = blockchainStats.currentHeight;
      
      // Calculate durability based on height difference
      final heightDifference = currentBlockHeight - profileInfo.height;
      final durability = heightDifference <= 0 ? 1.0 : (1.0 - (heightDifference / 10000.0)).clamp(0.0, 1.0);
      
      debugPrint('📊 Profile info received for ${identity.name}:');
      debugPrint('  RPS: ${profileInfo.rps}');
      debugPrint('  Balance: ${profileInfo.balance}');
      debugPrint('  Height: ${profileInfo.height}');
      debugPrint('  Current Blockchain Height: $currentBlockHeight');
      debugPrint('  Height Difference: $heightDifference');
      debugPrint('  Calculated Durability: ${(durability * 100).toStringAsFixed(1)}%');
      debugPrint('  Generated RPs: ${profileInfo.generatedRPs}');
      debugPrint('  Owned Profiles: ${profileInfo.ownedProfilesNo}');
      debugPrint('  NFT Slots: $nftSlots');
      debugPrint('  Owner ID: ${profileInfo.ownerId}');
      debugPrint('  Is Domain: ${profileInfo.isDomain}');
      
      // Update the identity with profile information
      if (mounted) {
        setState(() {
          final index = _identities.indexWhere((i) => i.id == identity.id);
          if (index != -1) {
            debugPrint('📝 Updating identity at index $index with new profile info');
            _identities[index] = _identities[index].copyWith(
              rps: profileInfo.rps,
              balance: profileInfo.balance,
              height: profileInfo.height,
              generatedRPs: profileInfo.generatedRPs,
              ownedProfilesNo: profileInfo.ownedProfilesNo,
              nftSlots: nftSlots,
              durability: durability,
              currentBlockHeight: currentBlockHeight,
              hasLoadedProfileInfo: true,
              isLoadingProfileInfo: false,
              ownerId: profileInfo.ownerId,
              isDomain: profileInfo.isDomain,
            );
            
            // Debug the updated identity
            debugPrint('✅ Updated identity with all profile info');
          } else {
            debugPrint('❌ Identity not found in list with id=${identity.id}');
          }
        });
        
        // Save updated identities to storage
        await _identityService.saveIdentities(_identities);
      }
    } catch (e) {
      if (mounted) {
        // Reset loading state
        setState(() {
          final index = _identities.indexWhere((i) => i.id == identity.id);
          if (index != -1) {
            _identities[index] = _identities[index].copyWith(
              isLoadingProfileInfo: false,
            );
          }
        });
        
        // Show error message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading profile info: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      debugPrint('Error loading profile info for ${identity.address}: $e');
    }
  }

  Future<void> _showAddIdentityDialog() async {
    final nameController = TextEditingController();
    
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Create New Identity'),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'Identity Name',
              hintText: 'Enter a name for this identity',
            ),
            autofocus: true,
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => _showImportIdentityDialog(),
              child: const Text('Import Instead'),
            ),
            TextButton(
              onPressed: () async {
                if (nameController.text.isNotEmpty) {
                  Navigator.of(context).pop();
                  
                  // Show loading indicator
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Generating new identity...'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                  
                  try {
                    await _identityService.addIdentity(nameController.text);
                    await _loadIdentities();
                    
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Identity created successfully'),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error creating identity: $e'),
                        ),
                      );
                    }
                  }
                }
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
  }
  
  Future<void> _showImportIdentityDialog() async {
    final nameController = TextEditingController();
    final addressController = TextEditingController();
    
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Import Existing Identity'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Identity Name',
                    hintText: 'Enter a name for this identity',
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: addressController,
                  decoration: const InputDecoration(
                    labelText: 'Profile ID',
                    hintText: 'Enter the profile ID (hex format)',
                    helperText: 'Accepts various formats including compressed public keys',
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Note: This will only store the address. The private key remains in your external wallet.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                if (nameController.text.isNotEmpty && addressController.text.isNotEmpty) {
                  Navigator.of(context).pop();
                  
                  try {
                    await _identityService.importIdentity(
                      nameController.text, 
                      addressController.text
                    );
                    await _loadIdentities();
                    
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Identity imported successfully'),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error importing identity: $e'),
                        ),
                      );
                    }
                  }
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please fill in all fields'),
                    ),
                  );
                }
              },
              child: const Text('Import'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showEditIdentityNameDialog(Identity identity) async {
    final nameController = TextEditingController(text: identity.name);
    
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Edit Identity Name'),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'Identity Name',
              hintText: 'Enter a new name for this identity',
            ),
            autofocus: true,
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                if (nameController.text.isNotEmpty) {
                  Navigator.of(context).pop();
                  
                  try {
                    await _identityService.updateIdentityName(
                      identity.id, 
                      nameController.text
                    );
                    await _loadIdentities();
                    
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Identity name updated successfully'),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error updating identity name: $e'),
                        ),
                      );
                    }
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }
  
  Future<void> _showAddressDialog(Identity identity) async {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        'Imported Identity: ${identity.name}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                    ),
                  ],
                ),
                const Divider(),
                const Text(
                  'This is an imported identity. Only the Profile ID is stored in this app. '
                  'The private key is managed by your external wallet.',
                  style: TextStyle(
                    color: Colors.blue,
                    fontWeight: FontWeight.normal,
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Profile ID:'),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          identity.address,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: identity.address));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Address copied to clipboard'),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text('QR Code:'),
                const SizedBox(height: 8),
                Center(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(8.0),
                    child: QrImageView(
                      data: identity.address,
                      version: QrVersions.auto,
                      size: 200,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showExportDialog(Identity identity) async {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'Export Identity: ${identity.name}',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      ),
                    ],
                  ),
                  const Divider(),
                  const Text(
                    'WARNING: Your private key is sensitive information. '
                    'Never share it with anyone you do not trust completely.',
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Private Key (WIF format):'),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _getWIFPrivateKey(identity) ?? '',
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _getWIFPrivateKey(identity) ?? ''));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Private key copied to clipboard'),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('QR Code:'),
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(8.0),
                      child: QrImageView(
                        data: _getWIFPrivateKey(identity) ?? '',
                        version: QrVersions.auto,
                        size: 200,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Profile ID:'),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            identity.address,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: identity.address));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Address copied to clipboard'),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmDeleteIdentity(Identity identity) async {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete Identity'),
          content: Text(
            'Are you sure you want to delete "${identity.name}"? '
            'This action cannot be undone.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                try {
                  await _identityService.deleteIdentity(identity.id);
                  await _loadIdentities();
                  
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Identity deleted successfully'),
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Error deleting identity: $e'),
                      ),
                    );
                  }
                }
              },
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _setAsDefault(Identity identity) async {
    try {
      await _identityService.setDefaultIdentity(identity.id);
      await _loadIdentities();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${identity.name} set as default identity'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error setting default identity: $e'),
          ),
        );
      }
    }
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
    
    // Show authentication UI if needed
    if (_identities.isEmpty && _isAuthEnabled) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Identity Management'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock,
                  size: 64,
                  color: Colors.blue,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Authentication Required',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Your identities are protected. Please authenticate to view them.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  icon: _authMethod == 'biometric' 
                      ? const Icon(Icons.fingerprint) 
                      : const Icon(Icons.password),
                  label: Text(_authMethod == 'biometric' 
                      ? 'Authenticate with Biometrics' 
                      : 'Authenticate with Password'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    debugPrint('Authentication button in dialog pressed');
                    final authMethod = await _identityService.getAuthMethod();
                    debugPrint('Authentication method: $authMethod');
                    
                    final authenticated = await _authenticateUser();
                    debugPrint('Authentication result: $authenticated');
                    
                    if (authenticated) {
                      if (authMethod == 'password') {
                        // For password auth, load identities directly using the bypass method
                        debugPrint('Loading identities directly after password auth');
                        final identities = await _identityService.getIdentitiesAfterPasswordVerification();
                        debugPrint('Loaded ${identities.length} identities from dialog button');
                        
                        if (mounted) {
                          setState(() {
                            _identities = identities;
                          });
                        }
                      } else {
                        // For biometric auth, reload identities normally
                        await _loadIdentities();
                      }
                    }
                  },
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () async {
                    // Require authentication before disabling security
                    final authenticated = await _authenticateUser();
                    if (authenticated) {
                      await _identityService.setAuthenticationEnabled(false);
                      await _checkAuthSettings();
                      await _loadIdentities();
                    }
                  },
                  child: const Text('Disable Authentication'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Identity Management'),
        actions: [
          // Update All button
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _updateAllIdentities,
            tooltip: 'Update All Identities',
          ),
          IconButton(
            icon: const Icon(Icons.file_download),
            onPressed: _showImportIdentityDialog,
            tooltip: 'Import Identity',
          ),
          IconButton(
            icon: const Icon(Icons.file_upload),
            onPressed: _exportIdentities,
            tooltip: 'Export Identities',
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            onPressed: _importIdentitiesFromJson,
            tooltip: 'Import Identities from JSON',
          ),
        ],
      ),
      body: _identities.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isAuthEnabled)
                    Column(
                      children: [
                        const Text(
                          'Authentication required',
                          style: TextStyle(fontSize: 18),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Please authenticate to view your identities',
                          style: TextStyle(color: Colors.grey),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          icon: _authMethod == 'biometric' 
                              ? const Icon(Icons.fingerprint) 
                              : const Icon(Icons.password),
                          label: Text(_authMethod == 'biometric' 
                              ? 'Authenticate with Biometrics' 
                              : 'Authenticate with Password'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                          ),
                          onPressed: _isAuthenticating
                              ? null
                              : () async {
                                  debugPrint('Authenticate button pressed');
                                  final authMethod = await _identityService.getAuthMethod();
                                  debugPrint('Authentication method from button: $authMethod');
                                  
                                  final authenticated = await _authenticateUser();
                                  debugPrint('Authentication result from button: $authenticated');
                                  
                                  if (authenticated) {
                                    if (authMethod == 'password') {
                                      // For password auth, load identities directly using the bypass method
                                      debugPrint('Loading identities directly after password auth');
                                      final identities = await _identityService.getIdentitiesAfterPasswordVerification();
                                      debugPrint('Loaded ${identities.length} identities from button');
                                      
                                      if (mounted) {
                                        setState(() {
                                          _identities = identities;
                                        });
                                        
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text('Authentication successful'),
                                            backgroundColor: Colors.green,
                                          ),
                                        );
                                      }
                                    } else {
                                      // For biometric auth, reload identities normally
                                      await _loadIdentities();
                                      
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text('Authentication successful'),
                                            backgroundColor: Colors.green,
                                          ),
                                        );
                                      }
                                    }
                                  }
                                },
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: _isAuthenticating
                              ? null
                              : () async {
                                  // Show a confirmation dialog first
                                  final shouldDisable = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text('Disable Authentication'),
                                      content: const Text(
                                        'Are you sure you want to disable authentication? '
                                        'This will make your identities accessible without security.'),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.of(context).pop(false),
                                          child: const Text('CANCEL'),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.of(context).pop(true),
                                          child: const Text('DISABLE'),
                                        ),
                                      ],
                                    ),
                                  ) ?? false;
                                  
                                  if (!shouldDisable) return;
                                  
                                  debugPrint('Attempting to disable authentication');
                                  final authenticated = await _authenticateUser();
                                  debugPrint('Authentication for disabling: $authenticated');
                                  
                                  if (authenticated) {
                                    await _identityService.setAuthenticationEnabled(false);
                                    await _loadIdentities();
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Authentication disabled'),
                                          backgroundColor: Colors.orange,
                                        ),
                                      );
                                    }
                                  }
                                },
                          child: const Text('Disable Authentication'),
                        ),
                        if (_isAuthenticating)
                          const Padding(
                            padding: EdgeInsets.only(top: 16),
                            child: CircularProgressIndicator(),
                          ),
                      ],
                    )
                  else
                    Column(
                          children: [
                            const Text(
                              'No identities found',
                              style: TextStyle(fontSize: 18),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.add),
                              label: const Text('Create New Identity'),
                              onPressed: _showAddIdentityDialog,
                            ),
                          ],
                        ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _identities.length,
                  itemBuilder: (context, index) {
                    final identity = _identities[index];
                    // Create a card with special styling for the default identity
                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      clipBehavior: Clip.antiAlias,
                      // Add color and elevation to highlight default identity
                      color: identity.isDefault ? Colors.blue.shade50 : null,
                      elevation: identity.isDefault ? 4 : 1,
                      shape: identity.isDefault 
                        ? RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: Colors.blue.shade300, width: 2),
                          )
                        : null,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // Determine if we're on a small screen
                          final isSmallScreen = constraints.maxWidth < 600;
                          
                          // For very small screens, we'll use a more compact layout
                          if (isSmallScreen) {
                            return InkWell(
                              onTap: () {
                                if (identity.hasLoadedProfileInfo) {
                                  _showIdentityDetailsModal(context, identity);
                                }
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Header with avatar and name
                                  Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Row(
                                      children: [
                                        // Avatar with badge
                                        Stack(
                                          children: [
                                            CircleAvatar(
                                              radius: 24,
                                              backgroundColor: identity.isDefault
                                                  ? Colors.blue
                                                  : identity.isImported 
                                                      ? Colors.orange
                                                      : Colors.grey,
                                              child: Icon(
                                                identity.isImported ? Icons.link : Icons.person,
                                                color: Colors.white,
                                                size: 22,
                                              ),
                                            ),
                                            if (identity.isDefault)
                                              Positioned(
                                                right: 0,
                                                bottom: 0,
                                                child: Container(
                                                  padding: const EdgeInsets.all(2),
                                                  decoration: BoxDecoration(
                                                    color: Colors.white,
                                                    shape: BoxShape.circle,
                                                    border: Border.all(color: Colors.blue, width: 1),
                                                  ),
                                                  child: const Icon(Icons.check_circle, size: 12, color: Colors.blue),
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(width: 16),
                                        // Identity name with default indicator and type badge
                                        Expanded(
                                          child: Row(
                                            children: [
                                              // Wrap the Row's content in an Expanded to provide bounded width
                                              Expanded(
                                                child: Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        identity.name,
                                                        style: TextStyle(
                                                          fontWeight: identity.isDefault ? FontWeight.bold : FontWeight.normal,
                                                          fontSize: 16,
                                                        ),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                    // Identity type badge
                                                    Container(
                                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                      margin: const EdgeInsets.only(right: 4),
                                                      decoration: BoxDecoration(
                                                        color: identity.getIdentityTypeColor(),
                                                        borderRadius: BorderRadius.circular(10),
                                                      ),
                                                      child: Text(
                                                        identity.getIdentityType(),
                                                        style: TextStyle(color: Colors.white, fontSize: 11),
                                                      ),
                                                    ),
                                                    if (identity.isDefault)
                                                      Container(
                                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                        decoration: BoxDecoration(
                                                          color: Colors.blue,
                                                          borderRadius: BorderRadius.circular(10),
                                                        ),
                                                        child: const Text(
                                                          'Default',
                                                          style: TextStyle(color: Colors.white, fontSize: 12),
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  
                                  // Durability progress bar
                                  if (identity.hasLoadedProfileInfo)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Icon(Icons.shield, size: 16, color: _getDurabilityColor(identity.durability)),
                                              const SizedBox(width: 8),
                                              Text(
                                                'Durability: ${(identity.durability * 100).toStringAsFixed(1)}%',
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w500,
                                                  color: _getDurabilityColor(identity.durability),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(4),
                                            child: LinearProgressIndicator(
                                              value: identity.durability,
                                              backgroundColor: Colors.grey.shade200,
                                              valueColor: AlwaysStoppedAnimation<Color>(_getDurabilityColor(identity.durability)),
                                              minHeight: 6,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  
                                  // Hint text to tap info button for details
                                  if (identity.hasLoadedProfileInfo)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                                      child: Row(
                                        children: [
                                          Icon(Icons.sync, size: 14, color: Colors.grey),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Tap card to view details',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontStyle: FontStyle.italic,
                                              color: Colors.grey.shade600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  
                                  // Loading indicator
                                  if (identity.isLoadingProfileInfo)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(height: 12, width: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                                          const SizedBox(width: 8),
                                          Text('Loading profile info...', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                                        ],
                                      ),
                                    ),
                                  
                                  // Action buttons
                                  Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        // Update/Refresh button
                                        IconButton(
                                          icon: const Icon(Icons.sync),
                                          tooltip: 'Update Profile Info',
                                          onPressed: () async {
                                            await _loadProfileInfo(identity);
                                            if (mounted) {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                  content: Text('${identity.name} updated'),
                                                  backgroundColor: Colors.green,
                                                  duration: const Duration(seconds: 2),
                                                ),
                                              );
                                            }
                                          },
                                          iconSize: 22,
                                          padding: const EdgeInsets.all(8),
                                        ),
                                        // Edit name button
                                        IconButton(
                                          icon: const Icon(Icons.edit),
                                          tooltip: 'Edit Name',
                                          onPressed: () => _showEditIdentityNameDialog(identity),
                                          iconSize: 22,
                                          padding: const EdgeInsets.all(8),
                                        ),
                                        // Set as default button (only for non-default identities)
                                        if (!identity.isDefault)
                                          IconButton(
                                            icon: const Icon(Icons.check_circle_outline),
                                            tooltip: 'Set as default',
                                            onPressed: () => _setAsDefault(identity),
                                            iconSize: 22,
                                            padding: const EdgeInsets.all(8),
                                          ),
                                        // Export button
                                        IconButton(
                                          icon: const Icon(Icons.qr_code),
                                          tooltip: 'Export',
                                          onPressed: identity.isImported 
                                            ? () => _showAddressDialog(identity) 
                                            : () => _showExportDialog(identity),
                                          iconSize: 22,
                                          padding: const EdgeInsets.all(8),
                                        ),
                                        // Delete button
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline),
                                          tooltip: 'Delete',
                                          onPressed: () => _confirmDeleteIdentity(identity),
                                          iconSize: 22,
                                          padding: const EdgeInsets.all(8),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          } else {
                            // For larger screens, use the original ListTile layout with some responsive tweaks
                            return InkWell(
                              onTap: () {
                                if (identity.hasLoadedProfileInfo) {
                                  _showIdentityDetailsModal(context, identity);
                                }
                              },
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                leading: Stack(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor: identity.isImported ? Colors.orange.shade200 : Colors.grey.shade300,
                                      child: Text(
                                        identity.name.isNotEmpty ? identity.name[0].toUpperCase() : '?',
                                        style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold),
                                      ),
                                      radius: 24,
                                    ),
                                    if (identity.isDefault)
                                      Positioned(
                                        right: 0,
                                        bottom: 0,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.blue,
                                            shape: BoxShape.circle,
                                            border: Border.all(color: Colors.white, width: 1.5),
                                          ),
                                          padding: const EdgeInsets.all(2),
                                          child: const Icon(Icons.check, color: Colors.white, size: 12),
                                        ),
                                      ),
                                    // Identity type badge
                                    Positioned(
                                      left: 0,
                                      top: 0,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: identity.getIdentityTypeColor(),
                                          shape: BoxShape.circle,
                                          border: Border.all(color: Colors.white, width: 1.5),
                                        ),
                                        padding: const EdgeInsets.all(2),
                                        child: Text(
                                          identity.getIdentityType()[0], // First letter of type
                                          style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                title: Padding(
                                  padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
                                  child: Text(
                                    identity.name,
                                    style: TextStyle(
                                      fontWeight: identity.isDefault ? FontWeight.bold : FontWeight.normal,
                                      fontSize: 18,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    
                                    // Durability progress bar
                                    if (identity.hasLoadedProfileInfo)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Icon(Icons.shield, size: 16, color: _getDurabilityColor(identity.durability)),
                                                const SizedBox(width: 8),
                                                Text(
                                                  'Durability: ${(identity.durability * 100).toStringAsFixed(1)}%',
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w500,
                                                    color: _getDurabilityColor(identity.durability),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            ClipRRect(
                                              borderRadius: BorderRadius.circular(4),
                                              child: LinearProgressIndicator(
                                                value: identity.durability,
                                                backgroundColor: Colors.grey.shade200,
                                                valueColor: AlwaysStoppedAnimation<Color>(_getDurabilityColor(identity.durability)),
                                                minHeight: 6,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    
                                    // Info text to indicate details are available
                                    if (identity.hasLoadedProfileInfo)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
                                        child: Row(
                                          children: [
                                            Icon(Icons.sync, size: 14, color: Colors.grey),
                                            const SizedBox(width: 4),
                                            Text(
                                              'Tap card to view details',
                                              style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontStyle: FontStyle.italic),
                                            ),
                                          ],
                                        ),
                                      ),
                                    
                                    // Loading indicator
                                    if (identity.isLoadingProfileInfo)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4.0),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            SizedBox(height: 12, width: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                                            const SizedBox(width: 8),
                                            Text('Loading profile info...', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                                isThreeLine: true,
                                trailing: Wrap(
                                  spacing: 0,
                                  children: [
                                    // Update/Refresh button
                                    IconButton(
                                      icon: const Icon(Icons.sync),
                                      tooltip: 'Update Profile Info',
                                      onPressed: () async {
                                        await _loadProfileInfo(identity);
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('${identity.name} updated'),
                                              backgroundColor: Colors.green,
                                              duration: const Duration(seconds: 2),
                                            ),
                                          );
                                        }
                                      },
                                      iconSize: 22,
                                      padding: const EdgeInsets.all(8),
                                    ),
                                    // Edit name button
                                    IconButton(
                                      icon: const Icon(Icons.edit),
                                      tooltip: 'Edit Name',
                                      onPressed: () => _showEditIdentityNameDialog(identity),
                                      iconSize: 22,
                                      padding: const EdgeInsets.all(8),
                                    ),
                                    if (!identity.isDefault)
                                      IconButton(
                                        icon: const Icon(Icons.check_circle_outline),
                                        tooltip: 'Set as default',
                                        onPressed: () => _setAsDefault(identity),
                                        iconSize: 22,
                                        padding: const EdgeInsets.all(8),
                                      ),
                                    IconButton(
                                      icon: const Icon(Icons.qr_code),
                                      tooltip: 'Export',
                                      onPressed: identity.isImported 
                                        ? () => _showAddressDialog(identity) 
                                        : () => _showExportDialog(identity),
                                      iconSize: 22,
                                      padding: const EdgeInsets.all(8),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline),
                                      tooltip: 'Delete',
                                      onPressed: () => _confirmDeleteIdentity(identity),
                                      iconSize: 22,
                                      padding: const EdgeInsets.all(8),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }
                        },
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddIdentityDialog,
        tooltip: 'Add Identity',
        child: const Icon(Icons.add),
      ),
    );
  }

  // Show identity details modal
  void _showIdentityDetailsModal(BuildContext context, Identity identity) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: identity.isDefault
                    ? Colors.blue
                    : identity.isImported 
                        ? Colors.orange
                        : Colors.grey,
                child: Icon(
                  identity.isImported ? Icons.link : Icons.person,
                  color: Colors.white,
                  size: 14,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${identity.name}',
                  style: const TextStyle(fontSize: 18),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Address
                const Text('Profile ID:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          identity.address,
                          style: TextStyle(fontSize: 13, fontFamily: 'monospace'),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 16),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: identity.address));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Profile ID copied to clipboard')),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                
                // RPS
                const Text('Reputation Score (RPS):', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.amber.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.star, size: 16, color: Colors.amber),
                      const SizedBox(width: 8),
                      Text(
                        '${identity.rps}', // Raw value without formatting
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                
                // Balance
                const Text('Balance:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.green.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.account_balance_wallet, size: 16, color: Colors.green),
                      const SizedBox(width: 8),
                      Text(
                        '${identity.balance}', // Raw value without formatting
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                
                // Block Height
                const Text('Last Updated At Block Height:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.purple.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.purple.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.height, size: 16, color: Colors.purple),
                      const SizedBox(width: 8),
                      Text(
                        '${identity.height}',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                
                // NFT Slots - Only shown for master identities
                if (identity.ownerId != null && identity.address == identity.ownerId) ...[
                  const Text('NFT Slots:', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.blue.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.grid_view, size: 16, color: Colors.blue),
                        const SizedBox(width: 8),
                        Text(
                          '${identity.nftSlots < 0 ? 0 : identity.nftSlots}',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  // Update all identities and their profile information
  Future<void> _updateAllIdentities() async {
    if (_identities.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No identities to update')),
      );
      return;
    }

    // Show a loading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Updating all identities...')),
    );

    // Create a set to track identities that have been updated
    // This helps avoid updating the same identity twice (for owned profiles)
    final Set<String> updatedIdentityIds = {};
    
    // First, make a copy of the identities list to iterate through
    final List<Identity> identitiesToUpdate = List.from(_identities);
    
    // Track how many identities were updated successfully
    int successCount = 0;
    int errorCount = 0;

    // Get current blockchain stats to calculate durability (do this once for all identities)
    final blockchainStats = await _profileService.getBlockchainStats();
    final currentBlockHeight = blockchainStats.currentHeight;

    // Update each identity
    for (final identity in identitiesToUpdate) {
      // Skip if this identity has already been updated (as a child of another identity)
      if (updatedIdentityIds.contains(identity.id)) {
        debugPrint('Skipping already updated identity: ${identity.name}');
        continue;
      }

      try {
        // Mark this identity as being updated
        updatedIdentityIds.add(identity.id);
        
        // Fetch profile info for this identity
        final profileId = identity.address;
        final profileInfo = await _profileService.getProfileInfo(profileId);
        
        // Calculate NFT slots
        final nftSlots = _profileService.calculateNftSlots(
          profileInfo.rps, 
          profileInfo.generatedRPs, 
          profileInfo.ownedProfilesNo
        );
        
        // Calculate durability based on height difference
        final heightDifference = currentBlockHeight - profileInfo.height;
        final durability = heightDifference <= 0 ? 1.0 : (1.0 - (heightDifference / 10000.0)).clamp(0.0, 1.0);
        
        // Update the identity with profile information
        if (mounted) {
          setState(() {
            final index = _identities.indexWhere((i) => i.id == identity.id);
            if (index != -1) {
              _identities[index] = _identities[index].copyWith(
                rps: profileInfo.rps,
                balance: profileInfo.balance,
                height: profileInfo.height,
                generatedRPs: profileInfo.generatedRPs,
                ownedProfilesNo: profileInfo.ownedProfilesNo,
                nftSlots: nftSlots,
                durability: durability,
                currentBlockHeight: currentBlockHeight,
                hasLoadedProfileInfo: true,
                isLoadingProfileInfo: false,
                ownerId: profileInfo.ownerId,
                isDomain: profileInfo.isDomain,
              );
            }
          });
        }
        
        // If this identity has owned profiles, update them directly from the profile response
        if (profileInfo.ownedProfiles.isNotEmpty) {
          debugPrint('Processing ${profileInfo.ownedProfiles.length} owned profiles for ${identity.name}');
          
          // For each owned profile, check if it exists in our identities list
          for (final ownedProfile in profileInfo.ownedProfiles) {
            // Find if this owned profile exists in our identities list
            final ownedIdentityIndex = _identities.indexWhere(
              (i) => i.address.toLowerCase() == ownedProfile.id.toLowerCase()
            );
            
            // If found, update it
            if (ownedIdentityIndex != -1) {
              // Mark this identity as being updated
              updatedIdentityIds.add(_identities[ownedIdentityIndex].id);
              debugPrint('Updating owned profile: ${_identities[ownedIdentityIndex].name}');
              
              // Calculate NFT slots for the owned profile
              final childNftSlots = _profileService.calculateNftSlots(
                ownedProfile.rps, 
                ownedProfile.generatedRPs, 
                ownedProfile.ownedProfilesNo
              );
              
              // Calculate durability for the owned profile
              final childHeightDifference = currentBlockHeight - ownedProfile.height;
              final childDurability = childHeightDifference <= 0 ? 1.0 : 
                  (1.0 - (childHeightDifference / 10000.0)).clamp(0.0, 1.0);
              
              // Update the owned identity
              if (mounted) {
                setState(() {
                  _identities[ownedIdentityIndex] = _identities[ownedIdentityIndex].copyWith(
                    rps: ownedProfile.rps,
                    balance: ownedProfile.balance,
                    height: ownedProfile.height,
                    generatedRPs: ownedProfile.generatedRPs,
                    ownedProfilesNo: ownedProfile.ownedProfilesNo,
                    nftSlots: childNftSlots,
                    durability: childDurability,
                    currentBlockHeight: currentBlockHeight,
                    hasLoadedProfileInfo: true,
                    isLoadingProfileInfo: false,
                    ownerId: ownedProfile.ownerId,
                    isDomain: ownedProfile.isDomain,
                  );
                });
              }
            }
          }
        }
        
        successCount++;
      } catch (e) {
        debugPrint('Error updating identity ${identity.name}: $e');
        errorCount++;
      }
    }
    
    // Save updated identities to storage
    await _identityService.saveIdentities(_identities);
    
    // Show completion message
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Updated $successCount identities${errorCount > 0 ? ' ($errorCount errors)' : ''}'),
          backgroundColor: errorCount > 0 ? Colors.orange : Colors.green,
        ),
      );
    }
  }

  // Export identities to JSON
  Future<void> _exportIdentities() async {
    if (_identities.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No identities to export')),
      );
      return;
    }

    try {
      // Use the identity service to export identities as JSON
      final jsonData = await _identityService.exportIdentitiesAsJson();
      
      // Show the JSON in a dialog
      showDialog<void>(
        context: context,
        builder: (BuildContext context) {
          return Dialog(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Text(
                            'Export Identities',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                          tooltip: 'Close',
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Your identities have been exported as JSON. This export does NOT include private keys for security reasons.',
                      style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      constraints: const BoxConstraints(
                        maxHeight: 300,
                      ),
                      child: SelectableText(
                        jsonData,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Use LayoutBuilder to make buttons responsive
                    LayoutBuilder(
                      builder: (context, constraints) {
                        // Check if we have enough width for side-by-side buttons
                        final isNarrow = constraints.maxWidth < 400;
                        
                        return isNarrow
                            ? // Vertical layout for small screens
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.copy),
                                    label: const Text('Copy to Clipboard'),
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(text: jsonData));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('JSON copied to clipboard'),
                                          backgroundColor: Colors.green,
                                        ),
                                      );
                                    },
                                  ),
                                  const SizedBox(height: 8),
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.download),
                                    label: const Text('Download JSON'),
                                    onPressed: () async {
                                      try {
                                        final fileName = 'kbunet_identities_${DateTime.now().millisecondsSinceEpoch}.json';
                                        
                                        // Save file using file_saver package (works on all platforms)
                                        await FileSaver.instance.saveFile(
                                          name: fileName,
                                          bytes: Uint8List.fromList(utf8.encode(jsonData)),
                                          ext: 'json',
                                          mimeType: MimeType.json,
                                        );
                                        
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text('JSON file saved successfully'),
                                              backgroundColor: Colors.green,
                                            ),
                                          );
                                        }
                                      } catch (e) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Error saving file: $e'),
                                              backgroundColor: Colors.red,
                                            ),
                                          );
                                        }
                                      }
                                    },
                                  ),
                                ],
                              )
                            : // Horizontal layout for larger screens
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      icon: const Icon(Icons.copy),
                                      label: const Text('Copy to Clipboard'),
                                      onPressed: () {
                                        Clipboard.setData(ClipboardData(text: jsonData));
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(
                                            content: Text('JSON copied to clipboard'),
                                            backgroundColor: Colors.green,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      icon: const Icon(Icons.download),
                                      label: const Text('Download JSON'),
                                      onPressed: () async {
                                        try {
                                          final fileName = 'kbunet_identities_${DateTime.now().millisecondsSinceEpoch}.json';
                                          
                                          // Save file using file_saver package (works on all platforms)
                                          await FileSaver.instance.saveFile(
                                            name: fileName,
                                            bytes: Uint8List.fromList(utf8.encode(jsonData)),
                                            ext: 'json',
                                            mimeType: MimeType.json,
                                          );
                                          
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(
                                                content: Text('JSON file saved successfully'),
                                                backgroundColor: Colors.green,
                                              ),
                                            );
                                          }
                                        } catch (e) {
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text('Error saving file: $e'),
                                                backgroundColor: Colors.red,
                                              ),
                                            );
                                          }
                                        }
                                      },
                                    ),
                                  ),
                                ],
                              );
                      },
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error exporting identities: $e')),
      );
    }
  }

  // Import identities from JSON
  Future<void> _importIdentitiesFromJson() async {
    final jsonController = TextEditingController();
    bool isImporting = false;
    String? selectedFileName;
    
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Import Identities from JSON'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Option 1: Select a file
                    const Text(
                      'Option 1: Select a JSON file',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.grey),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              selectedFileName ?? 'No file selected',
                              style: TextStyle(
                                color: selectedFileName != null ? Colors.black : Colors.grey,
                                fontSize: 14,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: isImporting ? null : () async {
                            try {
                              FilePickerResult? result = await FilePicker.platform.pickFiles(
                                type: FileType.custom,
                                allowedExtensions: ['json'],
                                allowMultiple: false,
                              );
                              
                              if (result != null && result.files.isNotEmpty) {
                                final file = result.files.first;
                                setState(() {
                                  selectedFileName = file.name;
                                });
                                
                                // Read file content
                                if (file.bytes != null) {
                                  // Web platform returns bytes directly
                                  final content = String.fromCharCodes(file.bytes!);
                                  jsonController.text = content;
                                } else if (file.path != null) {
                                  // Mobile/Desktop platforms return a file path
                                  final fileBytes = await File(file.path!).readAsBytes();
                                  final content = String.fromCharCodes(fileBytes);
                                  jsonController.text = content;
                                }
                              }
                            } catch (e) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Error selecting file: $e'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text('Browse'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // Option 2: Paste JSON
                    const Text(
                      'Option 2: Paste JSON content',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: jsonController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Paste JSON here',
                      ),
                      maxLines: 6,
                      minLines: 3,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Note: This will only import the profile IDs of identities. Private keys are never imported.',
                      style: TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                    if (isImporting)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: isImporting ? null : () async {
                    final jsonText = jsonController.text.trim();
                    if (jsonText.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter JSON data or select a file')),
                      );
                      return;
                    }
                    
                    setState(() {
                      isImporting = true;
                    });
                    
                    try {
                      // Import identities from JSON
                      final importedIdentities = await _identityService.importIdentitiesFromJson(jsonText);
                      
                      // Close the dialog
                      Navigator.of(context).pop();
                      
                      // Reload identities
                      await _loadIdentities();
                      
                      // Show success message
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              importedIdentities.isNotEmpty
                                ? 'Successfully imported ${importedIdentities.length} identities'
                                : 'No new identities were imported (all were duplicates)',
                            ),
                            backgroundColor: importedIdentities.isNotEmpty ? Colors.green : Colors.orange,
                          ),
                        );
                      }
                    } catch (e) {
                      setState(() {
                        isImporting = false;
                      });
                      
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error importing identities: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  child: const Text('Import'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showSecuritySettingsDialog() async {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Security Settings'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    title: const Text('Require Authentication'),
                    subtitle: const Text(
                      'Use biometrics or PIN to access identities',
                    ),
                    value: _isAuthEnabled,
                    onChanged: _isBiometricAvailable
                        ? (value) {
                            setState(() {
                              _isAuthEnabled = value;
                            });
                          }
                        : null,
                  ),
                  if (!_isBiometricAvailable)
                    const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Text(
                        'Biometric authentication is not available on this device',
                        style: TextStyle(
                          color: Colors.red,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    await _identityService.setAuthenticationEnabled(_isAuthEnabled);
                    await _checkAuthSettings();
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
