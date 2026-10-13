---
name: video-editing
description: 读取真实媒体项目，调整剪辑时长并回读验证，保留音频和其他代理的调色修改。
version: "1.0"
required-tools:
  - read_media_project
  - set_cut_duration
---
# 真实媒体项目剪辑

1. 调用 `read_media_project`，读取源视频信息、当前项目版本和计划时长。
2. 按分配目标调用 `set_cut_duration`，设置 `durationSeconds`，保持 `preserveAudio: true`。
3. 再次调用 `read_media_project`，核验计划时长及音频保留设置。
4. 只负责时长，不修改曝光或白平衡。其他代理可能同时调色，不把其字段恢复为旧值。
5. 向主代理报告读取与修改的证据。项目文件保存的是编辑计划，主代理负责最终导出媒体。
