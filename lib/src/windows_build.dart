import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cli_util/cli_logging.dart';
import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as p;
import 'method_extensions.dart';
import 'configuration.dart';

/// Handles Windows files build steps (now with auto-confirm "yes")
class WindowsBuild {
  final Logger _logger = GetIt.I<Logger>();
  final Configuration _config = GetIt.I<Configuration>();

  /// If true, we will attempt to automatically confirm any interactive prompts.
  final bool autoYes;

  /// If true, we skip smart detection and just pipe a stream of 'y' answers.
  /// Useful as a last resort on environments that require a real TTY.
  final bool forcePipeYes;

  WindowsBuild({
    this.autoYes = true,
    this.forcePipeYes = false,
  });

  /// Run "shorebird release windows" (or similar) command
  Future<void> build() async {
    // Build the Shorebird args list (mirrors your original)
    final shorebirdArgs = <String>[
      'release',
      'windows',
      ...?_config.windowsBuildArgs,
      if (_config.createWithDebugBuildFiles) '--debug',
    ];

    final shorebirdPath = await _getShorebirdPath();

    final joined = [shorebirdPath, ...shorebirdArgs].join(' ');
    _logger.trace('Preparing to run: $joined');

    final progress =
    _logger.progress('running "shorebird ${shorebirdArgs.join(' ')}"');

    final sw = Stopwatch()..start();

    int code;
    if (!autoYes) {
      // No auto-confirm; run normally (will prompt user if needed)
      _logger.trace('Auto-yes disabled; running normally.');
      final result = await Process.run(shorebirdPath, shorebirdArgs, runInShell: true);
      _forwardProcessResultToLogs(result);
      result.exitOnError();
      code = result.exitCode;
    } else if (forcePipeYes) {
      // Brutal but simple: pipe a stream of "y" answers
      _logger.trace('Auto-yes (pipe mode) enabled; will pipe "y" to Shorebird.');
      code = await _runWithPipeYes(shorebirdPath, shorebirdArgs);
    } else {
      // Smart: detect prompts and reply "y" only when needed
      _logger.trace('Auto-yes (smart mode) enabled; will detect prompts and reply.');
      code = await _runSmartYes(shorebirdPath, shorebirdArgs);
    }

    sw.stop();
    progress.finish(showTiming: true);

    if (code == 0) {
      _logger.stdout('Shorebird command completed successfully in ${sw.elapsed}.');
    } else {
      _logger.stderr(
          'Shorebird command failed with exit code $code after ${sw.elapsed}.');
      throw ProcessException(shorebirdPath, shorebirdArgs,
          'Shorebird failed with exit code $code', code);
    }
  }

  // -------------------- Internals --------------------

  void _forwardProcessResultToLogs(ProcessResult r) {
    if ((r.stdout is String && (r.stdout as String).isNotEmpty) ||
        (r.stdout is List && (r.stdout as List).isNotEmpty)) {
      _logger.stdout(r.stdout.toString());
    }
    if ((r.stderr is String && (r.stderr as String).isNotEmpty) ||
        (r.stderr is List && (r.stderr as List).isNotEmpty)) {
      _logger.stderr(r.stderr.toString());
    }
  }

  Future<int> _runSmartYes(String exe, List<String> args) async {
    final p = await Process.start(exe, args, runInShell: true);

    // decode streams
    final outLines = p.stdout.transform(utf8.decoder).transform(const LineSplitter());
    final errLines = p.stderr.transform(utf8.decoder).transform(const LineSplitter());

    // Common confirmation prompt patterns
    final patterns = <RegExp>[
      RegExp(r'Do you want to continue\??', caseSensitive: false),
      RegExp(r'Proceed\??', caseSensitive: false),
      RegExp(r'Confirm\??', caseSensitive: false),
      RegExp(r'\[\s*[yY]/[nN]\s*\]'), // [y/N], [Y/n]
      RegExp(r'\(\s*[yY]/[nN]\s*\)'), // (y/N), (Y/n)
      RegExp(r'continue\?\s*$', caseSensitive: false),
      RegExp(r'are you sure\??', caseSensitive: false),
    ];

    bool looksLikeConfirm(String line) =>
        patterns.any((re) => re.hasMatch(line));

    // Log and respond on the fly
    final outSub = outLines.listen((line) {
      _logger.stdout(line);
      if (looksLikeConfirm(line)) {
        _logger.trace('Prompt detected in stdout: "$line" -> sending "y"');
        p.stdin.writeln('y');
      }
    });

    final errSub = errLines.listen((line) {
      _logger.stderr(line);
      if (looksLikeConfirm(line)) {
        _logger.trace('Prompt detected in stderr: "$line" -> sending "y"');
        p.stdin.writeln('y');
      }
    });

    // Safety: if the process asks explicitly for "type YES"
    // (rare, but be defensive)
    final upperAffirm = RegExp(r'\btype\s+YES\b', caseSensitive: false);
    final anyLineStream = StreamGroup.merge([outLines, errLines]);
    final anyLineSub = anyLineStream.listen((line) {
      if (upperAffirm.hasMatch(line)) {
        _logger.trace('Explicit "type YES" detected -> sending "YES"');
        p.stdin.writeln('YES');
      }
    });

    final code = await p.exitCode;
    await p.stdin.close();
    await outSub.cancel();
    await errSub.cancel();
    await anyLineSub.cancel();
    return code;
  }

