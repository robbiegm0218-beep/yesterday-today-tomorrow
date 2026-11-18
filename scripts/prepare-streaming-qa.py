#!/usr/bin/env python3
"""Prepare an owned, opted-in QA bundle with synthetic data. Does not launch it."""
import argparse
import json
import plistlib
import subprocess
import tempfile
import uuid
from pathlib import Path

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app', required=True, type=Path)
p.add_argument('--output', required=True, type=Path)
a = p.parse_args()
assert not a.output.exists(), 'Refusing to replace an existing QA app'
info = plistlib.loads((a.app / 'Contents/Info.plist').read_bytes())
identifier = 'com.yuan.personal-assistant.qa.localstream' + uuid.uuid4().hex[:10]
subprocess.check_call(['/usr/bin/ditto', str(a.app), str(a.output)])
info.update(CFBundleIdentifier=identifier, CFBundleName='助手本地流式验收', CFBundleDisplayName='助手本地流式验收', AssistantLocalStreamingQA=True)
(a.output / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
identity = json.loads((root / 'Resources/Signing.local.json').read_text())['identity']
subprocess.check_call(['/usr/bin/codesign', '--force', '--deep', '--sign', identity, str(a.output)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.check_call(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(a.output)])
directory = Path(tempfile.gettempdir()) / ('YuanPersonalAssistant-QA-' + identifier)
directory.mkdir(exist_ok=False)
messages = [{'id': str(uuid.uuid4()), 'text': f'本地合成历史{i+1}：' + ('评审准备问题' if i % 2 == 0 else '材料已列出，仅用于UI验收，不含真实资料。'), 'isUser': i % 2 == 0, 'time': 816579000 + i} for i in range(500)]
(directory / 'conversation.json').write_text(json.dumps(messages, ensure_ascii=False))
for name in ['personal-todos.json', 'projects.json', 'memories.json', 'assistant-runs.json', 'knowledge-bases.json']:
    (directory / name).write_text('[]')
for key, value in [('autoMemoryEnabled', False), ('profileSetupComplete', True)]:
    subprocess.check_call(['/usr/bin/defaults', 'write', identifier, key, '-bool', str(value).lower()])
subprocess.check_call(['/usr/bin/defaults', 'write', identifier, 'dingTalkSelectedProfiles', '-array'])
report = {'app': str(a.output.resolve()), 'bundleID': identifier, 'data': str(directory), 'build': info['CFBundleVersion'], 'syntheticMessages': 500, 'optIn': True}
(a.output.parent / (a.output.stem + '-preparation.json')).write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(report, ensure_ascii=False))
