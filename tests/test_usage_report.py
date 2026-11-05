import importlib.util
from datetime import timezone
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch


module_path = Path(__file__).resolve().parents[1] / 'usage_report.py'
spec = importlib.util.spec_from_file_location('usage_report', module_path)
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)


class UsageReportTest(unittest.TestCase):
    def test_cross_midnight_multicard_and_overlapping_sessions(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            done = root / 'done'
            done.mkdir()
            (done / 'task_1').write_text('\n'.join([
                'SUBMIT_USER=alice',
                'START_TIME=2026-11-01T23:30:00+00:00',
                'FINISH_TIME=2026-11-02T00:30:00+00:00',
                'DEVICE=2,3',
                'EXIT_CODE=0',
            ]))
            last_output = '\n'.join([
                'alice pts/1 2026-11-01T23:00:00+00:00 - 2026-11-02T00:30:00+00:00 (01:30)',
                'alice pts/2 2026-11-01T23:45:00+00:00 - 2026-11-02T00:15:00+00:00 (00:30)',
                'wtmp begins 2026-11-01T00:00:00+00:00',
            ])
            db = usage.database(root / 'usage.sqlite3')
            usage.collect(db, root, last_output)
            usage.collect(db, root, last_output)
            first = usage.day_report(db, '2026-11-01', '686', timezone.utc)['users']['alice']
            second = usage.day_report(db, '2026-11-02', '686', timezone.utc)['users']['alice']
            self.assertEqual(first['tasks'], 1)
            self.assertEqual(first['task_hours'], 0.5)
            self.assertEqual(first['card_hours'], 1.0)
            self.assertEqual(first['login_hours'], 1.0)
            self.assertEqual(second['card_hours'], 1.0)
            self.assertEqual(second['login_hours'], 0.5)

    def test_publish_updates_one_week_document_on_retry(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            db = usage.database(root / 'usage.sqlite3')
            db.execute('INSERT INTO tasks VALUES (?,?,?,?,?,?)',
                       ('task_1', 'alice', usage.ts('2026-11-02T10:00:00+00:00'),
                        usage.ts('2026-11-02T11:00:00+00:00'), '2,3', 0))
            db.commit()

            class FakeFeishu:
                docs = {}
                sequence = 0

                def __init__(self, _config):
                    pass

                def create(self, title):
                    self.__class__.sequence += 1
                    doc = f'doc-{self.sequence}'
                    self.docs[doc] = []
                    return doc

                def content(self, doc):
                    return '\n'.join(self.docs[doc])

                def append(self, doc, texts):
                    self.docs[doc].extend(texts)

                def ensure_link(self, doc, url, label):
                    if url not in self.content(doc):
                        self.append(doc, [f'{label} → {url}'])

                def replace(self, doc, texts):
                    self.docs[doc] = list(texts)

            args = SimpleNamespace(db=root / 'usage.sqlite3', feishu_config=root / 'fake',
                                   hub_state_file=None, usage_index='', date='2026-11-02')
            with patch.object(usage, 'Feishu', FakeFeishu):
                usage.publish(db, args, '686', timezone.utc)
                usage.publish(db, args, '686', timezone.utc)
            self.assertEqual(FakeFeishu.sequence, 3)
            state = __import__('json').loads((root / 'publish-state.json').read_text())
            self.assertEqual(list(state['periods']), ['2026-W45'])
            self.assertEqual(sum('2026-11-02' in line for line in FakeFeishu.docs[state['periods']['2026-W45']]), 1)


if __name__ == '__main__':
    unittest.main()
