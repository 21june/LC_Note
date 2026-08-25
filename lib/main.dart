import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MyListenerApp());

const _ink = Color(0xFF182126);
const _muted = Color(0xFF66757D);
const _paper = Color(0xFFF7F6F1);
const _blue = Color(0xFF176B87);
const _mint = Color(0xFFB9DED5);

bool get _isKorean =>
    WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'ko';

String tr(String korean, String english) => _isKorean ? korean : english;

String clock(Duration value) {
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

class SilenceDetectionSettings {
  const SilenceDetectionSettings({
    this.threshold = 0.04,
    this.minimumSilence = const Duration(milliseconds: 800),
    this.minimumSegment = const Duration(seconds: 3),
    this.padding = const Duration(milliseconds: 200),
  });

  final double threshold;
  final Duration minimumSilence;
  final Duration minimumSegment;
  final Duration padding;
}

class DetectedSegment {
  const DetectedSegment(this.start, this.end);

  final Duration start;
  final Duration end;
  Duration get length => end - start;
}

List<DetectedSegment> detectSpeechSegments({
  required List<double> amplitudes,
  required Duration duration,
  SilenceDetectionSettings settings = const SilenceDetectionSettings(),
}) {
  if (amplitudes.isEmpty || duration <= Duration.zero) return const [];
  final sampleMs = duration.inMilliseconds / amplitudes.length;
  final minimumSilentSamples = max(
    1,
    (settings.minimumSilence.inMilliseconds / sampleMs).ceil(),
  );
  final silentRanges = <(int, int)>[];
  int? silentStart;
  for (var i = 0; i <= amplitudes.length; i++) {
    final silent = i < amplitudes.length && amplitudes[i] <= settings.threshold;
    if (silent && silentStart == null) silentStart = i;
    if (!silent && silentStart != null) {
      if (i - silentStart >= minimumSilentSamples) {
        silentRanges.add((silentStart, i));
      }
      silentStart = null;
    }
  }

  final raw = <DetectedSegment>[];
  var contentStartMs = 0;
  for (final range in silentRanges) {
    final silenceStartMs = (range.$1 * sampleMs).round();
    final silenceEndMs = (range.$2 * sampleMs).round();
    final segmentEndMs = min(
      duration.inMilliseconds,
      silenceStartMs + settings.padding.inMilliseconds,
    );
    if (segmentEndMs > contentStartMs) {
      raw.add(
        DetectedSegment(
          Duration(milliseconds: contentStartMs),
          Duration(milliseconds: segmentEndMs),
        ),
      );
    }
    contentStartMs = max(0, silenceEndMs - settings.padding.inMilliseconds);
  }
  if (contentStartMs < duration.inMilliseconds) {
    raw.add(DetectedSegment(Duration(milliseconds: contentStartMs), duration));
  }

  final merged = <DetectedSegment>[];
  for (final segment in raw) {
    if (segment.length < settings.minimumSegment && merged.isNotEmpty) {
      final previous = merged.removeLast();
      merged.add(DetectedSegment(previous.start, segment.end));
    } else {
      merged.add(segment);
    }
  }
  if (merged.length > 1 && merged.first.length < settings.minimumSegment) {
    final first = merged.removeAt(0);
    final second = merged.removeAt(0);
    merged.insert(0, DetectedSegment(first.start, second.end));
  }
  return merged.where((segment) => segment.length > Duration.zero).toList();
}

class StudyClip {
  StudyClip({
    required this.id,
    required this.title,
    required this.source,
    required this.start,
    required this.end,
    required this.script,
    required this.playlist,
    this.memo = '',
    this.completed = false,
    this.audioPath,
  });

  final String id;
  String title;
  String source;
  Duration start;
  Duration end;
  String script;
  String memo;
  String playlist;
  bool completed;
  String? audioPath;

  Duration get length => end - start;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'source': source,
    'start': start.inMilliseconds,
    'end': end.inMilliseconds,
    'script': script,
    'memo': memo,
    'playlist': playlist,
    'completed': completed,
    'audioPath': audioPath,
  };

  factory StudyClip.fromJson(Map<String, dynamic> json) => StudyClip(
    id: json['id'] as String,
    title: json['title'] as String,
    source: json['source'] as String,
    start: Duration(milliseconds: json['start'] as int),
    end: Duration(milliseconds: json['end'] as int),
    script: json['script'] as String,
    memo: json['memo'] as String? ?? '',
    playlist: json['playlist'] as String,
    completed: json['completed'] as bool? ?? false,
    audioPath: json['audioPath'] as String?,
  );
}

/// Connects the existing player to Android's media notification without
/// delaying Flutter's first frame. If the service is unavailable, the app can
/// continue to use the same [AudioPlayer] normally.
class _MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  _MyAudioHandler(this.player) {
    player.playbackEventStream.map(_broadcastState).pipe(playbackState);
    player.currentIndexStream.listen((index) {
      final items = queue.value;
      if (index != null && index >= 0 && index < items.length) {
        mediaItem.add(items[index]);
      }
    });
  }

  final AudioPlayer player;

  Future<void> loadQueue({
    required List<AudioSource> sources,
    required List<MediaItem> items,
    required int initialIndex,
    required Duration initialPosition,
  }) async {
    queue.add(items);
    mediaItem.add(items[initialIndex]);
    await player.setAudioSources(
      sources,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
    );
  }

  PlaybackState _broadcastState(PlaybackEvent event) {
    final playing = player.playing;
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekBackward,
        MediaAction.seekForward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: switch (player.processingState) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      },
      playing: playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: event.currentIndex,
    );
  }

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() => player.seekToNext();

  @override
  Future<void> skipToPrevious() => player.seekToPrevious();

  @override
  Future<void> fastForward() =>
      player.seek(player.position + const Duration(seconds: 5));

  @override
  Future<void> rewind() => player.seek(
    player.position > const Duration(seconds: 5)
        ? player.position - const Duration(seconds: 5)
        : Duration.zero,
  );

  @override
  Future<void> stop() async {
    await player.stop();
    return super.stop();
  }
}

class MyListenerApp extends StatefulWidget {
  const MyListenerApp({super.key});

  @override
  State<MyListenerApp> createState() => _MyListenerAppState();
}

