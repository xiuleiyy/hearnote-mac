# Apple 本地识别

macOS 26 配合 Swift 6.2+ / macOS 26 SDK 构建的听译，使用 `SpeechAnalyzer` 和 `Speech.SpeechTranscriber`，不先调用旧 `SFSpeechRecognizer` 授权。这条语音处理路径无需开启 Siri／系统听写。设备或语言不支持新转写模块时，会在同一套本地分析接口内尝试 `DictationTranscriber`，并显示实际后端；失败会明确提示，不会暗中改为联网识别或旧 Siri 接口。

## 使用

1. 安装本次 CI 成功构建的 App，结束旧 App 进程后再打开新版。

2. 中文会议选择“普通话”，英文会议选择“English”，识别方式选择“Apple 本地识别”。识别语言与翻译方向独立。

3. Zoom 等会议选“系统声音”；需要同时录入自己的讲话时选“麦克风 + 系统声音”。这些音频采集仍需对应系统权限。

4. 开始录音。首次使用语言时，Apple 可能需要下载系统识别资源，界面显示准备／安装进度。录音会独立保存；识别就绪后接收新的声音。准备期间录下的内容，可在结束保存后点击“重新转写”补齐。

5. 文件“重新转写”也使用新接口，持续输入音频并等待最后一段定稿。取消时已识别的部分可保留，已有原文不会被失败的部分结果覆盖。

中英混合会议仍使用本地 Whisper；新的 Apple 路径按所选单一语言处理。独立翻译页在明确选择原文语言且设置使用 Apple 时走 Apple；“自动识别”继续使用 Whisper。Bedrock 仅处理翻译和摘要所需文字，不参与这套语音识别。

## 已有模型与准备失败

App 会检查所选模块的资产状态和对应模块的已安装语言。发现已有模型时，先在 App 自身进程加载，避免不必要的下载；没有对应语言资源时才请求安装。安装接口返回 `nil` 表示无需继续安装，并不等于失败。

资产状态、已安装语言列表与真实加载结果是不同证据。App 不再仅因安装后状态仍为 `supported` 报“安装失败”；它会在同一个 `SpeechAnalyzer` 中验证资源加载、可用音频格式、实际格式准备和启动，全部成功后才接收识别音频。真正的加载、格式或启动失败仍会阻止就绪。

准备失败会区分请求安装、下载安装、加载资源、音频格式和启动阶段。XPC 服务连接错误单独提示，并保留原始 NSError 及底层错误链。`NSCocoaErrorDomain 4099` 只说明服务连接失效，不能据此认定网络、磁盘、权限或模型损坏；App 不会因此删除资源、重置权限或循环下载。

排查日志使用 subsystem `app.hearnote.mac`、category `AppleSpeechPreparation`，记录随机的本次准备标识、阶段、前后资产状态、已有语言是否匹配、安装请求是否存在，以及受控的系统错误 domain／code。日志不包含识别原文、API Key、原始 `userInfo` 或文件路径；未知 domain 隐去，只在内存中保留完整原始错误。`outcome=ready` 表示 App 实际格式准备和启动已返回成功，不代表已经收到音频或输出正确字幕。

## 复测

无需为这次测试打开 Siri／听写或重置系统权限。在两项关闭的状态下验证：

- 普通话／English + Apple：麦克风和会议系统声音能显示原文，保存后文件重新转写也能出字。

- 首次资源准备、取消准备、停止录音和立即开始下一场会议：录音可保存，旧任务不得写入新会议。双源中取消尚未就绪的一路，已就绪的一路继续识别。

- 停止时的最后一句、超过一分钟的连续讲话、数字／否定词／专有词：对照录音检查遗漏、重复与误识别。字幕能显示不代表准确率验收通过。

- 独立翻译页选择明确的中文／英文来源：显示真实 Apple 后端；自动来源仍显示 Whisper。

资源准备另测以下场景，不能用独立 CLI 的加载成功代替 App 验收：

| 场景 | 验收结果 |
|---|---|
| 已有 English／普通话资源 | App 能加载并出字；即使状态仍为 `supported`，也不重复报安装失败 |
| 已有资源，断开网络 | 不发起安装请求；App 的真实音频仍能转写 |
| 尚未安装的受支持语言 | 系统允许下载时，显示安装进度；下载后实际加载、启动并出字 |
| 安装请求返回 nil | 继续真实加载验证；加载失败仍明确报出阶段 |
| XPC／加载失败 | 界面显示相应阶段和安全错误码，录音可保存；不泛称网络或磁盘不足 |
| 各阶段取消、停止保存并开始下一场 | 立即结束本 App 的等待；旧系统操作晚到不能重新就绪或写入新会议 |
| 麦克风 + 系统声音 | 两路独立准备；一路取消或失败不得关闭已就绪的一路 |
| 保存后的文件重新转写 | 原始文件仍在，Apple 能转写并保存最终结果；失败不能覆盖已有原文 |

macOS 14–25 或使用旧编译工具的源码构建，继续使用旧 `SFSpeechRecognizer`。这条旧路径仍可能受到 Siri／听写和语音识别权限限制；联网识别仅在用户明确允许后启用。

## 官方依据与验证边界

- Apple WWDC25 “Bring advanced speech-to-text to your app”：https://developer.apple.com/videos/play/wwdc2025/277/
- SpeechAnalyzer：https://developer.apple.com/documentation/speech/speechanalyzer
- SpeechTranscriber：https://developer.apple.com/documentation/speech/speechtranscriber
- AssetInventory：https://developer.apple.com/documentation/speech/assetinventory
- 安装请求与 nil 返回值：https://developer.apple.com/documentation/speech/assetinventory/assetinstallationrequest(supporting:)
- 提前加载与音频格式：https://developer.apple.com/documentation/speech/speechanalyzer/preparetoanalyze(in:)
- 权限范围：https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition

识别模型资源由 Apple 系统管理和共享；首次使用不保证无需下载。App 取消准备会隔离该任务和后续结果，系统共享资源下载可能继续。构建、签名与启动检查不能替代真实会议声音、语音准确度、系统权限和北京 Mac 的功能验收。
