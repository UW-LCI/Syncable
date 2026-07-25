import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncable_properties/syncable_properties.dart';

void main() {
  group('Serialization round-trip', () {
    test('ValueSetChange', () {
      final change = ValueSetChange<String>(
        propertyKey: 'title',
        nodeId: 'node1',
        lamportClock: 42,
        value: 'hello',
      );
      final json = serializeChange(change);
      final restored = deserializeChange(jsonDecode(json));
      expect(restored, isA<ValueSetChange>());
      final vc = restored as ValueSetChange;
      expect(vc.propertyKey, 'title');
      expect(vc.nodeId, 'node1');
      expect(vc.lamportClock, 42);
      expect(vc.value, 'hello');
    });

    test('ListInsertChange', () {
      final change = ListInsertChange<String>(
        propertyKey: 'items',
        nodeId: 'node1',
        lamportClock: 5,
        elementId: const ElementId('node1', 3),
        value: 'item',
        afterElementId: const ElementId('node1', 2),
        position: 0.75,
      );
      final json = serializeChange(change);
      final restored = deserializeChange(jsonDecode(json));
      expect(restored, isA<ListInsertChange>());
      final lic = restored as ListInsertChange;
      expect(lic.propertyKey, 'items');
      expect(lic.elementId, const ElementId('node1', 3));
      expect(lic.value, 'item');
      expect(lic.afterElementId, const ElementId('node1', 2));
      expect(lic.position, 0.75);
    });

    test('ListInsertChange without afterElementId', () {
      final change = ListInsertChange<int>(
        propertyKey: 'nums',
        nodeId: 'node2',
        lamportClock: 1,
        elementId: const ElementId('node2', 0),
        value: 42,
        position: 0.5,
      );
      final json = serializeChange(change);
      final restored = deserializeChange(jsonDecode(json));
      expect(restored, isA<ListInsertChange>());
      final lic = restored as ListInsertChange;
      expect(lic.afterElementId, isNull);
      expect(lic.position, 0.5);
      expect(lic.value, 42);
    });

    test('ListRemoveChange', () {
      final change = ListRemoveChange<String>(
        propertyKey: 'items',
        nodeId: 'node1',
        lamportClock: 10,
        elementId: const ElementId('node1', 0),
      );
      final json = serializeChange(change);
      final restored = deserializeChange(jsonDecode(json));
      expect(restored, isA<ListRemoveChange>());
      final lrc = restored as ListRemoveChange;
      expect(lrc.propertyKey, 'items');
      expect(lrc.elementId, const ElementId('node1', 0));
    });

    test('ListUpdateChange', () {
      final change = ListUpdateChange<String>(
        propertyKey: 'items',
        nodeId: 'node1',
        lamportClock: 7,
        elementId: const ElementId('node1', 5),
        value: 'updated',
      );
      final json = serializeChange(change);
      final restored = deserializeChange(jsonDecode(json));
      expect(restored, isA<ListUpdateChange>());
      final luc = restored as ListUpdateChange;
      expect(luc.propertyKey, 'items');
      expect(luc.elementId, const ElementId('node1', 5));
      expect(luc.value, 'updated');
    });

    test('envelope round-trip preserves instanceId', () {
      final change = ValueSetChange<String>(
        propertyKey: 'title',
        nodeId: 'node1',
        lamportClock: 1,
        value: 'hello',
      );
      final json = serializeEnvelope('doc-a', change);
      final envelope = deserializeEnvelope(jsonDecode(json));
      expect(envelope.instanceId, 'doc-a');
      expect((envelope.change as ValueSetChange).value, 'hello');
    });

    test('deserializeEnvelope tolerates missing instanceId', () {
      final change = ValueSetChange<String>(
        propertyKey: 'title',
        nodeId: 'node1',
        lamportClock: 1,
        value: 'hello',
      );
      final envelope = deserializeEnvelope(jsonDecode(serializeChange(change)));
      expect(envelope.instanceId, isNull);
      expect((envelope.change as ValueSetChange).value, 'hello');
    });
  });
}
