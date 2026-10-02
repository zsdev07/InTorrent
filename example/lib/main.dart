import 'package:flutter/material.dart';
import 'package:intorrent/intorrent.dart';

void main() => runApp(const InTorrentExampleApp());

class InTorrentExampleApp extends StatelessWidget {
  const InTorrentExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'InTorrent Example',
      theme: ThemeData(useMaterial3: true),
      home: const TorrentDemoPage(),
    );
  }
}

class TorrentDemoPage extends StatefulWidget {
  const TorrentDemoPage({super.key});

  @override
  State<TorrentDemoPage> createState() => _TorrentDemoPageState();
}

class _TorrentDemoPageState extends State<TorrentDemoPage> {
  final controller = TextEditingController();
  int? torrentId;
  TorrentStatus? status;
  List<TorrentFile> files = const [];
  String? stream;
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> add() async {
    try {
      final id = await addMagnet(controller.text.trim());
      setState(() {
        torrentId = id;
        status = null;
        files = const [];
        stream = null;
        error = null;
      });
      await refresh();
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  Future<void> refresh() async {
    final id = torrentId;
    if (id == null) return;
    try {
      final nextStatus = await getStatus(id);
      var nextFiles = files;
      if (nextStatus.state != TorrentState.downloadingMetadata) {
        try {
          nextFiles = await listFiles(id);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        status = nextStatus;
        files = nextFiles;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> makeStream(TorrentFile file) async {
    final id = torrentId;
    if (id == null) return;
    try {
      final url = await streamUrl(id, file.index);
      if (mounted) setState(() => stream = url.toString());
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> removeTorrent() async {
    final id = torrentId;
    if (id == null) return;
    try {
      await remove(id);
      if (!mounted) return;
      setState(() {
        torrentId = null;
        status = null;
        files = const [];
        stream = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = status;

    return Scaffold(
      appBar: AppBar(title: const Text('InTorrent Example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: controller,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Magnet URI',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: add, child: const Text('Add magnet')),
          if (torrentId != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: refresh,
              child: const Text('Refresh status'),
            ),
            OutlinedButton(
              onPressed: removeTorrent,
              child: const Text('Remove torrent'),
            ),
          ],
          if (current != null) ...[
            const SizedBox(height: 16),
            Text('State: ${current.state}'),
            Text('Progress: ${(current.progress * 100).toStringAsFixed(1)}%'),
            Text('Peers: ${current.numPeers}'),
            Text('Seeds: ${current.numSeeds}'),
          ],
          for (final file in files)
            ListTile(
              title: Text(file.name),
              subtitle: Text('${file.size} bytes'),
              trailing: const Icon(Icons.play_arrow),
              onTap: () => makeStream(file),
            ),
          if (stream != null) ...[
            const SizedBox(height: 12),
            const Text('Local stream URL:'),
            SelectableText(stream!),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!),
          ],
        ],
      ),
    );
  }
}
