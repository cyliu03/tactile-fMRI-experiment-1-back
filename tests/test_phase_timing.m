function test_phase_timing()
root=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root,'scripts'));
folder=fullfile(root,'tests','timing_validation','engine_regression');
if ~isfolder(folder), mkdir(folder); end
for dataset={'train','test'}
    for modality={'visual','tactile'}
        name=[dataset{1} '_' modality{1}];
        [cfg,trials,iti]=inputs(root,name);
        plan=fmri_phase_plan(modality{1},cfg,iti);
        assert(numel(plan)==167 && abs(plan(end).onset+plan(end).duration-540)<1e-9);
        backend=FmriFakeBackend;
        % Include an early key that must not be assigned to a response, and a
        % valid key in the final 3 ms that is only polled in the next phase.
        ri=find(strcmp({plan.kind},'one_back_choice'));
        a=plan(ri(1)).onset;
        b=plan(ri(2)).onset;
        backend.key_schedule=[backend.origin+a-0.005 1; backend.origin+a+0.5 2; ...
            backend.origin+b+cfg.response-0.003 2];
        backend.key_sent=false(3,1);
        engine=FmriTimingEngine(backend,callbacks(backend),keys(),modality{1},cfg,trials,iti);
        engine.run(backend.origin);
        rows=engine.events(); summary=engine.summary();
        assert(summary.timing_valid && abs(summary.actual_seconds-540)<=backend.ifi);
        assert(abs(sum([rows.duration])+rows(1).onset-summary.actual_seconds)<1e-8);
        assert(all(abs([rows.duration]-[plan.duration])<=backend.ifi+1e-7));
        response=rows(strcmp({rows.trial_type},'one_back_choice'));
        assert(strcmp(response(1).response,'no') && abs(str2double(response(1).rt)-0.5)<1e-6);
        assert(strcmp(response(2).response,'no') && str2double(response(2).rt)>1.99);
        assert(all(strcmp({response(3:end).response},'no_response')));
        paths=engine.saveLogs(folder,name);
        t=readtable(paths.phases,'FileType','text','Delimiter','\t');
        assert(height(t)==168 && all(abs(t.actual_duration_s(1:167)-[rows.duration]')<1e-6));
        assert(any(t.draw_count>1),'Ack must restore the queued next page after its flip.');
        fprintf('PASS %s: complete 540 s timeline, responses, exact event coverage, export.\n',name);
    end
end
[cfg,trials,iti]=inputs(root,'train_tactile');
backend=FmriFakeBackend; backend.stall_at_s=17.98;
engine=FmriTimingEngine(backend,callbacks(backend),keys(),'tactile',cfg,trials,iti);
engine.run(backend.origin);
s=engine.summary(); rows=engine.events();
assert(~s.timing_valid && s.schedule_extension_s>0.9 && s.actual_seconds>540.9);
assert(all([rows.duration]>=[rows.planned_duration]-backend.ifi-1e-6));
paths=engine.saveLogs(folder,'injected_sleep_stall');
t=readtable(paths.phases,'FileType','text','Delimiter','\t');
assert(max(t.max_poll_gap_seconds)>0.9 && any(t.late_onset>0));
fprintf('PASS 1 s scheduling stall: explicit extension, quality flag, complete later windows.\n');

[cfg,trials,iti]=inputs(root,'train_visual');
backend=FmriFakeBackend; backend.read_stall_frame=60;
engine=FmriTimingEngine(backend,callbacks(backend),keys(),'visual',cfg,trials,iti);
engine.run(backend.origin);
s=engine.summary(); assert(~s.timing_valid && s.dropped_video_frames>0);
paths=engine.saveLogs(folder,'injected_frame_io_stall');
t=readtable(paths.frames,'FileType','text','Delimiter','\t');
assert(max(t.cache_read_end_s-t.cache_read_start_s)>0.19);
fprintf('PASS 200 ms frame read stall: slow operation and skipped frames logged.\n');

backend=FmriFakeBackend; backend.abort_at_s=17;
engine=FmriTimingEngine(backend,callbacks(backend),keys(),'visual',cfg,trials,iti);
try
    engine.run(backend.origin);
    error('test:ExpectedFailure','Abort was not propagated.');
catch ME
    assert(strcmp(ME.identifier,'test:InjectedAbort'));
end
rows=engine.events(); s=engine.summary();
assert(~s.end_measured_by_flip && s.aborted && ~s.timing_valid && ~isempty(rows));
assert(all(isfinite([rows.duration])) && rows(end).actual_end==s.actual_seconds);
engine.saveLogs(folder,'injected_abort');
fprintf('PASS abort: partial real durations preserved and censored end identified.\n');
end

function [cfg,trials,iti]=inputs(root,name)
if startsWith(name,'train'), suffix=''; else, suffix='_test'; end
c=jsondecode(fileread(fullfile(root,'config',['experiment_design' suffix '.json'])));
for f=fieldnames(c.timing)'
    key=f{1};
    if endsWith(key,'_s'), cfg.(key(1:end-2))=c.timing.(key); end
end
cfg.timing_poll_interval_s=0.010;
table_trials=readtable(fullfile(root,name,'experiment_schedule_seed42_current.xlsx'),'Sheet','Trials');
table_trials=table_trials(table_trials.run==1,:);
trials=table2struct(table_trials);
iti=double([trials.iti_s]');
end

function cb=callbacks(backend)
cb.read=@()backend.read(); cb.triggers=@(times)[];
cb.abort=@()error('test:InjectedAbort','Escape pressed.');
cb.trial_row=@row; cb.empty_row=@empty;
end
function k=keys()
k=struct('yes_keys',1,'no_keys',2,'escape_keys',3,'trigger_keys',5);
end
function r=row(trial,i,kind)
r=empty(kind); r.trial_index=i;
r.stimulus_id=sprintf('obj_%03d',trial.stimulus_number);
end
function r=empty(kind)
r=struct('onset',0,'duration',0,'trial_type',kind,'trial_index',NaN, ...
    'stimulus_id','n/a','response','n/a','accuracy','n/a','rt','n/a');
end
