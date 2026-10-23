# 视觉 / 触觉 fMRI 1-back 实验

基于 MATLAB 和 Psychtoolbox 的形状感知实验，包含视觉、触觉两种模态，以及各自的 train / test 排程。视觉任务播放物体视频，触觉任务显示准备、触摸、松手等提示，由实验员按排程提供实物。两种模态均要求被试判断当前物体是否与前一个物体相同。

本说明对应当前排程：**train 为 9 个 Session、36 个 run；test 为 3 个 Session、12 个 run；每个 Session 有 4 个 run，每个 run 计划 540 秒。** `train` / `test` 是本项目的数据集名称，两套程序都使用完整的 1-back 任务流程。

## 1. 环境与依赖

| 项目 | 用途 / 说明 |
| --- | --- |
| Windows + MATLAB | 当前开发与本地验证使用 Windows、MATLAB R2024b；其他系统及 MATLAB 版本尚未完成兼容性验证 |
| Psychtoolbox | 屏幕呈现、翻屏计时、键盘队列和高精度时钟；安装后应能调用 `Screen`、`GetSecs`、`KbQueueCreate` |
| 视频解码环境 | 视觉任务通过 MATLAB `VideoReader` 解码 MP4；应在实验电脑上验证实际视频能被读取 |
| 中文字体 | 默认使用 `Microsoft YaHei`（微软雅黑）；替换字体后需重新检查屏幕文字 |
| 扫描仪 / 响应盒 | 通过键盘事件输入触发和反应；正式使用前确认设备、键位和显示器设置 |
| Python 3 + openpyxl | 仅生成排程及部分审计需要；使用现有 Excel 运行 MATLAB 实验不需要 Python |

Python 依赖可在项目根目录安装：

```powershell
python -m pip install -r scripts/requirements.txt
```

视觉预加载会生成较大的临时文件。缓存所在磁盘需要充足空间，硬盘速度、可用内存和显卡性能都会影响播放质量，详见后面的预加载说明。

## 2. 项目结构

```text
.
├── config/
│   ├── experiment_design.json          # train 参数
│   ├── experiment_design_test.json     # test 参数
│   ├── stimulus_catalog.csv            # train 物体清单
│   └── stimulus_catalog_test.csv       # test 物体清单
├── train_visual/                       # 视觉 train 入口与排程
├── train_tactile/                      # 触觉 train 入口与排程
├── test_visual/                        # 视觉 test 入口与排程
├── test_tactile/                       # 触觉 test 入口与排程
├── scripts/                           # 四套程序共用的排程、计时、缓存与导出代码
├── tests/                             # 排程测试、计时回归及诊断工具
├── video/
│   ├── train/session01/ … session06/   # 视觉 train 原始素材分组
│   └── test/session01/ … session03/    # 视觉 test 原始素材分组
└── object/
    ├── train/session01/ … session06/   # 触觉物体模型 / 素材分组
    └── test/session01/ … session03/
```

四个任务目录各自包含：

- `fMRI_experiment.m`：统一启动入口。
- `visual_fMRI_experiment.m` 或 `tactile_fMRI_experiment.m`：任务主程序。
- `experiment_schedule_seed42_current.xlsx`：**运行时唯一读取的执行排程**。
- `printable_run_order_seed42.xlsx`：供实验员核对、摆放和换物体的打印表。
- `generate_experiment_schedule.py`：调用公共生成器，重新生成本目录的两份排程表。

旧的 `experiment_schedule_seed42.xlsx` 即使仍在本地，也不参与当前程序执行。不要删除 `scripts/`，四套任务都依赖它。

## 3. 当前实验设计

下表的数量均按**单一模态**统计；视觉、触觉各有一套对应排程。

