"""Asus-side single-attempt controller; invoke this filename, never shell stdin.

API: parse_receipt(bytes, expected_sha256), discover(baseline, current, seen),
parse_journal(bytes, candidate, run_id, window, previous_complete=b''), and
validate_report(bytes, candidate, relative_path, window, journal).
window is (earliest, latest) timezone-aware datetime, supplied by the controller.
Receipt JSON has exactly: pkg, versionCode (positive integer), candidate
(full 40-hex commit:sha256:64-hex digest), apkSHA256 (64 lowercase hex).
The receipt digest protects receipt integrity, NOT installed APK/source identity.
Discovery takes bounded path collections; preserve returned persistent paths in
seen on every poll. Baseline content snapshots must also be checked with
preserve_baseline. Raw snapshots, including partial tails, belong to the caller.
PASS requires a uniquely discovered new pair and this validator's complete
outcome. Pairing by candidate and time window is NOT cryptographic binding:
Dart reports have no shared runId reference. External audit and parent judgment
remain authoritative. Validators perform no I/O. Unit 2A adds explicitly called
transport/watchdog primitives below; imports perform no actions. CLI admission
requires an externally audited receipt and fresh screenshot attestation.
"""

import hashlib
import json
import re
from datetime import datetime

PKG = 'com.lifeos.lifeos.securityprobe'
CLAIM = 'build_injected_claim_pending_apk_binding'
IDS = ('harness_identity', 'sandbox_pristine', 'storage_fresh',
       'storage_missing_key', 'storage_malformed_key', 'storage_wrong_key',
       'storage_corrupt_ciphertext', 'storage_valid_empty_cleanup',
       'kdf_minimum_roundtrip', 'kdf_wrong_passphrase_tamper',
       'kdf_oversized_header', 'kdf_invalid_seal_costs', 'kdf_default_roundtrip',
       'telemetry_count_unavailable_accepted', 'telemetry_callback_error_persisted')
LIMITS = ['synthetic_transport_not_real_network_outage',
          'single_entry_recovery_not_multi_entry_fifo',
          'probe_ui_not_production_banner', 'apk_source_binding_requires_external_verifier']
HEX = r'[0-9a-f]{64}'
ROOT = r'probe-(?:progress|report)-[A-Za-z0-9_-]+'
BASE = {'schema', 'candidate', 'candidateEvidence', 'runId', 'sequence',
        'atUtc', 'elapsedMillis', 'event'}
