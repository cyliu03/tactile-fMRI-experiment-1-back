function test_run_video_preload()
% Exercise a complete real run without allocating all decoded videos in RAM.
root = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root, 'scripts'));
book = fullfile(root, 'train_visual', 'experiment_schedule_seed42_current.xlsx');
trials = readtable(book, 'Sheet', 'Trials', 'TextType', 'char');
trials = trials(trials.run == 1, :);
files = cell(height(trials), 1);
for i = 1:height(trials)
    files{i} = fullfile(root, 'video', 'train', ...
        sprintf('session%02d', trials.session(i)), ...
        sprintf('%03d.mp4', trials.stimulus_number(i)));
end
parent = fullfile(root, 'tests', 'timing_validation', 'video_cache');
timer = tic;
cache = FmriVideoCache(files, parent, @()[], @progress);
guard = onCleanup(@()cache.close());
elapsed = toc(timer);
assert(height(trials) == 33 && numel(cache.items) == 30);
bytes = 0;
for i = 1:numel(files)
    item = cache.get(files{i});
    assert(item.frame_count == 360 && item.width == 1080 && item.height == 1080);
    assert(isequal(size(item.map.Data(1).pixels), [1080 1080 3]));
    assert(isequal(size(item.map.Data(end).pixels), [1080 1080 3]));
end
for i = 1:numel(cache.items)
    item = cache.items{i};
    bytes = bytes + item.width * item.height * 3 * item.frame_count;
end
folder = cache.folder;
clear item;
cache.close();
assert(~isfolder(folder));
clear guard cache;
fprintf('FULL RUN PRELOAD PASS: 33 trials / 30 distinct original videos; %.3f GB temporary cache; %.3f s before trigger.\n', ...
    bytes/1e9, elapsed);
end

function progress(index, count)
if mod(index, 5) == 0 || index == 1
    fprintf('PRELOAD %d/%d\n', index, count);
end
end
