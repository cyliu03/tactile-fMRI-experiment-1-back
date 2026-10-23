classdef FmriPtbBackend < handle
    % Pre-render static pages/counters once; timing-critical draws only copy.
    properties (SetAccess = private)
        ifi
        texture_flags = 0
        texture_fallback_frames = 0
    end
    properties (Access = private)
        win
        rect
        pages
        counters
        page_names
        media
        destination
    end
    methods
        function obj = FmriPtbBackend(win, rect, modality, trials, cb, media)
            obj.win = win;
            obj.rect = [0 0 rect(3)-rect(1) rect(4)-rect(2)];
            obj.ifi = Screen('GetFlipInterval', win);
            assert(isfinite(obj.ifi) && obj.ifi > 0);
            obj.pages = [];
            obj.counters = [];
            obj.media = media;
            obj.destination = cell(size(media));
            obj.page_names = {'initial_dummy_scans','prepare','touch_shape', ...
                'release_hold','post_video_hold','one_back_choice','ack','iti', ...
                'final_rest','run_end'};
            if strcmp(modality,'visual'), prepare_text='准备观看视频';
            else, prepare_text='准备触摸物体'; end
            titles = {'+','准备','触摸','松手','视频结束','','','+','+','本轮任务结束'};
            subtitles = {'',prepare_text,'请触摸物体','请把手张开','请等待','','','','','正在保存数据，请等待'};
            try
                Screen('TextFont',win,'Microsoft YaHei');
                for i = 1:numel(obj.page_names)
                    % Legacy Windows GDI text is unreliable on offscreen FBOs.
                    % Rasterize on the real window's BACK buffer without a flip,
                    % then cache its pixels as a normal texture before start.
                    if ismember(obj.page_names{i}, {'one_back_choice','ack'})
                        cb.response(win, obj.rect, 0, 0, strcmp(obj.page_names{i},'ack'));
                    else
                        cb.draw(win, obj.rect, titles{i}, subtitles{i}, 0, 0);
                    end
                    pixels=Screen('GetImage',win,[],'backBuffer');
                    obj.pages(i)=Screen('MakeTexture',win,pixels);
                end
                counter_rect = [0 0 obj.rect(3) 100];
                for i = 1:numel(trials)
                    Screen('FillRect',win,[0 0 0]);
                    cb.text(win, sprintf('%d / %d',i,numel(trials)), ...
                        obj.rect(3)/2, 45, 22, [150 150 150]);
                    pixels=Screen('GetImage',win,counter_rect,'backBuffer');
                    obj.counters(i)=Screen('MakeTexture',win,pixels);
                end
                clear pixels;
                for i = 1:numel(media)
                    item = media{i};
                    scale = min(obj.rect(3)/item.width, obj.rect(4)/item.height);
                    obj.destination{i} = CenterRect([0 0 item.width*scale item.height*scale],obj.rect);
                end
                if ~isempty(media)
                    % Compile/warm the documented fast uint8 texture shader
                    % offscreen before the trigger, without exposing stimuli.
                    probe=[]; scratch=[];
                    try
                        probe=Screen('MakeTexture',win,media{1}.map.Data(1).pixels,0,4);
                        scratch=Screen('OpenOffscreenWindow',win,[0 0 0], ...
                            [0 0 media{1}.width media{1}.height]);
                        Screen('DrawTexture',scratch,probe);
                        Screen('GetImage',scratch,[0 0 1 1]);
                        obj.texture_flags=4;
                    catch fast_error
                        warning('fmri:FastTextureUnavailable', ...
                            'Fast video upload unavailable; using standard path: %s',fast_error.message);
                    end
                    if ~isempty(probe), Screen('Close',probe); end
                    if ~isempty(scratch), Screen('Close',scratch); end
                end
                % Warm the cached-draw/flip code path before the scanner trigger.
                obj.draw('initial_dummy_scans',0,false,[]);
                Screen('Flip',win);
            catch ME
                obj.close();
                rethrow(ME);
            end
        end

        function t = now(~), t=GetSecs; end
        function waitUntil(~, t), WaitSecs('UntilTime',t); end
        function [vbl, onset, returned, missed] = flip(obj, when)
            [vbl,onset,returned,missed] = Screen('Flip',obj.win,when);
        end
        function draw(obj, kind, trial, ack, texture)
            if strcmp(kind,'view_video')
                Screen('FillRect',obj.win,[0 0 0]);
                Screen('DrawTexture',obj.win,texture,[],obj.destination{trial});
            else
                if ack, kind='ack'; end
                if trial==0 && strcmp(kind,'final_rest'), trial=numel(obj.counters); end
                index=find(strcmp(obj.page_names,kind),1);
                assert(~isempty(index),'Unknown cached page: %s',kind);
                Screen('DrawTexture',obj.win,obj.pages(index),[],obj.rect);
                if trial > 0
                    Screen('DrawTexture',obj.win,obj.counters(trial),[],[0 0 obj.rect(3) 100]);
                end
            end
        end
        function texture = firstTexture(obj, trial)
            texture=obj.media{trial}.first_texture;
        end
        function [count,rate] = videoInfo(obj, trial)
            count=obj.media{trial}.frame_count; rate=obj.media{trial}.frame_rate;
        end
        function frame = readFrame(obj, trial, index)
            frame=obj.media{trial}.map.Data(index).pixels;
        end
        function texture = makeTexture(obj, frame)
            scale=min(obj.rect(3)/size(frame,2),obj.rect(4)/size(frame,1));
            flags=fmri_texture_flags(frame,obj.texture_flags,scale);
            if flags~=obj.texture_flags, obj.texture_fallback_frames=obj.texture_fallback_frames+1; end
            texture=Screen('MakeTexture',obj.win,frame,0,flags);
        end
        function closeTexture(~, texture), Screen('Close',texture); end
        function close(obj)
            handles=[obj.pages obj.counters];
            obj.pages=[]; obj.counters=[]; obj.media={};
            if ~isempty(handles), Screen('Close',handles); end
        end
        function delete(obj)
            try
                obj.close();
            catch
            end
        end
    end
end
