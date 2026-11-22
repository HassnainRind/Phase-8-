// Letter garden (words) and Minesweeper (mines) ports.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'game_core.dart';
import 'game_shell.dart';
import 'games.dart';
import 'theme.dart';
import 'widgets.dart';

// ============================================================== Letter garden
const wordModes = ['Bloom', 'Breeze', 'Thorns', 'Twilight', 'Sprint', 'Wildflower'];
String selectedWordMode = 'Bloom';

class WordData {
  static List<List<String>>? words;
  static Map<String, String>? clues;
  static Future<void> load() async {
    if (words != null) return;
    final j = jsonDecode(await rootBundle.loadString('assets/data/words.json')) as Map<String, dynamic>;
    words = (j['words'] as List).map((e) => [e[0] as String, e[1] as String]).toList();
    clues = Map<String, String>.from(j['clues'] as Map);
  }
}

class _Pick {
  final String word, cat, key;
  final int v, count;
  final bool recycled;
  _Pick(this.word, this.cat, this.key, this.v, this.count, this.recycled);
}

const _uniqueKey = 'rainlight_unique_games_v3';

Future<_Pick> pickGardenWord(String mode, int level, int seed) async {
  final prefs = await SharedPreferences.getInstance();
  Map<String, dynamic> store = {};
  try {
    store = Map<String, dynamic>.from(jsonDecode(prefs.getString(_uniqueKey) ?? '{}') as Map);
  } catch (_) {}
  final mem = Map<String, dynamic>.from((store['words'] as Map?) ?? {'seen': [], 'used': {}});
  var seen = Set<String>.from((mem['seen'] as List?) ?? []);
  var used = Map<String, int>.from(((mem['used'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, (v as num).toInt())));
  final all = WordData.words!;
  final desired = math.min(10, 4 + ((level - 1) / 3).floor());
  final minLen = math.max(4, desired - 1), maxLen = math.min(10, desired + 1);
  List<_Pick> gather(Iterable<List<String>> src, {bool zero = false}) {
    final out = <_Pick>[];
    for (final w in src) {
      for (var v = 0; v < 3; v++) {
        final key = '${w[0]}|$mode|$v';
        if (!seen.contains(key)) out.add(_Pick(w[0], w[1], key, v, zero ? 0 : (used[w[0]] ?? 0), false));
      }
    }
    return out;
  }

  var candidates = gather(all.where((w) => w[0].length >= minLen && w[0].length <= maxLen));
  if (candidates.isEmpty) candidates = gather(all);
  var recycled = false;
  if (candidates.isEmpty) {
    seen = {};
    used = {};
    recycled = true;
    candidates = gather(all, zero: true);
  }
  var never = candidates.where((x) => x.count == 0).toList();
  if (never.isEmpty) never = gather(all.where((w) => !used.containsKey(w[0]) || used[w[0]] == 0));
  final source = never.isNotEmpty ? never : candidates;
  final least = source.map((x) => x.count).reduce(math.min);
  final fresh = source.where((x) => x.count == least).toList();
  final p = fresh[seed % fresh.length];
  seen.add(p.key);
  used[p.word] = (used[p.word] ?? 0) + 1;
  store['words'] = {'seen': seen.toList(), 'used': used};
  try {
    await prefs.setString(_uniqueKey, jsonEncode(store));
  } catch (_) {}
  return _Pick(p.word, p.cat, p.key, p.v, p.count, recycled);
}

class WordsGame extends StatefulWidget {
  final GameHost host;
  const WordsGame(this.host, {super.key});
  @override
  State<WordsGame> createState() => _WordsState();
}

class _WordsState extends State<WordsGame> {
  GameHost get h => widget.host;
  bool ready = false;
  late String word, cat, mode;
  late List<String> letters;
  final List<int> answer = [];
  final Set<int> usedIdx = {};
  bool hintShown = false, hidden = false;
  int wrong = 0;
  int? seconds;
  bool recycled = false;
  late ToolSpec undo, clear, hint;

  @override
  void initState() {
    super.initState();
    mode = selectedWordMode;
    init();
  }

  Future<void> init() async {
    await WordData.load();
    final level = h.level;
    final p = await pickGardenWord(mode, level, rng.nextInt(1 << 30));
    if (!mounted || h.disposed) return;
    word = p.word;
    cat = p.cat;
    recycled = p.recycled;
    final r = math.Random(rng.nextInt(1 << 30));
    hidden = mode == 'Twilight' || mode == 'Wildflower';
    final extraCount = (mode == 'Bloom' || mode == 'Twilight')
        ? 0
        : mode == 'Breeze'
            ? math.min(2, (level / 8).floor())
            : mode == 'Sprint'
                ? 1
                : math.min(5, 2 + (level / 5).floor());
    const alphabet = 'AEIOURSTLNMDPCBHFGKWV';
    final pool = word.split('');
    final fake = <String>[];
    for (var i = 0; i < extraCount; i++) {
      final choices = alphabet.split('').where((ch) => !pool.contains(ch) || i >= 2).toList();
      fake.add(choices.isEmpty ? 'E' : choices[r.nextInt(choices.length)]);
    }
    letters = shuffle([...pool, ...fake], r);
    if (letters.take(word.length).join() == word) letters = letters.reversed.toList();
    if (mode == 'Breeze' || mode == 'Wildflower') hintShown = true;
    undo = ToolSpec('Undo letter', () {
      if (h.completed) return;
      if (answer.isNotEmpty) setState(() => usedIdx.remove(answer.removeLast()));
      sync();
    }, enabled: false);
    clear = ToolSpec('Clear', () {
      if (h.completed) return;
      setState(() {
        answer.clear();
        usedIdx.clear();
      });
      sync();
    });
    hint = ToolSpec('A little hint', () {
      if (h.completed) return;
      hintShown = true;
      hint.label = 'Hint opened';
      showStatus();
      h.changed();
    });
    h.tools = [undo, clear, hint];
    h.variants = variantsBar();
    if (mode == 'Sprint') {
      seconds = math.max(35, 88 - level * 2);
      tick();
    }
    showStatus();
    if (recycled) h.status = 'All available $mode puzzles were played. A fresh series has begun.';
    setState(() => ready = true);
    sync();
  }

  void tick() => h.later(() {
        if (h.completed) return;
        seconds = seconds! - 1;
        showStatus();
        if (seconds! <= 0) {
          h.fail('Time is up. Start a new challenge when ready.');
          return;
        }
        tick();
      }, 1000);

  void showStatus() {
    final clue = WordData.clues![word] ?? 'A ${word.length} letter word from the ${cat.toLowerCase()} collection';
    h.setStatus('$cat · ${word.length} letters · $mode${hidden && !hintShown ? ' · Clue hidden' : ' · $clue'}${seconds != null ? ' · ${seconds}s' : ''}');
  }

  void sync() {
    undo.enabled = answer.isNotEmpty && !h.completed;
    h.answer = (mode == 'Breeze' ? 'Starts with ${word[0]} · ' : '') + (answer.isEmpty ? 'Tap the letters below' : answer.map((i) => letters[i]).join());
    h.setProgress(answer.length, word.length);
  }

  void tap(int i) {
    if (h.completed || usedIdx.contains(i)) return;
    setState(() {
      usedIdx.add(i);
      answer.add(i);
    });
    sync();
    if (answer.length == word.length) {
      if (answer.map((j) => letters[j]).join() == word) {
        undo.enabled = clear.enabled = hint.enabled = false;
        h.complete('“${word.toLowerCase()}” · A new word has bloomed.');
      } else {
        wrong++;
        if (wrong == 2 && !hintShown) {
          hintShown = true;
          showStatus();
        } else {
          h.setStatus('Not quite. Undo a letter or try a different arrangement.');
        }
      }
    }
  }

  Widget variantsBar() {
    final th = h.th;
    Widget pill(String m) => Pressable(
          scale: .97,
          onTap: () {
            if (selectedWordMode == m) return;
            selectedWordMode = m;
            h.reopen?.call(h.level);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
            decoration: BoxDecoration(
                color: m == mode ? th.soft : Colors.white,
                border: Border.all(color: m == mode ? th.accent : th.edge, width: 1.5),
                borderRadius: BorderRadius.circular(999),
                boxShadow: m == mode ? [BoxShadow(color: th.accent, blurRadius: 12, offset: const Offset(0, 3), spreadRadius: -9)] : null),
            child: Center(child: Text(m, style: ts(10, FontWeight.w700, th.dark))),
          ),
        );
    Widget step(String t, bool on, VoidCallback f) => Opacity(
          opacity: on ? 1 : .35,
          child: Pressable(
            scale: .97,
            onTap: on ? f : null,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: Colors.white, border: Border.all(color: th.edge, width: 1.5), borderRadius: BorderRadius.circular(9)),
              child: Center(child: Text(t, style: ts(19, FontWeight.w700, th.dark, height: 1))),
            ),
          ),
        );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 370),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          childAspectRatio: 370 / 3 / 29,
          children: [for (final m in wordModes) pill(m)],
        ),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          step('−', h.level > 1, () => h.reopen?.call(math.max(1, h.level - 1))),
          const SizedBox(width: 8),
          Text('Challenge ${h.level}', style: ts(11, FontWeight.w700, th.dark)),
          const SizedBox(width: 8),
          step('+', h.level < 40, () => h.reopen?.call(math.min(40, h.level + 1))),
        ]),
        const SizedBox(height: 3),
        Pressable(
          scale: .97,
          onTap: () => h.reopen?.call(h.level),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            child: Text('New word', style: ts(11, FontWeight.w700, th.accent).copyWith(decoration: TextDecoration.underline)),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) return const SizedBox(height: 200);
    final f = (MediaQuery.of(context).size.width * .045).clamp(16.0, 23.0).toDouble();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 450),
      child: grid(math.min(7, letters.length), 5, [
        for (var i = 0; i < letters.length; i++)
          GameCell(th: h.th, index: i, text: letters[i], font: f, onTap: usedIdx.contains(i) ? null : () => tap(i)),
      ]),
    );
  }
}

