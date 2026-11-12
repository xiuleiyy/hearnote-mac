# 听记 · HearNote for Mac

原生 SwiftUI Mac App：录制麦克风和会议软件声音，实时显示原文与翻译，会议后生成带时间戳的摘要、决定和待办。App 在 Mac 本机运行，直接连接所选 Bedrock Region。

首版以速度和准确性为目标：先显示实时原文，稳定后翻译；重点核对人名、数字、专业术语、否定词和不确定表述。Region 和模型的选择以本机实际延迟与译文核对结果为依据。

独立“翻译”页面参考 iPhone 自带翻译的文字、语音、对话和收藏流程。它与会议听记共用 Bedrock API Key、Region、模型和术语表。详见 [安装使用](docs/安装使用.md) 和 [Mac 本机验收](docs/Mac本机验收.md)。

## 首版功能

| 功能 | 当前实现 |
|---|---|
| 录音来源 | 麦克风、系统声音、同时录制；系统音包含 Zoom、飞书等软件播放的声音 |
| 实时转写 | 中英混合使用本地 WhisperKit 多语种模型；单语可选 Apple Speech |
| 实时翻译 | Bedrock 文字模型；文字稳定或片段闭合后发送；仅时间戳变化不重新等待，原文修订立即撤下旧译文 |
| 中英双向 | 中文译英文，英文译中文；同句混用按主要语言选择方向，均衡混合显示完整英文和中文两行 |
| 翻译开关 | 开始前和录音中可切换；关闭时取消在途翻译、停止提交新翻译，录音和转写继续 |
| 文件转写 | 导入音视频文件，按小于一分钟的音频片段识别，保留时间戳 |
| 翻译 | 多语言、术语表、分块处理、检测截断，原文与译文分开保存 |
| AI 摘要 | 重点、决定、待办，要求引用原文时间戳，不编造负责人或日期 |
| 校对与回听 | 编辑原文，点时间戳回听；编辑后清除过期翻译与摘要 |
| 导出 | TXT、SRT、Markdown、JSON |
| Region 与模型 | 主界面可切换；设置中添加多个完整模型 ID |
| 认证 | 仅接受用户自己的 Bedrock API Key；首次启动填写，只存 macOS Keychain |
| 独立翻译 | 文字、语音、两人轮流对话、语言交换、朗读、复制、历史和收藏 |
| 图片翻译 | 导入图片／截图，在本机识别文字；校对后翻译 |

默认选用 Claude Sonnet 5.5，另有 Kimi K3（Kimi 3）、GLM 5.3、GPT 5.6 Sol 作为对比候选。

| 预置型号 | 完整 Bedrock model ID |
|---|---|
| Claude Sonnet 5.5，默认 | `global.anthropic.claude-sonnet-5-5` |
| Kimi K3 | `global.moonshotai.kimi-k3` |
| GLM 5.3 | `global.zai.glm-5.3` |
| GPT 5.6 Sol | `global.openai.gpt-5.6-sol` |

当前预置包含 GLM 5.3。GLM 5.2 的可调用 Bedrock ID 尚未核实，未将其预置；取得可验证的 ID 后可在设置中添加。

旧版本已保存的内置 Sonnet／Qwen 配置会升级；上一版内置 Kimi K3.1 会换成 K3，保留选中状态、Region 和其他自定义型号。迁移有版本门禁，用户已删除的候选不会每次重新添加。当前 API Key 是否可用仍以连接测试为准；官方 GLM 卡注明仅符合条件的客户可访问。连接测试真实调用所选模型并显示总耗时。默认展示东京 Region，也可选择其他 Region。这四个型号在东京使用 Global profile；东京是入口，实际推理位置可能在其他 Region，厂商国别也不等于数据所在地区。

App 自动按型号适配：Sonnet 使用 Converse 的 `between_tools` 与低 effort；Kimi 使用 Bedrock Chat Completions、关闭推理；GLM 使用 Converse、低 effort，无法关闭推理；GPT 使用 Bedrock Responses、关闭推理。均使用同一个用户 Bedrock API Key，无需其他厂商 Key。用户自行添加的其他型号沿用文本 Converse。

