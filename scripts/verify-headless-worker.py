#!/usr/bin/env python3
"""Exercise signed QA workers through the real executable entry, without UI/data access."""
import argparse
import json
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--bundle', required=True)
parser.add_argument('--report', required=True)
args = parser.parse_args()
bundle = Path(args.bundle).resolve()
info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
identifier = info['CFBundleIdentifier']
if not identifier.startswith('com.yuan.personal-assistant.qa.headless'):
    raise SystemExit('Refusing to run isolated verification against a production bundle')
root = Path(tempfile.gettempdir()) / ('YuanPersonalAssistant-QA-' + identifier)
root.mkdir(parents=True, exist_ok=True)
(root / 'background-daily-plan-settings.json').write_text('{"enabled":true}')
exe = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
env = dict(os.environ, YUAN_BACKGROUND_QA_GENERATOR='1', YUAN_HEADLESS_QA_HOLD_SECONDS='2')
protected_names = ('conversation.json', 'personal-todos.json', 'skill-runs.json', 'dingtalk-event-state.json')
def fingerprints():
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() if (root / name).exists() else None for name in protected_names}
before_files = fingerprints()
checks = []
for role in ('daily-plan', 'daily-plan', 'dingtalk-events'):
    result = subprocess.run([str(exe), '--daily-plan-worker' if role == 'daily-plan' else '--dingtalk-event-worker'], env=env, capture_output=True, timeout=60)
    diagnostic = json.loads((root / ('worker-' + role + '-diagnostic.json')).read_text())
    passed = result.returncode == 0 and diagnostic['windowCountAtStart'] == 0 and diagnostic['windowCountAtFinish'] == 0 and diagnostic['activationPolicy'] == 2 and diagnostic.get('finishedAt') is not None
    if role == 'dingtalk-events':
        passed = passed and diagnostic['outcome'] == 'not-registered'
    checks.append({'role': role, 'exitCode': result.returncode, 'passed': passed, 'diagnostic': diagnostic})
# Worker routing must not instantiate AssistantModel or create a conversation.
untouched = before_files == fingerprints()
state = json.loads((root / 'background-daily-plan.json').read_text()) if (root / 'background-daily-plan.json').exists() else {}
report = {'passed': all(c['passed'] for c in checks) and untouched, 'checks': checks, 'noForegroundModelFilesChanged': untouched, 'qaPlanStatus': state.get('status'), 'realSubscriptionsCreated': 0, 'realNotificationsSubmitted': 0}
Path(args.report).write_text(json.dumps(report, indent=2))
print(json.dumps({'passed': report['passed'], 'checks': len(checks), 'qaPlanStatus': report['qaPlanStatus']}, ensure_ascii=False))
raise SystemExit(0 if report['passed'] else 1)