// ============================================================== Minesweeper (thorns)
class MinesGame extends StatefulWidget {
  final GameHost host;
  const MinesGame(this.host, {super.key});
  @override
  State<MinesGame> createState() => _MinesState();
}

class _MinesState extends State<MinesGame> {
  GameHost get h => widget.host;
  int n = 8, total = 64, count = 10;
  Set<int> mine = {}, open = {}, flags = {};
  bool started = false, over = false, flagMode = false, built = false;
  late ToolSpec toggle;
  Timer? holdTimer;
  bool held = false;
  static const numColors = {
    1: Color(0xFF2563EB),
    2: Color(0xFF15803D),
    3: Color(0xFFDC2626),
    4: Color(0xFF7E22CE),
    5: Color(0xFFB45309),
    6: Color(0xFFB45309)
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (built) return;
    built = true;
    final mq = MediaQuery.of(context);
    final cap = (mq.size.width < 380 || mq.size.height < 640) ? 9 : (mq.size.width < 430 ? 10 : 12);
    n = math.min(cap, 8 + ((h.level - 1) / 2).floor());
    total = n * n;
    count = math.min((total * .26).floor(), (total * (.15 + math.min(h.level, 15) * .008)).round());
    toggle = ToolSpec('⚑ Flag mode: off', () {
      flagMode = !flagMode;
      toggle.label = '⚑ Flag mode: ${flagMode ? 'on' : 'off'}';
      toggle.on = flagMode;
      h.changed();
    });
    h.initial(status: 'Find the $count thorns. Tap to reveal · hold to flag.', progress: 0, tools: [toggle]);
  }