| 项目 | train | test |
| --- | --- | --- |
| 不同物体数 | 360 | 90 |
| 物体编号 | 101–160、201–260、301–360、401–460、501–560、601–660 | 001–090 |
| 每个物体基础呈现次数 | 3 | 4 |
| Session 数 | 9 | 3 |
| run 数 | 36 | 12 |
| 每个 run 的基础 trial | 30 | 30 |
| 每个 run 额外插入的 1-back trial | 3 | 3 |
| 每个 run 实际 trial | 33 | 33 |
| 全部实际 trial | 1188 | 396 |
| 每个 run 计划时长 | 540 秒（9 分钟） | 540 秒（9 分钟） |
| 单个 Session 计划时长 | 2160 秒（36 分钟） | 2160 秒（36 分钟） |
| 全部 Session 的计划任务时长 | 324 分钟 | 108 分钟 |

以上时长包含开头基线与结尾静息，不包含预加载、等待触发、实验员换 run、休息及保存数据等耗时。

每个 run 以 30 个不同物体为基础，选择 3 个物体，在其后立即再呈现一次，形成 1-back target。重复 trial 的正确答案是“是”，其他 trial 为“否”；每个 run 的第一个 trial 为“否”，比较不跨 run。基础呈现次数不包含额外的 target 重复。

train 使用升序、降序、逐列三种基础排序；test 增加反向逐列，共四种排序。物体盘为 5 行 × 6 列。同一数据集的视觉与触觉在当前配置下使用相同的物体顺序、target 和 ITI。随机种子为 42。

### 阶段与时长

每个 run 开始先显示 6 秒基线，随后执行 33 个 trial，最后显示 6 秒静息。

| 顺序 | 视觉阶段（日志名称） | 触觉阶段（日志名称） | 计划时长 |
| --- | --- | --- | --- |
| 1 | 准备 `prepare` | 准备 `prepare` | 2 秒 |
| 2 | 视频 `view_video` | 触摸 `touch_shape` | 6 秒 |
| 3 | 等待 `post_video_hold` | 松手 `release_hold` | 2 秒 |
| 4 | 判断 `one_back_choice` | 判断 `one_back_choice` | 2 秒 |
| 5 | 注视 / 间隔 `iti` | 注视 / 间隔 `iti` | 2、3、4、5 或 6 秒 |

每个 run 的 ITI 总和固定为 132 秒，平均 4 秒。因此：

```text
6 + 33 × (2 + 6 + 2 + 2) + 132 + 6 = 540 秒
```

当前触觉 `delivery_s=0`，没有单独的交付阶段；若修改该值，会加到准备阶段时长。反应后不会提前结束 2 秒回答窗口。

## 4. Session 和 Run 怎么填

**Run 输入框填写全局编号，不是在每个 Session 内重新从 01 开始。** 两种模态使用相同的填写规则。

| Session 输入 | train 的全局 Run 输入 | test 的全局 Run 输入 |
| --- | --- | --- |
| 01 | 01、02、03、04 | 01、02、03、04 |
| 02 | 05、06、07、08 | 05、06、07、08 |
| 03 | 09、10、11、12 | 09、10、11、12 |
| 04 | 13、14、15、16 | — |
| 05 | 17、18、19、20 | — |
| 06 | 21、22、23、24 | — |
| 07 | 25、26、27、28 | — |
| 08 | 29、30、31、32 | — |
| 09 | 33、34、35、36 | — |

例如 test 第二个 Session 的第一轮填写 `Session=02, Run=05`；最后一轮填写 `Session=03, Run=12`。每次启动只执行一个 run，下一轮需再次启动。

执行表中的 `session_run` 是组内轮次 1–4，`stimulus_session` 是原始素材分组。**输入 Session 与素材目录 `sessionXX` 含义不同**：train 重新按每 4 个 run 分组后，有些 Session 会跨素材目录。不要根据输入 Session 移动或重命名视频目录，程序会依据 `stimulus_session` 找素材。

## 5. 准备视频与触觉物体

排程由 CSV 清单生成，不会因为某个文件缺失而自动跳过该物体。取得代码和排程后，仍需核对自己是否拥有完整素材。

默认视频文件名为三位物体编号加 `.mp4`，例如：