RESULT = {'status', 'category', 'scenarioElapsedMillis'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def matches(pattern, value):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def integer(value):
    return type(value) is int and 0 <= value <= 2**53 - 1


def candidate_ok(candidate):
    require(matches(r'[0-9a-f]{40}:sha256:' + HEX, candidate), 'candidate')


def bounded(raw):
    require(type(raw) is bytes and len(raw) <= 65536, 'byte limit')


def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        require(key not in obj, 'duplicate JSON key')
        obj[key] = value
    return obj


def decode(raw):
    bounded(raw)
    try:
        value = json.loads(raw, object_pairs_hook=unique_object,
                           parse_constant=lambda _: require(False, 'JSON constant'))
    except (UnicodeError, RecursionError, json.JSONDecodeError) as error:
        raise ValueError('invalid JSON') from error
    require(type(value) is dict, 'JSON object required')
    return value


def parse_receipt(raw, expected_sha256):
    bounded(raw)
    require(matches(HEX, expected_sha256), 'receipt digest format')
    require(hashlib.sha256(raw).hexdigest() == expected_sha256, 'receipt digest mismatch')
    obj = decode(raw)
    require(set(obj) == {'pkg', 'versionCode', 'candidate', 'apkSHA256'}, 'receipt fields')
    require(obj['pkg'] == PKG and integer(obj['versionCode']) and obj['versionCode'] > 0,
            'receipt package/version')
    candidate_ok(obj['candidate'])
    require(matches(HEX, obj['apkSHA256']), 'APK digest')
    return obj


def persistent(path):
    return any(matches(ROOT, part) for part in path.split('/'))


def paths(values):
    require(isinstance(values, (set, frozenset, list, tuple)) and len(values) <= 512,
            'listing count')
    require(all(matches(r'files(?:/[A-Za-z0-9_.-]{1,128}){0,3}', p)
                and all(part not in ('.', '..') for part in p.split('/'))
                for p in values), 'private path')
    require(sum(len(p) + 1 for p in values) <= 65536, 'listing bytes')
    return set(values)


def discover(baseline, current, seen=()):
    baseline, current, seen = paths(baseline), paths(current), paths(seen)
    require(not any(part.startswith('security-probe-') for p in baseline
                    for part in p.split('/')), 'pre-existing fixture; preserve, no reset')
    required = {p for p in baseline | seen if persistent(p)}
    require(required <= current, 'persistent evidence disappeared')
    new = current - baseline
    old_roots = {p.split('/')[1] for p in baseline if persistent(p)}
    roots = {p.split('/')[1] for p in new if p.count('/') >= 1 and persistent(p)}
    require(not roots & old_roots, 'new entries in prior persistent directory')
    require(all(matches(ROOT, root) for root in roots), 'nested persistent root')
    progress = sorted(r for r in roots if r.startswith('probe-progress-'))
    reports = sorted(r for r in roots if r.startswith('probe-report-'))
    require(len(progress) <= 1 and len(reports) <= 1, 'ambiguous new evidence')
    return {'progress': progress[0] if progress else None,
            'report': reports[0] if reports else None,
            'persistent': {p for p in current if persistent(p)}}


def preserve_baseline(baseline, current):
    """Compare bounded bytes of prior persistent files; never overwrite them."""
    paths(list(baseline))
    paths(list(current))
    for path, raw in baseline.items():
        bounded(raw)
        if persistent(path):
            require(path in current and current[path] == raw, 'baseline evidence changed')


def timestamp(value, window):
    require(matches(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z', value), 'UTC timestamp')
    try:
        result = datetime.fromisoformat(value.replace('Z', '+00:00'))
        require(window[0] <= result <= window[1], 'outside run window')
    except (TypeError, OverflowError) as error:
        raise ValueError('invalid time window') from error
    return result


def result_ok(obj, elapsed_key):
    require(obj['status'] in ('passed', 'failed', 'blocked'), 'status')
    require(obj['category'] in ('verified', 'safetyGuard', 'invariant', 'unexpected'), 'category')
    require(integer(obj[elapsed_key]), 'elapsed')
    require((obj['status'] == 'passed') == (obj['category'] == 'verified'), 'result category')


def parse_journal(raw, candidate, run_id, window, previous_complete=b''):
    bounded(raw)
    bounded(previous_complete)
    candidate_ok(candidate)
    require(matches(r'probe-progress-[A-Za-z0-9_-]+', run_id), 'full runId')
    require(not previous_complete or previous_complete.endswith(b'\n'), 'previous prefix incomplete')
    require(raw.startswith(previous_complete), 'journal prefix changed/truncated')
    end = raw.rfind(b'\n') + 1
    complete, tail = raw[:end], raw[end:]
    lines = complete[:-1].split(b'\n') if complete else []
    require(len(lines) <= 64, 'record count')
    records, completed = [], []
    pending, terminal, identity = None, None, None
    last_time, last_elapsed = window[0], 0
    for number, line in enumerate(lines, 1):
        obj = decode(line)
        event = obj.get('event')
        extras = {'scenarioId'} if event == 'scenario_started' else set()
        if event in ('scenario_completed', 'identity_verified_before_journal'):
            extras = RESULT | {'scenarioId'}
        require(set(obj) == BASE | extras, 'journal fields')
        require(obj['schema'] == 'lifeos.security-probe-progress/v1' and
                obj['candidate'] == candidate and obj['candidateEvidence'] == CLAIM and
                obj['runId'] == run_id, 'journal identity')
        require(type(obj['sequence']) is int and obj['sequence'] == number, 'sequence gap')
        now = timestamp(obj['atUtc'], window)
        require(now >= last_time and integer(obj['elapsedMillis']) and
                obj['elapsedMillis'] >= last_elapsed, 'journal time regression')
        last_time, last_elapsed = now, obj['elapsedMillis']
        require(terminal is None, 'record after terminal')
        if number == 1:
            require(event == 'run_started', 'missing run start')
        elif number == 2:
            require(event == 'identity_verified_before_journal' and
                    obj['scenarioId'] == IDS[0], 'missing retrospective identity')
            result_ok(obj, 'scenarioElapsedMillis')
            require(obj['status'] == 'passed', 'identity not passed')
            identity = obj
        elif event == 'scenario_started':
            sid = obj['scenarioId']
            expected = IDS[1:][len(completed):len(completed) + 1]
            require(pending is None and (sid == 'harness_report_write' or
                    (expected == (sid,) and all(r['status'] == 'passed' for r in completed))),
                    'scenario order')
            require(not any(r['scenarioId'] == 'harness_report_write' for r in completed), 'after report')
            pending = sid
        elif event == 'scenario_completed':
            require(pending is not None and obj['scenarioId'] == pending, 'unmatched completion')
            result_ok(obj, 'scenarioElapsedMillis')
            completed.append(obj)
            pending = None
        else:
            require(event in ('run_terminal_passed', 'run_terminal_stopped') and
                    pending is None and completed and
                    completed[-1]['scenarioId'] == 'harness_report_write', 'terminal checkpoint')
            terminal = event
        records.append(obj)
    outcome = 'incomplete'
    if terminal == 'run_terminal_stopped' or any(r['status'] != 'passed' for r in completed):
        outcome = 'stopped'
    elif terminal == 'run_terminal_passed':
        require([r['scenarioId'] for r in completed] == list(IDS[1:]) + ['harness_report_write'],
                'passed journal missing scenarios')
        outcome = 'complete'
    return {'candidate': candidate, 'runId': run_id, 'window': window,
            'outcome': outcome, 'complete': complete, 'tail': tail,
            'identity': identity, 'completed': completed, 'terminal': terminal}


def validate_report(raw, candidate, relative_path, window, journal):
    candidate_ok(candidate)
    require(journal['candidate'] == candidate and journal['window'] == window, 'correlation identity')
    require(matches(r'probe-report-[A-Za-z0-9_-]+/security-probe-results\.json', relative_path), 'report path')
    obj = decode(raw)
    require(set(obj) == {'schema', 'appId', 'candidate', 'candidateEvidence', 'startedAtUtc',
                        'completedAtUtc', 'applicationSupportRelativePath', 'status',
                        'counts', 'results', 'limits'}, 'report fields')
    require(obj['schema'] == 'lifeos.security-probe/v1' and obj['appId'] == PKG and
            obj['candidate'] == candidate and obj['candidateEvidence'] == CLAIM and
            obj['applicationSupportRelativePath'] == relative_path, 'report identity')
    require(timestamp(obj['startedAtUtc'], window) <= timestamp(obj['completedAtUtc'], window), 'report time')
    require(obj['limits'] == LIMITS and obj['status'] in ('passed', 'stopped'), 'report limits/status')
    results = obj['results']
    require(type(results) is list and 1 <= len(results) <= 16, 'result count')
    for result in results:
        require(type(result) is dict and {'scenarioId', 'status', 'category', 'elapsedMillis'} <= set(result)
                <= {'scenarioId', 'status', 'category', 'elapsedMillis', 'fixtureHash', 'fixtureLength'}, 'result fields')
        result_ok(result, 'elapsedMillis')
        if 'fixtureHash' in result or 'fixtureLength' in result:
            require(matches(HEX, result.get('fixtureHash')) and integer(result.get('fixtureLength')), 'fixture metadata')
    ids = [r['scenarioId'] for r in results]
    normal = ids[:-1] if ids[-1] == 'harness_execution' else ids
    require(normal == list(IDS[:len(normal)]), 'report scenario order')
    counts = {s: sum(r['status'] == s for r in results) for s in ('passed', 'failed', 'blocked')}
    require(type(obj['counts']) is dict and all(type(v) is int for v in obj['counts'].values())
            and obj['counts'] == counts, 'counts')
    if obj['status'] == 'stopped':
        require(counts['failed'] + counts['blocked'] > 0, 'stopped without failure')
        return 'stopped'
    require(ids == list(IDS) and counts['passed'] == 15, 'passed report scenarios')
    if journal['outcome'] != 'complete':
        return journal['outcome']
    evidence = [journal['identity']] + journal['completed'][:-1]
    for result, record in zip(results, evidence):
        require(all(result[k] == record[k] for k in ('scenarioId', 'status', 'category')) and
                result['elapsedMillis'] == record['scenarioElapsedMillis'], 'report/journal mismatch')
    return 'complete'


# UNIT 2A BEGIN: transport/watchdog primitives; no dispatch until Unit 2B.
import os
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path

SERIAL = '29291FDH300LVM'


class CommandFailure(RuntimeError):
    def __init__(self, status, output=b'', returncode=None):
        super().__init__(status)
        self.status, self.output, self.returncode = status, output, returncode


def bounded_process(argv, seconds=12, cap=65536):
    """Trusted argv only. Retain at most cap bytes, never communicate()/capture_output.

    A fresh session owns the only host process group we may kill. Container-side
    timeout separately bounds ADB; killing pct does not prove device cancellation.
    """
    require(type(argv) is tuple and 1 <= len(argv) <= 32 and
            all(isinstance(a, str) and 0 < len(a) <= 512 for a in argv), 'argv')
    require(type(seconds) in (int, float) and 0 < seconds <= 12 and
            type(cap) is int and 0 < cap <= 65536, 'command bounds')
    deadline = time.monotonic() + seconds
    proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, start_new_session=True, bufsize=0)
    output = bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ)
            while True:
                left = deadline - time.monotonic()
                if left <= 0 or not selector.select(left):
                    raise CommandFailure('timeout', bytes(output))
                chunk = os.read(proc.stdout.fileno(), min(4096, cap - len(output) + 1))
                if not chunk:
                    break
                if len(output) + len(chunk) > cap:
                    output.extend(chunk[:cap - len(output)])
                    raise CommandFailure('output_limit', bytes(output))
                output.extend(chunk)
        while True:
            try:
                exited = os.waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG)
            except ChildProcessError as error:
                raise CommandFailure('ownership_lost', bytes(output)) from error
            if exited is not None:
                break
            if time.monotonic() >= deadline:
                raise CommandFailure('timeout', bytes(output))
            time.sleep(min(0.01, max(0, deadline - time.monotonic())))
        code = exited.si_status if exited.si_code == os.CLD_EXITED else -exited.si_status
        if code != 0:
            raise CommandFailure('nonzero', bytes(output), code)
        return bytes(output)
    finally:
        try:
            cleanup_owned(proc)
        finally:
            proc.stdout.close()


