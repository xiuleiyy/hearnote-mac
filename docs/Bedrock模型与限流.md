# Bedrock 模型选择与限流排查

App 只使用用户配置的 Bedrock API Key。首次启动或在设置中填写 Key；模型和 Region 可在主界面切换，Key 保存在 macOS Keychain。

## 东京与美国东部

以下预置使用官方 Global inference profile，支持东京（`ap-northeast-1`）与美国东部（`us-east-1`）入口：

| 型号 | 完整 ID | App 请求接口 | 推理设置 |
|---|---|---|---|
| Claude Sonnet 5.5，默认 | `global.anthropic.claude-sonnet-5-5` | Converse | `between_tools`、低 effort |
| Kimi K3 | `global.moonshotai.kimi-k3` | Chat Completions | `none` |
| GLM 5.3 | `global.zai.glm-5.3` | Converse | `low`，不能关闭推理 |
| GPT 5.6 Sol | `global.openai.gpt-5.6-sol` | Responses | `none` |
| GPT 6 Luna | `global.openai.gpt-6-luna` | Responses | `none` |

App 请求 `bedrock-runtime.<所选 Region>.amazonaws.com`。Global profile 可以将推理路由至其他地区；选择东京不代表模型一定在东京计算。App 不因一次失败暗中切换 Region 或模型。

官方支持入口与账号实际可调用是两个条件。每次更换 Region／型号后，在设置中运行连接测试，再用短文本核对译文。GLM 5.3 的官方模型卡另注明客户资格限制。

## 选择两款 GPT

GPT 6 Luna 和 GPT 5.6 Sol 使用同一 Responses 接口，并显式关闭推理，适合按相同文字、目标语言和术语表比较。升级会补入 Luna，保留已经选中的型号；以后自行删除 Luna，重新启动不会再补入。

先核对人名、数字、单位、否定词、专业术语与不确定性，再比较完整译文返回的耗时。“请求成功”不等于“译文准确”，连接测试的 `OK` 耗时也不等于会议翻译速度。机器所处地区、网络与样例长度影响结果，不能将海外开发机器的测速直接当成北京 Mac 的延迟。

## HTTP 429 的含义

429 表示服务端限制了本次请求。若服务端明确返回 `Too many tokens, please wait before trying again.`，App 会说明此次是 token 限流，并显示合法的 Request ID 供排查；不会展示原始服务端正文或请求头。

这个短错误没有说明限制来自分钟 token 配额、每日额度还是当前容量，不能据此断言 Key 失效、余额不足或型号不存在。检查方法：

1. 等待后重试一次短文本，记录时间、Region、完整模型 ID、错误提示与 Request ID。App 的实时翻译保留全局限流冷却和有界自动重试，不立即连续重发所有片段。

2. 换另一款可调用型号做控制测试。如果同一 Key 的其他型号成功，而目标型号持续 429，应针对目标型号排查额度与可用容量。

3. 在 AWS 控制台切到实际入口 Region，查看对应型号的 Global cross-Region 请求数／token 配额、调用量和每日限制。申请额度或确认客户资格需要账号内相应权限；App 中的 Key 不能替代这些管理权限。

4. 如仍无法确定，将时间、Region、型号与 Request ID 提供给 AWS Support，核查该账号的限流原因。不要提供 API Key、Authorization 请求头或真实会议内容。

降低 `max_tokens` 可减少输出预留；App 同时需要足够预算避免半截译文。若最小短请求仍限流，继续缩短文字、换 UI 或反复点击不能证明问题已解决。切换到同样限流的另一个入口也不能保证恢复。

## 官方资料

- [GPT 6 Luna](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-6-luna.html)

- [GPT 5.6 Sol](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-56-sol.html)

- [Kimi K3](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-moonshot-ai-kimi-k3.html)

- [GLM 5.3](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-zai-glm-5-3.html)

- [Global cross-Region inference](https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html)

- [Token 配额与输出预留](https://docs.aws.amazon.com/bedrock/latest/userguide/quotas-token-burndown.html)

- [AWS 官方限流排查](https://repost.aws/knowledge-center/bedrock-throttling-error)
