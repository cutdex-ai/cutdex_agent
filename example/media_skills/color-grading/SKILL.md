---
name: color-grading
description: 读取真实媒体项目，设置曝光与白平衡并回读验证，保留其他代理的剪辑修改。
version: "1.0"
required-tools:
  - read_media_project
  - set_color_grade
---
# 真实媒体项目调色

1. 调用 `read_media_project`，读取当前项目版本、曝光和白平衡。
2. 按分配目标调用 `set_color_grade`，设置 `exposureEv` 和 `whiteBalanceKelvin`。
3. 再次调用 `read_media_project`，核验自己的曝光与白平衡目标已生效。
4. 只负责调色，不修改时长与音频。其他代理可能同时剪辑，不把其字段恢复为旧值。
5. 向主代理报告实际证据。主代理将最新剪辑与调色计划一起导出成视频。
