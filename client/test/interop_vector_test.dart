import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/crypto/operator_identity.dart';

/// Emits a signed challenge response for the Go relay's verifier to check.
///
/// The Dart client and the Go node each derive operator IDs and verify
/// signatures independently. If those two implementations ever disagree — on
/// base64 alphabet, digest truncation, or signed bytes — no client can connect,
/// and neither unit suite would notice on its own.
void main() {
  test('emit interop vector for the Go relay', () async {
    final identity = await OperatorIdentity.forTesting();
    final nonce = base64Decode('YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3OA==');

    final vector = {
      'operator_id': identity.operatorId,
      'sign_key': identity.signPublicKey,
      'nonce': base64Encode(nonce),
      'signature': await identity.sign(nonce),
    };

    final out = Platform.environment['INTEROP_OUT'];
    if (out != null) File(out).writeAsStringSync(jsonEncode(vector));
    expect(vector['operator_id'], startsWith('op-'));
  });
}
