import 'dart:typed_data';

extension IntToBytes on int {
  Uint8List toBytes({required int size, required Endian endian}) {
    final byteData = ByteData(size);
    switch (size) {
      case 1:
        byteData.setUint8(0, this);
        break;
      case 2:
        byteData.setUint16(0, this, endian);
        break;
      case 4:
        byteData.setUint32(0, this, endian);
        break;
      case 8:
        byteData.setUint64(0, this, endian);
        break;
      default:
        throw ArgumentError('Invalid size: $size');
    }
    return byteData.buffer.asUint8List();
  }
}
