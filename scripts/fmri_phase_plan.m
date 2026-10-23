function plan = fmri_phase_plan(modality, cfg, iti)
% One scanner-relative timeline shared by all four experiment entry points.
assert(ismember(modality, {'visual','tactile'}));
iti = double(iti(:));
assert(all(isfinite(iti) & iti > 0), 'Invalid ITI values.');
if strcmp(modality, 'visual')
    names = {'prepare','view_video','post_video_hold','one_back_choice','iti'};
    fixed = [cfg.prepare cfg.video cfg.post_video_hold cfg.response];
else
    names = {'prepare','touch_shape','release_hold','one_back_choice','iti'};
    fixed = [cfg.prepare+cfg.delivery cfg.touch cfg.hold cfg.response];
end
assert(all(isfinite(fixed) & fixed > 0));
assert(isfinite(cfg.initial_dummy) && cfg.initial_dummy >= 0);
assert(isfinite(cfg.final_rest) && cfg.final_rest >= 0);
template = struct('kind','','trial',0,'onset',0,'duration',0);
plan = repmat(template, 5*numel(iti)+2, 1);
n = 0; offset = 0;
if cfg.initial_dummy > 0
    append('initial_dummy_scans', 0, cfg.initial_dummy);
end
for trial = 1:numel(iti)
    durations = [fixed iti(trial)];
    for j = 1:5, append(names{j}, trial, durations(j)); end
end
if cfg.final_rest > 0, append('final_rest', 0, cfg.final_rest); end
plan = plan(1:n);

    function append(kind, index, seconds)
        n = n+1;
        plan(n) = struct('kind',kind,'trial',index,'onset',offset,'duration',seconds);
        offset = offset+seconds;
    end
end
