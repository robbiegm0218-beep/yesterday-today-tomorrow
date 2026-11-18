#!/usr/bin/env python3
"""One explicitly approved 45-second @me connection; never sends messages.

Set YUAN_EVENT_LIVE_APPROVED=ONE_BOUNDED_AT_ME_CONNECTION only after the
human approves this exact profile and cleanup scope. Never retries creation.
"""
import argparse
import json
import os
import re
import selectors
import subprocess
import sys
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', required=True)
    parser.add_argument('--report', required=True)
    args = parser.parse_args()
    if os.environ.get('YUAN_EVENT_LIVE_APPROVED') != 'ONE_BOUNDED_AT_ME_CONNECTION':
        parser.error('One bounded @me connection and cleanup require fresh human approval.')
    dws = '/usr/local/bin/dws'
    def status():
        p = subprocess.run([dws, 'event', 'status', '--profile', args.profile, '--format', 'json'], capture_output=True, timeout=40)
        r = json.loads(p.stdout)
        if p.returncode != 0 or not isinstance(r.get('subscriptions'), list):
            raise RuntimeError('Cannot verify subscription status; no creation retry allowed.')
        return r
    def contains(value, wanted):
        if isinstance(value, str):
            return value == wanted
        if isinstance(value, dict):
            return any(contains(v, wanted) for v in value.values())
        if isinstance(value, list):
            return any(contains(v, wanted) for v in value)
        return False
    before = status()
    parts = args.profile.split(':')
    identity = before.get('identity', {})
    if len(parts) != 2 or identity.get('corp_id') != parts[0] or str(identity.get('user_id')) != parts[1]:
        raise RuntimeError('Event identity does not match the approved organization/account; zero subscription creation.')
    report = {'ready': False, 'subscriptionID': None, 'events': 0, 'invalidLines': 0,
              'cleaned': False, 'messages_sent': 0, 'notifications_sent': 0}
    p = subprocess.Popen([dws, 'event', '+listen-im', '--kind', 'at-me', '--events', 'message',
                          '--duration', '45s', '--profile', args.profile, '--format', 'ndjson'],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.PIPE, bufsize=0)
    sel = selectors.DefaultSelector()
    sel.register(p.stdout, selectors.EVENT_READ, 'out'); sel.register(p.stderr, selectors.EVENT_READ, 'err')
    pending = {'out': b'', 'err': b''}; deadline = time.monotonic() + 90
    try:
        while sel.get_map() and time.monotonic() < deadline:
            for key, _ in sel.select(1):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    sel.unregister(key.fileobj); continue
                pending[key.data] += chunk
                if len(pending[key.data]) > 1048576:
                    raise RuntimeError('Bounded live stream exceeded capture budget.')
                while b'\n' in pending[key.data]:
                    line, pending[key.data] = pending[key.data].split(b'\n', 1)
                    if key.data == 'err':
                        match = re.match(rb'\[event\] ready event_key=user_im_message_receive_at .*subscribe_id=([^\s]+)', line)
                        if match:
                            report['ready'] = True; report['subscriptionID'] = match[1].decode()
                    elif line.strip():
                        try:
                            item = json.loads(line)
                            valid = report['ready'] and item.get('subscribe_id') == report['subscriptionID'] and item.get('type') == 'user_im_message_receive_at' and item.get('message_id') and item.get('conversation_id')
                            report['events' if valid else 'invalidLines'] += 1
                        except Exception:
                            report['invalidLines'] += 1
        if p.poll() is None:
            p.stdin.close(); p.terminate()
        try:
            report['exitCode'] = p.wait(timeout=20)
        except subprocess.TimeoutExpired:
            report['stillRunningPID'] = p.pid
            raise RuntimeError('Consumer did not exit cleanly; exact subscription needs reconciliation, no new connection allowed.')
        after = status()
        sid = report['subscriptionID']
        report['new_id_not_preexisting'] = bool(sid) and not contains(before, sid)
        report['cleaned'] = bool(sid) and not contains(after, sid)
        report['passed'] = report['ready'] and report['new_id_not_preexisting'] and report['cleaned'] and report['exitCode'] == 0
    except Exception as issue:
        report['error'] = str(issue)
        if p.poll() is None:
            try: p.stdin.close()
            except Exception: pass
            p.terminate()
            try: p.wait(timeout=20)
            except subprocess.TimeoutExpired: report['stillRunningPID'] = p.pid
        report['passed'] = False
    finally:
        sel.close()
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['passed'] else 1

if __name__ == '__main__':
    sys.exit(main())
