import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;

import 'package:beecount/cloud/s3_encrypted_storage.dart';

/// 久经验证的参考实现(原本 S3 协同用的就是它,只是在真机上慢 4 倍)。
Uint8List _reference(String password, Uint8List salt, int iterations) {
  final derivator = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64))
    ..init(pc.Pbkdf2Parameters(salt, iterations, 32));
  return derivator.process(Uint8List.fromList(utf8.encode(password)));
}

void main() {
  // KDF 的输出变了就等于所有设备上已经传好的协同数据再也解不开,所以这里逐字节
  // 对着 pointycastle 守着,别让"优化"把密钥换掉。
  test('pbkdf2HmacSha256 与 pointycastle 逐字节一致', () {
    final cases = <(String, List<int>, int)>[
      ('correct horse battery staple', [1, 2, 3, 4], 1),
      ('correct horse battery staple', [1, 2, 3, 4], 2),
      ('', [0], 7),
      ('口令里有中文和 emoji 🐝', [9, 8, 7, 6, 5, 4, 3, 2, 1, 0], 1000),
      ('p', List.generate(16, (i) => i * 11 + 3), 333),
      // salt 长度正好让 salt||INT(1) 跨过一个 SHA-256 分组边界
      ('boundary', List.filled(60, 0x5a), 64),
      ('boundary', List.filled(64, 0x5a), 64),
    ];
    for (final (password, saltBytes, iterations) in cases) {
      final salt = Uint8List.fromList(saltBytes);
      expect(
          base64Encode(pbkdf2HmacSha256(password, salt, iterations)),
          base64Encode(_reference(password, salt, iterations)),
          reason: 'password=$password salt=$saltBytes iterations=$iterations');
    }
  });

  test('pbkdf2HmacSha256 派生 32 字节且随迭代次数变化', () {
    final salt = Uint8List.fromList([1, 2, 3, 4]);
    final once = pbkdf2HmacSha256('pw', salt, 1);
    final twice = pbkdf2HmacSha256('pw', salt, 2);
    expect(once, hasLength(32));
    expect(twice, hasLength(32));
    expect(base64Encode(twice), isNot(base64Encode(once)));
  });
}
