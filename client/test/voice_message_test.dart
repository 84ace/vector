import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_c2/models/c2_message.dart';
import 'package:vector_c2/services/ptt_audio_service.dart';
import 'package:vector_c2/ui/comms/voice_message_bubble.dart';

/// Voice transmissions carry their audio inside the message body, so the bubble
/// decodes what it renders. That parsing is the part most likely to break as
/// the payload evolves.
void main() {
  C2Message voice({
    String audio = 'QUJDRA==',
    int durationMs = 7000,
    String id = 'clip-1',
    bool mine = false,
  }) =>
      C2Message(
        id: id,
        type: MessageType.callSignaling,
        senderId: mine ? 'op-me' : 'op-alpha',
        encryptedBody: 'cipher',
        decryptedBody: 'PTT_STOP:${jsonEncode({
              'action': 'PTT_STOP',
              'audio_base64': audio,
              'duration_ms': durationMs,
              'callsign': 'ALPHA-1',
            })}',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        isMe: mine,
      );

  C2Message plain(String body) => C2Message(
        id: 'm1',
        type: MessageType.chat1to1,
        senderId: 'op-alpha',
        encryptedBody: 'cipher',
        decryptedBody: body,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  group('payload decoding', () {
    test('extracts audio and duration from a transmission', () {
      final payload = VoiceMessageBubble.payloadOf(voice());
      expect(payload, isNotNull);
      expect(payload!.duration, const Duration(seconds: 7));
      expect(payload.audio, isNotEmpty);
    });

    test('a text message is not a transmission', () {
      expect(VoiceMessageBubble.payloadOf(plain('rally at grid 41')), isNull);
    });

    test('malformed payloads are refused rather than thrown', () {
      expect(VoiceMessageBubble.payloadOf(plain('PTT_STOP:not json')), isNull);
      expect(VoiceMessageBubble.payloadOf(plain('PTT_STOP:{}')), isNull);
      expect(VoiceMessageBubble.payloadOf(voice(audio: '')), isNull);
    });

    test('a missing duration does not prevent playback', () {
      final msg = plain('PTT_STOP:${jsonEncode({'audio_base64': 'QUJDRA=='})}');
      final payload = VoiceMessageBubble.payloadOf(msg);
      expect(payload, isNotNull);
      expect(payload!.duration, Duration.zero);
    });
  });

  group('rendering', () {
    Future<void> pump(WidgetTester tester, C2Message msg, {Size? size}) async {
      if (size != null) {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: VoiceMessageBubble(
                message: msg,
                accent: Colors.cyanAccent,
                mine: msg.isMe,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('shows a play control and the clip length', (tester) async {
      await pump(tester, voice(durationMs: 7000));
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.text('00:07'), findsOneWidget);
    });

    testWidgets('renders on a narrow screen without overflowing', (tester) async {
      await pump(tester, voice(durationMs: 605000), size: const Size(320, 568));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unusable payload degrades instead of crashing', (tester) async {
      await pump(tester, plain('PTT_STOP:garbage'));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('unavailable'), findsOneWidget);
    });

    testWidgets('the waveform is stable for a given message', (tester) async {
      // Bars derive from the message ID, so a clip must not reshuffle on every
      // rebuild while it plays.
      await pump(tester, voice(id: 'clip-stable'));
      final first = tester.widgetList<Container>(find.byType(Container)).length;
      await tester.pump();
      final second = tester.widgetList<Container>(find.byType(Container)).length;
      expect(first, second);
    });
  });

  tearDown(() {
    PttAudioService.playingClipId.value = null;
    PttAudioService.playbackPosition.value = Duration.zero;
    PttAudioService.playbackDuration.value = Duration.zero;
  });
}
