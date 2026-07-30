import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_c2/models/operator_profile.dart';
import 'package:vector_c2/models/telemetry.dart';
import 'package:vector_c2/ui/map/offscreen_member_layer.dart';

void main() {
  OperatorProfile op(String id, String callsign) => OperatorProfile(
        id: id,
        callsign: callsign,
        name: callsign,
        role: OperatorRole.operator,
        avatarBase64: '',
        signPublicKey: 'sign-$id',
        kexPublicKey: 'kex-$id',
        lastSeen: DateTime.now(),
      );

  Telemetry at(double lat, double lng, {Duration age = Duration.zero}) => Telemetry(
        operatorId: 'op',
        latitude: lat,
        longitude: lng,
        altitude: 0,
        speed: 0,
        heading: 0,
        accuracy: 5,
        batteryLevel: 90,
        isCharging: false,
        networkType: NetworkType.wifi,
        cellularSignalBars: 0,
        wifiSSID: '',
        timestamp: DateTime.now().subtract(age),
        reportInterval: const Duration(minutes: 10),
      );

  Future<void> pumpMap(
    WidgetTester tester,
    List<MemberFix> members, {
    LatLng? myPosition,
    String? locked,
    void Function(OperatorProfile)? onTap,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: FlutterMap(
          options: const MapOptions(
            initialCenter: LatLng(0, 0),
            initialZoom: 16,
          ),
          children: [
            OffscreenMemberLayer(
              members: members,
              myPosition: myPosition,
              lockedOperatorId: locked,
              onTap: onTap ?? (_) {},
            ),
          ],
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a member outside the viewport gets an edge chevron', (tester) async {
    // Half a degree away is roughly 55km, far outside a zoom-16 viewport.
    await pumpMap(tester, [MemberFix(op('op-a', 'ALPHA'), at(0.5, 0.5))]);

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.navigation), findsOneWidget);
    expect(find.text('ALPHA'), findsOneWidget);
  });

  testWidgets('a member inside the viewport gets no chevron', (tester) async {
    // The real marker layer draws this one; two indicators for one operator
    // would read as two operators.
    await pumpMap(tester, [MemberFix(op('op-a', 'ALPHA'), at(0, 0))]);

    expect(find.byIcon(Icons.navigation), findsNothing);
    expect(find.text('ALPHA'), findsNothing);
  });

  testWidgets('range is shown only when this device has a fix', (tester) async {
    await pumpMap(
      tester,
      [MemberFix(op('op-a', 'ALPHA'), at(0.5, 0))],
      myPosition: const LatLng(0, 0),
    );
    expect(find.textContaining('km'), findsOneWidget);

    await pumpMap(tester, [MemberFix(op('op-a', 'ALPHA'), at(0.5, 0))]);
    expect(find.textContaining('km'), findsNothing);
  });

  testWidgets('chevrons stay inside the viewport on every bearing', (tester) async {
    // The clamp divides by the offset from centre, so a member due north or due
    // east — where one component is zero — is the case that would produce an
    // infinite coordinate and throw during layout.
    await pumpMap(tester, [
      MemberFix(op('op-n', 'NORTH'), at(0.5, 0)),
      MemberFix(op('op-s', 'SOUTH'), at(-0.5, 0)),
      MemberFix(op('op-e', 'EAST'), at(0, 0.5)),
      MemberFix(op('op-w', 'WEST'), at(0, -0.5)),
      MemberFix(op('op-ne', 'NE'), at(0.5, 0.5)),
    ]);

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.navigation), findsNWidgets(5));

    for (final callsign in ['NORTH', 'SOUTH', 'EAST', 'WEST', 'NE']) {
      final box = tester.getRect(find.text(callsign));
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.top, greaterThanOrEqualTo(0));
      expect(box.right, lessThanOrEqualTo(800));
      expect(box.bottom, lessThanOrEqualTo(600));
    }
  });

  testWidgets('tapping a chevron reports which operator it was', (tester) async {
    OperatorProfile? tapped;
    await pumpMap(
      tester,
      [MemberFix(op('op-a', 'ALPHA'), at(0.5, 0.5))],
      onTap: (p) => tapped = p,
    );

    await tester.tap(find.byIcon(Icons.navigation));
    await tester.pump();
    expect(tapped?.callsign, 'ALPHA');
  });

  testWidgets('no members means nothing is drawn over the map', (tester) async {
    await pumpMap(tester, const []);
    expect(find.byIcon(Icons.navigation), findsNothing);
  });
}
