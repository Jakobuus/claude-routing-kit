"""Delivery races and receipt ownership beyond the shell command contract."""
import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'plugins/routing-kit/lib'))
import board
import board_dm


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        env = patch.dict(os.environ, {
            'ROUTING_KIT_HOME': self.home.name,
            'KIT_BOARD_NAME': 'ignored-by-hooks', 'KIT_BOARD_FAMILY': 'claude',
        })
        env.start()
        self.addCleanup(env.stop)
        self.event = dict(agent='claude', session_id='test', cwd=self.home.name)
        # The hook ignores the inherited KIT_BOARD_NAME above: the receiver is named by its session id.
        self.receiver = board.session_name('claude', 'test')

    def post(self, text):
        with patch.dict(os.environ, KIT_BOARD_NAME='sender'):
            row = board.make_record(text, self.home.name, self.receiver, 'dm')
            board.append(row)
        return row

    def hook(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            board_dm.check(self.event)
        return out.getvalue()

    def test_write_during_delivery_is_read_on_next_hook(self):
        self.post('first')
        original = board.records

        def concurrent_write():
            snapshot = original()
            self.post('arrived during delivery')
            return snapshot

        with patch.object(board, 'records', side_effect=concurrent_write):
            first = self.hook()
        self.assertIn('first', first)
        self.assertNotIn('arrived during delivery', first)
        self.assertIn('arrived during delivery', self.hook())
        self.assertEqual('', self.hook())

    def test_only_recipient_can_acknowledge_dm(self):
        row = self.post('private')
        with patch.dict(os.environ, KIT_BOARD_NAME='other'):
            board.append(board.make_record('', self.home.name, 'sender', 'seen', row['id']))
        with patch.dict(os.environ, KIT_BOARD_NAME='sender'):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                board_dm.sent(None)
            self.assertIn('waiting', out.getvalue())
        self.assertIn('private', self.hook())
        with patch.dict(os.environ, KIT_BOARD_NAME='sender'):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                board_dm.sent(None)
            self.assertIn('seen', out.getvalue())

    def test_two_hook_runs_for_one_session_deliver_once(self):
        self.post('only once')
        printed, calls = [], []
        entered, release = threading.Event(), threading.Event()
        original = board.records

        def slow_records():
            rows = original()
            if not calls:  # the first run stalls between reading and posting seen
                calls.append(1)
                entered.set()
                release.wait(3)
            return rows

        with patch.object(board, 'records', side_effect=slow_records), \
                patch.object(board_dm, 'print', lambda text, **kw: printed.append(text), create=True):
            first = threading.Thread(target=board_dm.check, args=(self.event,))
            first.start()
            entered.wait(3)
            second = threading.Thread(target=board_dm.check, args=(self.event,))
            second.start()
            time.sleep(0.3)
            release.set()
            first.join()
            second.join()
        self.assertEqual(1, len(printed))

    def test_seen_is_posted_after_the_output(self):
        self.post('order')
        events, real_append = [], board.append

        def recording_append(row):
            events.append(row['kind'])
            real_append(row)

        with patch.object(board_dm, 'print', lambda text, **kw: events.append('print'), create=True), \
                patch.object(board, 'append', recording_append):
            board_dm.check(self.event)
        self.assertEqual(['print', 'seen'], events)

    def test_crash_before_output_posts_no_seen_and_keeps_the_dm(self):
        self.post('keep me')

        def boom(text, **kw):
            raise RuntimeError('killed before output')

        with patch.object(board_dm, 'print', boom, create=True):
            with self.assertRaises(RuntimeError):
                board_dm.check(self.event)
        self.assertFalse(any(r['kind'] == 'seen' for r in board.records()))
        self.assertFalse((Path(self.home.name) / 'board/hook-cursors' / (self.receiver + '.json')).exists())
        self.assertIn('keep me', self.hook())

    def test_agy_maps_to_gemini_and_unknown_agents_do_not_crash(self):
        with patch.dict(os.environ):
            os.environ.pop('KIT_BOARD_NAME')
            board_dm.check(dict(agent='agy', session_id='s-agy', cwd=self.home.name))
            board_dm.check(dict(agent='martian', session_id='s-m', cwd=self.home.name))
        names = [p.stem for p in (Path(self.home.name) / 'board/presence').glob('*.json')]
        self.assertEqual(1, len(names))
        self.assertTrue(names[0].startswith('gemini-'))

    def test_send_records_failed_unless_the_command_exits_zero(self):
        presence = Path(self.home.name) / 'board/presence/idle.json'
        presence.parent.mkdir(parents=True, exist_ok=True)
        presence.write_text('{"name":"idle","family":"claude","last_seen":"2020-01-01T00:00:00Z","paseo_id":"p1"}')
        args = type('Args', (), dict(name='idle', text='hi'))()
        cases = [(subprocess.CompletedProcess([], 0), 'queued'), (subprocess.CompletedProcess([], 1), 'failed'),
                 (FileNotFoundError('paseo'), 'failed'), (subprocess.TimeoutExpired('paseo', 10), 'failed')]
        for result, status in cases:
            patched = patch.object(board_dm.subprocess, 'run', side_effect=result if isinstance(result, BaseException) else None,
                                   return_value=None if isinstance(result, BaseException) else result)
            out = io.StringIO()
            with patch.dict(os.environ, KIT_BOARD_NAME='sender'), patched, \
                    patch.object(board, 'repository', return_value=self.home.name), contextlib.redirect_stdout(out):
                board_dm.send(args)
            self.assertTrue(out.getvalue().strip().endswith(status), (result, out.getvalue()))


if __name__ == '__main__':
    unittest.main()
