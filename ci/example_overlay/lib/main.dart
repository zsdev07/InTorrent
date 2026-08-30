// main.dart - InTorrent smoke test
//
// This is not a real app - it's a minimal UI that exercises every
// function InTorrent exposes, in the order a real app would call
// them, so CI (and you, testing on your own phone) can see the whole
// pipeline actually working: addMagnet -> poll getStatus until
// metadata arrives -> streamUrl -> pause/resume -> remove.

import 'package:flutter/material.dart';
import 'package:intorrent/intorrent.dart' as intorrent;

void main() {
  runApp(const IntorrentTestApp());
}

class IntorrentTestApp extends StatelessWidget {
  const IntorrentTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'InTorrent Smoke Test',
      home: SmokeTestPage(),
    );
  }
}

class SmokeTestPage extends StatefulWidget {
  const SmokeTestPage({super.key});

  @override
  State<SmokeTestPage> createState() => _SmokeTestPageState();
}

class _SmokeTestPageState extends State<SmokeTestPage> {
  final _magnetController = TextEditingController();
  final List<String> _log = [];
  int? _currentId;
  Uri? _streamUri;

  void _appendLog(String line) {
    setState(() => _log.add(line));
  }

  Future<void> _runAddMagnet() async {
    final uri = _magnetController.text.trim();
    if (uri.isEmpty) {
      _appendLog('Enter a magnet URI first.');
      return;
    }

    try {
      final id = await intorrent.addMagnet(uri);
      _currentId = id;
      _appendLog('addMagnet() -> id $id');
    } catch (e) {
      _appendLog('addMagnet() failed: $e');
    }
  }

  Future<void> _runGetStatus() async {
    if (_currentId == null) {
      _appendLog('Call addMagnet first.');
      return;
    }
    try {
      final status = await intorrent.getStatus(_currentId!);
      _appendLog('getStatus() -> $status');
    } catch (e) {
      _appendLog('getStatus() failed: $e');
    }
  }

  Future<void> _runListFiles() async {
    if (_currentId == null) {
      _appendLog('Call addMagnet first.');
      return;
    }
    try {
      final files = await intorrent.listFiles(_currentId!);
      _appendLog('listFiles() -> ${files.length} file(s):');
      for (final f in files) {
        _appendLog('  [${f.index}] ${f.name} (${f.size} bytes)');
      }
    } catch (e) {
      _appendLog('listFiles() failed: $e');
    }
  }

  Future<void> _runStreamUrl() async {
    if (_currentId == null) {
      _appendLog('Call addMagnet first.');
      return;
    }
    try {
      // fileIndex 0 - fine for a single-file torrent (tap listFiles
      // first on a multi-file one to find the right index).
      final url = await intorrent.streamUrl(_currentId!, 0);
      _streamUri = url;
      _appendLog('streamUrl() -> $url');
    } catch (e) {
      _appendLog('streamUrl() failed: $e');
    }
  }

  Future<void> _runPause() async {
    if (_currentId == null) return;
    try {
      await intorrent.pause(_currentId!);
      _appendLog('pause() -> ok');
    } catch (e) {
      _appendLog('pause() failed: $e');
    }
  }

  Future<void> _runResume() async {
    if (_currentId == null) return;
    try {
      await intorrent.resume(_currentId!);
      _appendLog('resume() -> ok');
    } catch (e) {
      _appendLog('resume() failed: $e');
    }
  }

  Future<void> _runRemove() async {
    if (_currentId == null) return;
    try {
      await intorrent.remove(_currentId!);
      _appendLog('remove() -> ok (id ${_currentId} is now invalid)');
      _currentId = null;
      _streamUri = null;
    } catch (e) {
      _appendLog('remove() failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('InTorrent Smoke Test')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: _magnetController,
              decoration: const InputDecoration(
                labelText: 'Magnet URI',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(onPressed: _runAddMagnet, child: const Text('addMagnet')),
                ElevatedButton(onPressed: _runGetStatus, child: const Text('getStatus')),
                ElevatedButton(onPressed: _runListFiles, child: const Text('listFiles')),
                ElevatedButton(onPressed: _runStreamUrl, child: const Text('streamUrl')),
                ElevatedButton(onPressed: _runPause, child: const Text('pause')),
                ElevatedButton(onPressed: _runResume, child: const Text('resume')),
                ElevatedButton(onPressed: _runRemove, child: const Text('remove')),
              ],
            ),
            const Divider(),
            if (_streamUri != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SelectableText('Stream URL: $_streamUri'),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (context, i) => Text(_log[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