```text
video/train/session01/101.mp4     # 101–160
video/train/session02/201.mp4     # 201–260
…
video/train/session06/601.mp4     # 601–660

video/test/session01/001.mp4      # 001–030
video/test/session02/031.mp4      # 031–060
video/test/session03/061.mp4      # 061–090
```

CSV 的 `video_filename` 可留空，程序会使用上述默认名称；有自定义名称时，只填写文件名，不填写目录。`object_name` 可留空。更改 CSV 后需要重新生成排程，MATLAB 不会直接读取 CSV 中的改动。

视觉正式运行前会检查当前 run 的视频文件是否存在，随后实际解码。文件存在不代表格式、时长或播放性能已经合格；应准备与 6 秒呈现窗口匹配的视频，并在目标实验电脑上完成播放检查。

触觉程序运行时不打开 STL，也不会自动控制物体交付设备。实验员需要按打印表准备实物、安排交付与重复 trial，并遵守屏幕上的触摸和松手提示。`object/` 用于管理物体模型，不能替代实际触觉刺激。

## 6. 启动实验

将整个项目放在本地磁盘，保留目录之间的相对位置。在 MATLAB 中将当前文件夹设为项目根目录，然后运行以下示例：

```matlab
root = pwd;                          % 当前文件夹必须是项目根目录
cd(fullfile(root, 'train_visual'));   % 换成所需任务目录
clear fMRI_experiment visual_fMRI_experiment tactile_fMRI_experiment
fMRI_experiment('checkschedule');    % 先检查排程结构和 Session / Run 映射
fMRI_experiment;                     % 打开被试信息输入框，开始该 run
```

目录选择：`train_visual`（视觉 train）、`train_tactile`（触觉 train）、`test_visual`（视觉 test）、`test_tactile`（触觉 test）。

四套入口及两套视觉 / 触觉主程序存在同名函数。**切换任务时应进入目标目录，并清除上例中的函数缓存；不要使用 `addpath(genpath(root))` 同时加入四套任务。** `scripts/` 会由入口自动加入路径。上例中的 `root` 在同一个 MATLAB 会话中可复用；若重新开始，请先回到项目根目录再赋值。

输入框需填写被试信息、Session、全局 Run 和模式：

- 调试填写 `行为` 或 `behavioral`：当前默认 `SkipSyncTests=1`。
- 正式扫描明确填写 `fmri`：当前默认 `SkipSyncTests=0`，执行屏幕同步测试。
- 当前代码将其他不包含“行为”、也不以 `beh` 开头的模式文本归入 fMRI 模式，请使用上述明确值。

视觉任务会先完成视频预加载，再进入准备与触发等待。触觉任务直接准备屏幕页面。准备页可按 `1` 确认，当前确认等待最多 20 秒；之后程序一直等待第一个有效触发。**行为模式同样等待触发**，可在本地调试时手动按 `s` 模拟。正式实验应先等程序进入触发等待界面，再启动扫描。

| 按键 | 功能 |
| --- | --- |
| `1` | 开始前确认准备；回答阶段表示“与前一个物体相同” |
| `2` | 回答阶段表示“不同” |
| `s`、`5` 或 `t` | 默认兼容的扫描触发键；键名配置还包含大小写 / 键盘布局变体 |
| `Esc` | 中止，尝试保存已产生的数据并释放资源 |
| 空格 | 结束后的确认 / 退出 |

默认使用 Psychtoolbox 默认键盘设备及编号最大的屏幕。若需指定显示器、响应盒或改变按键，可查看所选任务主程序的 `default_config`、`make_input` 和 `open_ptb_window`；各主程序中的这些设置应按实际需要分别调整。

## 7. 视频预加载与计时策略

视觉任务在**每次启动一个 run 时**，先解码本轮所有不同视频。同一个 run 中的 1-back 重复使用同一份缓存；目前不在不同 run 之间保留缓存。

缓存为未压缩 RGB 临时文件，保存在所选视觉目录的 `cache/video_preload/video_preload_*/` 下，正式入口与窗口诊断入口使用相同的缓存位置，通过内存映射读取。它既占用磁盘，也会随着读取占用系统文件缓存和物理内存，并非只消耗硬盘。正常结束或被捕获的异常退出会尝试清理本轮缓存；强制终止 MATLAB 后可能残留，应在确认实验已停止后检查。

