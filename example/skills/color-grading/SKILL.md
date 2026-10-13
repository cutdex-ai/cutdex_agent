---
name: color-grading
description: 分析画面曝光与白平衡，执行调色并回读验证结果。
version: "1.0"
required-tools:
  - read_example_color
  - grade_example_clip
---
# 调色示例流程

1. 调用 `read_example_color`，确认素材当前曝光补偿、白平衡、时长和音频状态。
2. 根据用户的目标调用 `grade_example_clip`，传入 `exposureEv` 和 `whiteBalanceKelvin`。
3. 调色时保留素材时长和原始音频，不调整时间线。
4. 再次调用 `read_example_color`，确认目标曝光补偿与白平衡已生效，时长和音频保持不变。
5. 根据回读结果报告完成情况。
