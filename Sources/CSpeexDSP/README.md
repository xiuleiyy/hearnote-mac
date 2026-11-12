# SpeexDSP echo canceller

仅使用 Xiph 官方 SpeexDSP 1.2.1 中的声学回声消除和 KISS FFT 源码。
上游固定提交为 `1b28a0f61bc31162979e1f26f3981fc3637095c8`，来自
`https://github.com/xiph/speexdsp` 的 `SpeexDSP-1.2.1` tag。
`upstream.json` 记录每个未修改上游文件的 SHA-256。

构建使用浮点运算和 KISS FFT；`speexdsp_config_types.h` 根据上游 configure
模板为 macOS / Linux 的 `stdint.h` 类型生成。`CSpeexDSP.h` 是本项目模块入口。
未引入音频设备、网络、编码器、语音识别或额外的降噪预处理。

上游使用 BSD 3-Clause 许可；完整条款见 `COPYING`。各源码保留原版权和许可。
分发二进制时，将此许可及源码内的 KISS FFT 条款一并放入 App 的第三方许可材料。