  @override
  void dispose() {
    holdTimer?.cancel();
    super.dispose();
  }

  List<int> nb(int i) {
    final r = i ~/ n, c = i % n;
    final o = <int>[];
    for (var a = -1; a <= 1; a++) {
      for (var b = -1; b <= 1; b++) {
        if (a == 0 && b == 0) continue;
        final y = r + a, x = c + b;
        if (y >= 0 && y < n && x >= 0 && x < n) o.add(y * n + x);
      }
    }
    return o;
  }

  int around(int i) => nb(i).where(mine.contains).length;

  void flag(int i) {
    if (h.completed || over || open.contains(i)) return;
    setState(() => flags.contains(i) ? flags.remove(i) : flags.add(i));
    h.setStatus('Thorns left to mark · ${math.max(0, count - flags.length)}');
  }

  void tap(int i) {
    if (h.completed || over) return;
    if (flagMode) {
      flag(i);
      return;
    }
    if (flags.contains(i) || open.contains(i)) return;
    if (!started) {
      started = true;
      final bad = {i, ...nb(i)};
      mine = shuffle([for (var k = 0; k < total; k++) if (!bad.contains(k)) k]).take(count).toSet();
    }
    if (mine.contains(i)) {
      setState(() => over = true);
      h.fail('A thorn! You cleared ${open.length} cells.');
      return;
    }
    final q = [i];
    setState(() {
      while (q.isNotEmpty) {
        final k = q.removeLast();
        if (open.contains(k) || flags.contains(k)) continue;
        open.add(k);
        if (around(k) == 0) {
          for (final j in nb(k)) {
            if (!open.contains(j)) q.add(j);
          }
        }
      }
    });
    h.setProgress(open.length, total - count);
    if (open.length == total - count) {
      h.complete('Every thorn avoided · $count found');
    } else {
      h.setStatus('Safe so far · ${total - count - open.length} cells to go');
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = (MediaQuery.of(context).size.width * .036).clamp(12.0, 20.0).toDouble();
    return grid(n, 3, [
      for (var i = 0; i < total; i++) cell(i, f),
    ]);
  }

  Widget cell(int i, double f) {
    final isOpen = open.contains(i), isFlag = flags.contains(i), boom = over && mine.contains(i);
    final k = isOpen ? around(i) : 0;
    final c = GameCell(
      th: h.th,
      index: i,
      text: boom ? '✹' : isOpen ? (k > 0 ? '$k' : '') : isFlag ? '⚑' : '',
      radius: 8,
      font: f,
      shadowY: 2,
      bgOverride: boom ? const Color(0xFFFCA5A5) : isOpen ? Colors.white : null,
      borderOverride: boom ? const Color(0xFFDC2626) : isOpen ? h.th.soft : null,
      fgOverride: boom ? const Color(0xFF7F1D1D) : isOpen ? (numColors[k] ?? h.th.dark) : isFlag ? const Color(0xFFDC2626) : null,
      noShadow: isOpen,
      shake: boom ? 1 : 0,
      onTap: () {
        if (held) {
          held = false;
          return;
        }
        tap(i);
      },
    );
    return Listener(
      onPointerDown: (_) {
        held = false;
        holdTimer?.cancel();
        holdTimer = Timer(const Duration(milliseconds: 420), () {
          held = true;
          flag(i);
          HapticFeedback.lightImpact();
        });
      },
      onPointerUp: (_) => holdTimer?.cancel(),
      onPointerCancel: (_) => holdTimer?.cancel(),
      child: c,
    );
  }
}
