#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

HOME = Path.home()
SYNCROOT = HOME / 'Library/Application Support/ocr2md-sync'
UNISON_DIR = HOME / 'Library/Application Support/Unison'
CONFIG = SYNCROOT / 'sync-groups.json'
STATE = SYNCROOT / 'unison-state.txt'
RUNLOG = HOME / 'Library/Logs/ocr2md-sync/unison-run.log'
UNISON_LOG = HOME / 'Library/Logs/ocr2md-sync/unison.log'
BACKUP_DIR = SYNCROOT / 'unison-backups'
UNISON_BIN = Path('/opt/homebrew/bin/unison')
HOSTNAME = 'ocr2md-mac'

CHANGE_RE = re.compile(r'(<----|---->|<-\?->)|\b(?:new file|changed|deleted)\b|Propagating updates|\[BGN\]\s+(?:Copying|Deleting|Updating)', re.I)
CONFLICT_RE = re.compile(r'<-\?->')


def now():
    return datetime.now().strftime('%Y-%m-%d %H:%M:%S')


def atomic_write(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def write_state(**fields):
    ordered = [
        'last_start', 'last_end', 'exit_code', 'status', 'phase',
        'group', 'group_id', 'pass', 'progress_current', 'progress_total',
        'edge_from', 'edge_to', 'profile'
    ]
    lines = []
    for key in ordered:
        if key in fields and fields[key] is not None:
            value = str(fields[key]).replace('\n', ' ')
            lines.append(f'{key}={value}')
    for key, value in fields.items():
        if key not in ordered and value is not None:
            lines.append(f'{key}={str(value).replace(chr(10), " ")}')
    atomic_write(STATE, '\n'.join(lines) + '\n')


def log(text=''):
    RUNLOG.parent.mkdir(parents=True, exist_ok=True)
    with RUNLOG.open('a', encoding='utf-8', errors='replace') as f:
        f.write(text)
        if text and not text.endswith('\n'):
            f.write('\n')
        f.flush()


def load_config():
    with CONFIG.open('r', encoding='utf-8') as f:
        doc = json.load(f)
    if doc.get('version') != 2:
        raise RuntimeError(f'unsupported sync-groups.json version: {doc.get("version")}')
    groups = [g for g in doc.get('groups', []) if g.get('enabled')]
    if not groups:
        raise RuntimeError('no enabled sync groups')
    return groups


def normalized_root(raw):
    if not isinstance(raw, str) or not raw.strip():
        raise RuntimeError('empty directory path')
    if '\n' in raw or '\r' in raw:
        raise RuntimeError('directory path contains newline')
    p = Path(os.path.normpath(os.path.expanduser(raw)))
    if not p.is_absolute():
        raise RuntimeError(f'root is not absolute: {p}')
    if p.is_symlink():
        raise RuntimeError(f'root must not be a symlink: {p}')
    if not p.is_dir():
        raise RuntimeError(f'root is not an accessible directory: {p}')
    return p


def normalized_excludes(directory, group_name, root):
    raw_items = directory.get('excludes') or []
    if not isinstance(raw_items, list):
        raise RuntimeError(f'group {group_name!r} has invalid excludes for {root}')
    result = []
    seen = set()
    for raw in raw_items:
        if not isinstance(raw, str):
            raise RuntimeError(f'group {group_name!r} has non-string exclude for {root}')
        value = raw.strip().replace('\\', '/')
        if not value or '\n' in value or '\r' in value or value.startswith('/'):
            raise RuntimeError(f'group {group_name!r} has invalid exclude {raw!r} for {root}')
        parts = [part for part in value.split('/') if part not in ('', '.')]
        if not parts or any(part == '..' for part in parts):
            raise RuntimeError(f'group {group_name!r} has unsafe exclude {raw!r} for {root}')
        value = '/'.join(parts)
        if value not in seen:
            seen.add(value)
            result.append(value)
    return result


def validate_group(group):
    name = str(group.get('name') or '未命名同步组')
    gid = str(group.get('id') or '')
    dirs = group.get('directories') or []
    if len(dirs) < 2:
        raise RuntimeError(f'group {name!r} needs at least 2 directories')
    roots = [normalized_root(d.get('path')) for d in dirs]
    excludes = [normalized_excludes(d, name, root) for d, root in zip(dirs, roots)]
    normalized = [os.path.normcase(str(p)) for p in roots]
    if len(set(normalized)) != len(normalized):
        raise RuntimeError(f'group {name!r} contains duplicate directories')
    # Nested roots can recursively sync one replica into another; refuse them.
    for i, a in enumerate(roots):
        for j, b in enumerate(roots):
            if i >= j:
                continue
            try:
                b.relative_to(a)
                raise RuntimeError(f'group {name!r} contains nested roots: {a} -> {b}')
            except ValueError:
                pass
            try:
                a.relative_to(b)
                raise RuntimeError(f'group {name!r} contains nested roots: {b} -> {a}')
            except ValueError:
                pass
    return name, gid, roots, excludes


def generic_preferences():
    return f'''\n# Generic safe defaults generated by ocr2md group sync.\nignore = Name .DS_Store\nignore = Name .sync.ffs_db\nignore = Name ._*\n\nperms = 0\nowner = false\ngroup = false\nxattrs = false\ntimes = false\nlinks = false\n\nconfirmbigdel = true\nlog = true\nlogfile = {UNISON_LOG}\n\ncopyonconflict = false\nbackuploc = central\nbackupdir = {BACKUP_DIR}\nbackup = Name *\nmaxbackups = 10\n'''


def preferences_for_group(group):
    legacy = group.get('legacyProfile')
    if not legacy:
        return generic_preferences()
    legacy_name = str(legacy)
    if '/' in legacy_name or '\\' in legacy_name or not re.fullmatch(r'[A-Za-z0-9._-]+', legacy_name):
        raise RuntimeError(f'invalid legacyProfile name: {legacy_name}')
    path = UNISON_DIR / f'{legacy_name}.prf'
    if not path.is_file():
        raise RuntimeError(f'legacy profile not found: {path}')
    kept = []
    for line in path.read_text(encoding='utf-8').splitlines():
        if re.match(r'^\s*root\s*=', line):
            continue
        kept.append(line)
    return '\n'.join(kept).strip() + '\n'


def safe_profile_component(value):
    s = re.sub(r'[^A-Za-z0-9_-]+', '-', value or '').strip('-')
    return (s[:24] or 'group')


def make_profiles(group, roots, excludes):
    gid = safe_profile_component(str(group.get('id') or group.get('name') or 'group'))
    prefs = preferences_for_group(group)
    profiles = []

    # Keep the normal no-exclusion case as the efficient hub-and-spoke topology.
    # When any directory has custom exclusions, add the spoke-to-spoke edges too.
    # This preserves directory-local exclusion semantics: a path excluded from one
    # replica can still synchronize among all other replicas that do not exclude it.
    pairs = [(0, j) for j in range(1, len(roots))]
    if any(excludes):
        pairs.extend((i, j) for i in range(1, len(roots)) for j in range(i + 1, len(roots)))

    for i, j in pairs:
        left, right = roots[i], roots[j]
        if i == 0:
            # Preserve existing archive/profile names for current hub edges.
            profile_name = f'ocr2md-group-{gid}-edge-{j + 1}'
        else:
            profile_name = f'ocr2md-group-{gid}-edge-{i + 1}-{j + 1}'
        profile_path = UNISON_DIR / f'{profile_name}.prf'

        edge_excludes = []
        seen = set()
        for value in excludes[i] + excludes[j]:
            if value not in seen:
                seen.add(value)
                edge_excludes.append(value)
        exclude_prefs = ''
        if edge_excludes:
            lines = ['# Directory-specific exclusions for this edge.']
            lines.extend(f'ignore = Path {value}' for value in edge_excludes)
            exclude_prefs = '\n' + '\n'.join(lines) + '\n'

        content = (
            f'# AUTO-GENERATED by ocr2md group sync. Do not edit.\n'
            f'root = {left}\n'
            f'root = {right}\n\n'
            f'{prefs}'
            f'{exclude_prefs}'
        )
        atomic_write(profile_path, content)
        os.chmod(profile_path, 0o600)
        profiles.append((profile_name, left, right))
    return profiles


def unison_env():
    env = os.environ.copy()
    env['UNISON'] = str(UNISON_DIR)
    env['UNISONLOCALHOSTNAME'] = HOSTNAME
    return env


def test_profile(profile_name):
    cp = subprocess.run(
        [str(UNISON_BIN), profile_name, '-testserver'],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors='replace',
        env=unison_env(),
        timeout=30,
    )
    if cp.returncode != 0:
        raise RuntimeError(f'profile {profile_name} failed -testserver rc={cp.returncode}: {cp.stdout[-2000:]}')


def run_edge(profile_name, group_name, group_id, pass_no, current, total, hub, spoke, start_time):
    state_base = dict(
        last_start=start_time,
        last_end='',
        exit_code='',
        status='running',
        phase='polling',
        group=group_name,
        group_id=group_id,
        **{'pass': pass_no},
        progress_current=current,
        progress_total=total,
        edge_from=str(hub),
        edge_to=str(spoke),
        profile=profile_name,
    )
    write_state(**state_base)
    log(f'\n===== {now()} GROUP={group_name} PASS={pass_no} PROGRESS={current}/{total} PROFILE={profile_name} =====')

    proc = subprocess.Popen(
        [str(UNISON_BIN), profile_name, '-batch', '-auto'],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors='replace',
        bufsize=1,
        env=unison_env(),
    )
    saw_change = False
    saw_conflict_text = False
    assert proc.stdout is not None
    for raw in proc.stdout:
        log(raw.rstrip('\n'))
        line = raw.replace('\r', ' ')
        if CONFLICT_RE.search(line):
            saw_conflict_text = True
        if CHANGE_RE.search(line) and 'Nothing to do' not in line:
            if not saw_change:
                saw_change = True
                state_base['phase'] = 'syncing'
                write_state(**state_base)
    rc = proc.wait()
    return rc, saw_change, saw_conflict_text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--validate-only', action='store_true')
    args = parser.parse_args()

    SYNCROOT.mkdir(parents=True, exist_ok=True)
    UNISON_DIR.mkdir(parents=True, exist_ok=True)
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    RUNLOG.parent.mkdir(parents=True, exist_ok=True)

    if not UNISON_BIN.is_file():
        raise RuntimeError(f'Unison binary not found: {UNISON_BIN}')

    groups = load_config()
    plans = []
    for group in groups:
        name, gid, roots, excludes = validate_group(group)
        profiles = make_profiles(group, roots, excludes)
        for profile_name, _, _ in profiles:
            test_profile(profile_name)
        plans.append((group, name, gid, roots, excludes, profiles))

    if args.validate_only:
        for _, name, gid, roots, excludes, profiles in plans:
            print(f'OK group={name} id={gid} dirs={len(roots)} edges={len(profiles)} excluded_dirs={sum(bool(x) for x in excludes)}')
            for profile_name, hub, spoke in profiles:
                print(f'  {profile_name}: {hub} <-> {spoke}')
        return 0

    overall_start = now()
    any_change = False
    for _, name, gid, roots, excludes, profiles in plans:
        total = len(roots)
        # Two sweeps make changes discovered on a later edge reach earlier edges
        # during the same launch, including the full-mesh case used for exclusions.
        for pass_no in (1, 2):
            for edge_index, (profile_name, hub, spoke) in enumerate(profiles, start=2):
                # On pass 1, progress reflects directories incorporated so far.
                # On pass 2 the group is in final convergence, so keep N/N visible.
                current = min(total, edge_index - 1) if pass_no == 1 else total
                rc, changed, conflict_text = run_edge(
                    profile_name, name, gid, pass_no, current, total,
                    hub, spoke, overall_start
                )
                any_change = any_change or changed
                if rc != 0 or conflict_text:
                    status = 'conflict_or_skipped' if rc == 1 or conflict_text else 'error'
                    end = now()
                    write_state(
                        last_start=overall_start, last_end=end, exit_code=rc,
                        status=status, phase='', group=name, group_id=gid,
                        **{'pass': pass_no}, progress_current=current,
                        progress_total=total, edge_from=str(hub), edge_to=str(spoke),
                        profile=profile_name,
                    )
                    log(f'===== HALT {end} rc={rc} status={status} =====')
                    return 1 if status == 'conflict_or_skipped' else (rc or 2)
            # After the first sweep, all configured replicas have participated.
            if pass_no == 1:
                write_state(
                    last_start=overall_start, last_end='', exit_code='',
                    status='running', phase='polling', group=name, group_id=gid,
                    **{'pass': pass_no}, progress_current=total,
                    progress_total=total, profile='group-convergence',
                )

    end = now()
    last_name = plans[-1][1]
    last_gid = plans[-1][2]
    last_total = len(plans[-1][3])
    write_state(
        last_start=overall_start,
        last_end=end,
        exit_code=0,
        status='ok',
        phase='',
        group=last_name,
        group_id=last_gid,
        **{'pass': 2},
        progress_current=last_total,
        progress_total=last_total,
        profile='sync-groups',
        changed='yes' if any_change else 'no',
    )
    log(f'===== {end} ALL GROUPS COMPLETE rc=0 status=ok changed={"yes" if any_change else "no"} =====')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        end = now()
        try:
            write_state(last_start=end, last_end=end, exit_code=2, status='error', phase='', profile='sync-groups', error=str(exc))
            log(f'\n===== {end} GROUP SYNC ERROR =====\n{type(exc).__name__}: {exc}')
        except Exception:
            pass
        print(f'ocr2md group sync error: {exc}', file=sys.stderr)
        sys.exit(2)