class _MyListenerAppState extends State<MyListenerApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  BuildContext get _appContext => _navigatorKey.currentContext!;
  int _tab = 0;
  int _selected = 0;
  bool _playing = false;
  bool _repeat = true;
  bool _shuffle = false;
  double _speed = 1;
  int _skipSeconds = 5;
  String? _activePlaylist;
  Duration _position = const Duration(seconds: 11);
  Timer? _timer;
  final AudioPlayer _audio = AudioPlayer();
  _MyAudioHandler? _audioHandler;
  Future<_MyAudioHandler?>? _audioHandlerInitialization;
  String? _loadedClipId;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<int?>? _indexSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  List<String> _loadedQueueIds = [];

  final List<StudyClip> _clips = [
    StudyClip(
      id: 'c1',
      title: tr('호텔 예약 일정 변경', 'Changing a Hotel Reservation'),
      source: 'TOEIC Practice Test 01',
      start: const Duration(minutes: 2, seconds: 10),
      end: const Duration(minutes: 3, seconds: 5),
      playlist: tr('Part 3 · 오답', 'Part 3 · Review'),
      script:
          "M: Hello, I'd like to change my reservation for this Friday.\n\nW: Certainly. What date would you prefer instead?\n\nM: Would next Monday be available? I plan to stay for two nights.\n\nW: Yes, we still have a room available. I'll update that for you now.",
      memo: tr('would prefer: ~을 더 선호하다', 'would prefer: to favor something'),
    ),
    StudyClip(
      id: 'c2',
      title: tr('배송 일정 문의', 'Delivery Schedule Inquiry'),
      source: 'TOEIC Practice Test 02',
      start: const Duration(minutes: 5, seconds: 42),
      end: const Duration(minutes: 6, seconds: 36),
      playlist: tr('Part 3 · 오답', 'Part 3 · Review'),
      script:
          "W: I'm calling about an order I placed last week.\n\nM: Let me check the delivery status for you. Could I have your order number?\n\nW: It's printed at the top of my receipt. The number is 50318.",
      completed: true,
    ),
    StudyClip(
      id: 'c3',
      title: tr('신제품 출시 안내', 'New Product Launch'),
      source: 'TOEIC Practice Test 03',
      start: const Duration(minutes: 8, seconds: 5),
      end: const Duration(minutes: 9, seconds: 17),
      playlist: tr('Part 4 · 이번 주', 'Part 4 · This Week'),
      script:
          "Thank you for joining us today. We're pleased to introduce our newest line of office furniture. All items will be available in stores beginning next month.",
    ),
  ];
  final List<String> _playlists = [
    tr('Part 3 · 오답', 'Part 3 · Review'),
    tr('Part 4 · 이번 주', 'Part 4 · This Week'),
    tr('출퇴근 복습', 'Commute Review'),
  ];

  StudyClip get clip => _clips[_selected.clamp(0, _clips.length - 1)];

  @override
  void initState() {
    super.initState();
    _restoreClips();
    _positionSubscription = _audio.positionStream.listen((position) {
      if (!mounted || _loadedClipId != clip.id) return;
      setState(() {
        _position = position < Duration.zero
            ? Duration.zero
            : position > clip.length
            ? clip.length
            : position;
      });
    });
    _indexSubscription = _audio.currentIndexStream.listen((index) {
      if (!mounted || index == null || index >= _loadedQueueIds.length) return;
      final clipIndex = _clips.indexWhere(
        (item) => item.id == _loadedQueueIds[index],
      );
      if (clipIndex < 0 || clipIndex == _selected) return;
      setState(() {
        _selected = clipIndex;
        _loadedClipId = _clips[clipIndex].id;
        _position = Duration.zero;
      });
    });
    _playerStateSubscription = _audio.playerStateStream.listen((state) {
      if (!mounted || _loadedQueueIds.isEmpty) return;
      setState(() => _playing = state.playing);
    });
  }

  Future<void> _restoreClips() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final stored = preferences.getString('study_clips');
      if (stored == null || !mounted) return;
      final decoded = jsonDecode(stored) as List<dynamic>;
      final restored = decoded
          .map((e) => StudyClip.fromJson(e as Map<String, dynamic>))
          .toList();
      if (restored.isNotEmpty) {
        setState(() {
          _clips
            ..clear()
            ..addAll(restored);
          _selected = 0;
          _position = Duration.zero;
        });
      }
      final savedPlaylists = preferences.getStringList('playlists');
      if (savedPlaylists != null && savedPlaylists.isNotEmpty && mounted) {
        setState(
          () => _playlists
            ..clear()
            ..addAll(savedPlaylists),
        );
      }
      _speed = preferences.getDouble('speed') ?? _speed;
      _skipSeconds = preferences.getInt('skip_seconds') ?? _skipSeconds;
    } catch (_) {
      // Keep bundled examples when saved data is invalid.
    }
  }

  Future<void> _saveClips() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'study_clips',
      jsonEncode(_clips.map((e) => e.toJson()).toList()),
    );
    await preferences.setStringList('playlists', _playlists);
    await preferences.setDouble('speed', _speed);
    await preferences.setInt('skip_seconds', _skipSeconds);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _positionSubscription?.cancel();
    _indexSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _audio.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (clip.audioPath != null) {
      try {
        await _ensureAudioHandler();
        if (_loadedClipId != clip.id) {
          await _loadBackgroundQueue();
        }
        if (_audio.playing) {
          await _audio.pause();
        } else {
          await _audio.setSpeed(_speed);
          unawaited(_audio.play());
        }
        if (mounted) setState(() => _playing = _audio.playing);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(_appContext).showSnackBar(
            SnackBar(
              content: Text(
                tr(
                  '오디오 파일을 열 수 없습니다. 파일을 다시 선택해 주세요.',
                  'Unable to open the audio file. Please select it again.',
                ),
              ),
            ),
          );
        }
      }
      return;
    }
    setState(() => _playing = !_playing);
    _timer?.cancel();
    if (_playing) {
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted) return;
        final next = _position + Duration(milliseconds: (250 * _speed).round());
        if (next >= clip.length) {
          if (_repeat) {
            setState(() => _position = Duration.zero);
          } else {
            _go(1, autoPlay: true);
          }
        } else {
          setState(() => _position = next);
        }
      });
    }
  }

  Future<_MyAudioHandler?> _ensureAudioHandler() {
    return _audioHandlerInitialization ??= _initializeAudioHandler();
  }

  Future<_MyAudioHandler?> _initializeAudioHandler() async {
    final initialization = AudioService.init<_MyAudioHandler>(
      builder: () => _MyAudioHandler(_audio),
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.mylistener.audio.playback',
        androidNotificationChannelName: tr('LC Note 재생', 'LC Note Playback'),
        androidNotificationChannelDescription: tr(
          '영어 듣기 클립 재생 제어',
          'English listening clip controls',
        ),
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        fastForwardInterval: Duration(seconds: 5),
        rewindInterval: Duration(seconds: 5),
      ),
    );
    try {
      _audioHandler = await initialization.timeout(const Duration(seconds: 4));
      return _audioHandler;
    } on TimeoutException {
      // Keep normal in-app playback working even if a device does not connect
      // its Android media service promptly. Adopt the handler if it arrives.
      unawaited(
        initialization.then((handler) {
          _audioHandler = handler;
        }),
      );
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadBackgroundQueue() async {
    final queueIndices = List<int>.generate(_clips.length, (i) => i)
        .where(
          (i) =>
              _clips[i].audioPath != null &&
              (_activePlaylist == null ||
                  _clips[i].playlist == _activePlaylist),
        )
        .toList();
    final initialIndex = queueIndices.indexOf(_selected);
    if (initialIndex < 0) throw StateError('Selected clip is not playable');
    final items = queueIndices.map((index) {
      final item = _clips[index];
      return MediaItem(
        id: item.id,
        title: item.title,
        album: item.playlist,
        artist: item.source,
        duration: item.length,
        extras: {'sourcePath': item.audioPath},
      );
    }).toList();
    final sources = queueIndices.map((index) {
      final item = _clips[index];
      return ClippingAudioSource(
        child: AudioSource.file(item.audioPath!),
        start: item.start,
        end: item.end,
        duration: item.length,
        tag: items[queueIndices.indexOf(index)],
      );
    }).toList();
    _loadedQueueIds = queueIndices.map((i) => _clips[i].id).toList();
    final handler = _audioHandler;
    if (handler != null) {
      await handler.loadQueue(
        sources: sources,
        items: items,
        initialIndex: initialIndex,
        initialPosition: _position,
      );
    } else {
      await _audio.setAudioSources(
        sources,
        initialIndex: initialIndex,
        initialPosition: _position,
      );
    }
    await _audio.setLoopMode(_repeat ? LoopMode.one : LoopMode.all);
    await _audio.setShuffleModeEnabled(_shuffle);
    await _audio.setSpeed(_speed);
    _loadedClipId = clip.id;
  }

  void _go(int direction, {bool autoPlay = false}) {
    if (_clips.isEmpty) return;
    if (_loadedQueueIds.isNotEmpty && clip.audioPath != null) {
      final move = direction < 0
          ? _audio.seekToPrevious()
          : _audio.seekToNext();
      move.then((_) {
        if (autoPlay && mounted && !_audio.playing) unawaited(_audio.play());
      });
      return;
    }
    final queue = List<int>.generate(_clips.length, (i) => i)
        .where(
          (i) =>
              _activePlaylist == null || _clips[i].playlist == _activePlaylist,
        )
        .toList();
    if (queue.isEmpty) return;
    setState(() {
      if (_shuffle) {
        final candidates = queue.where((i) => i != _selected).toList();
        _selected = candidates.isEmpty
            ? queue.first
            : candidates[Random().nextInt(candidates.length)];
      } else {
        var queueIndex = queue.indexOf(_selected);
        if (queueIndex < 0) queueIndex = 0;
        queueIndex = (queueIndex + direction) % queue.length;
        if (queueIndex < 0) queueIndex = queue.length - 1;
        _selected = queue[queueIndex];
      }
      _position = Duration.zero;
      _loadedClipId = null;
      _loadedQueueIds = [];
      _playing = false;
    });
    _timer?.cancel();
    _audio.stop().then((_) {
      if (autoPlay && mounted) _togglePlay();
    });
  }

  void _openClip(int index, {String? playlist}) {
    _audio.stop();
    _timer?.cancel();
    setState(() {
      _selected = index;
      _activePlaylist = playlist;
      _tab = 2;
      _position = Duration.zero;
      _playing = false;
      _loadedClipId = null;
      _loadedQueueIds = [];
    });
  }

  Future<void> _showSettings() async {
    var skip = _skipSeconds;
    var speed = _speed;
    final saved = await showModalBottomSheet<bool>(
      context: _appContext,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('재생 설정', 'Playback Settings'),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 20),
                Text(
                  tr('기본 이동 시간', 'Default Skip Interval'),
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                SegmentedButton<int>(
                  segments: [
                    ButtonSegment(value: 3, label: Text(tr('3초', '3 sec'))),
                    ButtonSegment(value: 5, label: Text(tr('5초', '5 sec'))),
                    ButtonSegment(value: 10, label: Text(tr('10초', '10 sec'))),
                  ],
                  selected: {skip},
                  onSelectionChanged: (v) =>
                      setSheetState(() => skip = v.first),
                ),
                const SizedBox(height: 20),
                Text(
                  tr('기본 배속', 'Default Speed'),
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                DropdownButton<double>(
                  value: speed,
                  isExpanded: true,
                  items: [.5, .75, 1.0, 1.25, 1.5, 2.0]
                      .map(
                        (v) => DropdownMenuItem(value: v, child: Text('$v×')),
                      )
                      .toList(),
                  onChanged: (v) => setSheetState(() => speed = v!),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: Text(tr('저장', 'Save')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved == true) {
      setState(() {
        _skipSeconds = skip;
        _speed = speed;
      });
      await _audio.setSpeed(speed);
      await _saveClips();
    }
  }

  Future<void> _showClipActions(StudyClip target) async {
    final action = await showModalBottomSheet<String>(
      context: _appContext,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(tr('클립 편집', 'Edit Clip')),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
            ListTile(
              leading: Icon(
                target.completed
                    ? Icons.restart_alt
                    : Icons.check_circle_outline,
              ),
              title: Text(
                target.completed
                    ? tr('학습 완료 취소', 'Mark as Not Complete')
                    : tr('학습 완료 표시', 'Mark as Complete'),
              ),
              onTap: () => Navigator.pop(context, 'complete'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text(
                tr('클립 삭제', 'Delete Clip'),
                style: const TextStyle(color: Colors.red),
              ),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'edit') return _editClip(target: target);
    if (action == 'complete') {
      setState(() => target.completed = !target.completed);
      return _saveClips();
    }
    if (_clips.length == 1) {
      ScaffoldMessenger.of(_appContext).showSnackBar(
        SnackBar(
          content: Text(
            tr('마지막 클립은 삭제할 수 없습니다.', 'The last clip cannot be deleted.'),
          ),
        ),
      );
      return;
    }
    final confirmed =
        await showDialog<bool>(
          context: _appContext,
          builder: (context) => AlertDialog(
            title: Text(tr('클립을 삭제할까요?', 'Delete this clip?')),
            content: Text(target.title),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr('취소', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr('삭제', 'Delete')),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    final index = _clips.indexOf(target);
    setState(() {
      _clips.remove(target);
      if (_selected >= _clips.length) {
        _selected = _clips.length - 1;
      } else if (index < _selected) {
        _selected--;
      }
      _position = Duration.zero;
    });
    await _audio.stop();
    await _saveClips();
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: _appContext,
      builder: (context) => AlertDialog(
        title: Text(tr('새 재생목록', 'New Playlist')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: tr('재생목록 이름', 'Playlist Name'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('취소', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr('만들기', 'Create')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || _playlists.contains(name)) return;
    setState(() => _playlists.add(name));
    await _saveClips();
  }

  Future<void> _renamePlaylist(String oldName) async {
    final controller = TextEditingController(text: oldName);
    final name = await showDialog<String>(
      context: _appContext,
      builder: (context) => AlertDialog(
        title: Text(tr('재생목록 이름 변경', 'Rename Playlist')),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('취소', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(tr('저장', 'Save')),
          ),
        ],
      ),
    );
    if (name == null ||
        name.isEmpty ||
        (name != oldName && _playlists.contains(name))) {
      return;
    }
    setState(() {
      final i = _playlists.indexOf(oldName);
      _playlists[i] = name;
      for (final c in _clips.where((c) => c.playlist == oldName)) {
        c.playlist = name;
      }
      if (_activePlaylist == oldName) _activePlaylist = name;
    });
    await _saveClips();
  }

  Future<void> _deletePlaylist(String name) async {
    if (_playlists.length == 1) return;
    final fallback = _playlists.firstWhere((p) => p != name);
    final confirmed =
        await showDialog<bool>(
          context: _appContext,
          builder: (context) => AlertDialog(
            title: Text(tr('재생목록을 삭제할까요?', 'Delete this playlist?')),
            content: Text(
              tr(
                '포함된 클립은 “$fallback”(으)로 이동합니다.',
                'Its clips will be moved to “$fallback”.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr('취소', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr('삭제', 'Delete')),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    setState(() {
      _playlists.remove(name);
      for (final c in _clips.where((c) => c.playlist == name)) {
        c.playlist = fallback;
      }
      if (_activePlaylist == name) _activePlaylist = null;
    });
    await _saveClips();
  }

  void _seekBy(int seconds) {
    final next = _position + Duration(seconds: seconds);
    setState(
      () => _position = Duration(
        milliseconds: next.inMilliseconds.clamp(0, clip.length.inMilliseconds),
      ),
    );
    if (_loadedClipId == clip.id) _audio.seek(_position);
  }

  Future<void> _editClip({StudyClip? target}) async {
    final created = await showModalBottomSheet<StudyClip>(
      context: _appContext,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ClipEditor(clip: target, playlists: _playlists),
    );
    if (created == null) return;
    setState(() {
      if (target == null) {
        _clips.add(created);
        _selected = _clips.length - 1;
      } else {
        final index = _clips.indexWhere((e) => e.id == target.id);
        _clips[index] = created;
        _selected = index;
      }
      _position = Duration.zero;
      _tab = 2;
    });
    _loadedClipId = null;
    _loadedQueueIds = [];
    _audio.stop();
    _saveClips();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'LC Note',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _paper,
        colorScheme: ColorScheme.fromSeed(seedColor: _blue, surface: _paper),
        fontFamily: 'sans-serif',
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            fontWeight: FontWeight.w800,
            color: _ink,
            letterSpacing: -1,
          ),
          titleLarge: TextStyle(fontWeight: FontWeight.w800, color: _ink),
          titleMedium: TextStyle(fontWeight: FontWeight.w700, color: _ink),
          bodyLarge: TextStyle(color: _ink, height: 1.55),
          bodyMedium: TextStyle(color: _muted, height: 1.45),
        ),
      ),
      home: Scaffold(
        body: SafeArea(
          child: IndexedStack(
            index: _tab,
            children: [
              HomePage(
                clips: _clips,
                onOpen: (i) => _openClip(i),
                onSettings: _showSettings,
              ),
              LibraryPage(
                clips: _clips,
                onOpen: (i) => _openClip(i),
                onAdd: () => _editClip(),
                onMore: (c) => _showClipActions(c),
              ),
              PlayerPage(
                clip: clip,
                playing: _playing,
                repeat: _repeat,
                shuffle: _shuffle,
                speed: _speed,
                position: _position,
                skipSeconds: _skipSeconds,
                onPlay: _togglePlay,
                onPrevious: () => _go(-1),
                onNext: () => _go(1),
                onSeek: (v) {
                  setState(() => _position = Duration(milliseconds: v.round()));
                  if (_loadedClipId == clip.id) {
                    _audio.seek(_position);
                  }
                },
                onSkip: (direction) => _seekBy(direction * _skipSeconds),
                onRepeat: () {
                  setState(() => _repeat = !_repeat);
                  if (_loadedQueueIds.isNotEmpty) {
                    _audio.setLoopMode(_repeat ? LoopMode.one : LoopMode.all);
                  }
                },
                onShuffle: () {
                  setState(() => _shuffle = !_shuffle);
                  if (_loadedQueueIds.isNotEmpty) {
                    _audio.setShuffleModeEnabled(_shuffle);
                  }
                },
                onSpeed: () async {
                  final value = await showModalBottomSheet<double>(
                    context: _appContext,
                    builder: (_) => SpeedSheet(value: _speed),
                  );
                  if (value != null) {
                    setState(() => _speed = value);
                    _audio.setSpeed(value);
                  }
                },
                onEdit: () => _showClipActions(clip),
                queueName: _activePlaylist,
                onClose: () => setState(() => _tab = 1),
              ),
              PlaylistPage(
                clips: _clips,
                playlists: _playlists,
                onOpen: (i, playlist) => _openClip(i, playlist: playlist),
                onAdd: _createPlaylist,
                onRename: _renamePlaylist,
                onDelete: _deletePlaylist,
              ),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          indicatorColor: _mint,
          onDestinationSelected: (value) => setState(() => _tab = value),
          destinations: [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: tr('홈', 'Home'),
            ),
            NavigationDestination(
              icon: Icon(Icons.library_music_outlined),
              selectedIcon: Icon(Icons.library_music),
              label: tr('클립', 'Clips'),
            ),
            NavigationDestination(
              icon: const Icon(Icons.graphic_eq),
              label: tr('플레이어', 'Player'),
            ),
            NavigationDestination(
              icon: Icon(Icons.queue_music_outlined),
              selectedIcon: Icon(Icons.queue_music),
              label: tr('재생목록', 'Playlists'),
            ),
          ],
        ),
        floatingActionButton: _tab == 1
            ? FloatingActionButton.extended(
                onPressed: () => _editClip(),
                icon: const Icon(Icons.add),
                label: Text(tr('클립 만들기', 'Create Clip')),
              )
            : null,
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.clips,
    required this.onOpen,
    required this.onSettings,
  });
  final List<StudyClip> clips;
  final ValueChanged<int> onOpen;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
      children: [
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: _ink,
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Icon(Icons.multitrack_audio, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'LC NOTE',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                      color: _ink,
                    ),
                  ),
                  Text(
                    tr('오늘도 귀가 트이는 시간', 'Make every listen count'),
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        const SizedBox(height: 30),
        const Text(
          'Good evening.',
          style: TextStyle(fontSize: 14, color: _muted),
        ),
        Text(
          tr('오늘은 무엇을\n다시 들어볼까요?', 'What would you like to\nlisten to again?'),
          style: const TextStyle(
            fontSize: 31,
            height: 1.2,
            fontWeight: FontWeight.w900,
            letterSpacing: -1.3,
            color: _ink,
          ),
        ),
        const SizedBox(height: 24),
        InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () => onOpen(0),
          child: Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: _blue,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: _blue.withValues(alpha: .22),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        tr('이어 듣기', 'Continue'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Spacer(),
                    const Icon(Icons.headphones, color: _mint),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  clips.first.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  clips.first.source,
                  style: const TextStyle(color: Color(0xFFC9E3EA)),
                ),
                const SizedBox(height: 18),
                const LinearProgressIndicator(
                  value: .28,
                  backgroundColor: Color(0xFF4C8DA2),
                  color: Colors.white,
                  borderRadius: BorderRadius.all(Radius.circular(4)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '00:11 / ${clock(clips.first.length)}',
                      style: const TextStyle(color: Color(0xFFC9E3EA)),
                    ),
                    const Spacer(),
                    Container(
                      width: 46,
                      height: 46,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: _blue,
                        size: 30,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 30),
        SectionTitle(
          title: tr('최근 학습 클립', 'Recent Clips'),
          action: tr('전체 보기', 'View All'),
        ),
        const SizedBox(height: 12),
        ...List.generate(
          clips.length,
          (i) => ClipTile(clip: clips[i], onTap: () => onOpen(i)),
        ),
      ],
    );
  }
}

class LibraryPage extends StatelessWidget {
  const LibraryPage({
    super.key,
    required this.clips,
    required this.onOpen,
    required this.onAdd,
    required this.onMore,
  });
  final List<StudyClip> clips;
  final ValueChanged<int> onOpen;
  final VoidCallback onAdd;
  final ValueChanged<StudyClip> onMore;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      SliverAppBar.large(
        title: Text(tr('학습 클립', 'Study Clips')),
        backgroundColor: _paper,
        actions: [
          IconButton(
            onPressed: onAdd,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
        sliver: SliverList.builder(
          itemCount: clips.length,
          itemBuilder: (_, i) => ClipTile(
            clip: clips[i],
            onTap: () => onOpen(i),
            onMore: () => onMore(clips[i]),
            numbered: i + 1,
          ),
        ),
      ),
    ],
  );
}

class PlaylistPage extends StatelessWidget {
  const PlaylistPage({
    super.key,
    required this.clips,
    required this.playlists,
    required this.onOpen,
    required this.onAdd,
    required this.onRename,
    required this.onDelete,
  });
  final List<StudyClip> clips;
  final List<String> playlists;
  final void Function(int index, String playlist) onOpen;
  final VoidCallback onAdd;
  final ValueChanged<String> onRename;
  final ValueChanged<String> onDelete;
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 28, 22, 30),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                tr('재생목록', 'Playlists'),
                style: const TextStyle(
                  fontSize: 31,
                  fontWeight: FontWeight.w900,
                  color: _ink,
                ),
              ),
            ),
            IconButton.filledTonal(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          tr(
            '목적에 맞게 클립을 모아 연속으로 들어보세요.',
            'Group clips by purpose and listen continuously.',
          ),
          style: const TextStyle(color: _muted),
        ),
        const SizedBox(height: 26),
        ...playlists.map((name) {
          final items = clips.where((e) => e.playlist == name).toList();
          return Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFE6E4DC)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: name.contains('Part 4')
                            ? const Color(0xFFFFE2C5)
                            : _mint,
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Icon(
                        name.contains('Part 4')
                            ? Icons.campaign_outlined
                            : Icons.forum_outlined,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            tr(
                              '${items.length}개 클립 · ${items.fold<int>(0, (s, e) => s + e.length.inSeconds) ~/ 60}분',
                              '${items.length} ${items.length == 1 ? 'clip' : 'clips'} · ${items.fold<int>(0, (s, e) => s + e.length.inSeconds) ~/ 60} min',
                            ),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (value) =>
                          value == 'rename' ? onRename(name) : onDelete(name),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'rename',
                          child: ListTile(
                            leading: Icon(Icons.edit_outlined),
                            title: Text(tr('이름 변경', 'Rename')),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                            leading: Icon(Icons.delete_outline),
                            title: Text(tr('삭제', 'Delete')),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ...items.map((item) {
                  final index = clips.indexOf(item);
                  return InkWell(
                    onTap: () => onOpen(index, name),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.play_circle_outline,
                            size: 21,
                            color: _blue,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            clock(item.length),
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class PlayerPage extends StatelessWidget {
  const PlayerPage({
    super.key,
    required this.clip,
    required this.playing,
    required this.repeat,
    required this.shuffle,
    required this.speed,
    required this.position,
    required this.skipSeconds,
    required this.onPlay,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onSkip,
    required this.onRepeat,
    required this.onShuffle,
    required this.onSpeed,
    required this.onEdit,
    required this.onClose,
    this.queueName,
  });
  final StudyClip clip;
  final bool playing, repeat, shuffle;
  final double speed;
  final Duration position;
  final int skipSeconds;
  final String? queueName;
  final VoidCallback onPlay,
      onPrevious,
      onNext,
      onRepeat,
      onShuffle,
      onSpeed,
      onEdit,
      onClose;
  final ValueChanged<double> onSeek;
  final ValueChanged<int> onSkip;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 34),
    children: [
      Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
          Expanded(
            child: Text(
              queueName?.toUpperCase() ?? 'NOW LEARNING',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.7,
                color: _muted,
              ),
            ),
          ),
          IconButton(onPressed: onEdit, icon: const Icon(Icons.more_horiz)),
        ],
      ),
      const SizedBox(height: 10),
      Container(
        height: 190,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [_blue, Color(0xFF254D5B)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(28),
        ),
        child: Stack(
          children: [
            Positioned(
              right: -15,
              bottom: -25,
              child: Icon(
                Icons.graphic_eq,
                size: 190,
                color: Colors.white.withValues(alpha: .07),
              ),
            ),
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.headphones_rounded, size: 58, color: _mint),
                  SizedBox(height: 12),
                  Text(
                    'LISTEN · REPEAT · LEARN',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      Text(
        clip.title,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w900,
          color: _ink,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        clip.source,
        textAlign: TextAlign.center,
        style: const TextStyle(color: _muted),
      ),
      const SizedBox(height: 18),
      Slider(
        value: position.inMilliseconds
            .clamp(0, clip.length.inMilliseconds)
            .toDouble(),
        max: max(1, clip.length.inMilliseconds).toDouble(),
        onChanged: onSeek,
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Text(
              clock(position),
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
            const Spacer(),
            Text(
              clock(clip.length),
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: onPrevious,
            iconSize: 30,
            icon: const Icon(Icons.skip_previous_rounded),
          ),
          IconButton.filled(
            onPressed: () => onSkip(-1),
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFE4ECEB),
              foregroundColor: _ink,
            ),
            icon: Text(
              '-$skipSeconds',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 4),
          IconButton.filled(
            onPressed: onPlay,
            style: IconButton.styleFrom(
              backgroundColor: _ink,
              foregroundColor: Colors.white,
              fixedSize: const Size(64, 64),
            ),
            iconSize: 36,
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            ),
          ),
          IconButton.filled(
            onPressed: () => onSkip(1),
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFE4ECEB),
              foregroundColor: _ink,
            ),
            icon: Text(
              '+$skipSeconds',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            onPressed: onNext,
            iconSize: 30,
            icon: const Icon(Icons.skip_next_rounded),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: tr('셔플', 'Shuffle'),
            onPressed: onShuffle,
            color: shuffle ? _blue : _muted,
            icon: const Icon(Icons.shuffle),
          ),
          const SizedBox(width: 18),
          ActionChip(
            onPressed: onSpeed,
            avatar: const Icon(Icons.speed, size: 18),
            label: Text(
              '$speed×',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 18),
          IconButton(
            tooltip: tr('현재 클립 반복', 'Repeat Current Clip'),
            onPressed: onRepeat,
            color: repeat ? _blue : _muted,
            icon: const Icon(Icons.repeat_one),
          ),
        ],
      ),
      const SizedBox(height: 24),
      Container(
        padding: const EdgeInsets.all(21),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: const Color(0xFFE7E4DB)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.notes_rounded, color: _blue),
                const SizedBox(width: 9),
                Text('SCRIPT', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              clip.script.isEmpty
                  ? tr(
                      '등록된 스크립트가 없습니다. 편집 버튼에서 추가할 수 있어요.',
                      'No script has been added. Use the edit button to add one.',
                    )
                  : clip.script,
              style: clip.script.isEmpty
                  ? Theme.of(context).textTheme.bodyMedium
                  : Theme.of(context).textTheme.bodyLarge,
            ),
            if (clip.memo.isNotEmpty) ...[
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E6),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  'NOTE  ${clip.memo}',
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ],
  );
}

class ClipTile extends StatelessWidget {
  const ClipTile({
    super.key,
    required this.clip,
    required this.onTap,
    this.onMore,
    this.numbered,
  });
  final StudyClip clip;
  final VoidCallback onTap;
  final VoidCallback? onMore;
  final int? numbered;
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(18),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: clip.completed
                  ? const Color(0xFFDDEAE6)
                  : const Color(0xFFFFE5CD),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Center(
              child: numbered == null
                  ? Icon(
                      clip.completed
                          ? Icons.check_rounded
                          : Icons.play_arrow_rounded,
                      color: _ink,
                    )
                  : Text(
                      '$numbered',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                        color: _ink,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  clip.title,
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  '${clip.playlist} · ${clock(clip.length)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                  maxLines: 1,
                ),
              ],
            ),
          ),
          if (onMore != null)
            IconButton(
              onPressed: onMore,
              icon: const Icon(Icons.more_vert, color: _muted),
            )
          else
            const Icon(Icons.chevron_right, color: _muted),
        ],
      ),
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({super.key, required this.title, required this.action});
  final String title, action;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      Text(
        action,
        style: const TextStyle(color: _blue, fontWeight: FontWeight.w700),
      ),
    ],
  );
}

class SpeedSheet extends StatelessWidget {
  const SpeedSheet({super.key, required this.value});
  final double value;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('재생 속도', 'Playback Speed'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 14),
          ...[.5, .75, 1.0, 1.25, 1.5, 2.0].map(
            (v) => ListTile(
              title: Text('$v×'),
              trailing: v == value
                  ? const Icon(Icons.check_circle, color: _blue)
                  : null,
              onTap: () => Navigator.pop(context, v),
            ),
          ),
        ],
      ),
    ),
  );
}

