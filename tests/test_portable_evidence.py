import importlib.util
import json
from pathlib import Path
import unittest

source = Path(__file__).resolve().parents[1] / 'tools/gameft-sw-analysis/portable_evidence.py'
spec = importlib.util.spec_from_file_location('portable_evidence', source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PortableEvidenceTests(unittest.TestCase):
    def test_preserves_values_and_nested_envelopes(self):
        root = 'X' + chr(58) + '/fixture'
        normalizer = module.PortableEvidence({root: '${SOURCE_ROOT}'})
        original = {'path': root + '/run.json', 'zero': 0, 'false': False, 'null': None, 'empty': [],
                    'rawResult': json.dumps({'path': root.replace('/', '\\') + '\\run.json'})}
        result = normalizer.value(original)
        self.assertEqual(result['path'], '${SOURCE_ROOT}/run.json')
        self.assertEqual(json.loads(result['rawResult'])['path'], '${SOURCE_ROOT}\\run.json')
        for key in ('zero', 'false', 'null', 'empty'):
            self.assertEqual(result[key], original[key])
        self.assertEqual(original['path'], root + '/run.json')

    def test_unknown_roots_use_only_local_mapping(self):
        path = 'Y' + chr(58) + '/private/run.bin'
        normalizer = module.PortableEvidence({})
        label = normalizer.text(path)
        self.assertTrue(label.startswith('${LOCAL_PATH_'))
        self.assertEqual(normalizer.local_mapping[label], path)
        self.assertEqual(normalizer.text('https://example.org/reference'), 'https://example.org/reference')


if __name__ == '__main__':
    unittest.main()
