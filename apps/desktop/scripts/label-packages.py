"""Label verified packages without changing installer bytes or legacy update URLs."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import zipfile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def label_packages(directory, build_number):
    if not re.fullmatch(r'[1-9][0-9]*\.[1-9][0-9]*', build_number):
        raise ValueError('Build number must be Desktop CI run_number.run_attempt')
    manifest_path = directory / 'release-manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
    version = manifest['version']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Invalid package version')
    originals = {item['name']: item for item in manifest['files']}
    expected = {f'MovieClaw-Desktop-{version}-{suffix}' for suffix in ['Setup-x64.exe', 'portable-x64.zip']}
    if set(originals) != expected:
        raise ValueError('Expected both verified legacy packages')
    for name, item in originals.items():
        path = directory / name
        if path.stat().st_size != item['size'] or digest(path) != item['sha256']:
            raise ValueError(f'Original package changed: {name}')
    sums_path = directory / 'SHA256SUMS.txt'
    sums = {}
    if sums_path.exists():
        for line in sums_path.read_text(encoding='utf-8-sig').splitlines():
            match = re.fullmatch(r'([0-9a-f]{64})  ([^/\\]+)', line)
            if not match or match[2] in ('.', '..') or digest(directory / match[2]) != match[1]:
                raise ValueError('Existing checksum list is invalid')
            sums[match[2]] = match[1]
    labeled = directory / 'labeled'
    labeled.mkdir(exist_ok=True)
    artifacts = []
    for suffix in ['Setup-x64.exe', 'portable-x64.zip']:
        original = f'MovieClaw-Desktop-{version}-{suffix}'
        local_name = f'MovieClaw-Desktop-{version}({build_number})-{suffix}'
        shutil.copyfile(directory / original, labeled / local_name)
        asset_suffix = 'Setup-x64.zip' if suffix.endswith('.exe') else suffix
        asset_name = f'MovieClaw-Desktop-{version}-build{build_number}-{asset_suffix}'
        asset_path = directory / asset_name
        if suffix.endswith('.exe'):
            # GitHub sanitizes parentheses in asset names; ZIP preserves the exact installer name.
            with zipfile.ZipFile(asset_path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                archive.write(labeled / local_name, local_name)
        else:
            shutil.copyfile(directory / original, asset_path)
        artifacts.append(dict(name=asset_name, label=f'MovieClaw-Desktop-{version}({build_number})-{asset_suffix}',
                              originalName=original, localName=local_name,
                              size=asset_path.stat().st_size, sha256=digest(asset_path)))
    manifest['buildNumber'] = build_number
    manifest['buildArtifacts'] = artifacts
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    for item in [*manifest['files'], *artifacts]:
        sums[item['name']] = item['sha256']
    sums_path.write_text(''.join(f'{sha}  {name}\n' for name, sha in sums.items()), encoding='utf-8')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=pathlib.Path, required=True)
    parser.add_argument('--build-number', required=True)
    args = parser.parse_args()
    label_packages(args.directory, args.build_number)