class ClipEditor extends StatefulWidget {
  const ClipEditor({super.key, this.clip, required this.playlists});
  final StudyClip? clip;
  final List<String> playlists;
  @override
  State<ClipEditor> createState() => _ClipEditorState();
}

class _ClipEditorState extends State<ClipEditor> {
  late final TextEditingController title, source, script, memo;
  late Duration start, end;
  late String playlist;
  String? audioPath;
  final AudioPlayer _previewPlayer = AudioPlayer();
  Timer? _previewTimer;
  bool _previewing = false;
  Duration _previewPosition = Duration.zero;
  bool _timelineMode = false;
  bool _locatorPlaying = false;
  Duration _audioDuration = Duration.zero;
  Duration _locatorPosition = Duration.zero;
  Duration _detailCenter = Duration.zero;
  int _detailWindowSeconds = 30;
  SilenceDetectionSettings _silenceSettings = const SilenceDetectionSettings();
  List<DetectedSegment> _detectedSegments = const [];
  int? _selectedDetectedSegment;
  bool _analyzingSilence = false;
  StreamSubscription<Duration>? _locatorSubscription;

  int get _detailStartMs {
    final durationMs = _audioDuration.inMilliseconds;
    final windowMs = _detailWindowSeconds * 1000;
    final latestStart = max(0, durationMs - windowMs);
    return (_detailCenter.inMilliseconds - windowMs ~/ 2).clamp(0, latestStart);
  }

