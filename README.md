# candysign-mirror-monitor

小电拼菜单栏工具（非官方）。

采用 [MIT License](LICENSE)，Copyright (c) 2026 HuskyNie。

macOS 13+ 原生 AppKit 应用，通过局域网读取小电拼 IonBridge 的 `/metrics.json`。每 2 秒刷新，菜单栏显示 USB 总输出功率，点击查看 C1～C4、USB-A 的当前协议、电压、电流、功率及连接状态。鼠标悬浮在端口整行，即可向侧边展开二级详情，无需点击箭头或打开窗口。

菜单栏采用适配深浅色模式的单色充电图标；未连接时显示斜杠图标并隐藏文字，点击仍可查看详情。应用图标由 `Sources/Artwork.swift` 中的矢量绘制代码生成，构建时自动打包各尺寸图标。

## 构建与运行

需要 Apple Command Line Tools（`swiftc`），无第三方依赖。

```sh
bash scripts/test.sh
bash scripts/test-ui.sh
bash scripts/build.sh
open "build/.artifacts/Mirror Monitor.app"
```

首次启动输入设备局域网 IP；之后可在「设备地址…」中更改。地址保存在本机 UserDefaults，不写进源码。可将应用复制到「应用程序」，按需在 macOS「登录项」中添加。

调试时可运行 `build/.artifacts/Mirror Monitor.app/Contents/MacOS/MirrorMonitor --probe <设备IP>`，使用与界面相同的解析与网络代码读取一次数据。`open` 启动可附加 `--args --host <设备IP> --show` 设置地址并展开面板。

实机集成验证：`build/.artifacts/Mirror Monitor.app/Contents/MacOS/MirrorMonitor --host <设备IP> --verify`，连续读取三次，校验实际界面文本、五行数据和面板边界，并模拟应用内离线状态后验证下一次轮询恢复；完成后自动退出。该模拟不操作设备或电脑的网络。

若 macOS 弹出本地网络访问提示，选择允许；若已拒绝，在系统设置的「隐私与安全性 → 本地网络」里允许小电拼。设备和电脑需处于可互访的局域网。

## 数据口径

- 固件上报电压单位 mV、电流单位 mA，显示时分别除以 1000；功率为 V × A。
- 总功率为已连接 USB 端口功率之和，不含 AC 插座和充电器自身损耗。
- 协议来自 `fc_protocol`，不是用电压猜测。未识别编号直接显示编号，未连接显示横线。
- 本机验证的端口布局是 id 0 = USB-A、id 1～4 = C1～C4。
- 无快充协议显示「普通充电」；PD 固定高压不会冒称 PD 3.1/3.2，因为该字段不足以区分版本。
- 请求超时 4 秒；不重叠请求，不缓存 HTTP 响应，不跟随跳转。错误时显示离线及最后成功时间，旧数据变灰，自动重试；睡眠暂停，唤醒恢复。
- 仅请求 `/metrics.json` 和 `/porthistoryz?limit=180`，不修改充电策略、端口开关、MQTT 或固件。只接受私有 IPv4 / 链路本地 IPv4 / `.local` 主机名，不使用系统代理。

## 协议来源

