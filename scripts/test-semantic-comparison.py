#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('comparison', Path(__file__).with_name('semantic-comparison.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'packet'

    def responses(self):
        return [{'case_id': c['id'], 'side': side, 'input_sha256': m.digest(c), 'provenance': 'real', 'answer': side + ' test fixture answer', 'evidence': 'unit-test-fixture only', 'reference_accepted': True, 'metrics': dict.fromkeys(m.METRICS)} for c in m.corpus()['cases'] for side in sorted(m.SIDES)]

    def rate(self, assistant=8, reference=10):
        review = json.loads((self.path / 'review.json').read_text())
        private = json.loads((self.path / 'private.json').read_text())
        review['reviewer'] = 'UNIT TEST ONLY'
        for row in review['cases']:
            for label, rating in row['ratings'].items():
                value = assistant if private['mapping'][row['case_id']][label] == 'assistant' else reference
                rating.update(scores=dict.fromkeys(m.WEIGHTS, value), critical=dict.fromkeys(m.CRITICAL, False), notes='unit fixture evidence')
        (self.path / 'review.json').write_text(json.dumps(review))
        return review, private

    def test_empty_packet_never_produces_score(self):
        self.assertEqual(m.prepare(self.path)['quality_score'], None)
        with self.assertRaisesRegex(ValueError, 'incomplete'): m.summarize(self.path)

    def test_simulated_incomplete_and_mismatched_inputs_rejected(self):
        for change in ['simulation', 'missing', 'input', 'duplicate']:
            rows = self.responses()
            if change == 'simulation': rows[0]['provenance'] = 'simulated'
            elif change == 'missing': rows.pop()
            elif change == 'input': rows[0]['input_sha256'] = 'different'
            else: rows[-1] = rows[0]
            with self.assertRaises(ValueError): m.prepare(self.path, rows)

    def test_blind_packet_excludes_provenance_and_metrics(self):
        m.prepare(self.path, self.responses())
        packet = json.loads((self.path / 'packet.json').read_text())
        self.assertEqual(set(packet['cases'][0]['answers']), {'A', 'B'})
        self.assertNotIn('evidence', packet['cases'][0])
        self.assertNotIn('metrics', packet['cases'][0])
        with self.assertRaises(FileExistsError): m.prepare(self.path, self.responses())

    def test_complete_ratings_small_sample_and_unknown_costs(self):
        m.prepare(self.path, self.responses()); self.rate()
        summary = m.summarize(self.path)
        self.assertAlmostEqual(summary['relative_to_reference'], 8)
        self.assertTrue(summary['sample_meets_relative_80_percent'])
        self.assertFalse(summary['product_8_point_claim'])
        self.assertIsNone(summary['metrics']['assistant']['cost_cny']['total'])
        self.assertEqual(summary['metrics']['assistant']['cost_cny']['known_cases'], 0)

    def test_safety_failure_cannot_be_offset_by_high_score(self):
        m.prepare(self.path, self.responses()); review, private = self.rate(10, 10)
        label = next(k for k,v in private['mapping'][review['cases'][0]['case_id']].items() if v == 'assistant')
        review['cases'][0]['ratings'][label]['critical']['wrong_target_write'] = True
        (self.path / 'review.json').write_text(json.dumps(review))
        self.assertFalse(m.summarize(self.path)['sample_meets_relative_80_percent'])

    def test_no_reference_endorsement_or_zero_baseline_no_relative_score(self):
        rows = self.responses(); rows[0]['reference_accepted'] = False; rows[1]['reference_accepted'] = False
        m.prepare(self.path, rows); self.rate()
        self.assertIsNone(m.summarize(self.path)['relative_to_reference'])
        self.rate(reference=0)
        self.assertIsNone(m.summarize(self.path)['relative_to_reference'])

    def test_missing_human_scores_or_critical_checks_rejected(self):
        m.prepare(self.path, self.responses())
        for change in ['score', 'critical', 'duplicate', 'notes']:
            review, _ = self.rate()
            if change == 'score': review['cases'][0]['ratings']['A']['scores']['facts'] = None
            elif change == 'critical': review['cases'][0]['ratings']['A']['critical']['wrong_target_write'] = None
            elif change == 'notes': review['cases'][0]['ratings']['A']['notes'] = ''
            else: review['cases'][-1] = review['cases'][0]
            (self.path / 'review.json').write_text(json.dumps(review))
            with self.assertRaises(ValueError): m.summarize(self.path)

    def test_packet_change_and_invalid_cost_rejected(self):
        rows = self.responses(); rows[0]['metrics']['tokens'] = -1
        with self.assertRaises(ValueError): m.prepare(self.path, rows)
        m.prepare(self.path, self.responses()); self.rate()
        packet = json.loads((self.path / 'packet.json').read_text()); packet['cases'][0]['answers']['A'] += 'changed'
        (self.path / 'packet.json').write_text(json.dumps(packet))
        with self.assertRaisesRegex(ValueError, 'packet changed'): m.summarize(self.path)


if __name__ == '__main__': unittest.main()
