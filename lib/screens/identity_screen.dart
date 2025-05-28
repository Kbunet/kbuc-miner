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

class IdentityScreen extends StatefulWidget {
  const IdentityScreen({Key? key}) : super(key: key);

  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  final ProfileService _profileService = ProfileService();
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

  @override
  void initState() {
    super.initState();
    _loadIdentities();
    _checkAuthSettings();
  }

  Future<void> _checkAuthSettings() async {
    final isBiometricAvailable = await _identityService.isBiometricAvailable();
    final isAuthEnabled = await _identityService.isAuthenticationEnabled();
    
    setState(() {
      _isBiometricAvailable = isBiometricAvailable;
      _isAuthEnabled = isAuthEnabled;
    });
  }

  // Authenticate the user explicitly
  Future<bool> _authenticateUser() async {
    setState(() {
      _isLoading = true;
    });
    
    try {
      final authenticated = await _identityService.authenticate();
      setState(() {
        _isLoading = false;
      });
      
      if (!authenticated) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Authentication failed')),
          );
        }
      }
      
      return authenticated;
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Authentication error: $e')),
        );
      }
      return false;
    }
  }

  Future<void> _loadIdentities() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final identities = await _identityService.getIdentities();
      setState(() {
        _identities = identities;
        _isLoading = false;
      });
      
      // We no longer load profile info automatically
      // Profile info will be loaded on demand when the user requests it
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading identities: $e')),
        );
      }
      setState(() {
        _isLoading = false;
      });
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
      
      debugPrint('🔍 Fetching profile info using ID: $profileId');
      final profileInfo = await _profileService.getProfileInfo(profileId);
      
      // Debug the profile info received
      debugPrint('📊 Profile info received for ${identity.name}: rps=${profileInfo.rps}, balance=${profileInfo.balance}');
      
      // Update the identity with profile information
      if (mounted) {
        setState(() {
          final index = _identities.indexWhere((i) => i.id == identity.id);
          if (index != -1) {
            debugPrint('📝 Updating identity at index $index with rps=${profileInfo.rps}, balance=${profileInfo.balance}');
            _identities[index] = _identities[index].copyWith(
              rps: profileInfo.rps,
              balance: profileInfo.balance,
              hasLoadedProfileInfo: true,
              isLoadingProfileInfo: false,
            );
            
            // Debug the updated identity
            debugPrint('✅ Updated identity: rps=${_identities[index].rps}, balance=${_identities[index].balance}, hasLoadedProfileInfo=${_identities[index].hasLoadedProfileInfo}');
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
                    labelText: 'Public Key Hash/Address',
                    hintText: 'Enter the public key hash (40 hex characters)',
                    helperText: 'This is the address that will receive mining rewards',
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Identity Management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _showImportIdentityDialog(),
            tooltip: 'Import Identity',
          ),
          // Security button temporarily hidden
          // IconButton(
          //   icon: const Icon(Icons.security),
          //   onPressed: () => _showSecuritySettingsDialog(),
          //   tooltip: 'Security Settings',
          // ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _identities.isEmpty
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
                              icon: const Icon(Icons.fingerprint),
                              label: const Text('Authenticate'),
                              onPressed: () async {
                                final authenticated = await _authenticateUser();
                                if (authenticated) {
                                  await _loadIdentities();
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                              ),
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
                            return Column(
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
                                      // Name with ellipsis for overflow
                                      Expanded(
                                        child: Text(
                                          identity.name,
                                          style: TextStyle(
                                            fontWeight: identity.isDefault ? FontWeight.bold : FontWeight.normal,
                                            fontSize: 18,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                
                                // Profile info chips
                                if (identity.hasLoadedProfileInfo)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        // RPS chip
                                        Container(
                                          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                                          decoration: BoxDecoration(
                                            color: Colors.amber.withOpacity(0.1),
                                            borderRadius: BorderRadius.circular(16),
                                            border: Border.all(color: Colors.amber.withOpacity(0.3), width: 1),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.star, size: 16, color: Colors.amber),
                                              const SizedBox(width: 6),
                                              Text(
                                                _profileService.formatRps(identity.rps),
                                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                              ),
                                            ],
                                          ),
                                        ),
                                        
                                        // Balance chip
                                        Container(
                                          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                                          decoration: BoxDecoration(
                                            color: Colors.green.withOpacity(0.1),
                                            borderRadius: BorderRadius.circular(16),
                                            border: Border.all(color: Colors.green.withOpacity(0.3), width: 1),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.account_balance_wallet, size: 16, color: Colors.green),
                                              const SizedBox(width: 6),
                                              Text(
                                                _profileService.formatBalance(identity.balance),
                                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                              ),
                                            ],
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
                                      // Info button
                                      IconButton(
                                        icon: const Icon(Icons.info_outline),
                                        tooltip: 'Get Profile Info',
                                        onPressed: () => _loadProfileInfo(identity),
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
                            );
                          } else {
                            // For larger screens, use the original ListTile layout with some responsive tweaks
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              leading: Stack(
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
                                  
                                  // Profile info row
                                  if (identity.hasLoadedProfileInfo)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12.0, bottom: 4.0),
                                      child: Wrap(
                                        spacing: 16,
                                        runSpacing: 8,
                                        children: [
                                          // RPS chip
                                          Container(
                                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                                            decoration: BoxDecoration(
                                              color: Colors.amber.withOpacity(0.1),
                                              borderRadius: BorderRadius.circular(16),
                                              border: Border.all(color: Colors.amber.withOpacity(0.3), width: 1),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.star, size: 16, color: Colors.amber),
                                                const SizedBox(width: 6),
                                                Text(
                                                  _profileService.formatRps(identity.rps),
                                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                                ),
                                              ],
                                            ),
                                          ),
                                          
                                          // Balance chip
                                          Container(
                                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                                            decoration: BoxDecoration(
                                              color: Colors.green.withOpacity(0.1),
                                              borderRadius: BorderRadius.circular(16),
                                              border: Border.all(color: Colors.green.withOpacity(0.3), width: 1),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.account_balance_wallet, size: 16, color: Colors.green),
                                                const SizedBox(width: 6),
                                                Text(
                                                  _profileService.formatBalance(identity.balance),
                                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                                ),
                                              ],
                                            ),
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
                                  // Info button to fetch profile information
                                  IconButton(
                                    icon: const Icon(Icons.info_outline),
                                    tooltip: 'Get Profile Info',
                                    onPressed: () => _loadProfileInfo(identity),
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