缓存体积近似为每个不同视频的 `宽 × 高 × 3 × 帧数` 之和。以 30 段 1920×1080、36 fps、6 秒视频为例，约为 **40.3 GB（37.5 GiB）**，还需为文件系统及输出留余量。预加载耗时取决于素材和电脑，不能把某次测得的耗时当成固定值。可用内存不足时，即使已预加载，仍可能出现换页、纹理上传延迟或跳帧。

四套程序共用 `scripts/FmriTimingEngine.m`：以第一个有效触发为零点，把所有阶段安排在同一条绝对时间轴上，按预定时间调用翻屏。这样可减少各阶段分别等待导致的累计漂移。文字页面、计数标签和日志空间也会在触发前准备。

这不保证实际运行始终恰好 540 秒。屏幕刷新有时间量化，系统停顿也可能错过翻屏；超过容差的正向延迟会明确顺延后续时间轴，并记录异常。当前容差为 `max(0.020 秒, 2 × 刷新间隔)`。视频播放会跳过已过期帧以跟随时间轴，并记录跳帧数量。应依据实际日志判断时序，不能仅凭实验总长接近 540 秒判定合格。

## 8. 输出数据与计时质量

四套程序均将实验数据写入各自目录的 `output/sub-<编号>/ses-<编号>/`：

| 任务目录 | 新实验结果 | 视频临时缓存 |
| --- | --- | --- |
| `train_visual/` | `output/` | `cache/video_preload/` |
| `test_visual/` | `output/` | `cache/video_preload/` |
| `train_tactile/` | `output/` | 无视频缓存 |
| `test_tactile/` | `output/` | 无视频缓存 |

无屏幕模拟和窗口诊断结果统一写入所选目录的 `output/timing_checks/`。本次目录调整仅影响后续运行：历史视觉结果仍保留在原 `output_visual/` 中，原 `output/video_preload/` 下可能残留的旧缓存也不会自动迁移或删除。

| 文件 | 内容 |
| --- | --- |
| `*_events.tsv` | 阶段事件、物体 / trial 标识、1-back 标记、反应、正确性和反应时等 |
| `*_triggers.tsv` | 扫描触发时间；有触发记录时生成 |
| 带时间戳的 `.xlsx` | 便于人工检查的 `events`、`triggers` 工作表 |
| `*_info.mat` | 被试信息、配置、输入排程路径、运行状态和计时摘要 |
| `*_timing.tsv` | 每个阶段的计划时间、真实翻屏、实测时长、时长偏差和切换检查点 |
| `*_frames.tsv` | 视频帧读取、纹理上传、翻屏、显示 / 跳过记录；亦含回答确认画面的记录 |
| `*_keypresses.tsv` | 按键事件时间和程序接收到按键的阶段 |
| `*_timing_summary.json` | 计划 / 实际总长、顺延量、超时、跳帧及质量标记 |

事件表的 `onset` 以首个有效触发为零点，单位为秒。所有阶段的 `duration` 均使用实测结束减实测开始，TSV 和 Excel 统一显示 6 位小数；`planned_duration` 与 `duration_error` 用于比较计划和实际值。正常完成时，相邻翻屏确定阶段边界，结尾静息以额外的 `run_end` 翻屏结束。中止时最后一个阶段结束于程序观测到中止的时刻，不能视为正常测得的显示结束。

做行为统计时，筛选 `trial_type=one_back_choice`，每个 trial 只统计一次。当前导出会把该 trial 的反应结果复制到它的各阶段行，不能直接把所有阶段的正确数相加。`rt` 是有效回答键相对于实际回答阶段开始的时间，单位为秒；无回答时 `response=no_response`、`rt=n/a`。

重点检查摘要中的：

