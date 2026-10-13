import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Installs a portable bundle after the running application exits. Paths are
/// data in JSON, never inserted into shell commands or PowerShell source.
class WindowsUpdateInstaller {
  Future<PreparedWindowsUpdate> prepare({
    required String packagePath,
    String? executablePath,
    int? processId,
    Directory? temporaryDirectory,
    bool restartApplication = true,
    bool showErrors = true,
  }) async {
    final executable = File(executablePath ?? Platform.resolvedExecutable);
    final package = File(packagePath);
    if (!await executable.exists() || !await package.exists()) {
      throw const FileSystemException('更新安装文件或应用程序不存在');
    }
    if (p.extension(package.path).toLowerCase() != '.zip') {
      throw const FormatException('Windows 便携更新必须是 ZIP 安装包');
    }
    final appDirectory = await executable.parent.resolveSymbolicLinks();
    if (p.dirname(appDirectory) == appDirectory) {
      throw const FileSystemException('不能更新根目录中的程序');
    }
    final temp = temporaryDirectory ?? await getTemporaryDirectory();
    final tempPath = await temp.resolveSymbolicLinks();
    if (p.equals(appDirectory, tempPath) ||
        p.isWithin(appDirectory, tempPath)) {
      throw const FileSystemException('更新临时目录不能位于应用目录中');
    }
    final staging = await Directory(tempPath).createTemp('monogatari-update-');
    final script = File(p.join(staging.path, 'install.ps1'));
    final config = File(p.join(staging.path, 'install.json'));
    // Windows PowerShell 5.1 interprets BOM-less scripts using the local ANSI
    // code page. A BOM keeps Chinese diagnostics and paths correctly parsed.
    await script.writeAsBytes([
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode(windowsUpdateScript),
    ], flush: true);
    await config.writeAsString(
      jsonEncode({
        'packagePath': await package.resolveSymbolicLinks(),
        'appDirectory': appDirectory,
        'executableName': p.basename(executable.path),
        'processId': processId ?? pid,
        'stagingDirectory': await staging.resolveSymbolicLinks(),
        'restartApplication': restartApplication,
        'showErrors': showErrors,
      }),
      flush: true,
    );
    return PreparedWindowsUpdate(script.path, config.path);
  }
}

class PreparedWindowsUpdate {
  const PreparedWindowsUpdate(this.scriptPath, this.configPath);
  final String scriptPath;
  final String configPath;

  Future<void> launch() async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows 更新安装器仅用于 Windows');
    }
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      scriptPath,
      '-ConfigPath',
      configPath,
    ], mode: ProcessStartMode.detached);
  }
}

