import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/update/windows_update_installer.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory app;
  late Directory stage;
  late File executable;
  late File package;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('monogatari_installer_test_');
    app = await Directory(
      p.join(root.path, "app's [portable] 中文 & data"),
    ).create();
    stage = await Directory(p.join(root.path, "stage's [files] 中文")).create();
    executable = await File(
      p.join(app.path, 'Monogatari.exe'),
    ).writeAsString('old executable');
    package = File(p.join(root.path, "release's [x64] & data.zip"));
  });

  tearDown(() async {
    // Every case owns this newly-created root, including junction targets.
    await root.delete(recursive: true);
  });

  Future<PreparedWindowsUpdate> prepare({bool testing = true}) =>
      WindowsUpdateInstaller().prepare(
        packagePath: package.path,
        executablePath: executable.path,
        processId: 2147483647,
        temporaryDirectory: stage,
        restartApplication: !testing,
        showErrors: !testing,
      );

  test(
    'quoted Unicode paths remain JSON data and do not alter script source',
    () async {
      await package.writeAsString('prepare does not execute the package');
      final prepared = await prepare(testing: false);
      final configuration =
          jsonDecode(await File(prepared.configPath).readAsString()) as Map;
      expect(
        configuration['packagePath'],
        await package.resolveSymbolicLinks(),
      );
      expect(configuration['appDirectory'], await app.resolveSymbolicLinks());
      expect(configuration['executableName'], 'Monogatari.exe');
      expect(configuration['processId'], 2147483647);
      expect(configuration['restartApplication'], isTrue);
      expect(configuration['showErrors'], isTrue);
      final bytes = await File(prepared.scriptPath).readAsBytes();
      expect(bytes.take(3), [0xef, 0xbb, 0xbf]);
      expect(utf8.decode(bytes.skip(3).toList()), windowsUpdateScript);
      expect(windowsUpdateScript.contains(package.path), isFalse);
    },
  );

  test(
    'missing package is rejected before a staging directory is created',
    () async {
      await expectLater(prepare(), throwsA(isA<FileSystemException>()));
      expect(await stage.list().toList(), isEmpty);
    },
  );

  test(
    'non-ZIP package is rejected before a staging directory is created',
    () async {
      package = await File(
        p.join(root.path, 'release.msix'),
      ).writeAsString('not ZIP');
      await expectLater(prepare(), throwsA(isA<FormatException>()));
      expect(await stage.list().toList(), isEmpty);
    },
  );

  test(
    'staging inside the application directory is rejected before creation',
    () async {
      await package.writeAsString('ZIP');
      final before = await app.list().toList();
      await expectLater(
        WindowsUpdateInstaller().prepare(
          packagePath: package.path,
          executablePath: executable.path,
          temporaryDirectory: app,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        (await app.list().toList()).map((entity) => entity.path),
        before.map((entity) => entity.path),
      );
    },
  );

  test(
    'Windows PowerShell parses the emitted UTF-8 script without errors',
    () async {
      await package.writeAsString('ZIP');
      final prepared = await prepare();
      final result = await _tool(
        root,
        r'''
param([string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$c = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($c.target, [ref]$tokens, [ref]$errors)
if ($errors.Count) { $errors | ForEach-Object { $_.Message }; exit 1 }
'parsed'
''',
        {'target': prepared.scriptPath},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('parsed'));
    },
    skip: !Platform.isWindows,
  );

  test(
    'real helper replaces the bundle, preserves unrelated data and keeps backups',
    () async {
      await File(
        p.join(app.path, 'flutter_windows.dll'),
      ).writeAsString('old DLL');
      await Directory(p.join(app.path, 'data')).create();
      await File(p.join(app.path, 'data', 'app.bin')).writeAsString('old data');
      await File(p.join(app.path, 'user-note.txt')).writeAsString('keep this');
      await _zip(root, package, _bundle);
      final prepared = await prepare();
      final result = await _runPrepared(prepared);
      expect(
        result.exitCode,
        0,
        reason: '${result.stdout}\n${result.stderr}\n${await _log(prepared)}',
      );
      expect(await executable.readAsString(), 'new executable');
      expect(
        await File(p.join(app.path, 'flutter_windows.dll')).readAsString(),
        'new DLL',
      );
      expect(
        await File(p.join(app.path, 'data', 'app.bin')).readAsString(),
        'new data',
      );
      expect(
        await File(p.join(app.path, 'user-note.txt')).readAsString(),
        'keep this',
      );
      final backup = p.join(p.dirname(prepared.scriptPath), 'backup');
      expect(
        await File(p.join(backup, 'Monogatari.exe')).readAsString(),
        'old executable',
      );
      expect(
        await File(p.join(backup, 'data', 'app.bin')).readAsString(),
        'old data',
      );
      expect(await _log(prepared), contains('更新成功'));
      expect(
        await app
            .list(recursive: true)
            .where((entity) => entity.path.contains('.monogatari-update-'))
            .toList(),
        isEmpty,
      );
    },
    skip: !Platform.isWindows,
  );

  test(
    'ZipSlip is rejected before extraction or changes outside the staging root',
    () async {
      await _zip(root, package, {..._bundle, '../outside.txt': 'escaped'});
      final prepared = await prepare();
      final result = await _runPrepared(prepared);
      expect(result.exitCode, 1);
      expect(await executable.readAsString(), 'old executable');
      expect(await File(p.join(stage.path, 'outside.txt')).exists(), isFalse);
      expect(
        await Directory(
          p.join(p.dirname(prepared.scriptPath), 'unpacked'),
        ).exists(),
        isFalse,
      );
    },
    skip: !Platform.isWindows,
  );

  test('case-colliding ZIP entries are rejected before extraction', () async {
    await _zip(root, package, {
      ..._bundle,
      'monogatari.exe': 'conflicting executable',
    });
    final prepared = await prepare();
    expect((await _runPrepared(prepared)).exitCode, 1);
    expect(await executable.readAsString(), 'old executable');
    expect(await _log(prepared), contains('重复'));
  }, skip: !Platform.isWindows);

  test(
    'drive-root destination and substituted staging directory cannot be written',
    () async {
      await _zip(root, package, _bundle);
      final prepared = await prepare();
      final configurationFile = File(prepared.configPath);
      final configuration = Map<String, dynamic>.from(
        jsonDecode(await configurationFile.readAsString()) as Map,
      );
      configuration['appDirectory'] = p.rootPrefix(app.path);
      await configurationFile.writeAsString(jsonEncode(configuration));
      expect((await _runPrepared(prepared)).exitCode, 1);
      expect(await _log(prepared), contains('根目录'));
      expect(await executable.readAsString(), 'old executable');
      configuration['appDirectory'] = app.path;
      configuration['stagingDirectory'] = app.path;
      await configurationFile.writeAsString(jsonEncode(configuration));
      expect((await _runPrepared(prepared)).exitCode, 1);
      expect(await File(p.join(app.path, 'install.log')).exists(), isFalse);
      expect(await Directory(p.join(app.path, 'unpacked')).exists(), isFalse);
    },
    skip: !Platform.isWindows,
  );

  test(
    'an existing application junction cannot redirect update writes',
    () async {
      final outside = await Directory(p.join(root.path, 'outside')).create();
      final sentinel = await File(
        p.join(outside.path, 'app.bin'),
      ).writeAsString('outside unchanged');
      final junction = p.join(app.path, 'data');
      final created = await _tool(
        root,
        r'''
param([string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$c = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Junction -Path $c.link -Value $c.target | Out-Null
''',
        {'link': junction, 'target': outside.path},
      );
      expect(
        created.exitCode,
        0,
        reason: '${created.stdout}\n${created.stderr}',
      );
      try {
        await _zip(root, package, _bundle);
        final prepared = await prepare();
        expect((await _runPrepared(prepared)).exitCode, 1);
        expect(await sentinel.readAsString(), 'outside unchanged');
        expect(await executable.readAsString(), 'old executable');
        expect(await _log(prepared), contains('符号链接'));
      } finally {
        await Link(junction).delete();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'a real locked-file failure rolls back committed files and removes new ones',
    () async {
      await File(
        p.join(app.path, '00-replaced.txt'),
      ).writeAsString('original marker');
      final locked = await File(
        p.join(app.path, 'zz-locked.dat'),
      ).writeAsString('original locked');
      await _zip(root, package, {
        ..._bundle,
        '00-replaced.txt': 'new marker',
        '01-created.txt': 'new file',
        'zz-locked.dat': 'new locked',
      });
      final ready = File(p.join(root.path, 'lock-ready'));
      final release = File(p.join(root.path, 'release-lock'));
      final locking = _tool(
        root,
        r'''
param([string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$c = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$file = [IO.File]::Open($c.target, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
  [IO.File]::WriteAllText($c.ready, 'ready')
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not (Test-Path -LiteralPath $c.release) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 30 }
} finally { $file.Dispose() }
''',
        {'target': locked.path, 'ready': ready.path, 'release': release.path},
      );
      try {
        for (
          var attempt = 0;
          attempt < 200 && !await ready.exists();
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(
          await ready.exists(),
          isTrue,
          reason: 'lock holder did not start',
        );
        final prepared = await prepare();
        expect((await _runPrepared(prepared)).exitCode, 1);
        expect(
          await File(p.join(app.path, '00-replaced.txt')).readAsString(),
          'original marker',
        );
        expect(
          await File(p.join(app.path, '01-created.txt')).exists(),
          isFalse,
        );
        expect(await executable.readAsString(), 'old executable');
        expect(
          await app
              .list(recursive: true)
              .where((entity) => entity.path.contains('.monogatari-update-'))
              .toList(),
          isEmpty,
        );
      } finally {
        await release.writeAsString('release');
        expect((await locking).exitCode, 0);
      }
      expect(await locked.readAsString(), 'original locked');
    },
    skip: !Platform.isWindows,
  );
}

const _bundle = {
  'Monogatari.exe': 'new executable',
  'flutter_windows.dll': 'new DLL',
  'data/app.bin': 'new data',
};

Future<String> _log(PreparedWindowsUpdate prepared) =>
    File(p.join(p.dirname(prepared.scriptPath), 'install.log')).readAsString();

Future<ProcessResult> _runPrepared(PreparedWindowsUpdate prepared) =>
    _powershell(prepared.scriptPath, prepared.configPath);

Future<ProcessResult> _tool(
  Directory root,
  String source,
  Map<String, Object?> configuration,
) async {
  final directory = await root.createTemp('tool-');
  final script = await File(
    p.join(directory.path, 'tool.ps1'),
  ).writeAsBytes([0xef, 0xbb, 0xbf, ...utf8.encode(source)]);
  final config = await File(
    p.join(directory.path, 'tool.json'),
  ).writeAsString(jsonEncode(configuration));
  return _powershell(script.path, config.path);
}

Future<ProcessResult> _powershell(String script, String config) async {
  final process = await Process.start('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-WindowStyle',
    'Hidden',
    '-File',
    script,
    '-ConfigPath',
    config,
  ]);
  final output = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final errors = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final exitCode = await process.exitCode.timeout(
    const Duration(seconds: 40),
    onTimeout: () {
      process.kill();
      throw TimeoutException('test PowerShell helper did not exit');
    },
  );
  return ProcessResult(process.pid, exitCode, await output, await errors);
}

Future<void> _zip(
  Directory root,
  File destination,
  Map<String, String> entries,
) async {
  final result = await _tool(
    root,
    r'''
param([string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$c = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($c.destination, [IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($entry in $c.entries) {
    $file = $zip.CreateEntry([string]$entry.name)
    $writer = [IO.StreamWriter]::new($file.Open(), [Text.UTF8Encoding]::new($false))
    try { $writer.Write([string]$entry.contents) } finally { $writer.Dispose() }
  }
} finally { $zip.Dispose() }
''',
    {
      'destination': destination.path,
      'entries': [
        for (final entry in entries.entries)
          {'name': entry.key, 'contents': entry.value},
      ],
    },
  );
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  expect(
    await destination.exists(),
    isTrue,
    reason: 'PowerShell did not create the requested ZIP fixture',
  );
}
