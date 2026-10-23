classdef FmriVideoCache < handle
    % Decode each distinct video before the scanner trigger. Original RGB
    % frames live in a temporary memory-mapped file, not a run-sized RAM array.
    properties (SetAccess = private)
        files
        items
        folder
        parent
    end
    methods
        function obj = FmriVideoCache(files, parent, poll, progress)
            obj.files = unique(files, 'stable');
            obj.items = cell(size(obj.files));
            obj.parent = char(parent);
            if ~isfolder(obj.parent), mkdir(obj.parent); end
            [~, token] = fileparts(tempname(obj.parent));
            obj.folder = fullfile(obj.parent, ['video_preload_' token]);
            mkdir(obj.folder);
            try
                for i = 1:numel(obj.files)
                    progress(i, numel(obj.files));
                    reader = VideoReader(obj.files{i});
                    assert(reader.Width > 0 && reader.Height > 0 && reader.FrameRate > 0, ...
                        'visual:InvalidVideo', 'Invalid video: %s', obj.files{i});
                    frame_bytes = double(reader.Width) * double(reader.Height) * 3;
                    % Keep a margin for the output and filesystem metadata.
                    disk = java.io.File(obj.folder);
                    required = frame_bytes * ceil(reader.Duration * reader.FrameRate);
                    assert(double(disk.getUsableSpace()) > required + 512*1024^2, ...
                        'visual:CacheDiskFull', 'Insufficient disk space for video preload.');
                    file = fullfile(obj.folder, sprintf('%03d.rgb', i));
                    fid = fopen(file, 'wb');
                    assert(fid >= 0, 'visual:CacheWrite', 'Cannot create video cache: %s', file);
                    file_guard = onCleanup(@()fclose(fid));
                    count = 0;
                    while hasFrame(reader)
                        poll();
                        frame = readFrame(reader);
                        assert(isa(frame, 'uint8') && isequal(size(frame), ...
                            [reader.Height reader.Width 3]), ...
                            'visual:InvalidVideo', 'Expected constant-size uint8 RGB frames.');
                        written = fwrite(fid, frame, 'uint8');
                        assert(written == frame_bytes, 'visual:CacheWrite', ...
                            'Video preload failed (disk full or write error): %s', file);
                        count = count + 1;
                    end
                    clear file_guard;
                    assert(count > 0, 'visual:InvalidVideo', 'Empty video: %s', obj.files{i});
                    item.width = reader.Width;
                    item.height = reader.Height;
                    item.frame_rate = reader.FrameRate;
                    item.frame_count = count;
                    item.first_texture = [];
                    item.map = memmapfile(file, 'Format', ...
                        {'uint8', [reader.Height reader.Width 3], 'pixels'}, ...
                        'Repeat', count, 'Writable', false);
                    obj.items{i} = item;
                    clear reader item;
                end
            catch ME
                clear file_guard reader;
                obj.close();
                rethrow(ME);
            end
        end

        function prepare_textures(obj, win, poll)
            % Upload first frames before the trigger as well. Remaining frames
            % retain the existing timed MakeTexture/DrawTexture playback path.
            for i = 1:numel(obj.items)
                poll();
                obj.items{i}.first_texture = Screen('MakeTexture', win, ...
                    obj.items{i}.map.Data(1).pixels);
            end
        end

        function item = get(obj, file)
            index = find(strcmp(obj.files, file), 1);
            assert(~isempty(index), 'visual:VideoNotPreloaded', ...
                'Video was not preloaded before scanner start: %s', file);
            item = obj.items{index};
        end

        function close(obj)
            for i = 1:numel(obj.items)
                if ~isempty(obj.items{i}) && ~isempty(obj.items{i}.first_texture)
                    try
                        Screen('Close', obj.items{i}.first_texture);
                    catch
                        % Screen may already be closed by the experiment guard.
                    end
                end
            end
            obj.items = {}; % Release every memory map before deleting on Windows.
            if ~isempty(obj.folder) && isfolder(obj.folder)
                % Only remove this object's uniquely created immediate child.
                [actual_parent, name] = fileparts(obj.folder);
                assert(strcmpi(actual_parent, obj.parent) && startsWith(name, 'video_preload_'), ...
                    'visual:CachePath', 'Refusing to remove an unexpected cache path.');
                try
                    rmdir(obj.folder, 's');
                catch ME
                    warning('visual:CacheCleanup', 'Cannot remove temporary video cache: %s (%s)', ...
                        obj.folder, ME.message);
                end
            end
        end

        function delete(obj)
            obj.close();
        end
    end
end