const windowsUpdateScript = r'''
param([Parameter(Mandatory=$true)][string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$configuration = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$appDirectory = [IO.Path]::GetFullPath($configuration.appDirectory).TrimEnd('\')
$stagingDirectory = [IO.Path]::GetFullPath($configuration.stagingDirectory).TrimEnd('\')
$appPrefix = $appDirectory + '\'
$unpacked = Join-Path $stagingDirectory 'unpacked'
$backup = Join-Path $stagingDirectory 'backup'
$logPath = Join-Path $PSScriptRoot 'install.log'
$copied = [Collections.Generic.List[object]]::new()
$applicationExited = $false
$executable = $null
$restartApplication = $true
$showErrors = $true
if ($configuration.PSObject.Properties.Name -contains 'restartApplication') {
  $restartApplication = [bool]$configuration.restartApplication
}
if ($configuration.PSObject.Properties.Name -contains 'showErrors') {
  $showErrors = [bool]$configuration.showErrors
}

function Assert-NoReparsePoint([string]$root, [string]$path) {
  $current = [IO.Path]::GetFullPath($root).TrimEnd('\')
  $parts = @('') + $path.Substring($current.Length).TrimStart('\').Split('\')
  foreach ($part in $parts) {
    if ($part) { $current = Join-Path $current $part }
    $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw '应用或临时目录包含符号链接/目录联接，不能安全更新'
    }
  }
}

function Resolve-Child([string]$root, [string]$relative) {
  if ([IO.Path]::IsPathRooted($relative) -or $relative -match '[<>:"|?*\x00-\x1F]') {
    throw '安装包包含无效的文件路径'
  }
  foreach ($component in $relative.Replace('/', '\').TrimEnd('\').Split('\')) {
    if ($component -eq '..' -or $component.EndsWith('.') -or $component.EndsWith(' ')) {
      throw '安装包包含不安全的文件路径'
    }
  }
  $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
  $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
  if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw '安装包路径超出应用目录'
  }
  Assert-NoReparsePoint $root $path
  return $path
}

try {
  $rootDirectory = [IO.Path]::GetPathRoot($appDirectory).TrimEnd('\')
  if ($rootDirectory -eq $appDirectory) { throw '不能替换根目录内容' }
  if (-not (Test-Path -LiteralPath $appDirectory -PathType Container)) {
    throw '应用目录不存在'
  }
  if ($stagingDirectory -ne [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')) {
    throw '更新临时目录与安装器目录不一致'
  }
  Assert-NoReparsePoint $stagingDirectory $stagingDirectory
  if ($stagingDirectory -eq $appDirectory -or $stagingDirectory.StartsWith($appPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw '更新临时目录不能位于应用目录中'
  }
  if ($configuration.executableName -ne [IO.Path]::GetFileName($configuration.executableName)) {
    throw '应用程序名称无效'
  }
  $executable = Resolve-Child $appDirectory $configuration.executableName
  if ([IO.Path]::GetExtension($configuration.packagePath) -ne '.zip') {
    throw 'Windows 便携更新必须是 ZIP 安装包'
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($configuration.packagePath)
  try {
    $entryPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $zip.Entries) {
      $entryPath = Resolve-Child $unpacked $entry.FullName
      if (-not $entryPaths.Add($entryPath)) { throw '安装包包含重复的文件路径' }
      if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or
          ($entry.ExternalAttributes -band [int][IO.FileAttributes]::ReparsePoint)) {
        throw '安装包包含符号链接'
      }
    }
  } finally { $zip.Dispose() }
  Expand-Archive -LiteralPath $configuration.packagePath -DestinationPath $unpacked
  if (-not (Test-Path -LiteralPath (Resolve-Child $unpacked $configuration.executableName) -PathType Leaf) -or
      -not (Test-Path -LiteralPath (Resolve-Child $unpacked 'flutter_windows.dll') -PathType Leaf) -or
      -not (Test-Path -LiteralPath (Resolve-Child $unpacked 'data') -PathType Container)) {
    throw '安装包不包含完整物语程序'
  }
  $files = @(Get-ChildItem -LiteralPath $unpacked -File -Recurse | Sort-Object FullName)
  foreach ($source in $files) {
    $relative = $source.FullName.Substring($unpacked.Length).TrimStart('\')
    [void](Resolve-Child $appDirectory $relative)
  }
  try { $parent = [Diagnostics.Process]::GetProcessById([int]$configuration.processId) }
  catch [ArgumentException] { $parent = $null }
  if ($null -ne $parent -and -not $parent.WaitForExit(60000)) {
    throw '应用仍在运行，请关闭后重新安装'
  }
  $applicationExited = $true
  foreach ($source in $files) {
    $relative = $source.FullName.Substring($unpacked.Length).TrimStart('\')
    $destination = Resolve-Child $appDirectory $relative
    $old = Resolve-Child $backup $relative
    $existed = Test-Path -LiteralPath $destination -PathType Leaf
    if ($existed) {
      [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($old))
      [IO.File]::Copy($destination, $old, $false)
    }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    $replacement = $destination + '.monogatari-update-' + [Guid]::NewGuid().ToString('N')
    $operation = @{ destination=$destination; backup=$old; existed=$existed; replacement=$replacement; committed=$false; relative=$relative }
    $copied.Add($operation)
    [IO.File]::Copy($source.FullName, $replacement, $false)
    if ($existed) {
      [IO.File]::Replace($replacement, $destination, [NullString]::Value)
    } else {
      [IO.File]::Move($replacement, $destination)
    }
    $operation.committed = $true
  }
  if ($restartApplication) { Start-Process -FilePath $executable -WorkingDirectory $appDirectory }
  '更新成功' | Set-Content -LiteralPath $logPath -Encoding UTF8
} catch {
  $failure = $_.Exception.Message
  for ($index = $copied.Count - 1; $index -ge 0; $index--) {
    $file = $copied[$index]
    try {
      [void](Resolve-Child $appDirectory $file.relative)
      if ($file.committed) {
        if ($file.existed) {
          [IO.File]::Copy($file.backup, $file.destination, $true)
        } elseif (Test-Path -LiteralPath $file.destination -PathType Leaf) {
          [IO.File]::Delete($file.destination)
        }
      }
      if (Test-Path -LiteralPath $file.replacement -PathType Leaf) { [IO.File]::Delete($file.replacement) }
    } catch { }
  }
  $failure | Set-Content -LiteralPath $logPath -Encoding UTF8
  if ($restartApplication -and $null -ne $executable) {
    if (-not $applicationExited) {
      try { $parent = [Diagnostics.Process]::GetProcessById([int]$configuration.processId) }
      catch [ArgumentException] { $parent = $null }
      $applicationExited = $null -eq $parent -or $parent.WaitForExit(60000)
    }
    if ($applicationExited -and (Test-Path -LiteralPath $executable -PathType Leaf)) {
      Start-Process -FilePath $executable -WorkingDirectory $appDirectory
    }
  }
  if ($showErrors) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show("更新未完成。已尝试恢复原版本，备份保留在更新临时目录；也可将下载的 ZIP 解压到可写目录后运行。`n$failure", '物语更新')
  }
  exit 1
}
''';
