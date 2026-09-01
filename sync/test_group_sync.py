#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).with_name('group-sync.py')
SPEC = importlib.util.spec_from_file_location('ocr2md_group_sync', MODULE_PATH)
assert SPEC and SPEC.loader
sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sync)


class FullScanPolicyTests(unittest.TestCase):
    def test_google_drive_provider_is_assigned_to_one_discovery_edge(self):
        google = Path('/Users/test/Library/CloudStorage/GoogleDrive-user@example.com/My Drive/vault')
        icloud = Path('/Users/test/Library/Mobile Documents/iCloud/Documents/vault')
        onedrive = Path('/Users/test/Library/CloudStorage/OneDrive-Personal/vault')
        assigned = set()

        self.assertTrue(sync.claim_periodic_discovery_scan(icloud, google, False, assigned))
        self.assertFalse(sync.claim_periodic_discovery_scan(google, onedrive, True, assigned))
        self.assertEqual(len(assigned), 1)

    def test_one_way_google_source_gets_discovery_scan_when_no_mirror_edge_exists(self):
        google = Path('/Users/test/Library/CloudStorage/GoogleDrive-user@example.com/My Drive/vault')
        backup = Path('/Users/test/Library/CloudStorage/OneDrive-Personal/vault')
        assigned = set()
        self.assertTrue(sync.claim_periodic_discovery_scan(google, backup, True, assigned))

    def test_google_drive_as_one_way_backup_is_not_scanned_for_ignored_backup_changes(self):
        source = Path('/Users/test/Documents/vault')
        google_backup = Path('/Users/test/Library/CloudStorage/GoogleDrive-user@example.com/My Drive/backup')
        self.assertFalse(sync.claim_periodic_discovery_scan(source, google_backup, True, set()))

    def test_periodic_full_scan_runs_at_baseline_and_after_interval_only(self):
        state = {'version': 1, 'profiles': {}}
        full, reason = sync.choose_full_scan('edge', True, state, now_epoch=1000)
        self.assertTrue(full)
        self.assertEqual(reason, 'provider-baseline-missing')

        with patch.object(sync, 'save_full_scan_state'):
            sync.record_full_scan_success('edge', state, now_epoch=1000)

        full, reason = sync.choose_full_scan('edge', True, state, now_epoch=1059)
        self.assertFalse(full)
        self.assertEqual(reason, 'fastcheck')

        full, reason = sync.choose_full_scan('edge', True, state, now_epoch=1060)
        self.assertTrue(full)
        self.assertEqual(reason, 'provider-periodic-safety-scan')

    def test_non_discovery_edge_always_uses_fastcheck(self):
        full, reason = sync.choose_full_scan('backup-edge', False, {'version': 1, 'profiles': {}}, now_epoch=99999)
        self.assertFalse(full)
        self.assertEqual(reason, 'fastcheck')

    def test_path_topology_output_triggers_group_convergence(self):
        self.assertIsNotNone(sync.PATH_TOPOLOGY_RE.search('         <---- new file   tools/a.md'))
        self.assertIsNotNone(sync.PATH_TOPOLOGY_RE.search('         ====> deleted    tools/a.md'))
        self.assertIsNone(sync.PATH_TOPOLOGY_RE.search('         ----> changed    tools/a.md'))

        full, reason = sync.apply_group_convergence_scan(False, 'fastcheck', True)
        self.assertTrue(full)
        self.assertEqual(reason, 'group-path-convergence')

        full, reason = sync.apply_group_convergence_scan(True, 'provider-periodic-safety-scan', True)
        self.assertTrue(full)
        self.assertEqual(reason, 'provider-periodic-safety-scan')


if __name__ == '__main__':
    unittest.main()
