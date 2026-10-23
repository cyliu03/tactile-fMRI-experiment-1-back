function diagnose_hold_pause()
% Reproduce first-entry late-policy overhead without modifying production.
root=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root,'scripts'),fullfile(root,'tests'));
folder=fullfile(root,'tests','timing_validation','hold_pause_diagnosis');
if ~isfolder(folder), mkdir(folder); end
data=readtable(fullfile(root,'train_visual','experiment_schedule_seed42_current.xlsx'),'Sheet','Trials');
trials=table2struct(data(data.run==2,:)); iti=[trials.iti_s]';
c=jsondecode(fileread(fullfile(root,'config','experiment_design.json')));
cfg=struct;
for f=fieldnames(c.timing)'
    key=f{1}; if endsWith(key,'_s'),cfg.(key(1:end-2))=c.timing.(key);end
end
cfg.timing_poll_interval_s=0.010;
cases={'normal','first_late_at_final_hold','repeat_late_at_final_hold','profile_late_at_final_hold'};
results=cell(size(cases));
for i=1:numel(cases)
    backend=FmriTimingDiagnosticBackend;
    if i>1
        backend.stall_at_s=524.98; backend.stall_seconds=0.095;
    end
    cb.read=@()backend.read(); cb.triggers=@(~)[];
    cb.abort=@()error('test:Abort','Abort'); cb.trial_row=@row; cb.empty_row=@empty;
    keys=struct('yes_keys',1,'no_keys',2,'escape_keys',3,'trigger_keys',5);
    engine=FmriTimingEngine(backend,cb,keys,'visual',cfg,trials,iti);
    if i==4, profile clear; profile on -nohistory; end
    cpu_start=cputime; wall_start=GetSecs;
    engine.run(backend.origin);
    elapsed_wall=GetSecs-wall_start; elapsed_cpu=cputime-cpu_start;
    if i==4
        profile off; profile_data=profile('info');
        save(fullfile(folder,'profile_original.mat'),'profile_data');
        functions=profile_data.FunctionTable;
        for j=1:numel(functions)
            if contains(functions(j).FunctionName,'FmriTimingEngine')
                fprintf('PROFILE %s %.6f seconds\n',functions(j).FunctionName,functions(j).TotalTime);
                disp(functions(j).ExecutedLines);
            end
        end
    end
    result.case=cases{i}; result.wall_seconds=elapsed_wall; result.cpu_seconds=elapsed_cpu;
    result.summary=engine.summary(); result.gaps=backend.gaps(1:backend.gap_count,:);
    result.flip_wall=backend.flip_wall(1:backend.flips,:);
    paths=engine.saveLogs(folder,cases{i}); result.phase_log=paths.phases;
    results{i}=result;
    fprintf('CASE %s wall %.6f CPU %.6f; max between-now gap %.6f\n', ...
        cases{i},elapsed_wall,elapsed_cpu,max([0;result.gaps(:,5)]));
    disp(result.gaps);
end
save(fullfile(folder,'original_results.mat'),'results');
fid=fopen(fullfile(folder,'original_results.json'),'w','n','UTF-8');
guard=onCleanup(@()fclose(fid));
fprintf(fid,'%s',jsonencode(results,'PrettyPrint',true));
end

function r=row(~,index,kind)
r=empty(kind); r.trial_index=index;
end
function r=empty(kind)
r=struct('onset',0,'duration',0,'trial_type',kind,'trial_index',NaN, ...
    'response','n/a','accuracy','n/a','rt','n/a');
end
