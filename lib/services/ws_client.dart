/// A minimal RFC 6455 WebSocket client.
///
/// `dart:io`'s `WebSocket.connect` is deliberately not used here, for two
/// reasons that both matter on the real link:
///
/// 1. **It must speak the host's dialect.** `WebSocketHostTransport` accepts an
///    upgrade only when the request carries `Upgrade: websocket` and
///    `Connection: Upgrade`, and when it carries **no** `Origin`,
///    `Transfer-Encoding` or `Content-Length` header. Driving the raw socket
///    means every byte of the request is under this project's control.
/// 2. **The build cannot be trusted to send them.** On the Dart 3.5.4 SDK used
///    to develop this app, `WebSocket.connect` emits a request with neither
///    `Upgrade` nor `Connection`, so it cannot complete an upgrade against the
///    host - or even against `dart:io`'s own `WebSocketTransformer`.
///
/// Only the client half of the protocol is implemented: masked text frames,
/// fragment reassembly, ping/pong and the close handshake.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// SHA-1 (RFC 3174) - needed only for `Sec-WebSocket-Accept`
// ---------------------------------------------------------------------------

/// SHA-1 of [message].
///
/// SHA-1 is not a security primitive here: RFC 6455 mandates it purely to prove
/// the peer understood the upgrade, and the host uses it for the same purpose.
Uint8List sha1(List<int> message) {
  final int length = message.length;
  final int padded = ((length + 9 + 63) ~/ 64) * 64;
  final Uint8List block = Uint8List(padded);
  block.setRange(0, length, message);
  block[length] = 0x80;

  final int highBits = length ~/ 536870912;
  final int lowBits = (length * 8) & 0xFFFFFFFF;
  block[padded - 8] = (highBits >>> 24) & 0xFF;
  block[padded - 7] = (highBits >>> 16) & 0xFF;
  block[padded - 6] = (highBits >>> 8) & 0xFF;
  block[padded - 5] = highBits & 0xFF;
  block[padded - 4] = (lowBits >>> 24) & 0xFF;
  block[padded - 3] = (lowBits >>> 16) & 0xFF;
  block[padded - 2] = (lowBits >>> 8) & 0xFF;
  block[padded - 1] = lowBits & 0xFF;

  int h0 = 0x67452301;
  int h1 = 0xEFCDAB89;
  int h2 = 0x98BADCFE;
  int h3 = 0x10325476;
  int h4 = 0xC3D2E1F0;

  final Uint32List w = Uint32List(80);
  for (int base = 0; base < padded; base += 64) {
    for (int i = 0; i < 16; i++) {
      final int o = base + i * 4;
      w[i] = (block[o] << 24) |
          (block[o + 1] << 16) |
          (block[o + 2] << 8) |
          block[o + 3];
    }
    for (int i = 16; i < 80; i++) {
      w[i] = _rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    int a = h0, b = h1, c = h2, d = h3, e = h4;
    for (int i = 0; i < 80; i++) {
      final int f;
      final int k;
      if (i < 20) {
        f = (b & c) | ((~b & 0xFFFFFFFF) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final int temp = (_rotl(a, 5) + f + e + k + w[i]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = _rotl(b, 30);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
  }

  final Uint8List out = Uint8List(20);
  final List<int> words = <int>[h0, h1, h2, h3, h4];
  for (int i = 0; i < 5; i++) {
    out[i * 4] = (words[i] >>> 24) & 0xFF;
    out[i * 4 + 1] = (words[i] >>> 16) & 0xFF;
    out[i * 4 + 2] = (words[i] >>> 8) & 0xFF;
    out[i * 4 + 3] = words[i] & 0xFF;
  }
  return out;
}

int _rotl(int x, int n) => ((x << n) | (x >>> (32 - n))) & 0xFFFFFFFF;

/// The RFC 6455 handshake GUID.
const String _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// The value the peer must echo back for `Sec-WebSocket-Key` [key].
String webSocketAccept(String key) => base64Encode(
      sha1(<int>[...utf8.encode(key), ...utf8.encode(_webSocketGuid)]),
    );

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// Opcodes this client cares about.
class _Opcode {
  const _Opcode._();

  static const int continuation = 0x0;
  static const int text = 0x1;
  static const int binary = 0x2;
  static const int close = 0x8;
  static const int ping = 0x9;
  static const int pong = 0xA;
}

class WebSocketHandshakeException implements Exception {
  WebSocketHandshakeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A connected, handshaken WebSocket.
class WsClient {
  WsClient._(this._socket);

  final Socket _socket;
  final List<int> _pending = <int>[];

  /// A single-subscription controller, deliberately: it buffers frames until
  /// the one subscriber attaches. A broadcast controller would *drop* them,
  /// and the host writes `pairing.challenge` in the same breath as the upgrade
  /// response - often in the very same TCP segment - so the challenge would be
  /// lost and every connect would sit until the handshake timeout.
  final StreamController<String> _messages = StreamController<String>();
  final Completer<void> _done = Completer<void>();

  /// Accumulates fragmented text frames until FIN.
  final BytesBuilder _fragment = BytesBuilder();
  int _fragmentOpcode = 0;
  Timer? _keepAlive;
  bool _disposed = false;

  /// Outbound frames waiting for a safe moment to be written.
  ///
  /// A frame must never be written from inside the socket's own read dispatch.
  /// On this SDK the sink reports `StreamSink is bound to a stream` while a
  /// read event - or an in-flight `flush()` - is being handled, and `add()`
  /// throws. That is not a theoretical case here: the challenge arrives as a
  /// read event, the pairing echo is produced from it, and the reference
  /// telemetry is pushed the same way. A timer task always runs on a fresh
  /// event-loop turn, where the sink is usable again.
  final List<List<int>> _outbox = <List<int>>[];
  Timer? _drain;

  /// Set once the HTTP upgrade has been accepted; from then on inbound bytes
  /// are parsed as frames rather than as handshake response.
  bool _upgraded = false;
  int? closeCode;
  String? closeReason;

  /// Decoded text messages.
  Stream<String> get messages => _messages.stream;

  /// Completes when the peer closes, the socket drops, or [close] finishes.
  Future<void> get done => _done.future;

  bool get isClosed => _disposed;

  /// The frames per second of traffic the keep-alive uses. The host answers a
  /// ping with a pong automatically, and the pong also proves the socket is
  /// still carrying traffic rather than merely open.
  static const Duration keepAliveInterval = Duration(seconds: 20);

  /// Performs the TCP connect and the HTTP upgrade.
  ///
  /// [path] is sent verbatim as the request target - the host compares the
  /// request line against `GET /ws HTTP/1.1` character for character.
  static Future<WsClient> connect(
    Uri uri, {
    Duration timeout = const Duration(seconds: 8),
    String? origin,
  }) async {
    final String host = uri.host;
    final int port = uri.hasPort ? uri.port : 80;
    final String path = uri.path.isEmpty ? '/' : uri.path;

    final Socket socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);

    // Declared before the upgrade closure below, which hands the first (already
    // buffered) bytes straight to the frame parser.
    final WsClient client = WsClient._(socket);

    final String key = base64Encode(_randomKey());
    final StringBuffer request = StringBuffer()
      ..write('GET $path HTTP/1.1\r\n')
      ..write('Host: $host:$port\r\n')
      ..write('Upgrade: websocket\r\n')
      ..write('Connection: Upgrade\r\n')
      ..write('Sec-WebSocket-Key: $key\r\n')
      ..write('Sec-WebSocket-Version: 13\r\n');
    // The host rejects any upgrade that carries an Origin header, so the header
    // is simply never written. The parameter exists to make that explicit.
    if (origin != null) {
      throw ArgumentError('The PCMonitor host rejects upgrades carrying Origin');
    }
    request.write('\r\n');

    final Completer<void> ready = Completer<void>();
    final List<int> header = <int>[];

    // A `Socket` is a single-subscription stream - it can be listened to only
    // once, even after the first subscription is cancelled. So there is exactly
    // one subscription for the life of the connection, and it switches from
    // "buffer the upgrade response" to "parse frames" on a flag.
    socket.listen(
      (Uint8List chunk) {
        if (client._upgraded) {
          client._ingest(chunk);
          return;
        }
        if (ready.isCompleted) return;
        header.addAll(chunk);
        final int end = _headerEnd(header);
        if (end < 0) {
          if (header.length > 8192) {
            socket.destroy();
            if (!ready.isCompleted) {
              ready.completeError(
                WebSocketHandshakeException('Upgrade response header too large'),
              );
            }
          }
          return;
        }
        final String text = latin1.decode(header.sublist(0, end));
        final List<String> lines = text.split('\r\n');
        final Map<String, String> fields = <String, String>{};
        for (final String line in lines.skip(1)) {
          final int colon = line.indexOf(':');
          if (colon > 0) {
            fields[line.substring(0, colon).toLowerCase().trim()] =
                line.substring(colon + 1).trim();
          }
        }
        if (!lines.first.startsWith('HTTP/1.1 101')) {
          socket.destroy();
          if (!ready.isCompleted) {
            ready.completeError(WebSocketHandshakeException(
              'Server refused the upgrade: ${lines.first}',
            ));
          }
          return;
        }
        final String? accept = fields['sec-websocket-accept'];
        if (accept != webSocketAccept(key)) {
          socket.destroy();
          if (!ready.isCompleted) {
            ready.completeError(
              WebSocketHandshakeException('Bad Sec-WebSocket-Accept from server'),
            );
          }
          return;
        }
        // Anything after the header belongs to the first frame - the host sends
        // `pairing.challenge` immediately, often in the same TCP segment.
        final List<int> rest = header.sublist(end);
        header.clear();
        client._upgraded = true;
        client._keepAlive =
            Timer.periodic(keepAliveInterval, (_) => client._ping());
        ready.complete();
        if (rest.isNotEmpty) client._ingest(Uint8List.fromList(rest));
      },
      onError: (Object error) {
        if (!ready.isCompleted) {
          ready.completeError(
            WebSocketHandshakeException('Socket error during upgrade: $error'),
          );
        } else {
          client._terminate('socket error');
        }
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(
            WebSocketHandshakeException('Connection closed during upgrade'),
          );
        } else {
          client._terminate('closed by peer');
        }
      },
      cancelOnError: false,
    );

    // `add` writes straight through to the OS on a connected socket, and
    // `flush` is deliberately avoided here: a flush in flight is exactly what
    // makes a later write in the same microtask fail.
    socket.add(utf8.encode(request.toString()));

    try {
      await ready.future.timeout(timeout);
    } on TimeoutException {
      socket.destroy();
      throw WebSocketHandshakeException('Upgrade timed out');
    }
    return client;
  }

  // -------------------------------------------------------------------------
  // sending
  // -------------------------------------------------------------------------

  /// Sends one masked text frame (client -> server must mask, RFC 6455 §5.3).
  void sendText(String text) => _enqueue(_encodeFrame(_Opcode.text, utf8.encode(text)));

  void _ping() => _enqueue(_encodeFrame(_Opcode.ping, Uint8List(0)));

  /// Queues a fully encoded frame and makes sure a drain is scheduled.
  void _enqueue(List<int> frame) {
    if (_disposed) return;
    _outbox.add(frame);
    if (_drain != null) return;
    _drain = Timer(Duration.zero, _flushOutbox);
  }

  void _flushOutbox() {
    _drain = null;
    while (_outbox.isNotEmpty) {
      if (_disposed) {
        _outbox.clear();
        return;
      }
      final List<int> frame = _outbox.first;
      try {
        _socket.add(frame);
      } on StateError {
        // The sink is momentarily bound; put the frame back and come round on
        // the next event-loop turn, where it is always writable.
        _drain = Timer(Duration.zero, _flushOutbox);
        return;
      } on Object {
        _outbox.clear();
        _terminate('write failed');
        return;
      }
      _outbox.removeAt(0);
    }
  }

  /// Performs the closing handshake, then destroys the socket.
  Future<void> close([int code = 1000, String reason = '']) async {
    if (_disposed) return;
    final List<int> payload = <int>[(code >> 8) & 0xFF, code & 0xFF];
    payload.addAll(utf8.encode(reason));
    _enqueue(_encodeFrame(_Opcode.close, payload));
    // Long enough for the drain (one event-loop turn) to put the frame on the
    // wire before the socket is torn down.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await _destroy();
  }

  Future<void> _destroy() async {
    if (_disposed) return;
    _disposed = true;
    _drain?.cancel();
    _drain = null;
    _outbox.clear();
    _keepAlive?.cancel();
    _keepAlive = null;
    try {
      await _socket.close();
    } on Object {
      // Already gone.
    }
    _socket.destroy();
    if (!_messages.isClosed) await _messages.close();
    if (!_done.isCompleted) _done.complete();
  }

  void _terminate(String reason) {
    if (_disposed) return;
    _disposed = true;
    _drain?.cancel();
    _drain = null;
    _outbox.clear();
    _keepAlive?.cancel();
    _keepAlive = null;
    _socket.destroy();
    if (!_messages.isClosed) _messages.close();
    if (!_done.isCompleted) _done.complete();
  }

  // -------------------------------------------------------------------------
  // framing
  // -------------------------------------------------------------------------

  void _ingest(Uint8List chunk) {
    if (_disposed) return;
    _pending.addAll(chunk);
    while (_decodeOne() != null) {
      if (_disposed) break;
    }
  }

  /// Decodes one frame from the head of [_pending]. Returns the number of bytes
  /// consumed, or `null` when more data is needed.
  int? _decodeOne() {
    if (_pending.length < 2) return null;
    final int b0 = _pending[0];
    final int b1 = _pending[1];
    final bool fin = (b0 & 0x80) != 0;
    final int opcode = b0 & 0x0F;
    final bool masked = (b1 & 0x80) != 0;
    int length = b1 & 0x7F;
    int offset = 2;

    if (length == 126) {
      if (_pending.length < offset + 2) return null;
      length = (_pending[offset] << 8) | _pending[offset + 1];
      offset += 2;
    } else if (length == 127) {
      if (_pending.length < offset + 8) return null;
      int big = 0;
      for (int i = 0; i < 8; i++) {
        big = (big << 8) | _pending[offset + i];
      }
      length = big;
      offset += 8;
    }

    if (length < 0 || length > 1 << 20) {
      // Larger than the protocol's own limit; drop the connection.
      _terminate('frame too large');
      return null;
    }

    List<int>? mask;
    if (masked) {
      if (_pending.length < offset + 4) return null;
      mask = _pending.sublist(offset, offset + 4);
      offset += 4;
    }

    if (_pending.length < offset + length) return null;
    final Uint8List payload = Uint8List.fromList(
      _pending.sublist(offset, offset + length),
    );
    if (mask != null) {
      for (int i = 0; i < payload.length; i++) {
        payload[i] ^= mask[i & 3];
      }
    }
    _pending.removeRange(0, offset + length);
    _handleFrame(fin, opcode, payload);
    return offset + length;
  }

  void _handleFrame(bool fin, int opcode, Uint8List payload) {
    switch (opcode) {
      case _Opcode.ping:
        // Raw echo; the host pings with an empty payload.
        _enqueue(_encodeFrame(_Opcode.pong, payload));
      case _Opcode.pong:
        return;
      case _Opcode.close:
        if (payload.length >= 2) {
          closeCode = (payload[0] << 8) | payload[1];
          if (payload.length > 2) {
            closeReason = utf8.decode(payload.sublist(2), allowMalformed: true);
          }
        }
        // No close reply is written: the peer has already torn its side down,
        // so a reply would be best-effort at most, and a courtesy frame is not
        // what the host waits for.
            _terminate('closed by peer');
      case _Opcode.text:
      case _Opcode.binary:
      case _Opcode.continuation:
        if (opcode != _Opcode.continuation) _fragmentOpcode = opcode;
        _fragment.add(payload);
        if (!fin) return;
        final Uint8List whole = _fragment.toBytes();
        _fragment.clear();
        if (_fragmentOpcode == _Opcode.text) {
          if (!_messages.isClosed) {
            _messages.add(utf8.decode(whole, allowMalformed: true));
          }
        }
      default:
        // Reserved opcodes are ignored.
        return;
    }
  }

  static Uint8List _encodeFrame(int opcode, List<int> payload) {
    final int length = payload.length;
    final BytesBuilder out = BytesBuilder();
    out.addByte(0x80 | opcode);
    if (length < 126) {
      out.addByte(0x80 | length);
    } else if (length <= 0xFFFF) {
      out.addByte(0x80 | 126);
      out.addByte((length >>> 8) & 0xFF);
      out.addByte(length & 0xFF);
    } else {
      out.addByte(0x80 | 127);
      for (int i = 7; i >= 0; i--) {
        out.addByte((length >>> (i * 8)) & 0xFF);
      }
    }
    // The masking key is four bytes (RFC 6455 §5.3). Using the 16-byte
    // handshake key here would shift every frame by 12 bytes and the peer
    // would read the overlap as payload.
    final Uint8List mask = _frameMask();
    out.add(mask);
    final Uint8List masked = Uint8List(length);
    for (int i = 0; i < length; i++) {
      masked[i] = payload[i] ^ mask[i & 3];
    }
    out.add(masked);
    return out.toBytes();
  }

  /// Index just past the `\r\n\r\n` that ends the response headers, or -1.
  static int _headerEnd(List<int> bytes) {
    for (int i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i + 4;
      }
    }
    return -1;
  }

  /// A fresh 16-byte `Sec-WebSocket-Key` for the handshake.
  static Uint8List _randomKey() => _randomBytes(16);

  /// A fresh 4-byte frame masking key.
  static Uint8List _frameMask() => _randomBytes(4);

  static Uint8List _randomBytes(int count) {
    final math.Random random = math.Random.secure();
    final Uint8List out = Uint8List(count);
    for (int i = 0; i < count; i++) {
      out[i] = random.nextInt(256);
    }
    return out;
  }
}