  int get _detailEndMs => min(
    _audioDuration.inMilliseconds,
    _detailStartMs + _detailWindowSeconds * 1000,
  );
  @override
  void initState() {
    super.initState();
    unawaited(_restoreSilenceSettings());
    final c = widget.clip;
    title = TextEditingController(
      text: c?.title ?? tr('새 Conversation', 'New Conversation'),
    );
    source = TextEditingController(text: c?.source ?? '');
    script = TextEditingController(text: c?.script ?? '');
    memo = TextEditingController(text: c?.memo ?? '');
    start = c?.start ?? const Duration(minutes: 1);
    end = c?.end ?? const Duration(minutes: 2);
    _previewPosition = start;
    playlist = c != null && widget.playlists.contains(c.playlist)
        ? c.playlist
        : widget.playlists.first;
    audioPath = c?.audioPath;
    _locatorPosition = c?.start ?? Duration.zero;
    _detailCenter = _locatorPosition;
    _locatorSubscription = _previewPlayer.positionStream.listen((position) {
      if (!mounted) return;
      if (_previewing) {
        if (position >= end) {
          _previewPlayer.pause();
          _previewTimer?.cancel();
          setState(() {
            _previewPosition = end;
            _previewing = false;
          });
        } else if (position >= start) {
          setState(() => _previewPosition = position);
        }
        return;
      }
      if (!_locatorPlaying) return;
      if (_audioDuration > Duration.zero && position >= _audioDuration) {
        _previewPlayer.pause();
        setState(() {
          _locatorPosition = _audioDuration;
          _locatorPlaying = false;
        });
      } else {
        setState(() => _locatorPosition = position);
      }
    });
    if (audioPath != null) unawaited(_loadAudioDuration(audioPath!));
  }

