bool needUpdate(String localVersion, String remoteVersion) {
  final local = _SemanticVersion.tryParse(localVersion);
  final remote = _SemanticVersion.tryParse(remoteVersion);
  // Malformed tags or local metadata must never trigger an update or throw
  // through the update UI. Build metadata does not affect SemVer precedence.
  return local != null && remote != null && local.compareTo(remote) < 0;
}

class _SemanticVersion implements Comparable<_SemanticVersion> {
  const _SemanticVersion(this.core, this.prerelease);

  static final _pattern = RegExp(
    r'^(?:monogatari-v|v)?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
  );
  static final _numericIdentifier = RegExp(r'^[0-9]+$');

  final List<BigInt> core;
  final List<String> prerelease;

  static _SemanticVersion? tryParse(String version) {
    final match = _pattern.firstMatch(version);
    if (match == null || match.end != version.length) return null;
    final prerelease = match[4]?.split('.') ?? const <String>[];
    for (final identifier in prerelease) {
      if (_numericIdentifier.hasMatch(identifier) &&
          identifier.length > 1 &&
          identifier.startsWith('0')) {
        return null;
      }
    }
    return _SemanticVersion([
      for (var i = 1; i <= 3; i++) BigInt.parse(match[i]!),
    ], prerelease);
  }

  @override
  int compareTo(_SemanticVersion other) {
    for (var i = 0; i < core.length; i++) {
      final comparison = core[i].compareTo(other.core[i]);
      if (comparison != 0) return comparison;
    }
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
      return prerelease.isEmpty ? 1 : -1;
    }
    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      final local = prerelease[i];
      final remote = other.prerelease[i];
      final localNumeric = _numericIdentifier.hasMatch(local);
      final remoteNumeric = _numericIdentifier.hasMatch(remote);
      final int comparison;
      if (localNumeric && remoteNumeric) {
        comparison = BigInt.parse(local).compareTo(BigInt.parse(remote));
      } else if (localNumeric != remoteNumeric) {
        comparison = localNumeric ? -1 : 1;
      } else {
        comparison = local.compareTo(remote);
      }
      if (comparison != 0) return comparison;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}