  /// Fallback: run via the platform shell piping "y" into the command.
  /// Windows:  cmd /c "echo y | shorebird args..."
  /// Unix:     bash -lc 'yes | shorebird args...'
  Future<int> _runWithPipeYes(String exe, List<String> args) async {
    if (Platform.isWindows) {
      final cmdLine = 'echo y | ${_quoteIfNeeded(exe)} ${_joinArgsWindows(args)}';
      _logger.trace('Windows pipe fallback: cmd /c "$cmdLine"');
      final p = await Process.start('cmd', ['/c', cmdLine], runInShell: true);
      _pipeLogs(p);
      return await p.exitCode;
    } else {
      // Use yes to feed unlimited 'y'
      final bashLine =
          'yes | ${_quoteIfNeeded(exe)} ${_joinArgsPosix(args)}';
      _logger.trace('POSIX pipe fallback: bash -lc \'$bashLine\'');
      final p = await Process.start('bash', ['-lc', bashLine], runInShell: true);
      _pipeLogs(p);
      return await p.exitCode;
    }
  }

  void _pipeLogs(Process p) {
    p.stdout.transform(utf8.decoder).listen(_logger.stdout);
    p.stderr.transform(utf8.decoder).listen(_logger.stderr);
  }

  String _quoteIfNeeded(String s) {
    if (s.contains(' ')) {
      return Platform.isWindows ? '"$s"' : "'$s'";
    }
    return s;
  }

  String _joinArgsWindows(List<String> args) =>
      args.map((a) => a.contains(' ') ? '"$a"' : a).join(' ');

  String _joinArgsPosix(List<String> args) =>
      args.map((a) => a.contains("'") ? '"$a"' : a).join(' ');

  Future<String> _getShorebirdPath() async {
    // default to 'shorebird' on PATH
    var shorebirdPath = 'shorebird';

    // e.g. C:\Users\Me\fvm\versions\3.7.12\bin\cache\dart-sdk\bin\dart.exe
    final dartPath = p.split(Platform.executable);

    // if contains 'dart-sdk' we can guess where 'shorebird' might live nearby
    if (dartPath.contains('dart-sdk') && dartPath.length > 4) {
      // e.g. ...\bin\shorebird
      final candidate = p.joinAll([
        ...dartPath.sublist(0, dartPath.length - 4),
        shorebirdPath,
      ]);

      if (await File(candidate).exists()) {
        shorebirdPath = candidate;
      }
    }

    _logger.trace('Resolved shorebird path: $shorebirdPath');
    return shorebirdPath;
  }
}

/// Utility to merge streams without importing extra packages.
/// (Small helper to avoid adding `async`/`stream_channel` deps.)
class StreamGroup<T> {
  static Stream<T> merge<T>(Iterable<Stream<T>> streams) async* {
    final subscriptions = <StreamSubscription<T>>[];
    final controller = StreamController<T>();

    void addSub(Stream<T> s) {
      subscriptions.add(s.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {},
        cancelOnError: false,
      ));
    }

    for (final s in streams) {
      addSub(s);
    }

    controller.onCancel = () async {
      for (final sub in subscriptions) {
        await sub.cancel();
      }
    };

    yield* controller.stream;
  }
}