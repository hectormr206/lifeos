// Proves the pure freshness/group/cap assembler: today/yesterday kept, older
// dropped, undated dropped, newest-first, 10-per-source cap, and zero-fresh
// (or failed) sources recorded as skipped.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/data/source_content_extractor.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_assembler.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';

ParsedFeedItem _item(String title, DateTime? published) =>
    ParsedFeedItem(title: title, link: 'https://ex.com/$title', published: published);

void main() {
  const assembler = BriefingAssembler();
  // A local "now" (isUtc=false) so isFresh's toLocal() is a no-op → deterministic.
  final now = DateTime(2026, 7, 22, 9);
  final generatedAt = now;

  test('isFresh keeps today and yesterday, drops older and undated', () {
    expect(BriefingAssembler.isFresh(DateTime(2026, 7, 22, 1), now: now), isTrue);
    expect(BriefingAssembler.isFresh(DateTime(2026, 7, 21, 23), now: now), isTrue);
    expect(BriefingAssembler.isFresh(DateTime(2026, 7, 20, 23), now: now), isFalse);
    expect(BriefingAssembler.isFresh(null, now: now), isFalse);
  });

  test('groups fresh items newest-first and records skipped empty sources', () {
    final briefing = assembler.assemble([
      SourceHarvest(name: 'A', items: [
        _item('viejo', DateTime(2026, 7, 20)),
        _item('ayer', DateTime(2026, 7, 21, 8)),
        _item('hoy', DateTime(2026, 7, 22, 8)),
      ]),
      SourceHarvest(name: 'Vacia', items: [_item('rancio', DateTime(2026, 1, 1))]),
      const SourceHarvest(name: 'Caida', failed: true),
    ], now: now, generatedAt: generatedAt);

    final groupA = briefing.groups.single;
    expect(groupA.sourceName, 'A');
    expect(groupA.articles.map((a) => a.title), ['hoy', 'ayer'],
        reason: 'fresh only, newest first');
    expect(briefing.skippedSources, containsAll(['Vacia', 'Caida']));
  });

  test('caps at 10 items per source', () {
    final items = List.generate(
        14, (i) => _item('n$i', DateTime(2026, 7, 22, 0, i)));
    final briefing = assembler.assemble(
      [SourceHarvest(name: 'Prolija', items: items)],
      now: now,
      generatedAt: generatedAt,
    );
    expect(briefing.groups.single.articles.length, 10);
  });

  test('JSON round-trips through encode/decode', () {
    final briefing = assembler.assemble([
      SourceHarvest(name: 'A', items: [_item('hoy', DateTime.utc(2026, 7, 22, 8))]),
    ], now: now, generatedAt: DateTime(2026, 7, 22, 9));
    final roundTripped = OnDeviceBriefing.decode(briefing.encode());
    expect(roundTripped, isNotNull);
    expect(roundTripped!.articles.single.title, 'hoy');
  });
}