def cleanup_owned(proc):
    """Linux single-owner child: retain zombie/PID until group cleanup, then reap.

    No poll(), wait(), SIGCHLD auto-reaper or concurrent child reaper is allowed
    before this function. ECHILD/already-reaped means ownership lost: never kill.
    """
    if proc.returncode is not None:
        return
    try:
        os.waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG)
    except ChildProcessError:
        return
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait(timeout=2)


def adb_command(action, argument=None):
    """Closed command vocabulary; no caller-provided shell programs or strings."""
    fixed = {
        'state': ('get-state',),
        'package': ('shell', 'dumpsys', 'package', PKG),
        'pwd': ('shell', 'run-as', PKG, 'pwd'),
        'inventory': ('shell', 'run-as', PKG, 'find', 'files', '-maxdepth', '3'),
        'keyguard': ('shell', 'dumpsys', 'window', 'policy'),
        'focus': ('shell', 'dumpsys', 'window'),
        'pid': ('shell', 'pidof', PKG),
        'stop': ('shell', 'am', 'force-stop', PKG),
    }
    require(isinstance(action, str), 'action type')
    if action == 'read':
        require(matches(r'files/(?:probe-progress-[A-Za-z0-9_-]+/progress\.jsonl|'
                        r'probe-report-[A-Za-z0-9_-]+/security-probe-results\.json)', argument)
                and len(argument) <= 256, 'evidence path')
        args = ('exec-out', 'run-as', PKG, 'head', '-c', '65537', argument)
    elif action == 'tap':
        require(type(argument) is tuple and len(argument) == 2 and
                all(type(n) is int and 0 <= n <= 16384 for n in argument), 'coordinates')
        args = ('shell', 'input', 'tap', *(str(n) for n in argument))
    else:
        require(action in fixed and argument is None, 'unsupported device command')
        args = fixed[action]
    return ('pct', 'exec', '212', '--', 'timeout', '-k', '2s', '10s',
            'adb', '-s', SERIAL, *args)


