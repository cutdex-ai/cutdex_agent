---
name: video-editing
description: 读取素材并按目标时长剪辑，保留原始音频。
version: "1.0"
required-tools:
  - read_example_clip
  - trim_example_clip
---
# 视频剪辑示例流程

1. 调用 `read_example_clip`，确认素材的实际时长与音频状态。
2. 将时长缩短到用户要求的 10 秒，素材不足 10 秒时保留原长度。
3. 调用 `trim_example_clip`，传入 `durationSeconds`，并设置 `preserveAudio: true`。
4. 再次调用 `read_example_clip`，确认最终时长正确且原始音频仍然保留。
5. 根据回读结果报告完成情况。
