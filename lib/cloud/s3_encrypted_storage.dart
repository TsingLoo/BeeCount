import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:pointycastle/export.dart';

/// 同步密码和云端已有数据对不上(GCM 校验失败)。调用方应把它当作"请输入当前
/// 密码",而不是网络错误重试。
class S3SyncPasswordMismatch implements Exception {
  const S3SyncPasswordMismatch(this.path);

  final String path;

  @override
  String toString() =>
      'S3SyncPasswordMismatch: sync password does not match remote object $path';
}

/// 对象存在但不是 BeeCount 的加密信封(例如别的工具往同一前缀写了文件)。
/// 和密码错误区分开,否则用户会被引导去改密码。
class S3EncryptedObjectFormatError implements Exception {
  const S3EncryptedObjectFormatError(this.path, this.reason);

  final String path;
  final String reason;

  @override
  String toString() =>
      'S3EncryptedObjectFormatError: $path is not a BeeCount encrypted object ($reason)';
}

/// Encrypts collaboration objects before they reach S3. Object names remain
/// visible to the storage provider; names and transaction content do not.
///
/// 分两层密钥:
/// - 数据密钥(DEK):随机 256 位,所有协同对象都用它加密;
/// - 口令密钥(KEK):PBKDF2(同步密码) 推出来,只用来把 DEK 封装进
///   [keyParamsPath] 这一个对象。
///
/// 这样换同步密码只需把 DEK 重新封一遍([changePassword]),云端数据一个字节都
/// 不用重写;而丢了口令依然解不开 DEK —— 服务端始终拿不到明文。
class S3EncryptedStorage implements CloudStorageService {
  S3EncryptedStorage(this.delegate, {
    required String password,
    required String bucket,
  })  : _password = password,
        _bucket = bucket;

  final CloudStorageService delegate;
  String _password;
  final String _bucket;
  Future<Uint8List>? _keyFuture;

  /// 同一组(口令, salt, 迭代次数)只派生一次 KEK。真机实测(天玑 8100, profile)
  /// 一次 PBKDF2 要 4.5 秒,而首次启用会"封装后回读再解封装",salt 没变却要重算
  /// 一遍 —— 白等 4.5 秒。只在内存里,不落盘。
  String? _kekCacheId;
  Uint8List? _kekCache;

  /// 密钥封装对象:随机 salt、迭代次数,以及被 KEK 加密的 DEK。
  /// **不经过本层加解密**(里面没有明文秘密),但必须和数据放在同一个 bucket,
  /// 这样所有设备算出同一把数据密钥。
  static const keyParamsPath = 'beecount-sync/v3/keyparams.json';
  static const _iterations = 200000;

  Future<Uint8List> get _key =>
      _keyFuture ??= _resolveKey().onError<Object>((error, stack) {
        _keyFuture = null; // 网络抖动不该把一次失败固化成永久失败
        Error.throwWithStackTrace(error, stack);
      });

  /// 在写入任何数据之前把口令验一遍:口令不对就抛 [S3SyncPasswordMismatch],
  /// 避免用错口令的设备往云端灌一堆别人解不开的对象。
  Future<void> ensureKey() => _key;

  /// 把本机缓存的数据密钥丢掉(云端 keyparams 被删之后要调一次)。
  void invalidateKeyCache() => _keyFuture = null;

  /// 只读校验,给"测试连接"用:云端还没有密钥封装(全新 bucket)返回 false,
  /// 口令不对抛 [S3SyncPasswordMismatch]。不会往用户 bucket 里写任何东西 ——
  /// 点一次测试不该把 bucket 初始化成协同库。
  Future<bool> verifyPassword() async {
    final parsed = _parseParams(await delegate.download(path: keyParamsPath));
    if (parsed == null) return false;
    final dek = await _unwrapKey(parsed);
    _keyFuture = Future.value(dek);
    return true;
  }