- `planned_seconds`、`actual_seconds`：计划与实际总长。
- `schedule_extension_s`：严重延迟造成的累计顺延。
- `late_phase_count`：超过容差的阶段切换次数。
- `dropped_video_frames`、`late_video_frames`：跳过和迟到的视频帧数。
- `backend`：使用真实显示后端还是时钟模拟后端。
- `timing_valid`：只有完整完成、无超容差阶段切换、无跳帧且无迟到视频帧时才为真。

例如“85 帧跳过”表示本应显示的 85 帧因错过时机被跳过；即使阶段总长接近计划，该轮仍标记计时异常。该标记应与日志一起保留。时钟模拟的 `timing_valid=true` 也不代表显示器和视频播放已通过验证。

可在项目根目录使用以下只读工具核对一次运行的日志；将示例路径替换为实际文件：

```powershell
python scripts/audit_timing_output.py "path/to/run_timing_summary.json"
python scripts/analyze_phase_pauses.py "path/to/run_timing_summary.json"
```

前者检查时长覆盖、阶段边界和计数一致性；后者用于定位阶段间停顿和视频读取 / 上传耗时。日志结构一致不等于计时质量合格。

## 9. 检查与试运行

### 排程检查

进入任一任务目录后，在 MATLAB 执行：

```matlab
clear fMRI_experiment visual_fMRI_experiment tactile_fMRI_experiment
fMRI_experiment('checkschedule');
```

该命令不打开实验窗口，检查 Excel 数据、当前 Session / 全局 Run 对应关系和计划时长。视觉版还会构造视频路径，但**不验证文件存在或可播放**。

视觉任务可额外检查某个全局 run 的视频文件是否齐全：

```matlab
fMRI_experiment('checkmedia', 1);   % 仅视觉任务支持；1 是全局 Run
```

### 无屏幕时钟模拟

四套任务均支持，不需要视频和扫描仪，也不显示刺激；仍需 MATLAB 与 Psychtoolbox 时钟函数：

```matlab
fMRI_experiment('selftest', 1, 'short');   % 2% 时长，计划 10.8 秒
fMRI_experiment('selftest', 1, 'full');    % 完整 540 秒时钟流程
```

### 窗口试运行

四套任务均支持；视觉需要该 run 的实际视频。此模式自动开始，不等待扫描触发，使用 960×720 窗口并跳过同步测试，**仅用于诊断**：

```matlab
fMRI_experiment('timingtest', 1, 'short');
fMRI_experiment('timingtest', 1, 'full');
```

短模式缩放阶段时长，不能验证完整 6 秒视频播放质量；完整播放排查应使用 `full`。以上两类试运行输出保存在各自的 `output/timing_checks/`，与正式被试输出区分；视觉窗口试运行的视频缓存写入各自的 `cache/video_preload/`。

### 开发回归检查

在项目根目录执行 Python 排程测试：

```powershell
python -m unittest discover -s tests -p "test_*.py"
```

在 MATLAB 项目根目录执行计时和导出回归：

```matlab
root = pwd;
addpath(fullfile(root, 'scripts'), fullfile(root, 'tests'));
test_phase_timing;
test_event_duration_export;
```

这些回归会生成测试输出，其中计时回归使用模拟后端，覆盖时间轴、按键、注入停顿和中止情形。正式采集仍需在目标显示器、响应盒和扫描环境下完成全流程检查。

`scripts/audit_experiment.py` 还包含开发阶段旧素材迁移清单的校验，依赖 `schedule_backup/` 中的历史记录，不适合作为公开精简副本的唯一安装验收命令。优先使用上述排程、素材和运行检查。

## 10. 修改配置与重新生成排程

修改 train 的 `config/experiment_design.json` / `config/stimulus_catalog.csv`，或 test 的 `config/experiment_design_test.json` / `config/stimulus_catalog_test.csv`，然后在项目根目录执行：

```powershell
python train_visual/generate_experiment_schedule.py
python train_tactile/generate_experiment_schedule.py
python test_visual/generate_experiment_schedule.py
python test_tactile/generate_experiment_schedule.py
```

