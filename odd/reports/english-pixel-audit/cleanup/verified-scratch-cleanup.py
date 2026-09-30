"""Parent-run maintenance: verify exact owned /tmp assets, then optionally remove.
Expected hashes are supplied through stdin; no credentials or app storage paths.
"""
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile

payload = json.load(sys.stdin)
delete = sys.argv[1] == 'delete'
assert sys.argv[1] in ('inspect', 'delete')
actions = []

def digest(path):
    assert path.is_file() and not path.is_symlink(), str(path)
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

apks = {
    '/tmp/lifeos-english-candidate2-1024.apk': 'a934f62da9985efed746d158b278c6607d9d7dc4a21cd61f66f62664ce6cef9f',
    '/tmp/lifeos-english-candidate-1024.apk': '1cf8fe1044f00e26afa06d9c1ddb7cf31bb1ec4885d40682af989fb1702b58d5',
}
for name, expected in {**apks, **payload['captures']}.items():
    p = Path(name)
    if p.exists() or p.is_symlink():
        assert digest(p) == expected, name
        actions.append({'path': name, 'kind': 'file', 'sha256': expected})

fixture_tar = Path('/tmp/lifeos-english-fixtures.tar')
if fixture_tar.exists():
    assert not fixture_tar.is_symlink()
    with tarfile.open(fixture_tar) as tf:
        members = [m for m in tf.getmembers() if not m.isdir()]
        assert len(members) == len(payload['fixtures'])
        seen = set()
        for member in members:
            assert member.isfile()
            name = PurePosixPath(member.name).name
            assert name in payload['fixtures'] and name not in seen
            seen.add(name)
            assert hashlib.sha256(tf.extractfile(member).read()).hexdigest() == payload['fixtures'][name]
    actions.append({'path': str(fixture_tar), 'kind': 'file', 'sha256': digest(fixture_tar)})
fixture_dir = Path('/tmp/lifeos-english-fixtures')
if fixture_dir.exists():
    assert fixture_dir.resolve() == fixture_dir and not fixture_dir.is_symlink()
    files = [p for p in fixture_dir.rglob('*') if not p.is_dir()]
    assert len(files) == len(payload['fixtures'])
    assert {p.name for p in files} == set(payload['fixtures'])
    for p in files:
        assert digest(p) == payload['fixtures'][p.name]
    actions.append({'path': str(fixture_dir), 'kind': 'directory', 'verified_fixture_files': len(files)})

capture_tar = Path('/tmp/lifeos-english-capture-v333.tar.gz')
capture_dir = Path('/tmp/lifeos-english-capture-v333')
if capture_tar.exists():
    expected = '9b30e813e8191329ba8025dc80cb0f198fb0a318960a3b5c15395cf675c9c638'
    assert digest(capture_tar) == expected
    if capture_dir.exists():
        assert capture_dir.resolve() == capture_dir and not capture_dir.is_symlink()
        verified = set()
        with tarfile.open(capture_tar) as tf:
            for member in tf.getmembers():
                if member.isdir():
                    continue
                assert member.isfile(), member.name
                parts = PurePosixPath(member.name).parts
                assert '..' not in parts and not PurePosixPath(member.name).is_absolute()
                candidates = [capture_dir.joinpath(*parts), capture_dir.joinpath(*parts[1:])]
                actual = [p for p in candidates if p.is_file()]
                assert len(actual) == 1, member.name
                p = actual[0]
                assert digest(p) == hashlib.sha256(tf.extractfile(member).read()).hexdigest()
                verified.add(p)
        actual = {p for p in capture_dir.rglob('*') if not p.is_dir()}
        assert actual == verified, [str(p) for p in actual - verified]
        actions.append({'path': str(capture_dir), 'kind': 'directory', 'verified_archive_files': len(verified)})
    actions.append({'path': str(capture_tar), 'kind': 'file', 'sha256': expected})
else:
    assert not capture_dir.exists(), 'Cannot verify tool directory without its archive'

# All preconditions above run before any removal on this host.
if delete:
    for action in actions:
        p = Path(action['path'])
        if action['kind'] == 'directory':
            shutil.rmtree(p)
        else:
            p.unlink()
        assert not p.exists()
print(json.dumps({'mode': sys.argv[1], 'actions': actions}, indent=2))