  /// 换同步密码。需要能解开当前的 DEK —— 也就是本机存的口令必须还是云端认的
  /// 那个,否则抛 [S3SyncPasswordMismatch]。成功后云端只有 keyparams.json 变了,
  /// 其它设备下次同步会因为解不开而提示输入新口令。
  Future<void> changePassword(String newPassword) async {
    final dek = await _key;
    final salt = _randomBytes(16);
    final wrapped = await _wrapKey(dek, newPassword, salt, _iterations);
    await delegate.upload(
        path: keyParamsPath, data: _encodeParams(salt, _iterations, wrapped));
    _password = newPassword;
    _keyFuture = Future.value(dek);
  }

  Future<Uint8List> _resolveKey() async {
    final raw = await delegate.download(path: keyParamsPath);
    final parsed = _parseParams(raw);
    if (parsed == null) return _createKey();
    return _unwrapKey(parsed);
  }

  Future<Uint8List> _createKey() async {
    final dek = _randomBytes(32);
    final salt = _randomBytes(16);
    final wrapped = await _wrapKey(dek, _password, salt, _iterations);
    await delegate.upload(
        path: keyParamsPath, data: _encodeParams(salt, _iterations, wrapped));
    // 两台设备同一秒首次启用会各写一份,这里回读一次,让双方都认云端最终留下的
    // 那份(口令相同则两边解出的 DEK 一致;口令不同则这里就报不匹配)。
    final confirmed = _parseParams(await delegate.download(path: keyParamsPath));
    if (confirmed == null) return dek;
    return _unwrapKey(confirmed);
  }

  Future<Uint8List> _unwrapKey(_KeyParams params) async {
    final kek = await _deriveKek(_password, params.salt, params.iterations);
    try {
      return _crypt(false, kek, params.wrapNonce, keyParamsPath,
          params.wrappedKey);
    } on InvalidCipherTextException {
      throw const S3SyncPasswordMismatch(keyParamsPath);
    }
  }

  Future<_Wrapped> _wrapKey(
      Uint8List dek, String password, Uint8List salt, int iterations) async {
    final kek = await _deriveKek(password, salt, iterations);
    final nonce = _randomBytes(12);
    return _Wrapped(nonce, _crypt(true, kek, nonce, keyParamsPath, dek));
  }

  Future<Uint8List> _deriveKek(
      String password, Uint8List salt, int iterations) async {
    final cacheId = '$iterations|${base64Encode(salt)}|$password';
    final cached = _kekCache;
    if (cached != null && _kekCacheId == cacheId) return cached;
    // 随机 salt 再拼上 bucket 名:同一份 keyparams 被复制到别的 bucket 也推不出
    // 同一把钥匙。
    final bound = Uint8List.fromList([...salt, ...utf8.encode('|$_bucket')]);
    final kek = await Isolate.run(() => _pbkdf2(password, bound, iterations));
    _kekCacheId = cacheId;
    _kekCache = kek;
    return kek;
  }

  static String _encodeParams(
          Uint8List salt, int iterations, _Wrapped wrapped) =>
      jsonEncode({
        'v': 2,
        'kdf': 'pbkdf2-hmac-sha256',
        'cipher': 'aes-256-gcm',
        'iterations': iterations,
        'salt': base64Encode(salt),
        'wrapNonce': base64Encode(wrapped.nonce),
        'wrappedKey': base64Encode(wrapped.ciphertext),
      });