## 在 Mac 上构建

需要 macOS 14+ 和支持 Swift 5.10+ 的 Xcode 编译工具；WhisperKit 官方建议 Xcode 16 或更新版本。首次构建会从 GitHub 下载精确版本 `1.1.1` 的 WhisperKit 和它的依赖。

仓库为 private，需要当前 GitHub 账号有访问权限。登录 GitHub 后取得源码：

```bash
git clone https://github.com/xiuleiyy/hearnote-mac.git
cd hearnote-mac
bash scripts/build-mac.sh --open
```

也可双击 `开始使用.command`。首次缺少编译工具时，先运行 `xcode-select --install`。

脚本先执行 `swift test`，再编译并生成 `dist/HearNote.app`，复制依赖的资源 bundle，最后做本地 ad-hoc 签名。构建不安装后台服务，不发布 App Store。生成的 `.app` 可复制到 Mac 的 `/Applications`；当前未进行 Developer ID 签名或公证。

本机验收成功后执行 `bash scripts/package-mac.sh`，生成 `dist/HearNote.dmg`；打开后将 App 拖到 Applications。该脚本使用已构建的 App，不重复编译和测试。当前仓库交付源码，尚未提供经 Mac 实机验收的二进制安装包。

## 独立翻译

侧栏点“翻译”（或 `⌘⇧T`）。默认自动识别并中英双向：中文译英文、英文译中文；也可选固定原文／目标语言，交换语言后继续翻译。

- 文字：输入或粘贴，再点“翻译”或 `⌘Return`。短文本只发一次翻译请求，不另外请求语言检测、摘要或润色；不在每次按键时调用模型。

- 语音：点麦克风，先显示识别原文；说完结束，按这一轮语音生成译文。多语种识别复用已准备的本地 Whisper 模型，与会议录音互斥。

- 对话：中文和英文双方轮流点自己的语音按钮；每轮保存原文和译文，支持复制、朗读和收藏。

- 图片：导入图片或截图，本地 OCR 后先检查文字再翻译。OCR 错误可在输入框直接校对。

- 历史与收藏：译文成功且对应当前输入后保存到本机独立记录；失败、截断和已取消结果不保存。原文、语种或模型改变时，旧请求不能覆盖新结果。

翻译需要连接所选 Bedrock endpoint；本地识别模型准备完成后，语音识别和图片文字识别在 Mac 内执行。译文可由 macOS 语音朗读，具体声音与语言支持以本机为准。独立翻译的 Mac UI、麦克风、OCR 与朗读仍需按 [Mac 本机验收](docs/Mac本机验收.md) 实测。

## 第一次使用

1. 在配置页粘贴自己的 Bedrock API Key。Region 和模型已经预选，无需填写其他认证信息。

2. 点击“测试连接”，成功后保存。需要时可调整 Region，展开“添加或管理模型”添加其他模型。可以跳过配置，先使用录音、转写和校对。

3. 点击“开始会议录音”，选择声音来源。中英会议选择“中英混合”及“中英双向”；单语也可选择对应语言。中英混合先点击“准备模型”，首次需要下载模型与 tokenizer，后续复用本地缓存。准备失败时可导入完整本地模型目录。首次使用按所选来源允许麦克风、系统录制；Apple 单语识别还需语音识别权限。

4. 按需要开启“实时翻译”；可在会议中随时关闭或重新开启。关闭期间只保存录音与原文，重新开启后翻译新产生的稳定文字；不自动补翻关闭期间的内容。结束后保存，可点击“生成摘要”或“翻译全文”，导出需要的结果。

为了准确性，可以在设置里添加常用专有词与 `原词=译法` 术语表。建议戴耳机减少麦克风重复收录会议音频。系统音模式录制全部系统声音，不要求在 Zoom / 飞书内打开屏幕共享，也不保存屏幕图像。

