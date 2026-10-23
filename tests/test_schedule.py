import copy
import unittest
from collections import Counter
from pathlib import Path
import sys
import json
import hashlib
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from schedule_core import ROOT, CONFIG_DIR, build_schedule, load_inputs, workbook_specs


class ScheduleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config, cls.groups = load_inputs(CONFIG_DIR/'stimulus_catalog.csv', CONFIG_DIR/'experiment_design.json')
        cls.visual = build_schedule('visual', cls.config, cls.groups)
        cls.tactile = build_schedule('tactile', cls.config, cls.groups)

    def test_counts_identity_and_exact_repetitions(self):
        for schedule in [self.visual, self.tactile]:
            self.assertEqual(len(schedule['runs']), 36)
            self.assertEqual(len(schedule['trials']), 1188)
            self.assertEqual(len(schedule['stimuli']), 360)
            repetitions = Counter(t['stimulus_number'] for t in schedule['trials'] if not t['nback_target'])
            self.assertEqual(set(repetitions.values()), {3})
            self.assertEqual(set(repetitions), {s*100+i for s in range(1,7) for i in range(1,61)})
            self.assertEqual(schedule['parameters']['n_sessions'], 9)
            for session in range(1,10):
                self.assertEqual(sum(r['session'] == session for r in schedule['runs']), 4)

    def test_targets_timing_and_no_cross_session_objects(self):
        target_objects = []
        for run in self.visual['runs']:
            rows = [t for t in self.visual['trials'] if t['run'] == run['run']]
            self.assertEqual(len(rows), 33)
            self.assertEqual(sum(t['nback_target'] for t in rows), 3)
            self.assertEqual(sum(t['iti_s'] for t in rows), 132)
            self.assertEqual(run['duration_s'], 540)
            positions = [t['trial'] for t in rows if t['nback_target']]
            self.assertTrue(all(b-a >= 8 for a,b in zip(positions, positions[1:])))
            for i, trial in enumerate(rows):
                same = i > 0 and trial['stimulus_number'] == rows[i-1]['stimulus_number']
                self.assertEqual(bool(trial['nback_target']), same)
                self.assertEqual(trial['correct_response'], 'yes' if same else 'no')
                self.assertEqual(trial['stimulus_number']//100, run['stimulus_session'])
                if same:
                    target_objects.append(trial['stimulus_number'])
        self.assertEqual(len(set(target_objects)), len(target_objects))

    def test_order_and_modality_pairing(self):
        expected = [list(range(101,131)), list(range(131,161)),
                    list(range(130,100,-1)), list(range(160,130,-1)),
                    [101+r*6+c for c in range(6) for r in range(5)],
                    [131+r*6+c for c in range(6) for r in range(5)]]
        for run, order in enumerate(expected, 1):
            self.assertEqual([t['stimulus_number'] for t in self.visual['trials'] if t['run']==run and not t['nback_target']], order)
        for a,b in zip(self.visual['trials'], self.tactile['trials']):
            self.assertEqual({k:v for k,v in a.items() if k!='video_filename'}, b)
            self.assertEqual(a['video_filename'], '')
            self.assertNotIn('video_filename', b)
        self.assertEqual(self.visual, build_schedule('visual', self.config, self.groups))

    def test_add_session_and_plate(self):
        groups = copy.deepcopy(self.groups)
        groups[7] = [dict(x, session=7, stimulus_number=700+i,
            object_name='', video_filename='')
            for i,x in enumerate(groups[1],1)]
        extra = build_schedule('visual', self.config, groups)
        self.assertEqual(len(extra['runs']), 42)
        self.assertEqual(len(extra['trials']), 1386)
        groups = copy.deepcopy(self.groups)
        groups[1] += [dict(x, stimulus_number=160+i,
            object_name='', video_filename='')
            for i,x in enumerate(groups[1][:30],1)]
        extra = build_schedule('tactile', self.config, groups)
        self.assertEqual(sum(r['stimulus_session']==1 for r in extra['runs']), 9)
        self.assertEqual(len(extra['runs']), 39)

    def test_impossible_targets_fail_without_silent_relaxation(self):
        config = copy.deepcopy(self.config)
        config['min_nback_target_gap'] = 100
        with self.assertRaisesRegex(ValueError, '1-back'):
            build_schedule('visual', config, self.groups)

    def test_no_duplicate_object_fields_in_execution_tables(self):
        removed = {'stimulus_id','object_id','stimulus_order_number','stimulus_name','object_filename','stim_file'}
        for task, schedule in [('visual', self.visual), ('tactile', self.tactile)]:
            specs, _ = workbook_specs(schedule, task, self.config)
            for sheet in specs:
                if sheet['name'] in {'Trials','Stimuli'}:
                    self.assertFalse(removed.intersection(sheet['rows'][0]))
            self.assertEqual(len(next(s for s in specs if s['name']=='Trials')['rows'][0]), 17 if task=='visual' else 16)

    def test_simplification_preserves_original_execution_order(self):
        for schedule in [self.visual, self.tactile]:
            # Reconstruct the old source-group session labels for the frozen
            # pre-regrouping checksum; all actual stimulus/target/ITI rows stay.
            rows = [[t['stimulus_session'], (t['run']-1)%6+1, t['run'],t['trial'],
                     t['stimulus_number'],t['nback_target'],t['iti_s']] for t in schedule['trials']]
            checksum = hashlib.sha256(json.dumps(rows,separators=(',',':')).encode()).hexdigest()
            self.assertEqual(checksum, '7fb1634914d2d1c642ef6b49ca16ab3043c397ef1795ec03556e8c343d783a9f')

    def test_catalog_requires_only_number_and_supports_custom_video(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'tests') as folder:
            catalog = Path(folder)/'objects.csv'
            catalog.write_text('stimulus_number\n'+'\n'.join(str(i) for i in range(101,131)), encoding='utf-8')
            config, groups = load_inputs(catalog, CONFIG_DIR/'experiment_design.json')
            self.assertEqual(groups[1][0]['video_filename'], '')
            self.assertEqual(groups[1][0]['object_name'], '')
            catalog.write_text('stimulus_number,object_name,video_filename\n'+
                '\n'.join(f'{i},'+('球体,custom.mp4' if i==101 else ',') for i in range(101,131)), encoding='utf-8')
            config, groups = load_inputs(catalog, CONFIG_DIR/'experiment_design.json')
            schedule = build_schedule('visual', config, groups)
            self.assertEqual(schedule['trials'][0]['video_filename'], 'custom.mp4')
            self.assertEqual(schedule['stimuli'][0]['object_name'], '球体')


class TestDatasetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config, cls.groups = load_inputs(CONFIG_DIR/'stimulus_catalog_test.csv', CONFIG_DIR/'experiment_design_test.json')
        cls.visual = build_schedule('visual', cls.config, cls.groups)
        cls.tactile = build_schedule('tactile', cls.config, cls.groups)
        train_config, train_groups = load_inputs(CONFIG_DIR/'stimulus_catalog.csv', CONFIG_DIR/'experiment_design.json')
        cls.train_visual = build_schedule('visual', train_config, train_groups)

    def test_three_acquisition_sessions_and_four_repetitions(self):
        for schedule in [self.visual,self.tactile]:
            p = schedule['parameters']
            self.assertEqual((p['n_objects'],p['n_sessions'],p['n_runs'],p['n_base_trials'],p['n_total_trials']), (90,3,12,360,396))
            self.assertEqual([sum(r['session']==s for r in schedule['runs']) for s in range(1,4)], [4,4,4])
            reps = Counter(t['stimulus_number'] for t in schedule['trials'] if not t['nback_target'])
            self.assertEqual(set(reps),set(range(1,91)))
            self.assertEqual(set(reps.values()),{4})
            for session in range(1,4):
                rows = [t for t in schedule['trials'] if t['stimulus_session']==session]
                self.assertEqual(len(rows),132)
                self.assertEqual(sum(not t['nback_target'] for t in rows),120)
                self.assertEqual({t['stimulus_number'] for t in rows},set(range((session-1)*30+1,session*30+1)))

    def test_test_targets_order_and_padding(self):
        for run in self.visual['runs']:
            rows = [t for t in self.visual['trials'] if t['run']==run['run']]
            self.assertEqual(len(rows),33)
            self.assertEqual(sum(t['nback_target'] for t in rows),3)
            for i,row in enumerate(rows):
                same = i>0 and rows[i-1]['stimulus_number']==row['stimulus_number']
                self.assertEqual(same,bool(row['nback_target']))
        specs, printable = workbook_specs(self.visual,'visual',self.config)
        self.assertEqual(printable[0]['rows'][1][1],'001')
        self.assertEqual(printable[1]['rows'][1][1],'031')
        self.assertEqual(printable[2]['rows'][1][1],'061')
        self.assertEqual(len(printable[-1]['rows'][0]),5)
        self.assertEqual(self.visual['parameters']['video_root'],'../video/test')
        self.assertEqual(self.config['numbering_scheme'],'sequential')

    def test_test_pairing_and_session_video_paths(self):
        for a,b in zip(self.visual['trials'],self.tactile['trials']):
            self.assertEqual({k:v for k,v in a.items() if k!='video_filename'}, b)
        for dataset, schedule in [('test',self.visual), ('train',self.train_visual)]:
            for trial in schedule['trials']:
                name = trial['video_filename'] or f"{trial['stimulus_number']:03d}.mp4"
                path = ROOT/f"video/{dataset}/session{trial['stimulus_session']:02d}"/name
                self.assertEqual(path.relative_to(ROOT).parts[:3],('video',dataset,f"session{trial['stimulus_session']:02d}"))

    def test_regroup_preserves_every_run_and_media_path(self):
        for dataset in ['train','test']:
            suffix='' if dataset=='train' else '_test'
            config, groups=load_inputs(CONFIG_DIR/f'stimulus_catalog{suffix}.csv',CONFIG_DIR/f'experiment_design{suffix}.json')
            legacy_config=copy.deepcopy(config);legacy_config['runs_per_session']=6
            for modality in ['visual','tactile']:
                before=build_schedule(modality,legacy_config,groups)
                after=build_schedule(modality,config,groups)
                for key in ['runs','trials']:
                    self.assertEqual(len(before[key]),len(after[key]))
                    for a,b in zip(before[key],after[key]):
                        self.assertEqual({k:v for k,v in a.items() if k not in {'session','session_run'}},
                                         {k:v for k,v in b.items() if k not in {'session','session_run'}})
                        self.assertEqual((b['session'],b['session_run']),((b['run']-1)//4+1,(b['run']-1)%4+1))


if __name__ == '__main__':
    unittest.main()
