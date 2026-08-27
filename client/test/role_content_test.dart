// FR37 / E1 — `data/role_content.dart` is the one sanctioned crossing point
// for a role's own content outside `RevealResolver` (gate 1 of
// `tools/ci/reveal_gate_lint.sh` forbids Presentation from reading
// `Role.note`/`Role.media` directly).
import 'package:flutter_test/flutter_test.dart';

import 'package:plotlines_client/data/role_content.dart';
import 'package:plotlines_client/domain/domain.dart';

void main() {
  test('loadRoleContent copies note and media as-is', () {
    final role = Role(
      id: 'r1',
      kind: RoleKind.narrative,
      note: 'A vista.',
      media: [MediaRef(id: 'm1', kind: 'image', path: 'p.jpg')],
    );
    final draft = loadRoleContent(role);
    expect(draft.note, 'A vista.');
    expect(draft.media.single.path, 'p.jpg');
    expect(draft.hasContent, isTrue);
  });

  test('hasContent is false for a role with neither note nor media', () {
    final role = Role(id: 'r1', kind: RoleKind.station);
    expect(loadRoleContent(role).hasContent, isFalse);
  });

  test('hasContent is true with media alone, or note alone', () {
    expect(
      loadRoleContent(Role(id: 'r1', kind: RoleKind.station, note: 'x')).hasContent,
      isTrue,
    );
    expect(
      loadRoleContent(Role(
        id: 'r1',
        kind: RoleKind.station,
        media: [MediaRef(id: 'm1', kind: 'image', path: 'p.jpg')],
      )).hasContent,
      isTrue,
    );
  });
}
