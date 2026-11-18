#!/usr/bin/env python3
"""Validate the synthetic evaluation corpus; summarize separately recorded results.
Does not invoke a model, alter assistant data, or infer quality from test counts.
"""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', type=Path, help='JSON array of case_id, outcome and evidence')
    args = parser.parse_args()
    corpus = json.loads((ROOT / 'Tests/PersonalAssistantTests/Fixtures/intelligence-baseline-v1.json').read_text())
    cases = corpus['cases']
    assert len(cases) >= 30 and len({c['id'] for c in cases}) == len(cases)
    assert all(len(c['turns']) >= 3 and c['expected'] and c['fixture'] for c in cases)
    results = json.loads(args.results.read_text()) if args.results else []
    known = {c['id'] for c in cases}
    assert len({r['case_id'] for r in results}) == len(results), 'duplicate result'
    assert all(r['case_id'] in known and r['outcome'] in ('pass', 'fail', 'blocked') and r.get('evidence') for r in results)
    counts = {status: sum(r['outcome'] == status for r in results) for status in ('pass', 'fail', 'blocked')}
    print(json.dumps({'corpus_version': corpus['version'], 'case_count': len(cases), 'recorded_results': len(results),
                      'unmeasured': len(cases) - len(results), 'outcomes': counts,
                      'quality_score': None, 'note': 'Corpus validation does not establish assistant quality or an 8/10 score.'}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
