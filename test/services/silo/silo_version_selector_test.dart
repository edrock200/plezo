import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/services/silo/silo_version_selector.dart';

/// Ports of silo-android `DetailVersionSelectorTest` (#899): Edition picks the
/// cut, Version Auto the best file in it for the quality preference.
Map<String, dynamic> _file(
  int id, {
  String? resolution,
  String? key,
  String? raw,
  bool hdr = false,
  int size = 0,
  int bitrate = 0,
  String? kind,
  int? part,
}) => {
  'file_id': '$id',
  'resolution': ?resolution,
  'edition_key': ?key,
  'edition_raw': ?raw,
  'hdr': hdr,
  'file_size': size,
  'bitrate': bitrate,
  'presentation_kind': ?kind,
  'presentation_part_index': ?part,
};

void main() {
  // The issue's example: Theatrical in 4K and 1080p, Extended in 1080p only.
  final theatrical4k = _file(1, resolution: '2160p', raw: 'Theatrical', key: 'theatrical');
  final theatrical1080 = _file(2, resolution: '1080p', raw: 'Theatrical', key: 'theatrical');
  final extended1080 = _file(3, resolution: '1080p', raw: 'Extended', key: 'extended');
  final versions = [extended1080, theatrical1080, theatrical4k];

  // Ranks as Silo's preference strings do: 2160p = 4, 1080p = 3, 720p = 2, 480p = 1, Auto = null.
  int? cap(String? quality) => switch (quality) {
    '2160p' => 4,
    '1080p' => 3,
    '720p' => 2,
    '480p' => 1,
    _ => null,
  };

  String? select({
    String? pinnedFileId,
    String? editionId,
    String? lastFileId,
    String? lastEditionKey,
    bool inProgress = false,
    String? preferredQuality = '2160p',
    List<Map<String, dynamic>>? files,
    List<Map<String, dynamic>>? variants,
  }) {
    final list = files ?? versions;
    final index = SiloVersionSelector.select(
      versions: list,
      variants: variants,
      pinnedFileId: pinnedFileId,
      editionId: editionId,
      lastFileId: lastFileId,
      lastEditionKey: lastEditionKey,
      inProgress: inProgress,
      capRank: cap(preferredQuality),
    );
    return index < 0 ? null : list[index]['file_id'] as String;
  }

  test('nothing played opens on the edition holding the best file', () {
    expect(select(), '1');
  });

  test('a picked edition keeps Auto inside it even when another cut is better', () {
    expect(select(editionId: 'extended'), '3');
  });

  test('the last-played edition opens with its best file for the preference', () {
    expect(select(lastFileId: '3'), '3');
    // Last played the Theatrical 1080p file: the cut comes from history, the file from the preference.
    expect(select(lastFileId: '2'), '1');
    // The last file is gone; its edition key still names the cut.
    expect(select(lastFileId: '99', lastEditionKey: 'extended'), '3');
    // The edition key wins over the last file's edition; a key no edition has falls back to the file.
    expect(select(lastFileId: '3', lastEditionKey: 'theatrical'), '1');
    expect(select(lastFileId: '3', lastEditionKey: 'imax'), '3');
    // A present "" names the unnamed edition.
    expect(
      select(
        lastFileId: '3',
        lastEditionKey: '',
        files: [
          ...versions,
          _file(5, resolution: '720p'),
        ],
      ),
      '5',
    );
  });

  test('Auto breaks resolution ties on HDR then file size, not bitrate', () {
    final sdrBig = _file(1, resolution: '1080p', size: 9000, bitrate: 90000);
    final hdrSmall = _file(2, resolution: '1080p', hdr: true, size: 1000);
    final sdrSmall = _file(3, resolution: '1080p', size: 1000, bitrate: 99000);
    expect(select(files: [sdrBig, sdrSmall, hdrSmall]), '2');
    expect(select(files: [sdrSmall, sdrBig]), '1');
    // Equal on everything the server sorts by: list order.
    expect(
      select(
        files: [
          sdrSmall,
          _file(1, resolution: '1080p', size: 1000, bitrate: 90000),
        ],
      ),
      '3',
    );
  });

  test('an unknown resolution is a last resort', () {
    final unknown = _file(1, size: 9000);
    final above = _file(2, resolution: '2160p');
    expect(select(files: [unknown, above], preferredQuality: '1080p'), '2');
    expect(select(files: [unknown, above], preferredQuality: 'auto'), '2');
    expect(
      select(
        files: [
          unknown,
          _file(3, resolution: '1440p'),
        ],
        preferredQuality: '1080p',
      ),
      '1',
    );
  });

  test('with no history each cut\'s Auto file is compared across cuts', () {
    Map<String, dynamic> cut(int id, String? key, String resolution, {bool hdr = false, int size = 1}) =>
        _file(id, resolution: resolution, hdr: hdr, size: size, key: key, raw: key);
    // A cut with a file within the cap beats one only above it.
    expect(select(preferredQuality: '1080p', files: [cut(1, 'imax', '2160p'), cut(2, 'extended', '720p')]), '2');
    // Above the cap, the closer one wins.
    expect(select(preferredQuality: '480p', files: [cut(1, 'imax', '2160p'), cut(2, 'extended', '720p')]), '2');
    // Same resolution: HDR, then edition preference (unnamed or standard, then theatrical); never file size.
    expect(select(files: [cut(1, 'theatrical', '1080p'), cut(2, 'directors_cut', '1080p', hdr: true)]), '2');
    expect(select(files: [cut(1, 'directors_cut', '1080p', size: 9000), cut(2, 'theatrical', '1080p')]), '2');
    expect(select(files: [cut(1, 'theatrical', '1080p'), cut(2, null, '1080p')]), '2');
    expect(select(files: [cut(1, 'theatrical', '1080p'), cut(2, 'standard edition', '1080p')]), '2');
    // A full tie keeps server order.
    expect(select(files: [cut(1, 'extended', '1080p'), cut(2, 'directors_cut', '1080p', size: 9000)]), '1');
  });

  test('a pin wins', () {
    expect(select(pinnedFileId: '2'), '2');
    expect(select(pinnedFileId: '2', editionId: 'theatrical'), '2');
  });

  test('with no file at the preference Auto takes the closest above', () {
    final theatrical720 = _file(4, resolution: '720p', raw: 'Theatrical', key: 'theatrical');
    expect(select(editionId: 'theatrical', preferredQuality: '480p', files: [...versions, theatrical720]), '4');
    expect(select(editionId: 'theatrical', preferredQuality: '720p'), '2');
    // A preference that names no resolution reads as Auto.
    expect(select(editionId: 'theatrical', preferredQuality: 'high'), '1');
  });

  test('Auto ranks every presentation of the cut', () {
    final single4k = _file(20, resolution: '2160p', raw: 'Final Cut', key: 'final_cut');
    final cd1 = _file(11, resolution: '1080p', raw: 'Final Cut', key: 'final_cut', kind: 'multipart_movie', part: 1);
    final cd2 = {...cd1, 'file_id': '12', 'presentation_part_index': 2};
    final variants = [
      {
        'variant_id': 'final_cut|single',
        'edition_key': 'final_cut',
        'parts': [
          {
            'part_index': 1,
            'versions': [single4k],
          },
        ],
      },
      {
        'variant_id': 'final_cut|multipart',
        'edition_key': 'final_cut',
        'parts': [
          {
            'part_index': 1,
            'versions': [cd1],
          },
          {
            'part_index': 2,
            'versions': [cd2],
          },
        ],
      },
    ];
    final files = [cd1, cd2, single4k];
    // Last played the first CD: the cut's best file wins.
    expect(select(lastFileId: '11', files: files, variants: variants), '20');
    // Stopped in CD2: Resume keeps that part, and Start Over plays CD1.
    expect(select(lastFileId: '12', inProgress: true, files: files, variants: variants), '12');
    expect(SiloVersionSelector.firstPlaybackPart(files, cd2)['file_id'], '11');
    // One Edition row for the cut, offering both presentations' first parts.
    final edition = SiloVersionSelector.editions(files, variants).single;
    expect(edition.versionIndexes.map((i) => files[i]['file_id']), ['11', '20']);
    expect(edition.fileIds, {'11', '12', '20'});
    expect(edition.label, 'Final Cut');
  });

  test('Resume stays on the later part of a multi-part edition', () {
    final part1 = _file(10, resolution: '1080p', kind: 'multipart_movie', part: 1);
    final part2 = _file(11, resolution: '1080p', kind: 'multipart_movie', part: 2);
    final variant = {
      'variant_id': 'standard',
      'parts': [
        {
          'part_index': 1,
          'default_file_id': '10',
          'versions': [part1],
        },
        {
          'part_index': 2,
          'default_file_id': '11',
          'versions': [part2],
        },
      ],
    };
    expect(select(lastFileId: '11', inProgress: true, files: [part1, part2], variants: [variant]), '11');
    expect(select(lastFileId: '11', inProgress: true, editionId: '', files: [part1, part2], variants: [variant]), '11');
    expect(select(files: [part1, part2], variants: [variant]), '10');
    // Without variants, a later part is still recognised, and Auto starts at part 1
    // even when a later part has the better file.
    expect(select(lastFileId: '11', inProgress: true, files: [part1, part2]), '11');
    expect(
      select(
        files: [
          part1,
          {...part2, 'bitrate': 9000},
        ],
      ),
      '10',
    );
  });

  test('only a saved position keeps a later part', () {
    final part1 = _file(10, resolution: '1080p', kind: 'multipart_movie', part: 1);
    final part2 = {...part1, 'file_id': '11', 'presentation_part_index': 2};
    String? selectFor(Map<String, dynamic> userData) {
      final history = SiloVersionSelector.history({'user_data': userData});
      return select(lastFileId: history.lastFileId, inProgress: history.inProgress, files: [part1, part2]);
    }

    // Finished on the last part: the server reset the position, so a rewatch starts at part 1.
    expect(selectFor({'played': true, 'position_seconds': 0, 'last_file_id': '11'}), '10');
    // A rewatch stopped in part 2 keeps it, though the title stays marked played.
    expect(selectFor({'played': true, 'position_seconds': 600, 'last_file_id': '11'}), '11');
  });

  group('Plezilo glue', () {
    test('the startup quality caps Auto; Original has no cap', () {
      expect(SiloVersionSelector.capRank(TranscodeQualityPreset.original), isNull);
      expect(SiloVersionSelector.capRank(null), isNull);
      expect(SiloVersionSelector.capRank(TranscodeQualityPreset.p1080_20mbps), 3);
      expect(SiloVersionSelector.capRank(TranscodeQualityPreset.p720_3mbps), 2);
      expect(SiloVersionSelector.capRank(TranscodeQualityPreset.p480_1_5mbps), 1);
      expect(SiloVersionSelector.capRank(TranscodeQualityPreset.p240_320), 1);
    });

    test('edition names follow Silo: the raw name, else the key spelled out', () {
      expect(siloEditionLabel('Director\'s Cut', 'directors_cut'), 'Director\'s Cut');
      expect(siloEditionLabel(null, 'directors_cut'), 'Directors Cut');
      expect(siloEditionLabel('  ', 'imax-enhanced'), 'IMAX Enhanced');
      expect(siloEditionLabel(null, ' '), isNull);
    });

    test('the menu opens on the last-played edition and keeps its shown file', () {
      final watch = <String, dynamic>{
        'user_data': {'last_file_id': '3', 'position_seconds': 0},
        'versions': versions,
      };
      final menu = SiloVersionMenu.fromWatch(watch, versions)!;
      expect(menu.hasEditionChoices, isTrue);
      expect(menu.editions.map((e) => e.label), ['Extended', 'Theatrical']);
      expect(menu.current.id, 'extended');
      expect(menu.versions[menu.shownIndex].id, '3');
      // Picking Theatrical keeps Version on Auto: its best file.
      final theatrical = menu.editions.firstWhere((e) => e.id == 'theatrical');
      expect(menu.versions[menu.autoIndex(theatrical)].id, '1');
      expect(theatrical.versionIndexes.map((i) => menu.versions[i].id), ['2', '1']);
      // Plain Play starts the same file the menu shows.
      expect(SiloVersionSelector.selectForWatch(watch, versions), menu.shownIndex);
    });
  });
}