def adb_call(action, argument=None, *, deadline=None):
    """One attempt only, including tap. Output-limit errors retain bounded bytes."""
    seconds = 12 if deadline is None else min(12, deadline - time.monotonic())
    if seconds <= 0:
        raise CommandFailure('timeout')
    return bounded_process(adb_command(action, argument), seconds=seconds)


def watchdog_event(root, event):
    """Private append-only bounded status records, flushed before returning.

    Root must be the caller-created unique evidence directory. No broad device
    logs are stored here. Armed is written by the child, never by its launcher.
    """
    root = Path(root)
    require(matches(r'/tmp/lifeos-probe-run-[A-Za-z0-9_-]+', str(root)) and
            root.is_dir() and not root.is_symlink(), 'watchdog root')
    raw = (json.dumps(event, sort_keys=True) + '\n').encode()
    require(len(raw) <= 2048, 'watchdog event bound')
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW
    with os.fdopen(os.open(root / 'watchdog.jsonl', flags, 0o600), 'ab') as stream:
        require(os.fstat(stream.fileno()).st_size <= 16384 - len(raw), 'watchdog log bound')
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    if event['event'] in ('armed', 'terminal'):
        name = root / ('watchdog-' + event['event'])
        with os.fdopen(os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                               0o600), 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)