这些命令会覆盖各任务目录中的当前执行表和打印表。**先备份，并关闭 Excel 中打开的相关文件。** 只修改 JSON 不会改变现有 MATLAB 实验，必须重新生成 Excel；不建议单独修改 MATLAB 默认时长，因为运行时会由 Excel 参数覆盖。

可先生成到其他目录进行核对，例如：

```powershell
python test_visual/generate_experiment_schedule.py --output-dir schedule_preview/test_visual
```

确认无误后再更新运行目录。同一数据集的两种模态应一起生成、一起检查。生成器无需素材齐全即可生成表格，素材检查需要另做。

当前表结构为 schema 4。`Parameters`、`Runs`、`Trials` 是运行读取的主要工作表，`Overview` 和 `Stimuli` 用于说明与核对。不要只改表头或删除机器读取列。配置中的 `objects_per_session` 仍表示原始素材组大小（train 60、test 30），运行 Session 的分组由 `runs_per_session=4` 控制。

改动物体清单、排序、target 数量或种子后，即使全局 Run 编号相同，target 位置和 ITI 也可能变化。已有数据采集期间应固定代码、配置和执行表版本，保存对应 Git 提交及原始排程副本。

## 11. 常见问题

**为什么一直停在“等待扫描仪 S 触发”？**  
所有模式都等待触发。调试时手动按 `s`；正式实验核对扫描仪键值和键盘设备。准备页按 `1` 不会启动任务计时。

**为什么设置 2 秒，实际日志有小数或多出时间？**  
显示只能在刷新边界更新，实际时长由真实翻屏测得。严重系统停顿还会触发时间轴顺延。查看 `duration_error_s`、`late_phase_count`、`schedule_extension_s` 及逐帧日志定位，不能用计划值替换实测值。

**为什么预加载后仍然跳帧或卡顿？**  
预解码避免了计时窗口内解码，但缓存读取、纹理上传和翻屏仍发生在运行中。高分辨率缓存可能造成内存压力，磁盘或显卡也可能成为瓶颈。先查看资源占用和计时日志，再在实验设计允许的范围内调整素材或硬件。

**正式模式报 Synchronization failure 怎么办？**  
检查目标屏幕、刷新率、显卡驱动及显示链路，并在本机环境排查。行为模式或窗口诊断可帮助检查流程，但跳过同步测试不能证明正式呈现计时合格。

**切换到 test 却运行了 train，或运行了错误模态？**  
检查 MATLAB 当前目录，执行前述 `clear`，并使用 `which fMRI_experiment -all` 排查同名入口。MATLAB 搜索路径中只加入当前所需的任务目录，公共代码由程序自动加载。

## 12. 发布到 GitHub 前

公开副本保留 README、四套程序及其当前执行表 / 打印表、`config/`、`scripts/` 和测试源文件。根目录的 [`.gitignore`](.gitignore) 已设置为仅发布代码、配置及当前排程，排除以下本地内容：

- 实验结果 `output/`、历史视觉结果 `output_visual/`，包括其中的计时检查结果。
- 视频缓存 `cache/`、`video_preload/` 和 Python 缓存。
- `schedule_backup/`、`tests/timing_validation/`、`schedule_preview/`。
- 素材目录 `video/`、`object/`，以及本地依赖、虚拟环境和临时文件。
- 其他 `.xlsx` 文件；四套任务各自的 `experiment_schedule_seed42_current.xlsx` 和 `printable_run_order_seed42.xlsx` 共八份文件已明确保留。

视频与物体模型需要另外获取。维护者发布时应补充获取方式；使用者需按第 5 节创建素材目录并补齐文件。Git 不保存空目录。

实验输出可能包含姓名、年龄等被试信息，尤其是 `*_info.mat`。若文件已经被 Git 跟踪，新增忽略规则不会自动移除它们；发布前需检查实际提交内容。`.gitignore` 只控制 Git 的文件选择，不会删除本地文件；通过网页或压缩包上传时，也需自行排除这些目录。

当前项目根目录尚未附带 `LICENSE`。发布前请由维护者补充代码许可、视频 / 物体模型的授权与获取说明。
