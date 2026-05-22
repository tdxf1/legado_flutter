# T2 Followup — 仿真翻页 prev 镜像未完成项 (backlog)

## 状态

⏸ **暂搁置** — 用户实机反馈"还有点问题"但当时没时间复现详述。等用户后续再次提供具体现象后激活。

## 上游

T2（archive 在 `.trellis/tasks/archive/2026-05/05-18-simulation-prev-mirror-md3/`）已完成主要镜像逻辑：
- `_setDirectionMirrorCorner(dir)` 镜像 cornerXY
- `prevPageByAnim` 走 tap 落点 → 镜像 → 重置 (0, h) → lerp (2w, h)
- `onDragUpdate` 方向首次确定时应用镜像
- 测试 225/225 全绿

APK：`dist/legado-arm64-debug-T2-prev-mirror.apk`，commit `4721d57`。

## 用户报告

"还有点问题 接下来时间我没法测试先不修 记录下来去做其他的"

具体现象未给出。可能涉及：
- 视觉细节不完全对齐 MD3 期望
- drag prev 的 corner 镜像在方向切换边界帧的闪烁
- 跨章 prev 路径的镜像残留（commit 后下一次 prev 行为）
- lerp 终点 (2w, h) 屏外是否让动画"过早结束感"

## 重启时操作清单

1. 让用户描述具体现象（哪种翻页方式？哪一帧不对？）
2. 实机抓 logcat（已有 `[SimulationDelegate]` debug 日志可用）
3. 对照 MD3 SimulationPageDelegate.kt L188-L206 / L208-L239 复核数值
4. 检查 cross-chapter prev：commit 后 onDragUpdate 是否再次正确镜像
5. 必要时回看 MD3 `onAnimStart` (L208-L239) PREV 分支 dx/dy 公式，
   看 lerp 终点 (2w, h) 与 MD3 `dx = viewWidth - touchX = w` (touch=(0, h)
   时 dx=w → 终点 (w, h)) 的差异是否引入了"过头一帧"

## 候选修复方向

如果是 lerp 终点过远导致末段动画"飞过去"：
- 把终点拉回 (w, h) 但在 _calcPoints 入口加 NaN 兜底（_touchX→cornerX 时
  返回上一帧 _bv* 值）
- 或 lerp 终点 `(w, h - 1)` 微偏一像素破奇点

如果是镜像逻辑边界 case：
- 加更多 `debugPrint('[SimulationDelegate] mirror dir=$dir start=$startTouch corner=($_cornerX, $_cornerY)')`
- 实机抓帧对照

## 不阻塞

T4（drag 回滚阈值）独立，不依赖 T2 完美。可先开 T4。