ARMED_ACK = b'lifeos-watchdog-armed/v1\n'


def watchdog_ack(fd):
    """Child-only acknowledgement AFTER all armed file/directory fsyncs succeed."""
    require(type(fd) is int and fd >= 3, 'ack descriptor')
    os.set_blocking(fd, False)
    require(os.write(fd, ARMED_ACK) == len(ARMED_ACK), 'incomplete watchdog acknowledgement')


def run_watchdog(root, *, acknowledge, stop=None, sleep=None, emit=None, clock=None):
    """Invoke only inside launch_watchdog's 268+2s supervisor, never inline.

    Relative deadline 240s from entry; pre-arm persistence consumes that budget.
    Both bounded stops precede any deadline logging, even if the first fails.
    Post-stop evidence can stall until the outer supervisor ends this child;
    missing terminal remains inconclusive. No cancellation on controller exit.
    A working host is assumed:
    neither detachment nor a successful force-stop proves subsequent PID absence.
    Parent must wait for terminal and independently check the probe PID is absent.
    """
    stop = stop if stop is not None else lambda: adb_call('stop')
    sleep = sleep if sleep is not None else time.sleep
    emit = emit if emit is not None else lambda event: watchdog_event(root, event)
    clock = clock if clock is not None else time.monotonic
    stop_due = clock() + 240
    statuses, evidence_failed = [], False

    def record(event):
        nonlocal evidence_failed
        try:
            emit(event)
        except Exception:
            # Logging failure must not prevent the deadline's stop attempts.
            evidence_failed = True

    try:
        emit({'event': 'armed', 'stop_after_seconds': 240})
        require(clock() < stop_due, 'arming deadline expired')
        acknowledge()
    except Exception:
        evidence_failed = True  # No acknowledgement on any persistence failure.
    sleep(max(0, stop_due - clock()))
    # No evidence I/O between the deadline and BOTH bounded stop attempts.
    for attempt in (1, 2):
        try:
            stop()
            status = 'command_succeeded_pid_unverified'
        except CommandFailure as error:
            status = error.status
        except Exception:
            status = 'transport_error'
        statuses.append(status)
    for attempt, status in enumerate(statuses, 1):
        record({'event': 'attempt_finished', 'attempt': attempt, 'status': status})
    record({'event': 'terminal', 'attempts': statuses, 'evidence_failed': evidence_failed,
            'status': 'finished_pid_unverified'})
    return statuses