  static _KeyParams? _parseParams(String? raw) {
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const S3EncryptedObjectFormatError(
          keyParamsPath, 'not a json object');
    }
    final salt = decoded['salt'];
    final iterations = decoded['iterations'];
    final nonce = decoded['wrapNonce'];
    final wrappedKey = decoded['wrappedKey'];
    if (salt is! String ||
        nonce is! String ||
        wrappedKey is! String ||
        iterations is! int ||
        iterations <= 0) {
      throw const S3EncryptedObjectFormatError(
          keyParamsPath, 'unexpected key params shape');
    }
    return _KeyParams(
      salt: Uint8List.fromList(base64Decode(salt)),
      iterations: iterations,
      wrapNonce: Uint8List.fromList(base64Decode(nonce)),
      wrappedKey: Uint8List.fromList(base64Decode(wrappedKey)),
    );
  }

  static Uint8List _pbkdf2(String password, Uint8List salt, int iterations) =>
      pbkdf2HmacSha256(password, salt, iterations);

  /// 对象路径当 AAD:密文搬到别的 key 下面就解不开,服务端换不了内容的位置。
  static Uint8List _crypt(bool encrypt, Uint8List key, Uint8List nonce,
      String path, Uint8List input) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce,
          Uint8List.fromList(utf8.encode(path))));
    return cipher.process(input);
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(length, (_) => random.nextInt(256)));
  }

  @override
  Future<void> upload({required String path, required String data,
      Map<String, String>? metadata}) async {
    final key = await _key;
    final nonce = _randomBytes(12);
    final encrypted =
        _crypt(true, key, nonce, path, Uint8List.fromList(utf8.encode(data)));
    await delegate.upload(path: path, data: jsonEncode({
      'beecountE2ee': 1,
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(encrypted),
    }), metadata: metadata);
  }

  @override
  Future<String?> download({required String path}) async {
    final raw = await delegate.download(path: path);
    if (raw == null) return null;
    // 信封解析失败 = 对象不是我们写的;GCM 校验失败 = 密码不对。两者分开报,
    // 别的异常(网络、权限)原样抛出去,不要被吞成"密码错误"。
    final Uint8List nonce;
    final Uint8List ciphertext;
    try {
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      if (envelope['beecountE2ee'] != 1) {
        throw const FormatException('missing beecountE2ee marker');
      }
      nonce = Uint8List.fromList(base64Decode(envelope['nonce'] as String));
      ciphertext =
          Uint8List.fromList(base64Decode(envelope['ciphertext'] as String));
    } on FormatException catch (e) {
      throw S3EncryptedObjectFormatError(path, e.message);
    } on TypeError {
      throw S3EncryptedObjectFormatError(path, 'unexpected envelope shape');
    }
    final key = await _key;
    try {
      return utf8.decode(_crypt(false, key, nonce, path, ciphertext));
    } on InvalidCipherTextException {
      throw S3SyncPasswordMismatch(path);
    }
  }

  @override
  Future<void> delete({required String path}) => delegate.delete(path: path);

  @override
  Future<List<CloudFile>> list({required String path}) => delegate.list(path: path);

  @override
  Future<bool> exists({required String path}) => delegate.exists(path: path);

  @override
  Future<CloudFile?> getMetadata({required String path}) =>
      delegate.getMetadata(path: path);
}

class _KeyParams {
  const _KeyParams({
    required this.salt,
    required this.iterations,
    required this.wrapNonce,
    required this.wrappedKey,
  });

  final Uint8List salt;
  final int iterations;
  final Uint8List wrapNonce;
  final Uint8List wrappedKey;
}

class _Wrapped {
  const _Wrapped(this.nonce, this.ciphertext);

  final Uint8List nonce;
  final Uint8List ciphertext;
}

/// PBKDF2-HMAC-SHA256,派生 32 字节(单块,所以只有一次 INT(1) 迭代链)。
///
/// 自己写循环是因为 pointycastle 的实现在真机上太慢:同样 20 万次迭代、同样的
/// 输出,天玑 8100 上 pointycastle 4477ms,这版 1015ms(profile 模式实测)。KDF
/// 本身没变,所以用旧版本写上去的 keyparams.json 照样能解开。
/// 输出一致性由 test/cloud/pbkdf2_test.dart 对着 pointycastle 守着。
Uint8List pbkdf2HmacSha256(String password, Uint8List salt, int iterations) {
  final hmac = crypto.Hmac(crypto.sha256, utf8.encode(password));
  // U1 = HMAC(password, salt || INT_32_BE(1))
  final seed = Uint8List(salt.length + 4)
    ..setRange(0, salt.length, salt)
    ..[salt.length + 3] = 1;
  var u = Uint8List.fromList(hmac.convert(seed).bytes);
  final result = Uint8List.fromList(u);
  for (var round = 1; round < iterations; round++) {
    u = Uint8List.fromList(hmac.convert(u).bytes);
    for (var i = 0; i < result.length; i++) {
      result[i] ^= u[i];
    }
  }
  return result;
}
