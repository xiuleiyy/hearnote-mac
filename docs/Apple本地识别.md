# Apple 本地识别

macOS 26 配合 Swift 6.2+ / macOS 26 SDK 构建的听记，使用 `SpeechAnalyzer` 和 `Speech.SpeechTranscriber`，不先调用旧 `SFSpeechRecognizer` 授权。这条语音处理路径无需开启 Siri／系统听写。设备或语言不支持新转写模块时，会在同一套本地分析接口内尝试 `DictationTranscriber`，并显示实际后端；失败会明确提示，不会暗中改为联网识别或旧 Siri 接口。

## 使用

1. 安装本次 CI 成功构建的 App，结束旧 App 进程后再打开新版。

2. 中文会议选择“普通话”，英文会议选择“English”，识别方式选择“Apple 本地识别”。识别语言与翻译方向独立。

3. Zoom 等会议选“系统声音”；需要同时录入自己的讲话时选“麦克风 + 系统声音”。这些音频采集仍需对应系统权限。

4. 开始录音。首次使用语言时，Apple 可能需要下载系统识别资源，界面显示准备／安装进度。录音会独立保存；识别就绪后接收新的声音。准备期间录下的内容，可在结束保存后点击“重新转写”补齐。

5. 文件“重新转写”也使用新接口，持续输入音频并等待最后一段定稿。取消时已识别的部分可保留，已有原文不会被失败的部分结果覆盖。

中英混合会议仍使用本地 Whisper；新的 Apple 路径按所选单一语言处理。独立翻译页在明确选择原文语言且设置使用 Apple 时走 Apple；“自动识别”继续使用 Whisper。Bedrock 仅处理翻译和摘要所需文字，不参与这套语音识别。

## 复测

无需为这次测试打开 Siri／听写或重置系统权限。在两项关闭的状态下验证：

- 普通话／English + Apple：麦克风和会议系统声音能显示原文，保存后文件重新转写也能出字。

- 首次资源准备、取消准备、停止录音和立即开始下一场会议：录音可保存，旧任务不得写入新会议。双源中取消尚未就绪的一路，已就绪的一路继续识别。

- 停止时的最后一句、超过一分钟的连续讲话、数字／否定词／专有词：对照录音检查遗漏、重复与误识别。字幕能显示不代表准确率验收通过。

- 独立翻译页选择明确的中文／英文来源：显示真实 Apple 后端；自动来源仍显示 Whisper。

macOS 14–25 或使用旧编译工具的源码构建，继续使用旧 `SFSpeechRecognizer`。这条旧路径仍可能受到 Siri／听写和语音识别权限限制；联网识别仅在用户明确允许后启用。

## 官方依据与验证边界

- Apple WWDC25 “Bring advanced speech-to-text to your app”：https://developer.apple.com/videos/play/wwdc2025/277/
- SpeechAnalyzer：https://developer.apple.com/documentation/speech/speechanalyzer
- SpeechTranscriber：https://developer.apple.com/documentation/speech/speechtranscriber
- AssetInventory：https://developer.apple.com/documentation/speech/assetinventory
- 权限范围：https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition

识别模型资源由 Apple 系统管理和共享；首次使用不保证无需下载。App 取消准备会隔离该任务和后续结果，系统共享资源下载可能继续。构建、签名与启动检查不能替代真实会议声音、语音准确度、系统权限和北京 Mac 的功能验收。