def launch_watchdog(source, root, ack_fd):
    """Detached same-file child under GNU timeout (dispatch added in Unit 2B).

    SIGHUP is ignored across exec; stdin/stdout/stderr never use the SSH pipe.
    Call from the main thread. Do not terminate/wait-cancel the returned process.
    Unit 2B must create a private pipe, pass its write fd here, close the parent's
    write copy after launch and bounded-read EXACTLY ARMED_ACK on the read fd.
    Child dispatch must call watchdog_ack(ack_fd) via run_watchdog's acknowledge,
    closing the child's write fd after that attempt (success or failure).
    Missing/partial/extra acknowledgement or EOF forbids tap; marker existence
    NEVER admits tap (it can be visible before directory fsync succeeds).
    Does not guarantee survival of host failure or a failed container/ADB service.
    """
    require(matches(r'/tmp/lifeos-probe-run-[A-Za-z0-9_-]+', str(root)), 'watchdog root')
    source = Path(source)
    require(source.is_absolute() and source.is_file(), 'same-file source required')
    require(source.resolve() == Path(__file__).resolve(), 'watchdog must use this file')
    require(type(ack_fd) is int and ack_fd >= 3, 'ack descriptor')
    argv = ('timeout', '-k', '2s', '268s', sys.executable, '-B', str(source),
            '--watchdog', str(root), '--ack-fd', str(ack_fd))
    previous = signal.signal(signal.SIGHUP, signal.SIG_IGN)
    try:
        return subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True,
                                pass_fds=(ack_fd,))
    finally:
        signal.signal(signal.SIGHUP, previous)


# UNIT 2A END
# UNIT 2B BEGIN: admission, evidence capture and filename-only dispatch.
import argparse
import tempfile
from datetime import timedelta, timezone

# Allow screenshot inspection/tool round trips, not additional probe/KDF runtime.
# The parent must review the actual image and retain its original capture epoch.
SCREENSHOT_ENTRY_MAX_AGE_SECONDS = 60
SCREENSHOT_TAP_MAX_AGE_SECONDS = 90


def screenshot_fresh(captured_at, max_age):
    """Inclusive age bound; future timestamps are never fresh."""
    return 0 <= time.time() - captured_at <= max_age


def receive_ack(fd, deadline):
    received = bytearray()
    os.set_blocking(fd, False)
    with selectors.DefaultSelector() as selector:
        selector.register(fd, selectors.EVENT_READ)
        while bytes(received) != ARMED_ACK:
            left = deadline - time.monotonic()
            require(left > 0 and selector.select(left), 'watchdog acknowledgement timeout')
            chunk = os.read(fd, len(ARMED_ACK) + 1 - len(received))
            require(bool(chunk), 'short watchdog acknowledgement')
            received.extend(chunk)
            require(ARMED_ACK.startswith(received), 'malformed watchdog acknowledgement')
        # Do not await EOF: GNU timeout may still hold the inherited writer.
        if selector.select(0):
            require(os.read(fd, 1) == b'', 'extra watchdog acknowledgement')


def arm_watchdog(root, deadline):
    reader, writer = os.pipe()
    try:
        try:
            child = launch_watchdog(Path(__file__).resolve(), root, writer)
        finally:
            os.close(writer)
        receive_ack(reader, min(deadline, time.monotonic() + 3))
        return child  # Keep a reference; never kill/cancel this independent child.
    finally:
        os.close(reader)