- [官方本地接口及 FastChargingProtocol 枚举](https://thecandysign.com/cocan/zh/mqtt/reference/)
- [官方 IonBridge 固件](https://github.com/ifanrx/IonBridge)，`components/port/include/port_data.h` 标明 mV、mA 及功率换算。

应用采用本地 ad-hoc 签名，未进行开发者公证。构建产物在 `build/`，不纳入 Git。

## 隐私与源码发布

设备地址只保存在本机 UserDefaults，源码中的 IP 均为测试或输入示例。应用只向配置的局域网设备请求状态，不上传数据。诊断命令会在本地终端显示端口数据；共享诊断输出或截图前请检查其中的设备地址。

使用 Git 推送源码即可，`build/`、本地环境文件、日志和常见私钥文件已忽略。不要将整个工作目录（含 `.git/` 和构建缓存）打包作为源码发布。提交作者邮箱属于 Git 历史元数据，公开发布前应确认是否使用 GitHub 提供的 noreply 地址。

## 端口二级详情（1.2.4）

- 本次累计输出直接读取硬件 `session_charge`（µWs），除以 3,600,000,000 转为 Wh；时长直接读取 `charging_duration_seconds`。这不是今日电量，也不是电池实际增加的能量。
- 分配功率上限来自 `power_budget`，不代表当前功率或线材额定功率。
- 近 30 分钟曲线读取硬件历史，当前固件为 180 个 10 秒样本。按接口采样周期计算覆盖时长；不足 30 分钟时显示实际覆盖时长，不补齐。
- 历史输出量按采样电压 × 电流 × 采样周期估算；平均和峰值都基于采样，不能代表瞬时峰值。
- 使用自定义主浮层和侧边详情卡片；端口整行高 56 点，悬浮或点击均可展开。没有原生级联菜单，也不打开带标题栏的独立窗口。悬浮展开详情时每 10 秒刷新历史，收起或电脑睡眠后停止，重新展开时重新读取。实时数据复用主菜单的轮询，不为每个端口重复请求。数据只保留在内存，不保存历史到磁盘，也不接入云端。
- 线材和 PD 信息来自可选 `pd_status`。缺失显示「未获取」；未检测到 eMarker 时不把默认零值解读为 USB 2.0 / 20 V 线材。USB 速率是线材声明能力，不是实测传输速率。
- HTTP JSON 协商电压、电流按 mV / mA 解析（与官方 Dashboard 一致），不同于底层结构体的 10 mV / 10 mA 单位。PD 修订编码 0/1/2 对应 1.0/2.0/3.0，3 为保留值；未知值保留编号。已识别 PD 协议但 pd_status 为空时，分别显示协议与详情未获取。
- 请求失败会清除详情中的对应数值并提示未获取；历史失败不影响会话数据显示。

可用 `open "build/.artifacts/Mirror Monitor.app" --args --show` 展开主浮层。`--verify` 检查五个自定义悬浮入口与侧边卡片、实机数据、历史、布局和断线恢复，并将 C4 的临时布局预览写到 `/private/tmp/mirror-detail-preview.png`；这是手动验证专用输出，正常运行不会写入。

构建产物位于 `build/.artifacts/` 隐藏目录，日常只启动安装在 `~/Applications/` 的副本，避免系统搜索同时收录安装版和构建版。优先在「设备地址」中配置设备的 `.local` 名称，以跟随 DHCP 地址变化。

主浮层与侧边卡片保持联动，鼠标可跨越间隙进入详情；悬浮其他端口直接切换。点击外部、按 Esc、再次点击菜单栏图标时统一收起；空间不足时详情自动显示在左侧，内容过长可滚动。

`--verify-ui` 使用内置模拟数据验证主面板、五个悬浮回调、侧边卡片位置和统一收起，不发起设备请求；它不是实机连接验收。临时预览输出为 `/private/tmp/mirror-main-preview.png` 和 `/private/tmp/mirror-detail-preview.png`。

鼠标离开当前端口和二级详情后延迟 280 ms 收起二级卡片；跨越间隙进入详情、重新进入当前端口或切换端口时取消旧的收起任务。主面板保持展开。`--verify-ui` 包含这五种悬浮退出回归检查。

1.2.4：一级端口行同时显示协议、电压、电流（A，三位小数）与功率。状态栏使用鼠标按下时切换，外部事件监听通过屏幕上的按钮边界排除状态栏点击，避免先关闭再被按钮重新打开；不异步延迟关闭以免影响后续打开。

线材状态区分 USB-A 不适用、USB-C 未连接、未检测到 eMarker 和设备未上报。设备返回 `pd_status: null` 时应用无法取得线材规格，不以实时功率猜测额定能力，也不把空值当作无 eMarker。`--verify-ui` 额外覆盖重复点击、没有窗口身份的状态栏事件、外部关闭后重新打开及一级菜单电流文本和宽度。
