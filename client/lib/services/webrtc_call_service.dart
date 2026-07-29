import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/c2_message.dart' as c2;
import '../models/operator_profile.dart';
import 'ice_configuration.dart';
import 'mesh_client.dart';
import 'p2p_mesh_engine.dart';
import 'secure_channel.dart';

enum CallMedia { voice, video }

enum CallState { idle, dialing, ringing, connecting, connected, ended }

/// Reason a call finished, for the event log.
enum CallEndReason { hangup, declined, failed, peerGone }

/// WebRtcCallService runs real-time voice and video calls over WebRTC.
///
/// Media travels peer-to-peer as DTLS-SRTP, not through the relay. The DTLS
/// fingerprint is inside the SDP, and the SDP travels inside a sealed, signed
/// envelope on [SecureChannel] — so the fingerprint exchange is authenticated
/// and the media is end-to-end encrypted to an operator whose identity has
/// already been proven. A relay that tampers with signalling breaks the
/// envelope signature; one that passes it through cannot decrypt the media.
///
/// This replaces the previous "record 600ms chunks, base64 them into JSON, and
/// push them through the relay" approach for live calls, which had no jitter
/// buffer, no echo cancellation, and sent every packet through the server.
/// Push-to-talk clips still use the store-and-forward path, which is the right
/// model for a message that must survive the recipient being offline.
class WebRtcCallService {
  /// Public STUN, and no TURN unless a deployment asks for it.
  ///
  /// This is a deliberate default, not an omission: a call between two peers
  /// both behind symmetric NAT fails visibly rather than silently relaying media
  /// through a third party. Deployments that need calls across arbitrary carrier
  /// networks configure TURN with --dart-define rather than editing this file,
  /// so the trade is recorded where the deployment is described. What a TURN
  /// relay learns is spelled out in IceConfiguration and in SECURITY.md.
  static const String _stunServersEnv = String.fromEnvironment(
    'STUN_SERVERS',
    defaultValue: 'stun:stun.l.google.com:19302,stun:stun1.l.google.com:19302',
  );
  static const String _turnUrlsEnv =
      String.fromEnvironment('TURN_URLS', defaultValue: '');
  static const String _turnUsernameEnv =
      String.fromEnvironment('TURN_USERNAME', defaultValue: '');
  static const String _turnCredentialEnv =
      String.fromEnvironment('TURN_CREDENTIAL', defaultValue: '');

  static IceConfiguration get iceConfiguration => IceConfiguration.fromDefines(
        stunServers: _stunServersEnv,
        turnUrls: _turnUrlsEnv,
        turnUsername: _turnUsernameEnv,
        turnCredential: _turnCredentialEnv,
      );

  final SecureChannel channel;
  final MeshClient meshClient;
  final P2PMeshEngine p2pMeshEngine;

  /// Overridable so tests can drive ICE configuration without a rebuild.
  final IceConfiguration ice;

  WebRtcCallService({
    required this.channel,
    required this.meshClient,
    required this.p2pMeshEngine,
    IceConfiguration? ice,
  }) : ice = ice ?? iceConfiguration;

  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  OperatorProfile? _peerProfile;
  CallMedia _media = CallMedia.voice;
  bool _isCaller = false;

  /// ICE candidates that arrived before the remote description was set. Setting
  /// a candidate before the description throws, and candidates routinely arrive
  /// first.
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  final _stateController = StreamController<CallState>.broadcast();
  final _renderersController = StreamController<void>.broadcast();
  final _endedController = StreamController<CallEndReason>.broadcast();

  Stream<CallState> get stateChanges => _stateController.stream;
  Stream<void> get renderersChanged => _renderersController.stream;
  Stream<CallEndReason> get callEnded => _endedController.stream;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;

  /// Measures setup from the first user action to hearing the other end.
  final Stopwatch _setupClock = Stopwatch();

  CallState _state = CallState.idle;
  CallState get state => _state;
  OperatorProfile? get peerProfile => _peerProfile;
  CallMedia get media => _media;
  bool get isVideo => _media == CallMedia.video;

  bool _isMuted = false;
  bool _isCameraOff = false;
  bool get isMuted => _isMuted;
  bool get isCameraOff => _isCameraOff;