def device_guards(call, options, receipt):
    require(call('state').strip() == b'device', 'device unavailable')
    package = call('package').decode()
    require(re.search(r'\bversionCode=' + str(receipt['versionCode']) + r'\b', package), 'version mismatch')
    require(call('pwd').strip() == ('/data/user/0/' + PKG).encode(), 'private identity')
    policy = call('keyguard').decode()
    for field in ('showing', 'inputRestricted'):
        require(re.search(r'^\s*' + field + r'=false\s*$', policy, re.M), 'keyguard')
    focus = call('focus').decode()
    require(re.search(r'mCurrentFocus=Window\{[^}\n]* ' + re.escape(PKG) +
                      r'/com\.lifeos\.lifeos\.SecurityProbeActivity\}', focus), 'focus')
    require(call('pid').strip() == options.pid.encode(), 'PID changed')


def run_session(options, receipt, root, save):
    start, wall = time.monotonic(), datetime.now(timezone.utc)
    deadline = start + 240
    window = (wall - timedelta(seconds=2), wall + timedelta(seconds=240))
    call = lambda action, argument=None: adb_call(action, argument, deadline=deadline - 2)
    previous, seen, tick = b'', set(), 0
    outcome = 'inconclusive'

    def inventory():
        return paths(call('inventory').decode().splitlines())

    def capture(path, name):
        try:
            raw = call('read', path)
        except CommandFailure as error:
            save(name, error.output)
            raise
        save(name, raw)
        return raw

    try:
        device_guards(call, options, receipt)
        baseline = inventory()
        discover(baseline, baseline)
        old = {}
        for path in sorted(baseline):
            if persistent(path) and path.count('/') > 1:
                old[path] = capture(path, 'baseline-%03d.bin' % len(old))
        save('baseline.json', json.dumps({'paths': sorted(baseline), 'hashes': {
            path: hashlib.sha256(raw).hexdigest() for path, raw in old.items()}}).encode())
        launched = time.monotonic()
        child = arm_watchdog(root, deadline - 2)
        save('watchdog-launch.json', json.dumps({'pid': child.pid, 'monotonic': launched,
              'latest_finish_monotonic': launched + 270}).encode())
        device_guards(call, options, receipt)  # PID is the last device guard.
        save('tap-issued', b'Tap intent; admission must still be fresh. No retries.\n')
        require(call('pid').strip() == options.pid.encode(), 'PID changed before tap')
        require(screenshot_fresh(options.ready_at, SCREENSHOT_TAP_MAX_AGE_SECONDS) and
                time.monotonic() < min(deadline - 2, launched + 20), 'tap admission expired')
        call('tap', (options.x, options.y))
        while time.monotonic() < deadline - 2 and tick < 240:
            tick += 1
            current = inventory()
            found = discover(baseline, current, seen)
            seen = found['persistent']
            preserve_baseline(old, {path: call('read', path) for path in old})
            journal = {'candidate': receipt['candidate'], 'window': window, 'outcome': 'incomplete'}
            progress = 'files/' + found['progress'] + '/progress.jsonl' if found['progress'] else None
            if progress in current:
                raw = capture(progress, 'progress-%03d.jsonl' % tick)
                journal = parse_journal(raw, receipt['candidate'], found['progress'], window, previous)
                previous = journal['complete']
                save('checkpoint.json', json.dumps({'outcome': journal['outcome'],
                     'records': previous.count(b'\n'), 'snapshot': tick}).encode())
            relative = found['report'] + '/security-probe-results.json' if found['report'] else None
            if relative and 'files/' + relative in current:
                raw = capture('files/' + relative, 'report-%03d.json' % tick)
                try:
                    json.loads(raw)  # A still-being-written JSON snapshot is not a verdict.
                except (json.JSONDecodeError, UnicodeError):
                    pass
                else:
                    verdict = validate_report(raw, receipt['candidate'], relative, window, journal)
                    if verdict == 'complete':
                        outcome = 'complete'
                        return 0
                    if verdict == 'stopped':
                        outcome = 'stopped_not_fully_correlated'
                        return 3
            if journal['outcome'] == 'stopped':
                outcome = 'stopped_journal'
                return 3
            time.sleep(min(1, max(0, deadline - 2 - time.monotonic())))
        return 2
    except (Exception, KeyboardInterrupt) as error:
        save('failure.json', json.dumps({'type': type(error).__name__,
             'reason': str(error)[:256]}).encode())
        return 2
    finally:
        # No watchdog cancellation. Cleanup is probe-only and separately bounded.
        try:
            adb_call('stop')
            cleanup = 'command_succeeded_pid_unverified'
        except Exception:
            cleanup = 'stop_failed_pid_unverified'
        save('controller-terminal.json', json.dumps({'outcome': outcome, 'cleanup': cleanup,
             'limit': 'unique_pair_candidate_time_window_not_cryptographic_binding',
             'parent': 'Wait for watchdog-terminal and independently confirm PID absence.'}).encode())


