# 物语

物语（Monogatari）基于 [Kazumi](https://github.com/Predidit/Kazumi) 二次开发。

番剧资料来自 Bangumi，播放内容通过内置视频站点 API 自动查找。
播放优先使用 1080 资源站；当前站点没有对应番剧、集数或无法播放时，依次自动尝试暴风和[量子](https://lzizy1.com/)。
应用自动匹配番剧与集数，用户只需选择集数，无需安装规则或选择播放来源。

本项目按 [GNU GPL v3](LICENSE) 开源，保留原项目的许可与作者信息；第三方组件的许可随相应文件保留。

正式安装包在本仓库的 [GitHub Releases](https://github.com/Teikaraku/monogatari-anime/releases/latest) 下载。Android 按设备架构提供 APK，Windows 提供完整便携 ZIP，iOS 提供下载后自行签名的 IPA。三端都检查 GitHub 新版本；iOS 选择更新后在浏览器打开 IPA 下载地址。

生产构建由 `.github/workflows/release.yaml` 完成。推送 `monogatari-v*` 标签、`codex/production-*` 分支或手动运行工作流，会先检查与测试，再构建三端；全部成功后上传安装包和 SHA256 校验文件并公开发行版。

Android 正式构建需要 `MONOGATARI_ANDROID_KEYSTORE_BASE64`、`MONOGATARI_ANDROID_KEYSTORE_PASSWORD`、`MONOGATARI_ANDROID_KEY_ALIAS`、`MONOGATARI_ANDROID_KEY_PASSWORD` 四个 Actions Secrets。本地构建使用不提交的 `android/key.properties`，正式包不会回退到调试签名。
