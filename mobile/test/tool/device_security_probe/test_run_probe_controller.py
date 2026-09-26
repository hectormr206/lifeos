"""In-memory fixtures only; imports perform no device actions or writes."""
import hashlib
import json
import unittest
from datetime import datetime, timezone
from mobile.tool.device_security_probe import run_probe_controller as p

CANDIDATE = ('a673345cc578632fc2894cc7564e0c6b492d73a7:sha256:'
             '701b2cf2f0a3a016d17ffbd9ebf0f999f5111317a777414d97e488c34b9fbd2d')
RUN = 'probe-progress-ABC123'
STAMP = '2026-09-02T12:00:00.000Z'
WINDOW = (datetime(2026, 9, 2, tzinfo=timezone.utc), datetime(2026, 9, 3, tzinfo=timezone.utc))
PATH = 'probe-report-XYZ/security-probe-results.json'


def encode(obj):
    return json.dumps(obj).encode()


def journal_records():
    records = []
    def add(event, sid=None):
        obj = dict(schema='lifeos.security-probe-progress/v1', candidate=CANDIDATE,
                   candidateEvidence=p.CLAIM, runId=RUN, sequence=len(records) + 1,
                   atUtc=STAMP, elapsedMillis=0, event=event)
        if sid:
            obj['scenarioId'] = sid
        if event in ('scenario_completed', 'identity_verified_before_journal'):
            obj.update(status='passed', category='verified', scenarioElapsedMillis=0)
        records.append(obj)
    add('run_started')
    add('identity_verified_before_journal', p.IDS[0])
    for sid in p.IDS[1:] + ('harness_report_write',):
        add('scenario_started', sid)
        add('scenario_completed', sid)
    add('run_terminal_passed')
    return records


def raw_journal(records):
    return b''.join(encode(r) + b'\n' for r in records)


def report():
    return dict(schema='lifeos.security-probe/v1', appId=p.PKG, candidate=CANDIDATE,
                candidateEvidence=p.CLAIM, startedAtUtc=STAMP, completedAtUtc=STAMP,
                applicationSupportRelativePath=PATH, status='passed', limits=p.LIMITS,
                counts=dict(passed=15, failed=0, blocked=0),
                results=[dict(scenarioId=s, status='passed', category='verified', elapsedMillis=0)
                         for s in p.IDS])