def parse_options(argv):
    require(len(argv) <= 24 and all(len(v) <= 512 for v in argv), 'argument bounds')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--receipt', required=True)
    parser.add_argument('--receipt-sha256', required=True)
    parser.add_argument('--pid', required=True)
    parser.add_argument('--candidate', required=True)
    parser.add_argument('--ready', required=True, choices=['READY0_ENABLED'])
    parser.add_argument('--ready-at', required=True, type=int,
                        help='Actual reviewed screenshot epoch: at most 60s old at entry, '
                             '90s at tap; future epochs rejected. Runtime deadlines unchanged.')
    parser.add_argument('--x', required=True, type=int)
    parser.add_argument('--y', required=True, type=int)
    options = parser.parse_args(argv)
    candidate_ok(options.candidate)
    require(matches(HEX, options.receipt_sha256) and matches(r'[1-9][0-9]{0,9}', options.pid), 'receipt/PID')
    require(Path(options.receipt).is_absolute(), 'absolute receipt filename required')
    adb_command('tap', (options.x, options.y))  # Validate only; never execute here.
    require(screenshot_fresh(options.ready_at, SCREENSHOT_ENTRY_MAX_AGE_SECONDS),
            'entry attestation expired')
    return options


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    require(len(argv) <= 24 and all(len(v) <= 512 for v in argv), 'argument bounds')
    if argv and argv[0] == '--watchdog':
        require(len(argv) == 4 and argv[2] == '--ack-fd' and
                matches(r'/tmp/lifeos-probe-run-[A-Za-z0-9_-]+', argv[1]) and
                matches(r'[0-9]{1,6}', argv[3]), 'watchdog dispatch parameters')
        fd = int(argv[3])
        require(fd >= 3, 'ack descriptor')
        writer_open = True
        def acknowledge():
            nonlocal writer_open
            try:
                watchdog_ack(fd)
            finally:
                writer_open = False
                os.close(fd)
        try:
            run_watchdog(argv[1], acknowledge=acknowledge)
        finally:
            if writer_open:
                os.close(fd)
        return 0
    options = parse_options(argv)
    with open(options.receipt, 'rb') as stream:
        raw = stream.read(65537)
    receipt = parse_receipt(raw, options.receipt_sha256)
    require(receipt['candidate'] == options.candidate, 'attested candidate mismatch')
    os.umask(0o077)
    root = Path(tempfile.mkdtemp(prefix='lifeos-probe-run-', dir='/tmp'))
    def save(name, data):
        bounded(data)
        (root / name).write_bytes(data)
    # SIGHUP ignored before launching any child; output never controls cleanup.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    def interrupted(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        save('receipt.json', raw)
        save('metadata.json', json.dumps(vars(options)).encode())
    except Exception:
        adb_call('stop')
        return 2
    try:
        print('Evidence:', root, flush=True)
        print('Correlation is not cryptographic APK proof; external audit remains required.', flush=True)
    except (BrokenPipeError, OSError):
        pass
    return run_session(options, receipt, root, save)


# UNIT 2B END
if __name__ == '__main__':
    raise SystemExit(main())