  /// Where call audio is routed. Owned here rather than by the UI: the shell
  /// used to hold its own flag defaulting to loudspeaker, so a voice call came
  /// up on speaker no matter what the service had asked for.
  bool _speakerphone = false;
  bool get isSpeakerphone => _speakerphone;

  Future<void> initRenderers() async {
    if (_renderersReady) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersReady = true;
  }

  void _setState(CallState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  /// Places a call to [peer].
  Future<void> startCall(OperatorProfile peer, CallMedia media) async {
    if (_state != CallState.idle && _state != CallState.ended) return;

    await initRenderers();
    _setupClock
      ..reset()
      ..start();

    _peerProfile = peer;
    _media = media;
    _isCaller = true;
    _setState(CallState.dialing);

    // Put the audio route in place now rather than when media starts, so the
    // platform is not switching modes at the moment the call connects.
    unawaited(_applyDefaultAudioRoute());

    try {
      await _createPeerConnection();
      await _attachLocalMedia();

      final offer = await _peer!.createOffer();
      await _peer!.setLocalDescription(offer);

      await _sendSignal({
        'action': media == CallMedia.video ? 'CALL_INITIATE_VIDEO' : 'CALL_INITIATE_VOICE',
        'sdp': offer.sdp,
        'sdp_type': offer.type,
      });
      debugPrint('[CALL] Offer away at ${_setupClock.elapsedMilliseconds}ms');
    } catch (e) {
      debugPrint('[CALL] Failed to start: $e');
      await _teardown(CallEndReason.failed);
    }
  }

  /// Answers the offer captured when the invitation arrived.
  Future<void> acceptCall() async {
    if (_state != CallState.ringing || _peer == null) return;
    _setState(CallState.connecting);
    _setupClock
      ..reset()
      ..start();

    try {
      // Acquire the microphone and set the audio route together: the route
      // does not depend on the tracks, so there is no reason to serialise them.
      await Future.wait([_attachLocalMedia(), _applyDefaultAudioRoute()]);
      debugPrint('[CALL] Local media ready at ${_setupClock.elapsedMilliseconds}ms');

      final answer = await _peer!.createAnswer();
      await _peer!.setLocalDescription(answer);

      await _sendSignal({
        'action': 'CALL_ACCEPT',
        'sdp': answer.sdp,
        'sdp_type': answer.type,
      });
      // Anything already gathered goes with the answer rather than trailing it.
      _flushCandidates();
    } catch (e) {
      debugPrint('[CALL] Failed to accept: $e');
      await _teardown(CallEndReason.failed);
    }
  }

  Future<void> declineCall() async {
    if (_peerProfile == null) return;
    await _sendSignal({'action': 'CALL_DECLINE'});
    await _teardown(CallEndReason.declined);
  }

  Future<void> hangUp() async {
    if (_peerProfile == null) return;
    await _sendSignal({'action': 'CALL_END'});
    await _teardown(CallEndReason.hangup);
  }

  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    for (final track in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !_isMuted;
    }
    if (!_renderersController.isClosed) _renderersController.add(null);
  }

  Future<void> toggleCamera() async {
    if (!isVideo) return;
    _isCameraOff = !_isCameraOff;
    for (final track in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !_isCameraOff;
    }
    if (!_renderersController.isClosed) _renderersController.add(null);
  }

  Future<void> switchCamera() async {
    final videoTracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (videoTracks.isEmpty) return;
    await Helper.switchCamera(videoTracks.first);
  }

  Future<void> setSpeakerphone(bool enabled) async {
    _speakerphone = enabled;
    try {
      await Helper.setSpeakerphoneOn(enabled);
    } catch (e) {
      debugPrint('[CALL] Speakerphone toggle failed: $e');
    }
    if (!_renderersController.isClosed) _renderersController.add(null);
  }

  /// Candidates waiting to be sent, and the timer that will flush them.
  ///
  /// A typical negotiation produces a dozen or more candidates. Sealing and
  /// signing each one separately meant a dozen envelopes, a dozen signature
  /// verifications at the far end, and a dozen round trips — all of it on the
  /// critical path to hearing the other person.
  final List<Map<String, dynamic>> _pendingLocalCandidates = [];
  Timer? _candidateFlushTimer;

