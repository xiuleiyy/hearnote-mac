# HearNote

开始工作前，阅读并遵守本目录的 `AGENTS.md`。

本项目每次完成源码、测试、文档或构建脚本修改后，都要检查、commit 并 push 至 `xiuleiyy/hearnote-mac`，核对远端提交。用户于 2026-11-12 明确要求仓库改为 public，覆盖此前 private 要求；不得包含密钥、真实录音或私人交接资料。此同步已获用户授权，无需重复询问。

用户已授权以后每次更新发布 GitHub Releases，并只保留最近三个由发布流程管理的版本。推送 `main` 后等待 Mac 构建和自动发布成功，核对最新版安装包及校验值；新版本确认成功后才清理旧 Release，保留 Git tag。不要把仅上传 Actions artifact 当作 Release 已发布。详见 `AGENTS.md`。

安装与功能验证分别见 `docs/安装使用.md`、`docs/Mac本机验收.md`。真实密钥和用户数据不得进入 Git。