  @override
  void dispose() {
    title.dispose();
    source.dispose();
    script.dispose();
    memo.dispose();
    _previewTimer?.cancel();
    _locatorSubscription?.cancel();
    _previewPlayer.dispose();
    super.dispose();
  }

  Future<void> _pickAudio() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'm4a', 'wav', 'aac', 'ogg', 'flac'],
    );
    final file = result?.files.single;
    if (file?.path == null) return;
    setState(() {
      audioPath = file!.path;
      source.text = file.name;
      _detectedSegments = const [];
      _selectedDetectedSegment = null;
    });
    try {
      final duration = await _setPreviewFile(file!.path!);
      if (duration != null && mounted) {
        setState(() {
          _audioDuration = duration;
          _locatorPosition = Duration.zero;
          _detailCenter = Duration.zero;
          if (widget.clip == null) {
            start = Duration.zero;
            end = duration < const Duration(minutes: 1)
                ? duration
                : const Duration(minutes: 1);
          } else {
            if (start > duration) start = Duration.zero;
            if (end > duration) end = duration;
          }
          _previewPosition = start;
        });
      }
    } catch (_) {
      // The player will show a clear error if preview is attempted.
    }
  }

  Future<Duration?> _setPreviewFile(String path) =>
      _previewPlayer.setAudioSource(
        AudioSource.file(
          path,
          tag: MediaItem(
            id: 'preview-${path.hashCode}',
            title: title.text.trim().isEmpty
                ? tr('클립 위치 찾기', 'Find Clip Position')
                : title.text.trim(),
            album: tr('LC Note · 클립 편집', 'LC Note · Clip Editor'),
          ),
        ),
      );

  Future<void> _loadAudioDuration(String path) async {
    try {
      final duration = await _setPreviewFile(path);
      if (duration != null && mounted) {
        setState(() {
          _audioDuration = duration;
          _locatorPosition = _locatorPosition > duration
              ? Duration.zero
              : _locatorPosition;
          _detailCenter = _locatorPosition;
        });
      }
    } catch (_) {
      // A clear message is shown when the user tries to play the missing file.
    }
  }

  Future<void> _analyzeSilence() async {
    if (audioPath == null || _audioDuration <= Duration.zero) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              '먼저 원본 오디오 파일을 선택해 주세요.',
              'Please select the original audio file first.',
            ),
          ),
        ),
      );
      return;
    }
    setState(() => _analyzingSilence = true);
    try {
      final amplitudes = await _extractWaveformMemorySafe(audioPath!);
      final segments = detectSpeechSegments(
        amplitudes: amplitudes,
        duration: _audioDuration,
        settings: _silenceSettings,
      );
      if (!mounted) return;
      setState(() {
        _detectedSegments = segments;
        _selectedDetectedSegment = null;
        _analyzingSilence = false;
      });
      if (segments.length <= 1) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                '긴 무음을 찾지 못했습니다. 감지 설정을 조정해 보세요.',
                'No long silence was found. Try adjusting the detection settings.',
              ),
            ),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _analyzingSilence = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              '오디오를 분석할 수 없습니다. 다른 파일이나 설정으로 다시 시도해 주세요.',
              'Unable to analyze this audio. Try another file or different settings.',
            ),
          ),
        ),
      );
    }
  }

  Future<List<double>> _extractWaveformMemorySafe(String inputPath) async {
    const sampleRate = 8000;
    const samplesPerWindow = sampleRate ~/ 10;
    final separator = Platform.pathSeparator;
    final tempFile = File(
      '${Directory.systemTemp.path}${separator}lc_note_analysis_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    RandomAccessFile? reader;
    try {
      final wavPath = await AudioDecoder.convertToWav(
        inputPath,
        tempFile.path,
        sampleRate: sampleRate,
        channels: 1,
        bitDepth: 16,
      );
      reader = await File(wavPath).open();
      final header = await reader.read(44);
      if (header.length < 44 ||
          ascii.decode(header.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
          ascii.decode(header.sublist(8, 12), allowInvalid: true) != 'WAVE') {
        throw const FormatException('Invalid WAV output');
      }

      await reader.setPosition(12);
      var dataSize = 0;
      while (await reader.position() + 8 <= await reader.length()) {
        final chunkHeader = await reader.read(8);
        if (chunkHeader.length < 8) break;
        final chunkId = ascii.decode(
          chunkHeader.sublist(0, 4),
          allowInvalid: true,
        );
        final chunkSize = ByteData.sublistView(
          Uint8List.fromList(chunkHeader),
        ).getUint32(4, Endian.little);
        if (chunkId == 'data') {
          dataSize = chunkSize;
          break;
        }
        await reader.setPosition(
          await reader.position() + chunkSize + (chunkSize.isOdd ? 1 : 0),
        );
      }
      if (dataSize <= 0) throw const FormatException('Missing WAV data');

      final amplitudes = <double>[];
      var remainingBytes = dataSize;
      var maximum = 0.0;
      const bytesPerWindow = samplesPerWindow * 2;
      while (remainingBytes > 0) {
        final bytes = await reader.read(min(bytesPerWindow, remainingBytes));
        if (bytes.isEmpty) break;
        remainingBytes -= bytes.length;
        final data = ByteData.sublistView(Uint8List.fromList(bytes));
        var squaredSum = 0.0;
        final sampleCount = bytes.length ~/ 2;
        for (var offset = 0; offset + 1 < bytes.length; offset += 2) {
          final sample = data.getInt16(offset, Endian.little) / 32768.0;
          squaredSum += sample * sample;
        }
        final rms = sampleCount == 0 ? 0.0 : sqrt(squaredSum / sampleCount);
        amplitudes.add(rms);
        maximum = max(maximum, rms);
      }
      if (maximum > 0) {
        for (var i = 0; i < amplitudes.length; i++) {
          amplitudes[i] /= maximum;
        }
      }
      return amplitudes;
    } finally {
      await reader?.close();
      if (await tempFile.exists()) await tempFile.delete();
    }
  }

  Future<void> _restoreSilenceSettings() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _silenceSettings = SilenceDetectionSettings(
        threshold: preferences.getDouble('silenceThreshold') ?? .04,
        minimumSilence: Duration(
          milliseconds: preferences.getInt('minimumSilenceMs') ?? 800,
        ),
        minimumSegment: Duration(
          milliseconds: preferences.getInt('minimumSegmentMs') ?? 3000,
        ),
        padding: Duration(
          milliseconds: preferences.getInt('silencePaddingMs') ?? 200,
        ),
      );
    });
  }

  Future<void> _saveSilenceSettings() async {
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setDouble('silenceThreshold', _silenceSettings.threshold),
      preferences.setInt(
        'minimumSilenceMs',
        _silenceSettings.minimumSilence.inMilliseconds,
      ),
      preferences.setInt(
        'minimumSegmentMs',
        _silenceSettings.minimumSegment.inMilliseconds,
      ),
      preferences.setInt(
        'silencePaddingMs',
        _silenceSettings.padding.inMilliseconds,
      ),
    ]);
  }

  Future<void> _showSilenceSettings() async {
    var threshold = _silenceSettings.threshold;
    var minimumSilenceMs = _silenceSettings.minimumSilence.inMilliseconds;
    var minimumSegmentMs = _silenceSettings.minimumSegment.inMilliseconds;
    var paddingMs = _silenceSettings.padding.inMilliseconds;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('자동 구간 감지 설정', 'Automatic Segmentation Settings'),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 18),
                Text(
                  tr(
                    '무음 민감도 · ${(threshold * 100).round()}%',
                    'Silence sensitivity · ${(threshold * 100).round()}%',
                  ),
                ),
                Slider(
                  value: threshold,
                  min: .01,
                  max: .15,
                  divisions: 14,
                  onChanged: (value) => setSheetState(() => threshold = value),
                ),
                Text(
                  tr(
                    '최소 무음 길이 · ${(minimumSilenceMs / 1000).toStringAsFixed(1)}초',
                    'Minimum silence · ${(minimumSilenceMs / 1000).toStringAsFixed(1)} sec',
                  ),
                ),
                Slider(
                  value: minimumSilenceMs.toDouble(),
                  min: 300,
                  max: 2500,
                  divisions: 22,
                  onChanged: (value) =>
                      setSheetState(() => minimumSilenceMs = value.round()),
                ),
                Text(
                  tr(
                    '최소 구간 길이 · ${(minimumSegmentMs / 1000).toStringAsFixed(0)}초',
                    'Minimum segment · ${(minimumSegmentMs / 1000).toStringAsFixed(0)} sec',
                  ),
                ),
                Slider(
                  value: minimumSegmentMs.toDouble(),
                  min: 1000,
                  max: 15000,
                  divisions: 14,
                  onChanged: (value) =>
                      setSheetState(() => minimumSegmentMs = value.round()),
                ),
                Text(
                  tr(
                    '앞뒤 여유 · ${(paddingMs / 1000).toStringAsFixed(1)}초',
                    'Boundary padding · ${(paddingMs / 1000).toStringAsFixed(1)} sec',
                  ),
                ),
                Slider(
                  value: paddingMs.toDouble(),
                  min: 0,
                  max: 1000,
                  divisions: 10,
                  onChanged: (value) =>
                      setSheetState(() => paddingMs = value.round()),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: Text(tr('설정 저장', 'Save Settings')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved != true || !mounted) return;
    setState(() {
      _silenceSettings = SilenceDetectionSettings(
        threshold: threshold,
        minimumSilence: Duration(milliseconds: minimumSilenceMs),
        minimumSegment: Duration(milliseconds: minimumSegmentMs),
        padding: Duration(milliseconds: paddingMs),
      );
      _detectedSegments = const [];
      _selectedDetectedSegment = null;
    });
    await _saveSilenceSettings();
  }

  void _useDetectedSegment(int index) {
    final segment = _detectedSegments[index];
    _previewPlayer.pause();
    _previewTimer?.cancel();
    setState(() {
      _selectedDetectedSegment = index;
      start = segment.start;
      end = segment.end;
      _previewPosition = segment.start;
      _locatorPosition = segment.start;
      _detailCenter = segment.start;
      _previewing = false;
      _locatorPlaying = false;
    });
  }

  Future<void> _previewDetectedSegment(int index) async {
    _useDetectedSegment(index);
    await _togglePreview();
  }

  Future<void> _playFromLocator([Duration? position]) async {
    if (audioPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              '먼저 원본 오디오 파일을 선택해 주세요.',
              'Please select the original audio file first.',
            ),
          ),
        ),
      );
      return;
    }
    try {
      _previewTimer?.cancel();
      if (position != null) _locatorPosition = position;
      await _previewPlayer.seek(_locatorPosition);
      unawaited(_previewPlayer.play());
      if (mounted) {
        setState(() {
          _previewing = false;
          _locatorPlaying = true;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                '선택한 위치에서 오디오를 재생할 수 없습니다.',
                'Unable to play audio from the selected position.',
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _toggleLocatorPlayback() async {
    if (_locatorPlaying) {
      await _previewPlayer.pause();
      if (mounted) setState(() => _locatorPlaying = false);
    } else {
      await _playFromLocator();
    }
  }

  Future<void> _nudgeLocator(int seconds) async {
    final nextMs = (_locatorPosition.inMilliseconds + seconds * 1000).clamp(
      0,
      _audioDuration.inMilliseconds,
    );
    setState(() {
      _locatorPosition = Duration(milliseconds: nextMs);
      _detailCenter = _locatorPosition;
    });
    await _playFromLocator();
  }

  void _setBoundaryFromLocator(bool isStart) {
    if (isStart &&
        _audioDuration > Duration.zero &&
        _locatorPosition >= _audioDuration) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              '시작점은 오디오 끝보다 앞이어야 합니다.',
              'The start point must be before the end of the audio.',
            ),
          ),
        ),
      );
      return;
    }
    setState(() {
      if (isStart) {
        start = _locatorPosition;
        if (start >= end) {
          final proposed = start + const Duration(seconds: 1);
          end = _audioDuration > Duration.zero && proposed > _audioDuration
              ? _audioDuration
              : proposed;
        }
      } else if (_locatorPosition > start) {
        end = _locatorPosition;
      }
      _previewPosition = start;
    });
    if (!isStart && _locatorPosition <= start) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              '종료점은 시작점보다 뒤에 있어야 합니다.',
              'The end point must be after the start point.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _togglePreview() async {
    if (audioPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              '먼저 원본 오디오 파일을 선택해 주세요.',
              'Please select the original audio file first.',
            ),
          ),
        ),
      );
      return;
    }
    if (_previewing) {
      _previewTimer?.cancel();
      await _previewPlayer.pause();
      if (mounted) setState(() => _previewing = false);
      return;
    }
    try {
      if (_locatorPlaying) {
        await _previewPlayer.pause();
        _locatorPlaying = false;
      }
      await _setPreviewFile(audioPath!);
      await _previewPlayer.seek(start);
      unawaited(_previewPlayer.play());
      if (mounted) {
        setState(() {
          _previewPosition = start;
          _previewing = true;
        });
      }
      _previewTimer = Timer(end - start, () async {
        await _previewPlayer.pause();
        if (mounted) {
          setState(() {
            _previewPosition = end;
            _previewing = false;
          });
        }
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('선택한 오디오를 재생할 수 없습니다.', 'Unable to play the selected audio.'),
            ),
          ),
        );
      }
    }
  }

  Future<void> _playSelectionFrom(Duration position) async {
    if (audioPath == null || end <= start) return;
    final safePosition = position < start || position >= end ? start : position;
    try {
      _previewTimer?.cancel();
      if (_locatorPlaying) {
        await _previewPlayer.pause();
        _locatorPlaying = false;
      }
      await _setPreviewFile(audioPath!);
      await _previewPlayer.seek(safePosition);
      unawaited(_previewPlayer.play());
      if (!mounted) return;
      setState(() {
        _previewPosition = safePosition;
        _previewing = true;
      });
      _previewTimer = Timer(end - safePosition, () async {
        await _previewPlayer.pause();
        if (mounted) {
          setState(() {
            _previewPosition = end;
            _previewing = false;
          });
        }
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('선택한 오디오를 재생할 수 없습니다.', 'Unable to play the selected audio.'),
            ),
          ),
        );
      }
    }
  }

  void adjust(bool isStart, int milliseconds) {
    setState(() {
      if (isStart) {
        start += Duration(milliseconds: milliseconds);
        if (start < Duration.zero) start = Duration.zero;
        if (start >= end) start = end - const Duration(milliseconds: 100);
      } else {
        end += Duration(milliseconds: milliseconds);
        if (end <= start) end = start + const Duration(milliseconds: 100);
      }
      _previewPosition = start;
    });
  }

  Future<void> editTime(bool isStart) async {
    final current = isStart ? start : end;
    final controller = TextEditingController(
      text:
          '${current.inMinutes}:${current.inSeconds.remainder(60).toString().padLeft(2, '0')}.${current.inMilliseconds.remainder(1000) ~/ 100}',
    );
    final value = await showDialog<Duration>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isStart
              ? tr('시작 시간 입력', 'Enter Start Time')
              : tr('종료 시간 입력', 'Enter End Time'),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.datetime,
          decoration: InputDecoration(
            hintText: tr('분:초.소수 (예: 2:10.5)', 'min:sec.tenths (e.g. 2:10.5)'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('취소', 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              final match = RegExp(
                r'^(\d+):([0-5]?\d)(?:\.(\d))?$',
              ).firstMatch(controller.text.trim());
              if (match == null) return;
              Navigator.pop(
                context,
                Duration(
                  minutes: int.parse(match.group(1)!),
                  seconds: int.parse(match.group(2)!),
                  milliseconds: int.parse(match.group(3) ?? '0') * 100,
                ),
              );
            },
            child: Text(tr('적용', 'Apply')),
          ),
        ],
      ),
    );
    if (value != null) adjust(isStart, (value - current).inMilliseconds);
  }

  @override
  Widget build(BuildContext context) => Container(
    height: MediaQuery.sizeOf(context).height * .91,
    decoration: const BoxDecoration(
      color: _paper,
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    child: SafeArea(
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          22,
          12,
          22,
          22 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFC8C8C2),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.clip == null
                      ? tr('새 클립 만들기', 'Create New Clip')
                      : tr('클립 편집', 'Edit Clip'),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr('취소', 'Cancel')),
              ),
            ],
          ),
          Text(
            tr(
              'Conversation 전체의 시작과 끝을 지정하세요.',
              'Set the start and end of the entire conversation.',
            ),
            style: const TextStyle(color: _muted),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  icon: const Icon(Icons.tune),
                  label: Text(tr('시간 직접 조정', 'Adjust Time')),
                ),
                ButtonSegment(
                  value: true,
                  icon: const Icon(Icons.linear_scale),
                  label: Text(tr('타임라인 탐색', 'Explore Timeline')),
                ),
              ],
              selected: {_timelineMode},
              onSelectionChanged: (value) {
                _previewPlayer.pause();
                _previewTimer?.cancel();
                setState(() {
                  _timelineMode = value.first;
                  _previewing = false;
                  _locatorPlaying = false;
                });
              },
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _ink,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                if (!_timelineMode) ...[
                  Row(
                    children: [
                      Expanded(
                        child: TimeAdjuster(
                          label: tr('시작', 'Start'),
                          time: start,
                          onChange: (v) => adjust(true, v),
                          onTimeTap: () => editTime(true),
                        ),
                      ),
                      Container(width: 1, height: 82, color: Colors.white24),
                      Expanded(
                        child: TimeAdjuster(
                          label: tr('종료', 'End'),
                          time: end,
                          onChange: (v) => adjust(false, v),
                          onTimeTap: () => editTime(false),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(Icons.graphic_eq, color: _mint, size: 19),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tr(
                            '선택 구간 안에서 들을 위치를 조절하세요.',
                            'Seek within the selected range.',
                          ),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    min: start.inMilliseconds.toDouble(),
                    max: max(
                      start.inMilliseconds + 1,
                      end.inMilliseconds,
                    ).toDouble(),
                    value: _previewPosition.inMilliseconds
                        .clamp(
                          start.inMilliseconds,
                          max(start.inMilliseconds + 1, end.inMilliseconds),
                        )
                        .toDouble(),
                    onChanged: audioPath == null
                        ? null
                        : (value) {
                            _previewTimer?.cancel();
                            _previewPlayer.pause();
                            setState(() {
                              _previewing = false;
                              _previewPosition = Duration(
                                milliseconds: value.round(),
                              );
                            });
                          },
                    onChangeEnd: audioPath == null
                        ? null
                        : (value) => _playSelectionFrom(
                            Duration(milliseconds: value.round()),
                          ),
                  ),
                  Row(
                    children: [
                      Text(
                        clock(start),
                        style: const TextStyle(color: Colors.white60),
                      ),
                      const Spacer(),
                      Text(
                        clock(_previewPosition),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        clock(end),
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ],
                  ),
                ] else ...[
                  Row(
                    children: [
                      const Icon(
                        Icons.touch_app_outlined,
                        color: _mint,
                        size: 19,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          audioPath == null
                              ? tr(
                                  '먼저 아래에서 오디오 파일을 선택하세요.',
                                  'Select an audio file below first.',
                                )
                              : tr(
                                  '바를 누르거나 움직이면 그 위치부터 재생됩니다.',
                                  'Tap or drag the bar to play from that position.',
                                ),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      tr('전체 오디오에서 대략 찾기', 'Find an Approximate Position'),
                      style: const TextStyle(
                        color: _mint,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Slider(
                    value: _locatorPosition.inMilliseconds
                        .clamp(0, max(1, _audioDuration.inMilliseconds))
                        .toDouble(),
                    max: max(1, _audioDuration.inMilliseconds).toDouble(),
                    onChanged: audioPath == null
                        ? null
                        : (value) => setState(
                            () => _locatorPosition = Duration(
                              milliseconds: value.round(),
                            ),
                          ),
                    onChangeEnd: audioPath == null
                        ? null
                        : (value) {
                            final position = Duration(
                              milliseconds: value.round(),
                            );
                            setState(() {
                              _locatorPosition = position;
                              _detailCenter = position;
                            });
                            _playFromLocator();
                          },
                  ),
                  Row(
                    children: [
                      Text(
                        clock(_locatorPosition),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        clock(_audioDuration),
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white24, height: 28),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      tr('현재 위치 주변 정밀 탐색', 'Fine-tune Around Current Position'),
                      style: const TextStyle(
                        color: _mint,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 7,
                    children: [15, 30, 60]
                        .map(
                          (seconds) => ChoiceChip(
                            label: Text(
                              tr('$seconds초 확대', '$seconds-sec zoom'),
                            ),
                            selected: _detailWindowSeconds == seconds,
                            onSelected: (_) => setState(() {
                              _detailWindowSeconds = seconds;
                              _detailCenter = _locatorPosition;
                            }),
                            visualDensity: VisualDensity.compact,
                          ),
                        )
                        .toList(),
                  ),
                  Slider(
                    min: _detailStartMs.toDouble(),
                    max: max(_detailStartMs + 1, _detailEndMs).toDouble(),
                    value: _locatorPosition.inMilliseconds
                        .clamp(
                          _detailStartMs,
                          max(_detailStartMs + 1, _detailEndMs),
                        )
                        .toDouble(),
                    onChanged: audioPath == null
                        ? null
                        : (value) => setState(
                            () => _locatorPosition = Duration(
                              milliseconds: value.round(),
                            ),
                          ),
                    onChangeEnd: audioPath == null
                        ? null
                        : (value) => _playFromLocator(
                            Duration(milliseconds: value.round()),
                          ),
                  ),
                  Row(
                    children: [
                      Text(
                        clock(Duration(milliseconds: _detailStartMs)),
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        clock(Duration(milliseconds: _detailEndMs)),
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton.filledTonal(
                        onPressed: audioPath == null
                            ? null
                            : () => _nudgeLocator(-5),
                        icon: const Text(
                          '-5',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filled(
                        onPressed: _toggleLocatorPlayback,
                        icon: Icon(
                          _locatorPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        tooltip: _locatorPlaying
                            ? tr('탐색 재생 정지', 'Stop Preview')
                            : tr('현재 위치부터 재생', 'Play from Current Position'),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filledTonal(
                        onPressed: audioPath == null
                            ? null
                            : () => _nudgeLocator(5),
                        icon: const Text(
                          '+5',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: audioPath == null
                              ? null
                              : () => _setBoundaryFromLocator(true),
                          child: Text(
                            tr(
                              '현재 위치를 시작으로\n${clock(start)}',
                              'Set Current as Start\n${clock(start)}',
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: audioPath == null
                              ? null
                              : () => _setBoundaryFromLocator(false),
                          child: Text(
                            tr(
                              '현재 위치를 종료로\n${clock(end)}',
                              'Set Current as End\n${clock(end)}',
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _togglePreview,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white30),
                  ),
                  icon: Icon(_previewing ? Icons.pause : Icons.play_arrow),
                  label: Text(
                    _previewing
                        ? tr('미리 듣기 정지', 'Stop Preview')
                        : tr(
                            '선택 구간 미리 듣기 · ${clock(end - start)}',
                            'Preview Selection · ${clock(end - start)}',
                          ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: title,
            decoration: InputDecoration(
              labelText: tr('클립 제목', 'Clip Title'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: source,
            readOnly: true,
            onTap: _pickAudio,
            decoration: InputDecoration(
              labelText: tr('원본 오디오', 'Original Audio'),
              hintText: tr('눌러서 오디오 파일 선택', 'Tap to select an audio file'),
              prefixIcon: const Icon(Icons.audio_file_outlined),
              suffixIcon: IconButton(
                onPressed: _pickAudio,
                icon: const Icon(Icons.folder_open_outlined),
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFEAF3F1),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFFD3E5E1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.auto_awesome, color: _blue),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        tr('무음 기준 자동 구간', 'Automatic Silence Segments'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      onPressed: _showSilenceSettings,
                      tooltip: tr('감지 설정', 'Detection Settings'),
                      icon: const Icon(Icons.tune),
                    ),
                  ],
                ),
                Text(
                  tr(
                    '긴 무음을 찾아 듣기 문제를 자동으로 나눕니다.',
                    'Find long silences and split the listening exercise automatically.',
                  ),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: audioPath == null || _analyzingSilence
                      ? null
                      : _analyzeSilence,
                  icon: _analyzingSilence
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.content_cut),
                  label: Text(
                    _analyzingSilence
                        ? tr('오디오 분석 중…', 'Analyzing Audio…')
                        : tr('자동 구간 찾기', 'Find Segments Automatically'),
                  ),
                ),
                if (_detectedSegments.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    tr(
                      '${_detectedSegments.length}개 구간을 찾았습니다. 사용할 구간을 선택하세요.',
                      '${_detectedSegments.length} ${_detectedSegments.length == 1 ? 'segment' : 'segments'} found. Select one to use.',
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  ...List.generate(_detectedSegments.length, (index) {
                    final segment = _detectedSegments[index];
                    final selected = _selectedDetectedSegment == index;
                    return Card(
                      elevation: 0,
                      color: selected ? _mint : Colors.white,
                      margin: const EdgeInsets.only(bottom: 7),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _useDetectedSegment(index),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                          child: Row(
                            children: [
                              Icon(
                                selected
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                color: selected ? _blue : _muted,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      tr(
                                        '구간 ${index + 1}',
                                        'Segment ${index + 1}',
                                      ),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    Text(
                                      '${clock(segment.start)} – ${clock(segment.end)} · ${clock(segment.length)}',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                onPressed: () => _previewDetectedSegment(index),
                                tooltip: tr('미리 듣기', 'Preview'),
                                icon: const Icon(Icons.play_arrow_rounded),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: playlist,
            decoration: InputDecoration(
              labelText: tr('재생목록', 'Playlist'),
              border: const OutlineInputBorder(),
            ),
            items: widget.playlists
                .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                .toList(),
            onChanged: (v) => playlist = v!,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: script,
            minLines: 7,
            maxLines: 12,
            decoration: InputDecoration(
              labelText: tr('전체 스크립트 (선택)', 'Full Script (Optional)'),
              alignLabelWithHint: true,
              hintText: tr(
                '필요한 경우 Conversation 전체 스크립트를 입력하세요.',
                'Enter the full conversation script if needed.',
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: memo,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: tr('메모 (선택)', 'Notes (Optional)'),
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () {
              if (title.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      tr('클립 제목을 입력해 주세요.', 'Please enter a clip title.'),
                    ),
                  ),
                );
                return;
              }
              Navigator.pop(
                context,
                StudyClip(
                  id:
                      widget.clip?.id ??
                      DateTime.now().millisecondsSinceEpoch.toString(),
                  title: title.text.trim(),
                  source: source.text.trim(),
                  start: start,
                  end: end,
                  script: script.text.trim(),
                  memo: memo.text.trim(),
                  playlist: playlist,
                  completed: widget.clip?.completed ?? false,
                  audioPath: audioPath,
                ),
              );
            },
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(54),
              backgroundColor: _blue,
            ),
            icon: const Icon(Icons.check),
            label: Text(
              widget.clip == null
                  ? tr('클립 저장', 'Save Clip')
                  : tr('변경사항 저장', 'Save Changes'),
            ),
          ),
        ],
      ),
    ),
  );
}

class TimeAdjuster extends StatelessWidget {
  const TimeAdjuster({
    super.key,
    required this.label,
    required this.time,
    required this.onChange,
    required this.onTimeTap,
  });
  final String label;
  final Duration time;
  final ValueChanged<int> onChange;
  final VoidCallback onTimeTap;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        label,
        style: const TextStyle(color: _mint, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 4),
      InkWell(
        onTap: onTimeTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            '${clock(time)}.${(time.inMilliseconds.remainder(1000) ~/ 100)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SmallTimeButton(text: '-1', onTap: () => onChange(-1000)),
          SmallTimeButton(text: '-.1', onTap: () => onChange(-100)),
          SmallTimeButton(text: '+.1', onTap: () => onChange(100)),
          SmallTimeButton(text: '+1', onTap: () => onChange(1000)),
        ],
      ),
    ],
  );
}

class SmallTimeButton extends StatelessWidget {
  const SmallTimeButton({super.key, required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    ),
  );
}