  void _queueCandidate(RTCIceCandidate candidate) {
    if (candidate.candidate == null) return;

    _pendingLocalCandidates.add({
      'candidate': candidate.candidate,
      'sdp_mid': candidate.sdpMid,
      'sdp_mline_index': candidate.sdpMLineIndex,
    });

    // Host candidates arrive together and immediately; a short window collects
    // them into one message without delaying the first, which is usually the
    // one that connects on a local network.
    _candidateFlushTimer?.cancel();
    _candidateFlushTimer = Timer(const Duration(milliseconds: 40), _flushCandidates);
  }

  void _flushCandidates() {
    _candidateFlushTimer?.cancel();
    _candidateFlushTimer = null;
    if (_pendingLocalCandidates.isEmpty) return;

    final batch = List<Map<String, dynamic>>.from(_pendingLocalCandidates);
    _pendingLocalCandidates.clear();
    _sendSignal({'action': 'CALL_ICE', 'candidates': batch});
  }

  /// Re-applies the call's audio route. Exposed so the shell can re-assert it
  /// after the ringtone player has released the audio session.
  Future<void> applyDefaultAudioRoute() => _applyDefaultAudioRoute();

  /// Routes call audio the way a phone does: voice to the earpiece, video to
  /// the loudspeaker because the device is being held away from the face.
  ///
  /// Applied twice on purpose. The first call is a head start; the second, once
  /// the connection is up, is authoritative — by then WebRTC owns the audio
  /// session, and anything the ringback tone or the push-to-talk player left
  /// behind has been superseded.
  Future<void> _applyDefaultAudioRoute() async {
    await setSpeakerphone(_media == CallMedia.video);
  }

