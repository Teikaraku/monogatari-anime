import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/version.dart';

void main() {
  test('compares complete core versions numerically', () {
    expect(needUpdate('2.3.8', '2.3.9'), isTrue);
    expect(needUpdate('2.3.9', '2.3.10'), isTrue);
    expect(needUpdate('2.9.9', '2.10.0'), isTrue);
    expect(needUpdate('2.99.99', '3.0.0'), isTrue);
    expect(needUpdate('2.3.8', '2.3.8'), isFalse);
    expect(needUpdate('3.0.0', '2.99.99'), isFalse);
  });

  test('accepts the supported GitHub tag prefixes on either version', () {
    for (final local in ['2.3.8', 'v2.3.8', 'monogatari-v2.3.8']) {
      for (final remote in ['2.3.9', 'v2.3.9', 'monogatari-v2.3.9']) {
        expect(needUpdate(local, remote), isTrue, reason: '$local -> $remote');
        expect(needUpdate(remote, local), isFalse);
      }
    }
    expect(needUpdate('v2.3.9', 'monogatari-v2.3.9'), isFalse);
  });

  test('ignores build metadata including Flutter build numbers', () {
    expect(needUpdate('2.3.8+20308', 'v2.3.9+20309'), isTrue);
    expect(needUpdate('2.3.8+20308', '2.3.8+99999'), isFalse);
    expect(needUpdate('2.3.8+git.abc', '2.3.8+git.def'), isFalse);
    expect(needUpdate('2.3.8+0001', '2.3.8'), isFalse);
    expect(needUpdate('2.3.8-alpha+001', '2.3.8-alpha+002'), isFalse);
  });

  test('follows the SemVer prerelease precedence sequence', () {
    const versions = [
      '1.0.0-alpha',
      '1.0.0-alpha.1',
      '1.0.0-alpha.beta',
      '1.0.0-beta',
      '1.0.0-beta.2',
      '1.0.0-beta.11',
      '1.0.0-rc.1',
      '1.0.0',
    ];
    for (var i = 0; i < versions.length; i++) {
      for (var j = 0; j < versions.length; j++) {
        expect(
          needUpdate(versions[i], versions[j]),
          i < j,
          reason: '${versions[i]} -> ${versions[j]}',
        );
      }
    }
  });

  test(
    'numeric prerelease identifiers precede text and compare numerically',
    () {
      expect(needUpdate('1.0.0-9', '1.0.0-10'), isTrue);
      expect(needUpdate('1.0.0-999', '1.0.0-a'), isTrue);
      expect(needUpdate('1.0.0-alpha.9', '1.0.0-alpha.10'), isTrue);
      expect(needUpdate('1.0.0-alpha.0', '1.0.0-alpha.0.1'), isTrue);
      expect(needUpdate('1.0.0-Alpha', '1.0.0-alpha'), isTrue);
      expect(needUpdate('1.0.0-alpha-beta', '1.0.0-alpha-beta.1'), isTrue);
    },
  );

  test('stable releases outrank prereleases only after comparing the core', () {
    expect(needUpdate('2.3.9-rc.1', 'v2.3.9'), isTrue);
    expect(needUpdate('2.3.9', '2.3.9-rc.2'), isFalse);
    expect(needUpdate('2.3.9', '2.4.0-alpha'), isTrue);
    expect(needUpdate('2.4.0-alpha', '2.3.99'), isFalse);
  });

  test('large valid SemVer integers do not overflow or lose precision', () {
    expect(
      needUpdate('184467440737095516150.0.0', '184467440737095516151.0.0'),
      isTrue,
    );
    expect(
      needUpdate(
        '1.0.0-9999999999999999999999999',
        '1.0.0-10000000000000000000000000',
      ),
      isTrue,
    );
    expect(
      needUpdate(
        '1.0.0-10000000000000000000000000',
        '1.0.0-9999999999999999999999999',
      ),
      isFalse,
    );
  });

  test('invalid versions do not trigger an update or throw', () {
    const invalid = [
      '',
      'v',
      'monogatari-v',
      '1',
      '1.2',
      '1.2.3.4',
      '01.2.3',
      '1.02.3',
      '1.2.03',
      '-1.2.3',
      '+1.2.3',
      '1.2.3-',
      '1.2.3-alpha..beta',
      '1.2.3-01',
      '1.2.3-alpha.01',
      '1.2.3+',
      '1.2.3+build..number',
      '1.2.3-alpha_beta',
      '1.2.3-中文',
      '1.2.3+🙂',
      '1.2.3+meta+extra',
      'vv1.2.3',
      'monogatari-1.2.3',
      'refs/tags/v1.2.3',
      ' 1.2.3',
      '1.2.3 ',
      '1. 2.3',
      '1.2.3\n',
    ];
    for (final version in invalid) {
      expect(
        needUpdate(version, '999.0.0'),
        isFalse,
        reason: 'invalid local $version',
      );
      expect(
        needUpdate('0.0.0', version),
        isFalse,
        reason: 'invalid remote $version',
      );
    }
  });
}
