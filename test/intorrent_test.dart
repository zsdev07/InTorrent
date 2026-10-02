import 'package:flutter_test/flutter_test.dart';
import 'package:intorrent/intorrent.dart';

void main() {
  test('TorrentState contains the documented states', () {
    expect(
      TorrentState.values,
      containsAll(<TorrentState>[
        TorrentState.queued,
        TorrentState.checking,
        TorrentState.downloadingMetadata,
        TorrentState.downloading,
        TorrentState.finished,
        TorrentState.seeding,
        TorrentState.unknown,
      ]),
    );
  });

  test('TorrentStatus stores its values', () {
    final status = TorrentStatus(
      totalBytes: 1000,
      downloadedBytes: 250,
      progress: 0.25,
      state: TorrentState.downloading,
      numPeers: 4,
      numSeeds: 2,
      isPaused: false,
    );

    expect(status.totalBytes, 1000);
    expect(status.downloadedBytes, 250);
    expect(status.progress, 0.25);
    expect(status.state, TorrentState.downloading);
    expect(status.numPeers, 4);
    expect(status.numSeeds, 2);
    expect(status.isPaused, isFalse);
  });

  test('TorrentFile stores file metadata', () {
    const file = TorrentFile(
      index: 3,
      name: 'movie.mkv',
      size: 1024,
    );

    expect(file.index, 3);
    expect(file.name, 'movie.mkv');
    expect(file.size, 1024);
  });
}