  Future<void> _createPeerConnection() async {
    _peer = await createPeerConnection({
      'iceServers': ice.toRtcIceServers(),
      'sdpSemantics': 'unified-plan',
      // Start gathering before there is an offer to attach candidates to.
      // Without this, gathering only begins at setLocalDescription and the
      // first seconds of a call are spent waiting on STUN.
      'iceCandidatePoolSize': 4,
      // One transport for audio and video, and RTCP muxed onto it: fewer
      // candidate pairs to nominate, so connectivity checks finish sooner.
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
    });

    _peer!.onIceCandidate = _queueCandidate;

    _peer!.onTrack = (event) {
      if (event.streams.isEmpty) return;
      remoteRenderer.srcObject = event.streams.first;
      if (!_renderersController.isClosed) _renderersController.add(null);
    };

    _peer!.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          debugPrint('[CALL] Media path up at ${_setupClock.elapsedMilliseconds}ms');
          _setupClock.stop();
          // Authoritative: WebRTC now owns the audio session, so this is the
          // point at which the route actually sticks.
          unawaited(_applyDefaultAudioRoute());
          _setState(CallState.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          // No TURN is configured, so this is the expected outcome when both
          // peers are behind restrictive NAT. Surfaced rather than left hanging.
          _teardown(CallEndReason.failed);
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          if (_state == CallState.connected) _teardown(CallEndReason.peerGone);
        default:
          break;
      }
    };
  }

  Future<void> _attachLocalMedia() async {
    if (_localStream != null) return;

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': isVideo
          ? {
              'facingMode': 'user',
              'width': {'ideal': 640},
              'height': {'ideal': 480},
              'frameRate': {'ideal': 24},
            }
          : false,
    });

    for (final track in _localStream!.getTracks()) {
      await _peer!.addTrack(track, _localStream!);
    }

    localRenderer.srcObject = _localStream;
    if (!_renderersController.isClosed) _renderersController.add(null);
  }

  /// Handles a verified, decrypted call-signalling payload.
  ///
  /// The caller has already established that [from] is a paired contact whose
  /// signature checked out, so this only has to deal with protocol state.
  Future<void> handleSignal(Map<String, dynamic> payload, OperatorProfile from) async {
    final action = payload['action'] as String?;

    switch (action) {
      case 'CALL_INITIATE_VOICE':
      case 'CALL_INITIATE_VIDEO':
        // Reject a second invitation while already engaged, rather than
        // trampling the call in progress.
        if (_state != CallState.idle && _state != CallState.ended) {
          await _sendSignalTo(from, {'action': 'CALL_DECLINE'});
          return;
        }

        await initRenderers();
        _peerProfile = from;
        _media = action == 'CALL_INITIATE_VIDEO' ? CallMedia.video : CallMedia.voice;
        _isCaller = false;

        await _createPeerConnection();
        await _applyRemoteDescription(payload);
        _setState(CallState.ringing);

      case 'CALL_ACCEPT':
        if (!_isCaller || _peer == null) return;
        await _applyRemoteDescription(payload);
        _setState(CallState.connecting);

      case 'CALL_ICE':
        if (_peer == null) return;

        // Accepts a batch, and still understands the one-per-message form a
        // peer on an older build will send.
        final raw = payload['candidates'];
        final incoming = raw is List
            ? raw.cast<Map<String, dynamic>>()
            : [
                {
                  'candidate': payload['candidate'],
                  'sdp_mid': payload['sdp_mid'],
                  'sdp_mline_index': payload['sdp_mline_index'],
                }
              ];

        final ready = await _peer!.getRemoteDescription() != null;
        for (final c in incoming) {
          final candidate = RTCIceCandidate(
            c['candidate'] as String?,
            c['sdp_mid'] as String?,
            c['sdp_mline_index'] as int?,
          );
          if (ready) {
            await _peer!.addCandidate(candidate);
          } else {
            _pendingRemoteCandidates.add(candidate);
          }
        }

      case 'CALL_DECLINE':
        await _teardown(CallEndReason.declined);

      case 'CALL_END':
        await _teardown(CallEndReason.hangup);
    }
  }

  Future<void> _applyRemoteDescription(Map<String, dynamic> payload) async {
    final sdp = payload['sdp'] as String?;
    final type = payload['sdp_type'] as String?;
    if (sdp == null || type == null || _peer == null) return;

    await _peer!.setRemoteDescription(RTCSessionDescription(sdp, type));

    for (final candidate in _pendingRemoteCandidates) {
      await _peer!.addCandidate(candidate);
    }
    _pendingRemoteCandidates.clear();
  }

  Future<void> _sendSignal(Map<String, dynamic> payload) async {
    final peer = _peerProfile;
    if (peer == null) return;
    await _sendSignalTo(peer, payload);
  }

  Future<void> _sendSignalTo(OperatorProfile peer, Map<String, dynamic> payload) async {
    try {
      final envelope = await channel.sealDirect(
        type: c2.MessageType.callSignaling,
        recipient: peer,
        plaintext: jsonEncode(payload),
        idPrefix: 'call',
      );
      final sentMesh = meshClient.sendMessage(envelope);
      final sentP2P = p2pMeshEngine.sendP2PDirectMessage(envelope);

      if (!sentMesh && !sentP2P) {
        debugPrint('[CALL] No transport available for ${payload['action']}');
      }
    } catch (e) {
      debugPrint('[CALL] Failed to seal ${payload['action']}: $e');
    }
  }

  Future<void> _teardown(CallEndReason reason) async {
    if (_state == CallState.idle) return;

    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _localStream?.dispose();
    _localStream = null;

    await _peer?.close();
    _peer = null;

    _candidateFlushTimer?.cancel();
    _candidateFlushTimer = null;
    _pendingLocalCandidates.clear();

    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    _pendingRemoteCandidates.clear();
    _peerProfile = null;
    _isMuted = false;
    _isCameraOff = false;
    _speakerphone = false;
    _isCaller = false;

    _setState(CallState.ended);
    if (!_endedController.isClosed) _endedController.add(reason);
    if (!_renderersController.isClosed) _renderersController.add(null);
    _setState(CallState.idle);
  }

  Future<void> dispose() async {
    await _teardown(CallEndReason.hangup);
    await localRenderer.dispose();
    await remoteRenderer.dispose();
    await _stateController.close();
    await _renderersController.close();
    await _endedController.close();
  }
}
