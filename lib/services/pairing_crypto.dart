/// SHA-256, HMAC-SHA256 and the pairing proof construction.
///
/// A self-contained hash implementation on purpose: the Android client has to
/// agree bit-for-bit with `PCMonitorHost.Core/Services/PairingAuthenticationService.cs`,
/// and keeping it in-tree means the wire format can be verified against the
/// published RFC vectors without pulling a crypto package into the build.
///
/// The proof layout is the host's, verbatim:
///
/// ```text
/// device proof = HMAC-SHA256(secret, nonce || hostId || deviceId)
/// host   proof = HMAC-SHA256(secret, "pcmonitor-host-v1\0" || nonce
///                                      || clientNonce || hostId || deviceId)
/// ```
///
/// `nonce` and `clientNonce` are the *decoded* 32 bytes; `hostId` and `deviceId`
/// are UTF-8. The domain separator on the host proof is what stops a device
/// proof from being replayed back as a host proof.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Round constants (FIPS 180-4 §4.2.2).
const List<int> _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xFFFFFFFF;

/// SHA-256 of [message]. Returns the raw 32-byte digest.
Uint8List sha256(List<int> message) {
  final int length = message.length;
  // 0x80, then zero padding until 8 bytes short of a block boundary, then the
  // 64-bit big-endian bit length.
  final int padded = ((length + 9 + 63) ~/ 64) * 64;
  final Uint8List block = Uint8List(padded);
  block.setRange(0, length, message);
  block[length] = 0x80;

  final int highBits = length ~/ 536870912; // (length * 8) >> 32
  final int lowBits = (length * 8) & 0xFFFFFFFF;
  block[padded - 8] = (highBits >>> 24) & 0xFF;
  block[padded - 7] = (highBits >>> 16) & 0xFF;
  block[padded - 6] = (highBits >>> 8) & 0xFF;
  block[padded - 5] = highBits & 0xFF;
  block[padded - 4] = (lowBits >>> 24) & 0xFF;
  block[padded - 3] = (lowBits >>> 16) & 0xFF;
  block[padded - 2] = (lowBits >>> 8) & 0xFF;
  block[padded - 1] = lowBits & 0xFF;

  int h0 = 0x6a09e667;
  int h1 = 0xbb67ae85;
  int h2 = 0x3c6ef372;
  int h3 = 0xa54ff53a;
  int h4 = 0x510e527f;
  int h5 = 0x9b05688c;
  int h6 = 0x1f83d9ab;
  int h7 = 0x5be0cd19;

  final Uint32List w = Uint32List(64);
  for (int base = 0; base < padded; base += 64) {
    for (int i = 0; i < 16; i++) {
      final int o = base + i * 4;
      w[i] = (block[o] << 24) |
          (block[o + 1] << 16) |
          (block[o + 2] << 8) |
          block[o + 3];
    }
    for (int i = 16; i < 64; i++) {
      final int x = w[i - 15];
      final int y = w[i - 2];
      final int s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >>> 3);
      final int s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }

    int a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (int i = 0; i < 64; i++) {
      final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final int ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final int t1 = (h + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
      final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int t2 = (s0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }

    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
    h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF;
    h7 = (h7 + h) & 0xFFFFFFFF;
  }

  final Uint8List out = Uint8List(32);
  final List<int> words = <int>[h0, h1, h2, h3, h4, h5, h6, h7];
  for (int i = 0; i < 8; i++) {
    out[i * 4] = (words[i] >>> 24) & 0xFF;
    out[i * 4 + 1] = (words[i] >>> 16) & 0xFF;
    out[i * 4 + 2] = (words[i] >>> 8) & 0xFF;
    out[i * 4 + 3] = words[i] & 0xFF;
  }
  return out;
}

/// HMAC-SHA256 (RFC 2104) with a 64-byte block.
Uint8List hmacSha256(List<int> key, List<int> message) {
  const int blockSize = 64;
  final List<int> padded = key.length > blockSize ? sha256(key) : key;
  final Uint8List oKey = Uint8List(blockSize);
  final Uint8List iKey = Uint8List(blockSize);
  for (int i = 0; i < blockSize; i++) {
    final int b = i < padded.length ? padded[i] : 0;
    oKey[i] = b ^ 0x5c;
    iKey[i] = b ^ 0x36;
  }
  final Uint8List inner = sha256(<int>[...iKey, ...message]);
  return sha256(<int>[...oKey, ...inner]);
}

// ---------------------------------------------------------------------------
// Pairing material
// ---------------------------------------------------------------------------

const int kSecretBytes = 32;

/// A fresh 32-byte pairing secret, the shape `NewSecret()` produces.
Uint8List newSecret() => randomBytes(kSecretBytes);

/// A fresh 32-byte nonce, base64 encoded - `NewNonce()`.
String newNonce() => base64Encode(randomBytes(32));

/// `Random.secure()` is a CSPRNG on Android, which is what pairing material
/// needs. The host's own `RandomNumberGenerator.GetBytes` is the mirror.
Uint8List randomBytes(int count) {
  final math.Random random = math.Random.secure();
  final Uint8List out = Uint8List(count);
  for (int i = 0; i < count; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

/// `Is32Bytes()` - a base64 string that decodes to exactly 32 bytes.
bool is32Bytes(String? encoded) => decodeBase64(encoded)?.length == 32;

/// Tolerant base64 decode: `null` instead of throwing, so malformed pairing
/// material is rejected rather than crashing the handshake.
Uint8List? decodeBase64(String? text) {
  if (text == null || text.isEmpty || text.length > 512) return null;
  try {
    return base64Decode(text);
  } on FormatException {
    return null;
  }
}

/// `ValidHostId()` - a canonical `D`-format GUID.
bool validHostId(String? id) {
  if (id == null || id.length != 36) return false;
  final RegExp pattern = RegExp(
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    '[0-9a-fA-F]{12}',
  );
  if (!pattern.hasMatch(id)) return false;
  return id != '00000000-0000-0000-0000-000000000000';
}

/// `ValidDeviceId()` - non-empty, at most 128 UTF-8 bytes, no control chars.
bool validDeviceId(String? id) {
  if (id == null || id.trim().isEmpty) return false;
  if (utf8.encode(id).length > 128) return false;
  for (int i = 0; i < id.length; i++) {
    final int code = id.codeUnitAt(i);
    if (code < 0x20 || code == 0x7F) return false;
  }
  return true;
}

/// The device-side proof: `HMAC(secret, nonce || hostId || deviceId)`.
String deviceProof({
  required List<int> secret,
  required String nonce,
  required String hostId,
  required String deviceId,
}) =>
    base64Encode(_proof(secret, nonce, null, hostId, deviceId));

/// The expected host-side proof, domain separated and bound to our client nonce.
String hostProof({
  required List<int> secret,
  required String nonce,
  required String clientNonce,
  required String hostId,
  required String deviceId,
}) =>
    base64Encode(_proof(secret, nonce, clientNonce, hostId, deviceId));

Uint8List _proof(
  List<int> secret,
  String nonce,
  String? clientNonce,
  String hostId,
  String deviceId,
) {
  final Uint8List? nonceBytes = decodeBase64(nonce);
  if (secret.length != kSecretBytes ||
      nonceBytes == null ||
      nonceBytes.length != 32) {
    throw ArgumentError('Invalid pairing material');
  }
  final List<int> input = <int>[];
  if (clientNonce != null) {
    input.addAll(utf8.encode('pcmonitor-host-v1\u0000'));
  }
  input.addAll(nonceBytes);
  if (clientNonce != null) {
    final Uint8List? bytes = decodeBase64(clientNonce);
    if (bytes == null || bytes.length != 32) {
      throw ArgumentError('Invalid client nonce');
    }
    input.addAll(bytes);
  }
  input.addAll(utf8.encode(hostId));
  input.addAll(utf8.encode(deviceId));
  return hmacSha256(secret, input);
}

/// Constant-time comparison, mirroring `CryptographicOperations.FixedTimeEquals`.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Verifies a base64 host proof against the expected one.
bool verifyProof(String expected, String? actual) {
  if (!is32Bytes(actual) || !is32Bytes(expected)) return false;
  return constantTimeEquals(decodeBase64(expected)!, decodeBase64(actual!)!);
}

/// Random UUID v4 in the canonical form `validHostId` accepts.
String newUuidV4() {
  final Uint8List bytes = randomBytes(16);
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  String hex(int start, int end) {
    final StringBuffer out = StringBuffer();
    for (int i = start; i < end; i++) {
      out.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
