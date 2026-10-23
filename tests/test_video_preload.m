function test_video_preload()
% Integration test against the actual decoder and memory-mapped RGB cache.
root = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(root, 'scripts'));
parent = fullfile(root, 'tests', 'timing_validation', 'video_cache');
file = fullfile(root, 'video', 'train', 'session01', '101.mp4');
timer = tic;
cache = FmriVideoCache({file, file}, parent, @()[], @(i,n)[]);
guard = onCleanup(@()cache.close());
preload_seconds = toc(timer);
assert(numel(cache.items) == 1, 'Repeated targets must reuse the same decoded video.');
folder = cache.folder;
item = cache.get(file);
reader = VideoReader(file);
assert(item.width == reader.Width && item.height == reader.Height);
assert(item.frame_rate == reader.FrameRate);
index = 0;
while hasFrame(reader)
    frame = readFrame(reader);
    index = index + 1;
    assert(isequal(item.map.Data(index).pixels, frame), 'Cached frame differs from original decoder output.');
end
assert(index == item.frame_count);
try
    cache.get('not_preloaded.mp4');
    error('test:ExpectedFailure', 'Missing video was accepted.');
catch ME
    assert(strcmp(ME.identifier, 'visual:VideoNotPreloaded'));
end
% Measure reading actual cached frames without allocating a whole-video array.
timer = tic;
checksum = 0;
for i = 1:item.frame_count
    frame = item.map.Data(i).pixels;
    checksum = checksum + double(frame(1));
end
read_seconds = toc(timer);
clear item frame reader;
cache.close();
assert(~isfolder(folder), 'Cache folder was not removed after releasing memory maps.');
cache.close(); % Closing twice must be safe.
clear guard cache;
% An interrupted preload must close open files and remove the partial cache.
before = dir(fullfile(parent, 'video_preload_*'));
try
    FmriVideoCache({file}, parent, @interrupt_preload, @(i,n)[]);
    error('test:ExpectedFailure', 'Interrupted preload was accepted.');
catch ME
    assert(strcmp(ME.identifier, 'test:Interrupted'));
end
after = dir(fullfile(parent, 'video_preload_*'));
assert(numel(before) == numel(after), 'Interrupted preload left temporary files.');
fprintf('PRELOAD PASS: %d original frames, duplicate reuse, missing-video rejection, cleanup, interruption.\n', index);
fprintf('PRELOAD %.3f s; cached frame reads %.3f s (%.3f ms/frame); checksum %.0f\n', ...
    preload_seconds, read_seconds, 1000*read_seconds/index, checksum);
end

function interrupt_preload()
error('test:Interrupted', 'Intentional cancellation during preload.');
end