## 数据位置

- 笔记和媒体：`~/Library/Application Support/HearNote/`。

- 独立翻译历史：`~/Library/Application Support/HearNote/translation-history.json`；不含 API Key。

- key：macOS Keychain，service `app.hearnote.mac.bedrock`。

- 首次启动默认“中英混合”，使用本地 Whisper 多语种模型，准备完成后音频识别在本机执行。单语 Apple Speech 默认设备端识别，不支持时提示用户，可明确允许 Apple 联网识别。

- 混合识别模型下载到 `~/Library/Application Support/HearNote/WhisperModels/`，并记住实际缓存目录。完整离线模型目录还须有 tokenizer 文件；下载可用性取决于本机网络。可比较 Whisper Large v3 Turbo 与 Small 在本机的速度和识别错误，不预先保证某个模型在所有 Mac 上实时。

- 翻译与摘要将对应文字发送到所选 Bedrock endpoint。原始录音不发给 Bedrock。使用跨区域 inference profile 时，入口 Region 不等于实际推理 Region。

- App 仅使用用户填写的 Bedrock API Key 认证，不读取 AWS CLI 或 SSO 配置。

## 验证状态

当前 Core XCTest 53 项全部通过，包含导出、本地库、API Key 调用、多模型协议、中英双向请求、实时翻译开关、排队和修订保护。Mac 源码通过 Swift 原生 parser；WhisperKit 接口已按官方 `v1.1.1` 源码核对。此前验证环境没有 Apple SDK，完整 macOS typecheck、`.app` 构建和真实音频功能仍需本机验收。

具体步骤见 [Mac 本机验收](docs/Mac本机验收.md)。准确率、实际翻译延迟、会议持续录音稳定性尚未经过 Mac 实机测量，不给未经验证的保证。

## 结构

```text
Sources/HearNote/          SwiftUI、录音、系统音、Apple/Whisper 实时识别、Keychain
Sources/HearNoteCore/      Bedrock、模型、本地库、导出
Tests/HearNoteCoreTests/   不产生模型费用的核心测试
Resources/                App 信息、权限用途与签名 entitlement
scripts/build-mac.sh      Mac 测试、构建、打包
scripts/package-mac.sh    将已构建 App 打成 DMG
docs/                     安装与 Mac 实机验收
```

下载与编译完成后，录音、转写、回听和本地笔记在 Mac 内执行，Bedrock 调用从 Mac 发起。

后续修改应按 [AGENTS.md](AGENTS.md) 完成检查、提交并推送到私有 GitHub 仓库；本机 Claude／Codex 的使用说明见安装文档。

## 官方接口依据

- Bedrock API key：https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-use.html

- Converse：https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_Converse.html

- Bedrock Chat Completions：https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html

- Bedrock Responses：https://docs.aws.amazon.com/bedrock/latest/userguide/inference-responses-api.html

- Apple Speech：https://developer.apple.com/documentation/speech/sfspeechrecognizer

- ScreenCaptureKit：https://developer.apple.com/documentation/screencapturekit

- Keychain：https://developer.apple.com/documentation/security/keychain-services

- WhisperKit v1.1.1：https://github.com/argmaxinc/WhisperKit/tree/v1.1.1

- Sonnet 5.5 模型卡：https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5-5.html

- Kimi K3 模型卡：https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-moonshot-ai-kimi-k3.html

- GLM 5.3 模型卡：https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-zai-glm-5-3.html

- GPT 5.6 Sol 模型卡：https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-sol.html

- Z.AI 官方型号目录：https://docs.aws.amazon.com/bedrock/latest/userguide/model-cards-zai.html

- iPhone 翻译功能参考：https://support.apple.com/guide/iphone/translate-text-voice-and-conversations-iph22b7291e3/ios

- Apple Vision OCR：https://developer.apple.com/documentation/vision/recognizing-text-in-images
