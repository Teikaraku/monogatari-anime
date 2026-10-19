"""Read-only mainland connectivity audit. No system proxy or account credentials."""
import concurrent.futures
import json
import os
import pathlib
import subprocess
import urllib.parse

ROOT = pathlib.Path('build/diagnostics/interface-audit')
ROOT.mkdir(parents=True, exist_ok=True)
TARGETS = []
RELAY = os.environ.get('PUBLIC_CATALOG_ORIGIN', '').rstrip('/')
if RELAY and urllib.parse.urlsplit(RELAY).scheme not in {'http', 'https'}:
    raise ValueError('PUBLIC_CATALOG_ORIGIN must be an HTTP(S) origin')

def add(name, url, body=None):
    if url.startswith(('https://', 'http://')):
        TARGETS.append((name, url, body))

paths = {
    'calendar': '/p1/calendar',
    'detail': '/p1/subjects/511936',
    'chapters': '/p1/subjects/511936/episodes?limit=1000',
    'trends': '/p1/trending/subjects?type=2&limit=24',
    'relations': '/p1/subjects/511936/relations',
    'cast': '/p1/subjects/400602/characters?limit=100',
    'staff': '/p1/subjects/400602/staffs/persons?limit=100',
    'character': '/p1/characters/104466',
    'comments': '/p1/episodes/1234567/comments?limit=20',
}
for name, path in paths.items():
    for route, origin in [('relay', RELAY), ('official', 'https://next.bgm.tv' if path.startswith('/p1') else 'https://api.bgm.tv')]:
        add(f'bgm-{name}-{route}', origin + path if origin else '')
for platform in ['TV', 'WEB']:
    add('season-' + platform, f'{RELAY}/p1/search/subjects?limit=100&offset=0',
        {'keyword': '', 'sort': 'heat', 'filter': {'type': [2], 'metaTags': [platform], 'date': ['>=2026-07-01', '<2026-10-01'], 'nsfw': False}})
for cat in [1, 5]:
    add(f'season-browse-{cat}', f'{RELAY}/p1/subjects?type=2&sort=date&cat={cat}&year=2026&month=7&page=1')
add('ranking', f'{RELAY}/p1/search/subjects?limit=20&offset=0',
    {'keyword': '', 'sort': 'rank', 'filter': {'type': [2], 'rank': ['>0'], 'nsfw': False}})
add('airtime', f'{RELAY}/meta/airtime.json')
add('github-update', 'https://api.github.com/repos/Teikaraku/monogatari-anime/releases/latest')
add('rules-github', 'https://raw.githubusercontent.com/Predidit/KazumiRules/main/index.json')
add('rules-relay', f'{RELAY}/rules/index.json')
add('trace-quota', 'https://api.trace.moe/me')
add('mikan-home', 'https://mikanani.me/')
add('mikan-search', 'https://mikanani.me/Home/Search?' + urllib.parse.urlencode({'searchstr': '世界最强'}))
add('mikan-torrent', 'https://mikanani.me/Download/20261014/8f8ddfb534fda546a1bbd7735b90e92a0295a2d6.torrent')
for name, endpoint in [('1080', 'https://api.yzzy-api.com/inc/apijson.php'), ('baofeng', 'https://bfzyapi.com/api.php/provide/vod/'), ('liangzi', 'https://cj.lziapi.com/api.php/provide/vod/')]:
    add('video-' + name, endpoint + '?' + urllib.parse.urlencode({'ac': 'detail', 'wd': '世界最强', 'pg': 1}))
    add('video-relay-' + name, f'{RELAY}/public/vod/' + name + '?' + urllib.parse.urlencode({'ac': 'detail', 'wd': '世界最强', 'pg': 1}))
for name, path in {
    'search': '/Home/Search?' + urllib.parse.urlencode({'searchstr': '世界最强'}),
    'show': '/Home/Bangumi/4062',
    'rss': '/RSS/Bangumi?bangumiId=4062&subgroupid=583',
    'torrent': '/Download/20261014/8f8ddfb534fda546a1bbd7735b90e92a0295a2d6.torrent',
}.items():
    add('mikan-relay-' + name, f'{RELAY}/public/mikan' + path)
add('dns-ali', 'https://dns.alidns.com/resolve?name=crypto.cloudflare.com&type=65')
add('dns-cf', 'https://cloudflare-dns.com/dns-query?name=api.yzzy-api.com&type=A')
cover = 'https://lain.bgm.tv/r/200/pic/cover/l/1c/b4/390200_Z9jPp.jpg'
add('image-official', cover)
add('image-relay', cover.replace('https://lain.bgm.tv/', f'{RELAY}/img/'))
add('image-wsrv', 'https://wsrv.nl/?' + urllib.parse.urlencode({'url': cover}))
add('image-original-relay', cover.replace('/r/200/', '/').replace('https://lain.bgm.tv/', f'{RELAY}/img/'))

def probe(task):
    round_, target = task
    name, url, payload = target
    output = ROOT / f'{name}-{round_}.body'
    args = ['curl.exe', '--noproxy', '*', '--silent', '--show-error', '--location', '--compressed', '--connect-timeout', '4', '--max-time', '7', '--max-filesize', '8388608', '-H', 'User-Agent: Monogatari (https://github.com/Teikaraku/monogatari-anime)', '-H', 'Accept: application/json', '-o', str(output), '-w', '%{json}']
    if payload is not None:
        body = ROOT / f'{name}.request.json'
        body.write_text(json.dumps(payload), encoding='utf-8')
        args += ['-H', 'Content-Type: application/json', '--data-binary', '@' + str(body)]
    p = subprocess.run(args + [url], capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=10)
    try:
        metrics = json.loads(p.stdout)
    except ValueError:
        metrics = {}
    result = {'name': name, 'round': round_, 'url': url,
              **{key: metrics.get(key) for key in ['http_code', 'time_total', 'time_starttransfer', 'size_download', 'content_type']},
              'error': p.stderr.strip()}
    if output.exists():
        raw = output.read_bytes()
        try:
            data = json.loads(raw)
            result['shape'] = list(data)[:12] if isinstance(data, dict) else type(data).__name__
            if isinstance(data, dict):
                result['total'] = data.get('total')
                result['count'] = len(data.get('data', data.get('list', [])))
                result['tag'] = data.get('tag_name')
        except (ValueError, TypeError):
            result['shape'] = 'binary' if name.startswith(('image', 'mikan-torrent')) else 'text'
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return result

if __name__ == '__main__':
    results = []
    for round_ in range(3):
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            results.extend(pool.map(probe, [(round_, target) for target in TARGETS]))
    (ROOT / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
