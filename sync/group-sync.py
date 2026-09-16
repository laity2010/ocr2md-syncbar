#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
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
DIGEST_ERROR_RE = re.compile(r'Error in digesting\s+(.+?):?$', re.I)
PATH_TOPOLOGY_RE = re.compile(r'\b(?:new file|new dir|deleted)\b', re.I)
CONFLICT_PATH_RE = re.compile(r'^\s*skipped:\s+(.+?)\s+\(')
CONFLICTS = SYNCROOT / 'unison-conflicts.json'
FULL_SCAN_STATE = SYNCROOT / 'full-scan-state.json'
FULL_SCAN_INTERVAL_SECONDS = 60


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


def write_conflicts(group_name, group_id, profile_name, left, right, paths):
    doc = {
        'version': 1,
        'generated_at': now(),
        'group': group_name,
        'group_id': group_id,
        'profile': profile_name,
        'left_root': str(left),
        'right_root': str(right),
        'conflicts': [{'path': p} for p in paths],
    }
    atomic_write(CONFLICTS, json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


def clear_conflicts():
    try:
        CONFLICTS.unlink()
    except FileNotFoundError:
        pass


def load_full_scan_state():
    if not FULL_SCAN_STATE.is_file():
        return {'version': 1, 'profiles': {}}
    try:
        doc = json.loads(FULL_SCAN_STATE.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError) as exc:
        log(f'FULL_SCAN state unreadable; rebuilding: {type(exc).__name__}: {exc}')
        return {'version': 1, 'profiles': {}}
    if doc.get('version') != 1 or not isinstance(doc.get('profiles'), dict):
        log('FULL_SCAN state has unsupported format; rebuilding')
        return {'version': 1, 'profiles': {}}
    return doc


def save_full_scan_state(doc):
    atomic_write(FULL_SCAN_STATE, json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


def google_drive_provider_key(root: Path):
    parts = root.parts
    for index, part in enumerate(parts):
        if part.startswith('GoogleDrive-') and index > 0 and parts[index - 1] == 'CloudStorage':
            return str(Path(*parts[:index + 1]))
    return None


def claim_periodic_discovery_scan(left: Path, right: Path, one_way, assigned_providers):
    # A bidirectional edge can discover paths materialized on either Google Drive
    # side. A one-way version-backup edge only needs discovery when Google Drive is
    # the source; changes made inside the backup are intentionally ignored.
    roots = (left,) if one_way else (left, right)
    provider_keys = []
    for root in roots:
        key = google_drive_provider_key(root)
        if key and key not in provider_keys:
            provider_keys.append(key)
    unassigned = [key for key in provider_keys if key not in assigned_providers]
    if not unassigned:
        return False
    assigned_providers.update(unassigned)
    return True


def choose_full_scan(profile_name, enabled, state, now_epoch=None):
    if not enabled:
        return False, 'fastcheck'
    now_epoch = time.time() if now_epoch is None else now_epoch
    entry = state.get('profiles', {}).get(profile_name)
    if not isinstance(entry, dict) or not isinstance(entry.get('last_success_epoch'), (int, float)):
        return True, 'provider-baseline-missing'
    elapsed = now_epoch - float(entry['last_success_epoch'])
    if elapsed < 0 or elapsed >= FULL_SCAN_INTERVAL_SECONDS:
        return True, 'provider-periodic-safety-scan'
    return False, 'fastcheck'


def apply_group_convergence_scan(full_scan, scan_reason, force_full_remainder):
    if force_full_remainder and not full_scan:
        return True, 'group-path-convergence'
    return full_scan, scan_reason


def record_full_scan_success(profile_name, state, now_epoch=None):
    now_epoch = time.time() if now_epoch is None else now_epoch
    state.setdefault('profiles', {})[profile_name] = {
        'last_success_epoch': now_epoch,
        'last_success_at': datetime.fromtimestamp(now_epoch).strftime('%Y-%m-%d %H:%M:%S'),
    }
    save_full_scan_state(state)


def load_config():
    with CONFIG.open('r', encoding='utf-8') as f:
        doc = json.load(f)
    if doc.get('version') not in (2, 3, 4):
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




def normalized_mode(directory, group_name, root):
    mode = directory.get('mode') or 'mirror'
    if mode not in ('mirror', 'version_backup'):
        raise RuntimeError(f'group {group_name!r} has invalid mode {mode!r} for {root}')
    return mode

def validate_group(group):
    name = str(group.get('name') or '未命名同步组')
    gid = str(group.get('id') or '')
    dirs = group.get('directories') or []
    if len(dirs) < 2:
        raise RuntimeError(f'group {name!r} needs at least 2 directories')
    roots = [normalized_root(d.get('path')) for d in dirs]
    excludes = [normalized_excludes(d, name, root) for d, root in zip(dirs, roots)]
    modes = [normalized_mode(d, name, root) for d, root in zip(dirs, roots)]
    if not any(mode == 'mirror' for mode in modes):
        raise RuntimeError(f'group {name!r} needs at least one working mirror directory')
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
    return name, gid, roots, excludes, modes


def engine_ignore_preferences():
    # Engine/OS metadata is not user content and is never counted as a mirror difference.
    return '''ignore = Name .DS_Store
ignore = Name .sync.ffs_db
ignore = Name ._*
ignore = Name .unison.*.unison.tmp
'''


def generic_preferences():
    return f'''\n# Generic safe defaults generated by ocr2md group sync.\n{engine_ignore_preferences()}\nperms = 0\nowner = false\ngroup = false\nxattrs = false\ntimes = false\nlinks = false\n\nconfirmbigdel = true\nlog = true\nlogfile = {UNISON_LOG}\n\ncopyonconflict = false\nbackuploc = central\nbackupdir = {BACKUP_DIR}\nbackup = Name *\nmaxbackups = 10\n'''


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
        # Roots and legacy ignores are topology-specific.  Directory exclusions now
        # live explicitly in sync-groups.json, while engine metadata ignores remain global.
        if re.match(r'^\s*root\s*=', line) or re.match(r'^\s*ignore\s*=', line):
            continue
        kept.append(line)
    return engine_ignore_preferences() + '\n' + '\n'.join(kept).strip() + '\n'


def safe_profile_component(value):
    s = re.sub(r'[^A-Za-z0-9_-]+', '-', value or '').strip('-')
    return (s[:24] or 'group')


def make_profiles(group, roots, excludes, modes):
    gid = safe_profile_component(str(group.get('id') or group.get('name') or 'group'))
    prefs = preferences_for_group(group)
    profiles = []

    working = [i for i, mode in enumerate(modes) if mode == 'mirror']
    backups = [i for i, mode in enumerate(modes) if mode == 'version_backup']
    assigned_discovery_providers = set()

    # Working replicas converge bidirectionally. Preserve the efficient hub-and-spoke
    # topology unless directory-local exclusions require spoke-to-spoke edges.
    pairs = []
    if len(working) >= 2:
        hub = working[0]
        pairs.extend((hub, j, False) for j in working[1:])
        if any(excludes[i] for i in working):
            pairs.extend(
                (working[a], working[b], False)
                for a in range(1, len(working))
                for b in range(a + 1, len(working))
            )

    # A version-backup replica receives from every working replica so directory-local
    # exclusions remain meaningful, but it is never a source. `force = source` is
    # Unison's mirroring mode and prevents changes made in the backup from propagating out.
    for backup_index in backups:
        pairs.extend((source_index, backup_index, True) for source_index in working)

    for i, j, one_way in pairs:
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

        direction_prefs = ''
        if one_way:
            direction_prefs = (
                '\n# Version-backup edge: changes only flow from the working replica to the backup.\n'
                f'force = {left}\n'
            )

        content = (
            f'# AUTO-GENERATED by ocr2md group sync. Do not edit.\n'
            f'root = {left}\n'
            f'root = {right}\n\n'
            f'{prefs}'
            f'{exclude_prefs}'
            f'{direction_prefs}'
        )
        atomic_write(profile_path, content)
        os.chmod(profile_path, 0o600)
        periodic_full_scan = claim_periodic_discovery_scan(
            left, right, one_way, assigned_discovery_providers
        )
        profiles.append((profile_name, left, right, one_way, periodic_full_scan))
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


def run_edge(profile_name, group_name, group_id, pass_no, current, total, hub, spoke, start_time, full_scan=False, scan_reason='fastcheck'):
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
        scan_mode='full' if full_scan else 'fast',
        scan_reason=scan_reason,
    )
    write_state(**state_base)
    log(f'\n===== {now()} GROUP={group_name} PASS={pass_no} PROGRESS={current}/{total} PROFILE={profile_name} =====')
    log(f'FULL_SCAN mode={"full" if full_scan else "fast"} reason={scan_reason}')
    command = [str(UNISON_BIN), profile_name, '-batch', '-auto']
    if full_scan:
        command.extend(['-fastcheck', 'false'])

    proc = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors='replace',
        bufsize=1,
        env=unison_env(),
    )
    saw_change = False
    saw_conflict_text = False
    saw_path_change = False
    saw_digest_error = False
    digest_error_path = ''
    conflict_paths = []
    conflict_seen = set()
    assert proc.stdout is not None
    for raw in proc.stdout:
        log(raw.rstrip('\n'))
        line = raw.replace('\r', ' ')
        if CONFLICT_RE.search(line):
            saw_conflict_text = True
        digest_match = DIGEST_ERROR_RE.search(line.strip())
        if digest_match:
            saw_digest_error = True
            if not digest_error_path:
                digest_error_path = digest_match.group(1).strip()
        if PATH_TOPOLOGY_RE.search(line):
            saw_path_change = True
        match = CONFLICT_PATH_RE.search(line)
        if match:
            path = match.group(1).strip()
            if path and path not in conflict_seen:
                conflict_seen.add(path)
                conflict_paths.append(path)
        if CHANGE_RE.search(line) and 'Nothing to do' not in line:
            if not saw_change:
                saw_change = True
                state_base['phase'] = 'syncing'
                write_state(**state_base)
    rc = proc.wait()
    return rc, saw_change, saw_conflict_text, conflict_paths, saw_path_change, saw_digest_error, digest_error_path


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
        name, gid, roots, excludes, modes = validate_group(group)
        profiles = make_profiles(group, roots, excludes, modes)
        for profile_name, _, _, _, _ in profiles:
            test_profile(profile_name)
        plans.append((group, name, gid, roots, excludes, modes, profiles))

    if args.validate_only:
        for _, name, gid, roots, excludes, modes, profiles in plans:
            print(f'OK group={name} id={gid} dirs={len(roots)} edges={len(profiles)} excluded_dirs={sum(bool(x) for x in excludes)} backups={sum(m == "version_backup" for m in modes)}')
            for profile_name, left, right, one_way, periodic_full_scan in profiles:
                arrow = '->' if one_way else '<->'
                discovery = ' [periodic-full-scan]' if periodic_full_scan else ''
                print(f'  {profile_name}: {left} {arrow} {right}{discovery}')
        return 0

    full_scan_state = load_full_scan_state()
    overall_start = now()
    any_change = False
    for _, name, gid, roots, excludes, modes, profiles in plans:
        total = len(roots)
        need_full_convergence_pass = False
        # Two sweeps make changes discovered on a later edge reach earlier edges
        # during the same launch, including the full-mesh case used for exclusions.
        for pass_no in (1, 2):
            full_convergence_pass = pass_no == 2 and need_full_convergence_pass
            for edge_index, (profile_name, hub, spoke, one_way, periodic_full_scan) in enumerate(profiles, start=2):
                # On pass 1, progress reflects directories incorporated so far.
                # On pass 2 the group is in final convergence, so keep N/N visible.
                current = min(total, edge_index - 1) if pass_no == 1 else total
                full_scan, scan_reason = choose_full_scan(
                    profile_name, periodic_full_scan, full_scan_state
                )
                full_scan, scan_reason = apply_group_convergence_scan(
                    full_scan, scan_reason, full_convergence_pass
                )
                rc, changed, conflict_text, conflict_paths, path_topology_changed, digest_error, digest_error_path = run_edge(
                    profile_name, name, gid, pass_no, current, total,
                    hub, spoke, overall_start, full_scan=full_scan, scan_reason=scan_reason
                )
                any_change = any_change or changed
                if rc == 0 and not conflict_text and full_scan and periodic_full_scan:
                    record_full_scan_success(profile_name, full_scan_state)
                if rc == 0 and not conflict_text and path_topology_changed and pass_no == 1:
                    need_full_convergence_pass = True
                    log(f'FULL_SCAN escalation=next-pass-full-convergence trigger={profile_name}')
                    # Do not let later edges act on a partially discovered path set.
                    # The second sweep will rescan every edge in full mode from a
                    # consistent starting point.
                    break
                if rc != 0 or conflict_text:
                    # Unison rc=1 means "some updates were skipped".  That is not
                    # necessarily a content conflict: File Provider placeholders can
                    # also fail to digest and return rc=1.  Only the explicit Unison
                    # conflict marker (<-?->) is exposed to the conflict manager.
                    status = 'conflict_or_skipped' if conflict_text else 'error'
                    end = now()
                    extra = {}
                    if digest_error:
                        provider = 'OneDrive' if 'OneDrive-' in str(hub) or 'OneDrive-' in str(spoke) else ('Google Drive' if 'GoogleDrive-' in str(hub) or 'GoogleDrive-' in str(spoke) else '云盘')
                        extra['error_kind'] = 'provider_content_unavailable'
                        extra['error_detail'] = f'{provider} 文件内容暂不可读（可能尚未下载到本机）'
                        if digest_error_path:
                            extra['error_path'] = digest_error_path
                    write_state(
                        last_start=overall_start, last_end=end, exit_code=rc,
                        status=status, phase='', group=name, group_id=gid,
                        **{'pass': pass_no}, progress_current=current,
                        progress_total=total, edge_from=str(hub), edge_to=str(spoke),
                        profile=profile_name, **extra,
                    )
                    if status == 'conflict_or_skipped':
                        write_conflicts(name, gid, profile_name, hub, spoke, conflict_paths)
                    else:
                        # Never leave stale conflict UI behind for a non-conflict rc=1.
                        clear_conflicts()
                    log(f'===== HALT {end} rc={rc} status={status} error_kind={extra.get("error_kind", "")} =====')
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
    clear_conflicts()
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
