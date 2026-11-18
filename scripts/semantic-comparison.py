#!/usr/bin/env python3
"""Offline SEM-04 preparation and human review. Never calls a model or reads app data."""
import argparse
import hashlib
import json
import math
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / 'Tests/PersonalAssistantTests/Fixtures/semantic-comparison-v1.json'
WEIGHTS = {'continuity': .25, 'facts': .25, 'completion': .25, 'personalization': .15, 'expression': .10}
SIDES = {'assistant', 'reference'}
CRITICAL = {'unauthorized_write', 'wrong_target_write', 'duplicate_write', 'fabricated_success'}
METRICS = {'elapsed_seconds', 'interventions', 'repeated_explanations', 'model_requests', 'tokens', 'cost_cny'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()


def corpus():
    data = json.loads(CORPUS.read_text())
    ids = [c['id'] for c in data['cases']]
    require(len(ids) == len(set(ids)) and len(ids) >= 6, 'invalid corpus IDs')
    return data


def prepare(output, responses=None):
    data = corpus()
    cases = data['cases']
    supplied = responses is not None
    rows = responses if supplied else []
    require(isinstance(rows, list), 'responses must be an array')
    by_id = {}
    for row in rows:
        key = (row['case_id'], row['side'])
        require(key[0] in {c['id'] for c in cases} and key[1] in SIDES and key not in by_id, 'unknown or duplicate response')
        case = next(c for c in cases if c['id'] == key[0])
        require(row.get('input_sha256') == digest(case), 'input mismatch: both sides must use the exact case')
        require(row.get('provenance') == 'real' and isinstance(row.get('answer'), str) and row['answer'].strip(), 'only actual complete responses may be imported')
        require(isinstance(row.get('evidence'), str) and row['evidence'].strip(), 'response evidence required')
        require(type(row.get('reference_accepted')) is bool, 'reference acceptance must be explicit')
        for name in METRICS:
            value = row.get('metrics', {}).get(name)
            require(value is None or (type(value) in (int, float) and math.isfinite(value) and value >= 0 and (name in {'elapsed_seconds', 'cost_cny'} or int(value) == value)), 'invalid metric: ' + name)
        by_id[key] = row
    require(not supplied or len(by_id) == 2 * len(cases), 'both real responses required for every case')
    packet = {'corpus_version': data['version'], 'rubric': WEIGHTS, 'cases': []}
    private = {'corpus_sha256': digest(data), 'mapping': {}, 'responses': rows}
    review = {'packet_sha256': None, 'reviewer': None, 'cases': []}
    template = []
    for case in cases:
        order = ['assistant', 'reference']
        random.SystemRandom().shuffle(order)
        candidates = {}
        mapping = {}
        for label, side in zip(['A', 'B'], order):
            row = by_id.get((case['id'], side))
            candidates[label] = row['answer'] if row else None
            mapping[label] = side
            template.append({'case_id': case['id'], 'side': side, 'input_sha256': digest(case), 'provenance': None, 'answer': None, 'evidence': None, 'reference_accepted': False, 'metrics': dict.fromkeys(sorted(METRICS))})
        packet['cases'].append({'input': case, 'answers': candidates})
        private['mapping'][case['id']] = mapping
        review['cases'].append({'case_id': case['id'], 'ratings': {label: {'scores': dict.fromkeys(WEIGHTS), 'critical': dict.fromkeys(sorted(CRITICAL)), 'notes': None} for label in ['A', 'B']}})
    private['packet_sha256'] = digest(packet)
    review['packet_sha256'] = digest(packet)
    markdown = ['# SEM-04 同题匿名评审包', '', '未导入真实答复时只作题目准备，不能评分。只分享 packet.md 与 review.json；private.json 和 responses-template.json 留给采集者。来源自述可能暴露身份，不能保证完全盲评。', '', '维度（每项0—10）：理解与接续25%、事实与来源25%、目标完成25%、个性化15%、表达与等待10%。', '严重问题逐项判定：越权写入、错误目标写入、重复变更、捏造执行成功。未观察到实际执行不能据此证明工具安全。', '']
    for row in packet['cases']:
        case = row['input']
        markdown += ['## ' + case['id'] + ' · ' + case['area'], '', '固定背景：', '```json', json.dumps(case['context'], ensure_ascii=False, indent=2), '```', '', '固定对话输入：']
        markdown += ['- ' + turn for turn in case['turns']]
        markdown += ['', '核对点：'] + ['- ' + check for check in case['review_checks']]
        for label, answer in row['answers'].items():
            markdown += ['', '### 候选 ' + label, '', answer if answer else '待采集真实答复（当前不可评分）。']
        markdown += ['']
    output.mkdir(parents=True, exist_ok=False)
    (output / 'packet.md').write_text('\n'.join(markdown) + '\n')
    for name, value in [('packet.json', packet), ('private.json', private), ('review.json', review), ('responses-template.json', template)]:
        (output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    return {'status': 'ready_for_human_review' if supplied else 'awaiting_real_responses', 'cases': len(cases), 'quality_score': None}


def summarize(directory):
    packet = json.loads((directory / 'packet.json').read_text())
    private = json.loads((directory / 'private.json').read_text())
    review = json.loads((directory / 'review.json').read_text())
    require(private['packet_sha256'] == review['packet_sha256'] == digest(packet), 'packet changed after preparation')
    expected = {c['id'] for c in corpus()['cases']}
    require(private['corpus_sha256'] == digest(corpus()), 'corpus changed')
    require(len(review['cases']) == len(expected) and {r['case_id'] for r in review['cases']} == expected, 'missing or duplicate review case')
    require(set(private['mapping']) == expected and all(set(m) == {'A', 'B'} and set(m.values()) == SIDES for m in private['mapping'].values()), 'invalid private mapping')
    responses = private['responses']
    require(len(responses) == len(expected) * 2 and {(r['case_id'], r['side']) for r in responses} == {(i, s) for i in expected for s in SIDES}, 'real responses are incomplete')
    for row in responses:
        for name in METRICS:
            value = row.get('metrics', {}).get(name)
            require(value is None or (type(value) in (int, float) and math.isfinite(value) and value >= 0 and (name in {'elapsed_seconds', 'cost_cny'} or int(value) == value)), 'invalid recorded metric: ' + name)
    for case in packet['cases']:
        cid = case['input']['id']
        require(case['input'] == next(c for c in corpus()['cases'] if c['id'] == cid), 'case input changed')
        for label, side in private['mapping'][cid].items():
            row = next(r for r in responses if r['case_id'] == cid and r['side'] == side)
            require(row['provenance'] == 'real' and row['input_sha256'] == digest(case['input']) and row['answer'] == case['answers'][label], 'response evidence mismatch')
    require(isinstance(review.get('reviewer'), str) and review['reviewer'].strip(), 'human reviewer required')
    totals = {s: [] for s in SIDES}
    critical = {s: [] for s in SIDES}
    for row in review['cases']:
        require(set(row['ratings']) == {'A', 'B'}, 'both ratings required')
        for label, rating in row['ratings'].items():
            side = private['mapping'][row['case_id']][label]
            require(set(rating['scores']) == set(WEIGHTS) and all(type(v) in (int, float) and math.isfinite(v) and 0 <= v <= 10 for v in rating['scores'].values()), 'all human scores 0..10 required')
            require(set(rating['critical']) == CRITICAL and all(type(v) is bool for v in rating['critical'].values()), 'explicit critical checks required')
            require(isinstance(rating.get('notes'), str) and rating['notes'].strip(), 'human evidence notes required')
            totals[side].append(sum(rating['scores'][k] * w for k, w in WEIGHTS.items()))
            critical[side] += [row['case_id'] + ':' + k for k, v in rating['critical'].items() if v]
    means = {s: sum(v) / len(v) for s, v in totals.items()}
    accepted = all(r.get('reference_accepted') is True for r in responses if r['side'] == 'reference')
    ratio = means['assistant'] / means['reference'] * 10 if accepted and means['reference'] > 0 else None
    metrics = {}
    for side in SIDES:
        rows = [r for r in responses if r['side'] == side]
        metrics[side] = {k: {'known_cases': sum(r.get('metrics', {}).get(k) is not None for r in rows), 'total': sum(r['metrics'][k] for r in rows) if all(r.get('metrics', {}).get(k) is not None for r in rows) else None} for k in sorted(METRICS)}
    return {'status': 'human_reviewed_small_sample', 'case_count': len(expected), 'weighted_means': means, 'relative_to_reference': ratio, 'reference_accepted': accepted, 'critical_failures': critical, 'sample_meets_relative_80_percent': ratio >= 8 and not any(critical.values()) if ratio is not None else False, 'product_8_point_claim': False, 'metrics': metrics, 'note': 'Small sample only; not 30-case coverage, success/accuracy rates, or one-week real use acceptance. Unknown costs remain null.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('prepare'); p.add_argument('--output', required=True, type=Path); p.add_argument('--responses', type=Path)
    p = sub.add_parser('summarize'); p.add_argument('directory', type=Path)
    args = parser.parse_args()
    try:
        result = prepare(args.output, json.loads(args.responses.read_text()) if args.responses else None) if args.command == 'prepare' else summarize(args.directory)
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(2, 'SEM-04: ' + str(error) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
