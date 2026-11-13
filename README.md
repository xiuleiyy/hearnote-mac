# 听译 · HearNote for Mac

原生 SwiftUI Mac App：录制麦克风和会议软件声音，实时显示原文与翻译，会议后生成带时间戳的摘要、决定和待办。App 在 Mac 本机运行，直接连接所选 Bedrock Region。

首版以速度和准确性为目标：先显示实时原文，稳定后翻译；重点核对人名、数字、专业术语、否定词和不确定表述。Region 和模型的选择以本机实际延迟与译文核对结果为依据。

独立“翻译”页面参考 iPhone 自带翻译的文字、语音、对话和收藏流程。它与会议记录共用 Bedrock API Key、Region、模型和术语表。详见 [安装使用](docs/安装使用.md) 和 [Mac 本机验收](docs/Mac本机验收.md)。

## 下载与安装

打开 [最新版下载](https://github.com/xiuleiyy/hearnote-mac/releases/latest)，在 Assets 下载 `HearNote-Mac-arm64.dmg`。仓库为 public，同事使用浏览器下载 Release 无需 GitHub 账号。

支持 Apple Silicon Mac、macOS 14+；双击 DMG，将“听译”拖到 Applications 后启动，不需要 Xcode。首次使用配置自己的 Bedrock API Key、授予录音权限并准备语音模型，详见安装说明。

### 首次打开被 macOS 拦截

当前安装包采用 ad-hoc 签名，尚未做 Developer ID 签名或 Apple 公证。首次可能显示 **“听译” Not Opened**、**Apple could not verify…** 或“Apple 无法验证”。

确认 App 来自上面的 GitHub Releases 后，按以下步骤打开：

1. 在提示中点击 **Done（完成）**，保留 App。

2. 打开 **系统设置 → 隐私与安全性**，向下找到“听译”被阻止的提示，点击 **仍要打开（Open Anyway）**。

3. 验证密码或 Touch ID，再点击 **打开（Open）**。

若没有“仍要打开”，重新尝试启动听译，再返回此设置页。授权后，这次安装通常可直接双击打开。完整说明见 [首次打开被拦截](docs/安装使用.md#首次打开被-macos-拦截)；步骤依据 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

### 更新与发布

每次 `main` 更新通过 Mac 构建与检查后，自动发布最新 Release。新安装包上传并回下载校验成功后才更新 Latest，保留最近三个由此流程发布的版本，Git tag 保留。源码、构建日志和修复 diff 继续存放在 Actions artifact。

## 首版功能

| 功能 | 当前实现 |
|---|---|
| 录音来源 | 麦克风、系统声音、同时录制；系统音包含 Zoom、飞书等软件播放的声音 |
| 外放双源 | 系统声音作为参考，使用本地 SpeexDSP 尝试消除麦克风中的回声；显示实际处理与参考覆盖状态，参考缺失时透传原音，结束保存后另保留原始音轨 |
| 实时转写 | 默认本地 WhisperKit；中英混合在中文／英文之间检测；单语可选 Apple，macOS 26 使用新的本地 SpeechAnalyzer |
| 实时翻译 | Bedrock 文字模型；Whisper 当前句增补并保护常见否定、数字和单位边界；单段失败有限重试后可手动重试，后续段继续；原文修订立即撤下旧译文 |
| 实时字幕 | 会议直接在主窗口中记录；原文在上、金色译文在下；字幕占据主区域，底部详情可折叠并拖动高度，可跟随最新或暂停回看 |
| 译文与操作状态 | 翻译页可读已有全文或有效逐段译文；全文操作暂停时显示原因与下一步，只读原文保持清晰 |
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

默认选用 Claude Sonnet 5.5，另有 Kimi K3（Kimi 3）、GLM 5.3、GPT 5.6 Sol、GPT 6 Luna 作为对比候选。

| 预置型号 | 完整 Bedrock model ID |
|---|---|
| Claude Sonnet 5.5，默认 | `global.anthropic.claude-sonnet-5-5` |
| Kimi K3 | `global.moonshotai.kimi-k3` |
| GLM 5.3 | `global.zai.glm-5.3` |
| GPT 5.6 Sol | `global.openai.gpt-5.6-sol` |
| GPT 6 Luna | `global.openai.gpt-6-luna` |

当前预置包含 GLM 5.3。GLM 5.2 的可调用 Bedrock ID 尚未核实，未将其预置；取得可验证的 ID 后可在设置中添加。

旧版本已保存的内置 Sonnet／Qwen 配置会升级；旧内置 Kimi K3.1 会换成 K3。此次升级只补入 GPT 6 Luna，保留当前选中型号、Region 和其他自定义配置；之后删除 Luna 不会每次重新添加。当前 API Key 是否可用仍以连接测试为准；官方 GLM 卡注明仅符合条件的客户可访问。连接测试真实调用所选模型并显示总耗时。五个型号均采用支持东京（`ap-northeast-1`）和美国东部（`us-east-1`）入口的 Global profile；入口不限定实际推理所在地区，厂商国别也不等于数据所在地区。

App 自动按型号适配：Sonnet 使用 Converse 的 `between_tools` 与低 effort；Kimi 使用 Bedrock Chat Completions、关闭推理；GLM 使用 Converse、低 effort，无法关闭推理；GPT 使用 Bedrock Responses、关闭推理。均使用同一个用户 Bedrock API Key，无需其他厂商 Key。用户自行添加的其他型号沿用文本 Converse。

服务端明确返回 token 限流时，App 显示对应中文说明和经过校验的 Request ID，不回显原始服务端正文。HTTP 429 本身不能区分分钟额度、每日额度和模型容量，不能只靠换 Region 或反复点击认定已经解决。详见 [模型选择与限流排查](docs/Bedrock模型与限流.md)。

## 在 Mac 上构建

需要 macOS 14+、Swift 5.10+ 和已完成首次初始化的完整 Xcode。要编译新的 Apple 本地识别分支，使用 Xcode 26+、Swift 6.2+ 和 macOS 26 SDK；交付 CI 会检查这一条件。Core 测试需要 Xcode 提供的 XCTest，仅安装 Command Line Tools 不够。首次构建会从 GitHub 下载精确版本 `1.1.1` 的 WhisperKit 和它的依赖。
交付 CI 使用标准 `macos-15` Apple Silicon runner，显式选择 Xcode 26.2（Swift 6.2.3／macOS 26.2 SDK）；App 的安装目标是 macOS 14+，macOS 26 的新语音运行路径需在 Mac 26 上验收。

仓库为 public，可直接取得源码：

```bash
git clone https://github.com/xiuleiyy/hearnote-mac.git
cd hearnote-mac
bash scripts/build-mac.sh --open
```

也可双击 `开始使用.command`。首次缺少编译工具时，安装并打开完整 Xcode，完成许可证与组件初始化，再在 Xcode → Settings → Locations 选择编译工具。

脚本先执行 `swift test`，再编译并生成 `dist/听译.app`，复制依赖的资源 bundle，最后做本地 ad-hoc 签名。构建不安装后台服务，不发布 App Store。生成的 `.app` 可复制到 Mac 的 `/Applications`；当前未进行 Developer ID 签名或公证。

本机验收成功后执行 `bash scripts/package-mac.sh`，生成 `dist/听译.dmg`；打开后将 App 拖到 Applications。该脚本使用已构建的 App，不重复编译和测试。

仓库的“Mac 安装包”GitHub Actions 使用 macOS arm64 runner 运行相同构建脚本。成功时自动把 App ZIP、DMG、安装说明与 SHA-256 发布到 Releases；含依赖锁文件的源码 ZIP、真实日志和修复 diff 仍可在成功运行的 Artifacts 下载 `HearNote-Mac-arm64`。CI 验证构建、签名、移动后启动与镜像挂载，音频、GUI 和真实模型调用仍需 Mac 功能验收。

## 独立翻译

侧栏点“翻译”（或 `⌘⇧T`）。默认自动识别并中英双向：中文译英文、英文译中文；也可选固定原文／目标语言，交换语言后继续翻译。

- 文字：输入或粘贴，再点“翻译”或 `⌘Return`。短文本只发一次翻译请求，不另外请求语言检测、摘要或润色；不在每次按键时调用模型。

- 语音：点麦克风，先显示识别原文；说完结束，按这一轮语音生成译文。多语种识别复用已准备的本地 Whisper 模型，与会议录音互斥。

- 对话：中文和英文双方轮流点自己的语音按钮；每轮保存原文和译文，支持复制、朗读和收藏。

- 图片：导入图片或截图，本地 OCR 后先检查文字再翻译。OCR 错误可在输入框直接校对。

- 历史与收藏：译文成功且对应当前输入后保存到本机独立记录；失败、截断和已取消结果不保存。原文、语种或模型改变时，旧请求不能覆盖新结果。

翻译需要连接所选 Bedrock endpoint；本地识别模型准备完成后，语音识别和图片文字识别在 Mac 内执行。译文可由 macOS 语音朗读，具体声音与语言支持以本机为准。独立翻译的 Mac UI、麦克风、OCR 与朗读仍需按 [Mac 本机验收](docs/Mac本机验收.md) 实测。

会议字幕的组句、局部翻译失败与停止录音处理见 [实时字幕与失败恢复](docs/实时字幕与失败恢复.md)。构建成功与回归测试通过不代表实际录音的识别准确度已经达标。

## 第一次使用

1. 在配置页粘贴自己的 Bedrock API Key。Region 和模型已经预选，无需填写其他认证信息。

2. 点击“测试连接”，成功后保存。需要时可调整 Region，展开“添加或管理模型”添加其他模型。可以跳过配置，先使用录音、转写和校对。

3. 点击“开始会议录音”，选择声音来源。会议语言默认 English，翻译目标默认“简体中文”；中英交替或同句混用选“中英混合”，需要双向翻译时选择“中英双向”。默认本地 Whisper，不依赖 Siri／听写。可提前“准备模型”；首次需要下载模型与 tokenizer，后续复用缓存。直接开始时先录音、后台准备识别；模型就绪后识别新声音，准备期间的音频会后点击“重新转写”。首次使用按所选来源允许麦克风、系统录制。

4. 按需要开启“实时翻译”；可在会议中随时关闭或重新开启。关闭期间只保存录音与原文，重新开启后翻译新产生的稳定文字；不自动补翻关闭期间的内容。结束后保存，可点击“生成摘要”或“翻译全文”，导出需要的结果。

会议页集成在主窗口中，可拖动标题栏、拖拽边缘调整大小。字幕原文与译文上下逐段对应；窗口拉高时字幕区随之增高。语言、实时翻译和简短收音状态位于底部，点击“详情”查看完整识别状态，展开后可拖动分隔线调整高度；“结束并保存”固定可见。关闭“跟随最新”可回看，点击“回到最新”恢复跟随。录音时可以返回笔记或翻译页，侧栏“返回当前会议”回到同一场录音；切换页面不结束录音，只有“结束并保存”结束会议。

主窗口红色 ❌ 缩小到 Dock，录音、识别与翻译继续；点击 Dock 恢复。`⌘W` 关闭窗口不会退出，真正退出使用 `⌘Q` 或退出菜单，并先保存当前录音。用户启动的录音与翻译任务进行期间持有后台工作保护，完成或取消后释放，避免窗口收起后被 App Nap 节流。

为了准确性，可以在设置里添加常用专有词与 `原词=译法` 术语表。建议戴耳机减少麦克风重复收录会议音频。系统音模式录制全部系统声音，不要求在 Zoom / 飞书内打开屏幕共享，也不保存屏幕图像。

## 数据位置

- 笔记和媒体：`~/Library/Application Support/HearNote/`。

- 保存后的录音：`~/Library/Application Support/HearNote/media/`。笔记“导出”菜单可在 Finder 中显示对应录音。

- 新会议的原始音轨：`~/Library/Application Support/HearNote/Recording/Originals/<会话 UUID>/`，按录制时间查找。包含原始麦克风、系统声音和双源处理后的麦克风；只保存在本机，会额外占用磁盘空间。旧版已删除的原音无法补回。详见 [外放回声消除](docs/外放回声消除.md)。

- 独立翻译历史：`~/Library/Application Support/HearNote/translation-history.json`；不含 API Key。

- key：macOS Keychain，service `app.hearnote.mac.bedrock`。

- 会议默认 English、本地 Whisper，实时翻译目标为“简体中文”；旧版本首次升级会更新这两个语言默认，之后保留手动选择。旧设置没有识别方式字段时也默认 Whisper。English 使用同一模型并固定英文；“中英混合”限制候选为中文／英文。独立翻译页有自己的语言设置。单语可选 [Apple 本地识别](docs/Apple本地识别.md)：macOS 26 的新接口无需开启 Siri／听写，首次可能下载 Apple 系统语言资源；旧系统保留原接口及明确选择的联网选项。

- 本地 Whisper 使用 WhisperKit 1.1.1／Core ML，默认 Large v3 Turbo，亦可选 Small；会议状态显示实际加载型号。字幕按词时间戳、句末标点和停顿组句，当前未完句持续补全，跨解码窗口保留。没有句界的长发言有长度上限，避免译文一直等待；不会调用大模型改写原文。旧笔记保留原分段，需用户主动重新转写后才应用新逻辑。

- 本地识别模型下载到 `~/Library/Application Support/HearNote/WhisperModels/`，记住实际缓存目录。界面区分文件下载、预热、模型与 tokenizer 加载，显示 SDK 文件准备百分比与耗时；百分比不是字节量。模型来自 Hugging Face，准备速度与 Bedrock Region 无关。完整离线模型目录还须有 tokenizer 文件；可比较两种模型在本机的速度与错误，不预先保证每台 Mac 都能实时。

- 翻译与摘要将对应文字发送到所选 Bedrock endpoint。原始录音不发给 Bedrock。使用跨区域 inference profile 时，入口 Region 不等于实际推理 Region。

- App 仅使用用户填写的 Bedrock API Key 认证，不读取 AWS CLI 或 SSO 配置。

## 验证状态

本机反馈发现播放器析构的 actor 隔离编译错误，以及测试 mock 未读取 Darwin 请求体 stream。这两处已修复，并按 Mac CI 的实际结果修正 Key 的控制字符校验。Core XCTest 包含导出、本地库、API Key 调用、多模型协议、中英双向请求、实时翻译开关、排队、修订保护、逐段译文、Whisper 技术占位清理、请求体 stream 和 Key 校验回归。数量与 macOS 完整构建结果以对应提交的“Mac 安装包”CI 日志为准。

具体步骤见 [Mac 本机验收](docs/Mac本机验收.md)。准确率、实际翻译延迟、会议持续录音稳定性尚未经过 Mac 实机测量，不给未经验证的保证。

## 结构

```text
Sources/HearNote/          SwiftUI、录音、系统音、Apple/Whisper 实时识别、Keychain
Sources/HearNoteCore/      Bedrock、模型、本地库、导出
Tests/HearNoteCoreTests/   不产生模型费用的核心测试
Resources/                App 信息、权限用途、原创图标与签名 entitlement
scripts/build-mac.sh      Mac 测试、构建、打包
scripts/package-mac.sh    将已构建 App 打成 DMG
scripts/ci-mac.sh         macOS CI 构建、验证与安装包归档
scripts/verify-mac-build.sh  架构、签名、移动后启动与 DMG 挂载
scripts/release-mac.py    发布成功构建、校验远端资产、保留三个 Release
docs/                     安装与 Mac 实机验收
```

下载与编译完成后，录音、转写、回听和本地笔记在 Mac 内执行，Bedrock 调用从 Mac 发起。

后续修改应按 [AGENTS.md](AGENTS.md) 完成检查、提交并推送到 GitHub 仓库，再核对自动发布结果；本机 Claude／Codex 的使用说明见安装文档。

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

- GPT 6 Luna 模型卡：https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-luna.html

- Z.AI 官方型号目录：https://docs.aws.amazon.com/bedrock/latest/userguide/model-cards-zai.html

- iPhone 翻译功能参考：https://support.apple.com/guide/iphone/translate-text-voice-and-conversations-iph22b7291e3/ios

- Apple Vision OCR：https://developer.apple.com/documentation/vision/recognizing-text-in-images
