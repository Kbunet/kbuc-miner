// This is a stub file for Windows platform to avoid dependency issues
// It provides a dummy implementation of FlutterSecureStorage

class FlutterSecureStorage {
  const FlutterSecureStorage();
  
  Future<void> write({required String key, required String? value}) async {
    // This is a stub and should never be called directly
    throw UnimplementedError('FlutterSecureStorage is not supported on Windows');
  }
  
  Future<String?> read({required String key}) async {
    // This is a stub and should never be called directly
    throw UnimplementedError('FlutterSecureStorage is not supported on Windows');
  }
  
  Future<void> delete({required String key}) async {
    // This is a stub and should never be called directly
    throw UnimplementedError('FlutterSecureStorage is not supported on Windows');
  }
  
  Future<void> deleteAll() async {
    // This is a stub and should never be called directly
    throw UnimplementedError('FlutterSecureStorage is not supported on Windows');
  }
}