class EvidenceTests(unittest.TestCase):
    def parse(self, records, **kwargs):
        return p.parse_journal(raw_journal(records), CANDIDATE, RUN, WINDOW, **kwargs)

    def test_receipt_integrity_and_exact_candidate(self):
        raw = encode(dict(pkg=p.PKG, versionCode=2, candidate=CANDIDATE, apkSHA256='a' * 64))
        self.assertEqual(p.parse_receipt(raw, hashlib.sha256(raw).hexdigest())['candidate'], CANDIDATE)
        with self.assertRaises(ValueError):
            p.parse_receipt(raw, 'b' * 64)
        with self.assertRaises(ValueError):
            p.candidate_ok('short:sha256:' + 'a' * 64)

    def test_complete_and_missing_terminal(self):
        records = journal_records()
        self.assertEqual(p.validate_report(encode(report()), CANDIDATE, PATH, WINDOW,
                                          self.parse(records)), 'complete')
        self.assertEqual(p.validate_report(encode(report()), CANDIDATE, PATH, WINDOW,
                                          self.parse(records[:-1])), 'incomplete')

    def test_partial_tail_and_prefix_mutation(self):
        prefix = raw_journal(journal_records()[:2])
        parsed = p.parse_journal(prefix + b'{"sequence":3', CANDIDATE, RUN, WINDOW, prefix)
        self.assertEqual(parsed['complete'], prefix)
        self.assertEqual(parsed['tail'], b'{"sequence":3')
        self.assertEqual(parsed['completed'], [])
        for raw in (prefix[:-1], prefix.replace(b'run_started', b'run_changed')):
            with self.assertRaises(ValueError):
                p.parse_journal(raw, CANDIDATE, RUN, WINDOW, prefix)

    def test_invalid_journal_identity_sequence_and_fields(self):
        for key, value in [('sequence', 4), ('runId', 'ABC123'), ('candidate', 'other'),
                           ('event', 'invented'), ('extra', True), ('status', 'unknown')]:
            records = journal_records()
            records[1][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.parse(records)

    def test_stopped_and_unfinished_scenario(self):
        records = journal_records()
        records[-1]['event'] = 'run_terminal_stopped'
        self.assertEqual(self.parse(records)['outcome'], 'stopped')
        self.assertEqual(self.parse(records[:3])['outcome'], 'incomplete')

    def test_discovery_preserves_old_evidence_but_allows_fixture_cleanup(self):
        old = {'files', 'files/probe-progress-old', 'files/probe-progress-old/progress.jsonl'}
        new = old | {'files/' + RUN, 'files/' + RUN + '/progress.jsonl'}
        found = p.discover(old, new | {'files/security-probe-temp'})
        self.assertEqual(p.discover(old, new, found['persistent'])['progress'], RUN)
        with self.assertRaises(ValueError):
            p.discover(old, new - {'files/probe-progress-old/progress.jsonl'})
        with self.assertRaises(ValueError):
            p.discover(old, new | {'files/probe-progress-another'})
        with self.assertRaises(ValueError):
            p.discover(old | {'files/security-probe-old'}, new)
        with self.assertRaises(ValueError):
            p.preserve_baseline({'files/probe-progress-old/progress.jsonl': b'old'},
                                {'files/probe-progress-old/progress.jsonl': b'changed'})

    def test_bounds_duplicate_keys_and_retrospective_mismatch(self):
        for raw in (b'x' * 65537, b'{"a":1,"a":2}', b'{"a":NaN}'):
            with self.assertRaises(ValueError):
                p.decode(raw)
        obj = report()
        obj['results'][0]['elapsedMillis'] = 1
        with self.assertRaises(ValueError):
            p.validate_report(encode(obj), CANDIDATE, PATH, WINDOW, self.parse(journal_records()))

    def test_report_rejects_wrong_order_counts_and_identity(self):
        for key, value in [('counts', dict(passed=16, failed=0, blocked=0)),
                           ('candidate', 'wrong'), ('appId', 'com.lifeos.lifeos')]:
            obj = report()
            obj[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                p.validate_report(encode(obj), CANDIDATE, PATH, WINDOW, self.parse(journal_records()))
        obj = report()
        obj['results'].reverse()
        with self.assertRaises(ValueError):
            p.validate_report(encode(obj), CANDIDATE, PATH, WINDOW, self.parse(journal_records()))


# UNIT 2A BEGIN: all process, pipe, signal and clock interactions are mocked.
from contextlib import ExitStack
from unittest.mock import Mock, patch


class TransportTests(unittest.TestCase):
    def run_fake(self, chunks, *, ready=True, code=0, reaped=False):
        with ExitStack() as stack:
            popen = stack.enter_context(patch.object(p.subprocess, 'Popen'))
            selector_type = stack.enter_context(patch.object(p.selectors, 'DefaultSelector'))
            read = stack.enter_context(patch.object(p.os, 'read', side_effect=chunks))
            kill = stack.enter_context(patch.object(p.os, 'killpg'))
            stack.enter_context(patch.object(p.time, 'monotonic', return_value=100))
            proc = popen.return_value
            proc.pid = 4321
            proc.returncode = None
            order = []
            def observe(*args):
                self.assertEqual(args, (p.os.P_PID, 4321, p.os.WEXITED | p.os.WNOWAIT | p.os.WNOHANG))
                order.append('observe')
                if reaped:
                    raise ChildProcessError()
                return Mock(si_status=code, si_code=p.os.CLD_EXITED)
            stack.enter_context(patch.object(p.os, 'waitid', side_effect=observe))
            kill.side_effect = lambda *args: order.append('kill')
            proc.wait.side_effect = lambda **kwargs: order.append('reap')
            selector_type.return_value.__enter__.return_value.select.return_value = [1] if ready else []
            try:
                result = p.bounded_process(('trusted-command',), cap=4)
            except p.CommandFailure as error:
                result = error
            self.assertTrue(proc.stdout.close.called)
            proc.poll.assert_not_called()
            if reaped:
                kill.assert_not_called()
                proc.wait.assert_not_called()
            else:
                self.assertEqual(order[-3:], ['observe', 'kill', 'reap'])
            popen.assert_called_once_with(('trusted-command',), stdin=p.subprocess.DEVNULL,
                                         stdout=p.subprocess.PIPE, stderr=p.subprocess.STDOUT,
                                         start_new_session=True, bufsize=0)
            return result, read, kill

    def test_success_bounded_reads_no_cleanup_of_other_groups(self):
        result, read, kill = self.run_fake([b'ab', b'cd', b''])
        self.assertEqual(result, b'abcd')
        self.assertEqual([c.args[1] for c in read.call_args_list], [5, 3, 1])
        kill.assert_called_once_with(4321, p.signal.SIGKILL)

    def test_output_cap_retains_only_bounded_prefix_and_kills_owned_group(self):
        result, read, kill = self.run_fake([b'abcde'])
        self.assertEqual((result.status, result.output), ('output_limit', b'abcd'))
        self.assertEqual(read.call_count, 1)
        kill.assert_called_once_with(4321, p.signal.SIGKILL)

    def test_timeout_nonzero_and_wait_timeout_cleanup(self):
        for options, status in [({'ready': False}, 'timeout'), ({'code': 7}, 'nonzero')]:
            with self.subTest(options=options):
                result, _, kill = self.run_fake([b''], **options)
                self.assertEqual(result.status, status)
                kill.assert_called_once_with(4321, p.signal.SIGKILL)

    def test_already_reaped_never_kills_or_reaps_again(self):
        result, _, kill = self.run_fake([b''], reaped=True)
        self.assertEqual(result.status, 'ownership_lost')
        kill.assert_not_called()
        proc = Mock(returncode=7)
        with patch.object(p.os, 'killpg') as kill:
            p.cleanup_owned(proc)
            kill.assert_not_called()
            proc.wait.assert_not_called()

    def test_exact_container_command_and_closed_vocabulary(self):
        prefix = ('pct', 'exec', '212', '--', 'timeout', '-k', '2s', '10s',
                  'adb', '-s', '29291FDH300LVM')
        self.assertEqual(p.adb_command('stop'), prefix + ('shell', 'am', 'force-stop',
                                                        'com.lifeos.lifeos.securityprobe'))
        self.assertEqual(p.adb_command('tap', (321, 654)), prefix + ('shell', 'input', 'tap', '321', '654'))
        for action, arg in [('shell', 'reboot'), ('tap', (True, 3)), ('stop', 'other.package'),
                            ('read', 'files/../../secret'), ('read', 'files/probe-progress-x/a;id')]:
            with self.subTest(action=action), self.assertRaises(ValueError):
                p.adb_command(action, arg)

    def test_deadline_and_ambiguous_tap_never_retried(self):
        with patch.object(p.time, 'monotonic', return_value=100), \
                patch.object(p, 'bounded_process', side_effect=p.CommandFailure('timeout')) as run:
            with self.assertRaises(p.CommandFailure):
                p.adb_call('tap', (321, 654), deadline=105)
            run.assert_called_once_with(p.adb_command('tap', (321, 654)), seconds=5)
            run.reset_mock()
            with self.assertRaises(p.CommandFailure):
                p.adb_call('tap', (321, 654), deadline=100)
            run.assert_not_called()


class WatchdogTests(unittest.TestCase):
    def test_relative_wait_and_two_stops_despite_failure(self):
        events = []
        stop = Mock(side_effect=[p.CommandFailure('timeout'), b''])
        def emit(event):
            events.append(event)
        def sleep(seconds):
            self.assertEqual(seconds, 240)
            self.assertEqual(events, [{'event': 'armed', 'stop_after_seconds': 240}])
            stop.assert_not_called()
        result = p.run_watchdog('unused-mocked-root', acknowledge=Mock(), stop=stop,
                                sleep=sleep, emit=emit, clock=lambda: 0)
        self.assertEqual(stop.call_count, 2)
        self.assertEqual(result, ['timeout', 'command_succeeded_pid_unverified'])
        self.assertEqual([e['event'] for e in events],
                         ['armed', 'attempt_finished', 'attempt_finished', 'terminal'])
        self.assertEqual(events[-1]['status'], 'finished_pid_unverified')

    def test_failed_logging_and_failed_stops_are_finite(self):
        stop = Mock(side_effect=OSError('transport unavailable'))
        emit = Mock(side_effect=OSError('evidence unavailable'))
        sleep = Mock()
        ack = Mock()
        self.assertEqual(p.run_watchdog('unused', acknowledge=ack, stop=stop, sleep=sleep,
                                       emit=emit, clock=lambda: 0),
                         ['transport_error', 'transport_error'])
        sleep.assert_called_once_with(240)
        self.assertEqual(stop.call_count, 2)
        self.assertEqual(emit.call_count, 4)
        ack.assert_not_called()
        self.assertTrue(emit.call_args.args[0]['evidence_failed'])

    def test_armed_marker_and_log_are_flushed_without_real_files(self):
        with ExitStack() as stack:
            stack.enter_context(patch.object(p.Path, 'is_dir', return_value=True))
            stack.enter_context(patch.object(p.Path, 'is_symlink', return_value=False))
            opened = stack.enter_context(patch.object(p.os, 'open', return_value=99))
            streams = stack.enter_context(patch.object(p.os, 'fdopen'))
            stack.enter_context(patch.object(p.os, 'fstat', return_value=Mock(st_size=0)))
            synced = stack.enter_context(patch.object(p.os, 'fsync'))
            closed = stack.enter_context(patch.object(p.os, 'close'))
            p.watchdog_event('/tmp/lifeos-probe-run-test', {'event': 'armed'})
            stream = streams.return_value.__enter__.return_value
            self.assertEqual(stream.write.call_count, 2)
            self.assertEqual(stream.flush.call_count, 2)
            self.assertEqual(synced.call_count, 3)
            self.assertEqual(opened.call_args_list[0].args[0].name, 'watchdog.jsonl')
            marker = opened.call_args_list[1].args
            self.assertEqual(marker[0].name, 'watchdog-armed')
            self.assertTrue(marker[1] & p.os.O_EXCL)
            self.assertTrue(marker[1] & p.os.O_NOFOLLOW)
            closed.assert_called_once_with(99)

    def test_persistence_failure_at_each_step_forbids_ack(self):
        for operation, count in [('open', 3), ('fdopen', 2), ('write', 2), ('flush', 2),
                                 ('fsync', 3), ('close', 1), ('exit', 2)]:
            for occurrence in range(count):
                with self.subTest(operation=operation, occurrence=occurrence), ExitStack() as stack:
                    stack.enter_context(patch.object(p.Path, 'is_dir', return_value=True))
                    stack.enter_context(patch.object(p.Path, 'is_symlink', return_value=False))
                    opened = stack.enter_context(patch.object(p.os, 'open', return_value=99))
                    streams = stack.enter_context(patch.object(p.os, 'fdopen'))
                    stack.enter_context(patch.object(p.os, 'fstat', return_value=Mock(st_size=0)))
                    synced = stack.enter_context(patch.object(p.os, 'fsync'))
                    closed = stack.enter_context(patch.object(p.os, 'close'))
                    stream = streams.return_value.__enter__.return_value
                    targets = dict(open=opened, fdopen=streams, write=stream.write,
                                   flush=stream.flush, fsync=synced, close=closed,
                                   exit=streams.return_value.__exit__)
                    target = targets[operation]
                    target.side_effect = [target.return_value] * occurrence + [OSError('durability failure')]
                    ack, stop = Mock(), Mock()
                    def emit(event):
                        if event['event'] == 'armed':
                            p.watchdog_event('/tmp/lifeos-probe-run-test', event)
                    p.run_watchdog('unused', acknowledge=ack, stop=stop,
                                   sleep=Mock(), emit=emit, clock=lambda: 0)
                    ack.assert_not_called()
                    self.assertEqual(stop.call_count, 2)

    def test_logging_stall_occurs_only_after_both_stops(self):
        now, order = [0], []
        def emit(event):
            order.append(event['event'])
            if event['event'] == 'armed':
                now[0] += 5  # Pre-arm persistence consumes deadline, not extra time.
            else:
                self.assertEqual(order.count('stop'), 2)
                now[0] += 29  # Simulate stall that would exceed the supervisor budget.
        def sleep(seconds):
            self.assertEqual(seconds, 235)
            now[0] += seconds
        def stop():
            self.assertEqual(now[0], 240)
            order.append('stop')
        p.run_watchdog('unused', acknowledge=lambda: order.append('ack'),
                       stop=stop, sleep=sleep, emit=emit, clock=lambda: now[0])
        self.assertEqual(order[:5], ['armed', 'ack', 'stop', 'stop', 'attempt_finished'])

    def test_ack_pipe_is_nonblocking_exact_and_failure_is_not_success(self):
        with patch.object(p.os, 'set_blocking') as blocking, \
                patch.object(p.os, 'write', return_value=len(p.ARMED_ACK)) as write:
            p.watchdog_ack(9)
            blocking.assert_called_once_with(9, False)
            write.assert_called_once_with(9, b'lifeos-watchdog-armed/v1\n')
            for failure in (0, BlockingIOError(), BrokenPipeError()):
                write.side_effect = failure if isinstance(failure, Exception) else None
                write.return_value = failure
                with self.assertRaises((ValueError, OSError)):
                    p.watchdog_ack(9)

    def test_detached_supervisor_has_no_ssh_pipes_or_cancellation(self):
        with patch.object(p.Path, 'is_file', return_value=True), \
                patch.object(p.Path, 'resolve', lambda path: path), \
                patch.object(p.signal, 'signal', return_value='previous') as signals, \
                patch.object(p.subprocess, 'Popen') as launch:
            child = p.launch_watchdog(p.__file__, '/tmp/lifeos-probe-run-test', 9)
            launch.assert_called_once_with(
                ('timeout', '-k', '2s', '268s', p.sys.executable, '-B', p.__file__,
                 '--watchdog', '/tmp/lifeos-probe-run-test', '--ack-fd', '9'),
                stdin=p.subprocess.DEVNULL, stdout=p.subprocess.DEVNULL,
                stderr=p.subprocess.DEVNULL, start_new_session=True, pass_fds=(9,))
            self.assertEqual(signals.call_args_list[0].args, (p.signal.SIGHUP, p.signal.SIG_IGN))
            self.assertEqual(signals.call_args_list[-1].args, (p.signal.SIGHUP, 'previous'))
            child.terminate.assert_not_called()
            child.wait.assert_not_called()
# UNIT 2A END

# UNIT 2B BEGIN: no real files, children, signals or device commands.
class AdmissionTests(unittest.TestCase):
    def options(self):
        return argparse.Namespace(pid='1234', candidate=CANDIDATE, ready_at=100,
                                  x=321, y=654, ready='READY0_ENABLED')

    def session(self, *, guard_error=None, arm_error=None, tap_error=None, inventories=None):
        saved, actions = {}, []
        listings = iter(inventories or [b'files\n', b'files\n'])
        calls = [0]
        def device(action, argument=None, **kwargs):
            actions.append((action, argument))
            if action == 'inventory':
                return next(listings)
            if action == 'tap' and tap_error:
                raise tap_error
            return b'1234' if action == 'pid' else b''
        def clock():
            calls[0] += 1
            return 0 if calls[0] < 7 else 240
        with patch.object(p, 'adb_call', side_effect=device), \
                patch.object(p, 'device_guards', side_effect=guard_error), \
                patch.object(p, 'arm_watchdog', side_effect=arm_error, return_value=Mock(pid=99)), \
                patch.object(p.time, 'time', return_value=100), \
                patch.object(p.time, 'monotonic', side_effect=clock), \
                patch.object(p.time, 'sleep'):
            code = p.run_session(self.options(), {'candidate': CANDIDATE}, 'unused', saved.__setitem__)
        self.assertEqual(actions[-1], ('stop', None))
        return code, actions, saved

    def test_guard_or_missing_ack_prevents_tap_and_still_stops_only_probe(self):
        for failure in ({'guard_error': ValueError('guard')}, {'arm_error': ValueError('not armed')}):
            code, actions, saved = self.session(**failure)
            self.assertEqual(code, 2)
            self.assertNotIn('tap', [a[0] for a in actions])
            self.assertIn('controller-terminal.json', saved)

    def test_ambiguous_tap_is_not_retried(self):
        code, actions, saved = self.session(tap_error=p.CommandFailure('timeout'))
        self.assertEqual(code, 2)
        self.assertEqual(actions.count(('tap', (321, 654))), 1)
        self.assertIn('tap-issued', saved)

    def test_missing_terminal_never_passes_and_old_inventory_is_preserved(self):
        old = b'files\nfiles/probe-progress-old\n'
        code, actions, saved = self.session(inventories=[old, old + b'files/security-probe-new\n', old])
        self.assertEqual(code, 2)
        self.assertIn('files/probe-progress-old', json.loads(saved['baseline.json'])['paths'])
        self.assertEqual(actions.count(('tap', (321, 654))), 1)

    def test_real_guard_contract_checks_version_focus_keyguard_and_pid(self):
        replies = dict(state=b'device', package=b'versionCode=2 minSdk=23',
                       pwd=b'/data/user/0/com.lifeos.lifeos.securityprobe',
                       keyguard=b'showing=false\ninputRestricted=false\n', pid=b'1234',
                       focus=b'mCurrentFocus=Window{abc com.lifeos.lifeos.securityprobe/com.lifeos.lifeos.SecurityProbeActivity}')
        p.device_guards(lambda action: replies[action], self.options(), {'versionCode': 2})
        for field in replies:
            bad = dict(replies, **{field: b'wrong'})
            with self.subTest(field=field), self.assertRaises(ValueError):
                p.device_guards(lambda action: bad[action], self.options(), {'versionCode': 2})

    def test_ack_fragments_extra_short_and_timeout(self):
        cases = [([p.ARMED_ACK[:5], p.ARMED_ACK[5:]], [[1], [1], []], True),
                 ([p.ARMED_ACK + b'x'], [[1]], False), ([b'short'], [[1]], False),
                 ([b'lifeos-', b''], [[1], [1]], False), ([], [[]], False)]
        for chunks, readiness, valid in cases:
            with self.subTest(chunks=chunks), patch.object(p.os, 'set_blocking'), \
                    patch.object(p.os, 'read', side_effect=chunks), \
                    patch.object(p.selectors, 'DefaultSelector') as selector, \
                    patch.object(p.time, 'monotonic', return_value=0):
                selector.return_value.__enter__.return_value.select.side_effect = readiness
                if valid:
                    p.receive_ack(9, 3)
                else:
                    with self.assertRaises(ValueError):
                        p.receive_ack(9, 3)

    def test_pipe_lifecycle_closes_parent_fds_without_cancelling_child(self):
        with patch.object(p.os, 'pipe', return_value=(8, 9)), \
                patch.object(p.os, 'close') as close, patch.object(p, 'receive_ack') as ack, \
                patch.object(p.Path, 'resolve', lambda path: path), \
                patch.object(p, 'launch_watchdog') as launch, \
                patch.object(p.time, 'monotonic', return_value=0):
            ack.side_effect = lambda *args: self.assertEqual(close.call_args.args, (9,))
            child = p.arm_watchdog('/tmp/lifeos-probe-run-test', 20)
            self.assertEqual([c.args for c in close.call_args_list], [(9,), (8,)])
            child.terminate.assert_not_called()
            launch.assert_called_once()

    def test_complete_poll_correlates_dart_shape_and_preserves_old_bytes(self):
        expected = ('harness_identity sandbox_pristine storage_fresh storage_missing_key '
                    'storage_malformed_key storage_wrong_key storage_corrupt_ciphertext '
                    'storage_valid_empty_cleanup kdf_minimum_roundtrip kdf_wrong_passphrase_tamper '
                    'kdf_oversized_header kdf_invalid_seal_costs kdf_default_roundtrip '
                    'telemetry_count_unavailable_accepted telemetry_callback_error_persisted').split()
        obj = report()
        self.assertEqual([r['scenarioId'] for r in obj['results']], expected)
        for result in obj['results']:
            if result['scenarioId'] in ('kdf_default_roundtrip', 'telemetry_callback_error_persisted'):
                result.update(fixtureHash='a' * 64, fixtureLength=128)
        old_path = 'files/probe-progress-old/progress.jsonl'
        baseline = {'files', 'files/probe-progress-old', old_path}
        current = baseline | {'files/' + RUN, 'files/' + RUN + '/progress.jsonl',
                              'files/probe-report-XYZ', 'files/' + PATH}
        inventories = iter([baseline, current])
        old_reads, saved = [], {}
        def device(action, argument=None, **kwargs):
            if action == 'inventory':
                return ('\n'.join(sorted(next(inventories))) + '\n').encode()
            if action == 'read':
                if argument == old_path:
                    old_reads.append(argument)
                    return b'prior incomplete evidence'
                return encode(obj) if argument.endswith('.json') else raw_journal(journal_records())
            return b'1234' if action == 'pid' else b''
        with patch.object(p, 'adb_call', side_effect=device), \
                patch.object(p, 'device_guards'), patch.object(p, 'arm_watchdog', return_value=Mock(pid=99)), \
                patch.object(p.time, 'monotonic', return_value=0), \
                patch.object(p.time, 'time', return_value=100), \
                patch.object(p, 'datetime', wraps=datetime) as date:
            date.now.return_value = datetime(2026, 9, 2, 12, tzinfo=timezone.utc)
            code = p.run_session(self.options(), {'candidate': CANDIDATE}, 'unused', saved.__setitem__)
        self.assertEqual(code, 0)
        self.assertEqual(len(old_reads), 2)
        self.assertEqual(saved['baseline-000.bin'], b'prior incomplete evidence')
        self.assertIn('progress-001.jsonl', saved)
        self.assertEqual(json.loads(saved['controller-terminal.json'])['outcome'], 'complete')

    def test_child_dispatch_ack_closes_writer_and_short_write_fails(self):
        with patch.object(p, 'run_watchdog') as run, patch.object(p.os, 'close') as close, \
                patch.object(p.os, 'set_blocking'), patch.object(p.os, 'write', return_value=3):
            def child(root, *, acknowledge):
                with self.assertRaises(ValueError):
                    acknowledge()
            run.side_effect = child
            self.assertEqual(p.main(['--watchdog', '/tmp/lifeos-probe-run-test', '--ack-fd', '9']), 0)
            close.assert_called_once_with(9)

    def test_dispatch_rejects_bad_parameters_without_actions(self):
        with patch.object(p, 'run_watchdog') as run:
            for argv in [['--watchdog', '/tmp/wrong', '--ack-fd', '9'],
                         ['--watchdog', '/tmp/lifeos-probe-run-x', '--ack-fd', '2']]:
                with self.assertRaises(ValueError):
                    p.main(argv)
            run.assert_not_called()
        with patch.object(p.time, 'time', return_value=100):
            argv = ['--receipt', '/audit.json', '--receipt-sha256', 'a' * 64, '--pid', '1234',
                    '--candidate', CANDIDATE, '--ready', 'READY0_ENABLED', '--ready-at', '100',
                    '--x', '321', '--y', '654']
            self.assertEqual(p.parse_options(argv).pid, '1234')
            argv[-1] = '-1'
            with self.assertRaises(ValueError):
                p.parse_options(argv)


import argparse
# UNIT 2B END


class ScreenshotFreshnessTests(unittest.TestCase):
    def test_entry_inclusive_boundary_expiry_and_future(self):
        argv = ['--receipt', '/audit.json', '--receipt-sha256', 'a' * 64, '--pid', '1234',
                '--candidate', CANDIDATE, '--ready', 'READY0_ENABLED', '--ready-at', '100',
                '--x', '321', '--y', '654']
        for now, valid in [(159.999, True), (160, True), (160.001, False), (99.999, False)]:
            with self.subTest(now=now), patch.object(p.time, 'time', return_value=now):
                if valid:
                    self.assertEqual(p.parse_options(argv).ready_at, 100)
                else:
                    with self.assertRaisesRegex(ValueError, 'entry attestation expired'):
                        p.parse_options(argv)

    def test_tap_inclusive_boundary_expiry_and_future(self):
        self.assertEqual(p.SCREENSHOT_ENTRY_MAX_AGE_SECONDS, 60)
        self.assertEqual(p.SCREENSHOT_TAP_MAX_AGE_SECONDS, 90)
        for now, valid in [(189.999, True), (190, True), (190.001, False), (99.999, False)]:
            with self.subTest(now=now), patch.object(p.time, 'time', return_value=now):
                self.assertEqual(p.screenshot_fresh(100, p.SCREENSHOT_TAP_MAX_AGE_SECONDS), valid)

