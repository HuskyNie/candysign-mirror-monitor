# candysign-mirror-monitor

小电拼菜单栏工具（非官方）。

采用 [MIT License](LICENSE)，Copyright (c) 2026 HuskyNie。

macOS 13+ 原生 AppKit 应用，通过局域网读取小电拼 IonBridge 的 `/metrics.json`。每 2 秒刷新，菜单栏显示 USB 总输出功率，点击查看 C1～C4、USB-A 的当前协议、电压、电流、功率及连接状态。

菜单栏采用适配深浅色模式的单色充电图标；未连接时显示斜杠图标并隐藏文字，点击仍可查看详情。应用图标由 `Sources/Artwork.swift` 中的矢量绘制代码生成，构建时自动打包各尺寸图标。

## 构建与运行

需要 Apple Command Line Tools（`swiftc`），无第三方依赖。

```sh
bash scripts/test.sh
bash scripts/build.sh
open "build/Mirror Monitor.app"
```

首次启动输入设备局域网 IP；之后可在「设备地址…」中更改。地址保存在本机 UserDefaults，不写进源码。可将应用复制到「应用程序」，按需在 macOS「登录项」中添加。

调试时可运行 `build/Mirror Monitor.app/Contents/MacOS/MirrorMonitor --probe <设备IP>`，使用与界面相同的解析与网络代码读取一次数据。`open` 启动可附加 `--args --host <设备IP> --show` 设置地址并展开面板。

实机集成验证：`build/Mirror Monitor.app/Contents/MacOS/MirrorMonitor --host <设备IP> --verify`，连续读取三次，校验实际界面文本、五行数据和面板边界，并模拟应用内离线状态后验证下一次轮询恢复；完成后自动退出。该模拟不操作设备或电脑的网络。

若 macOS 弹出本地网络访问提示，选择允许；若已拒绝，在系统设置的「隐私与安全性 → 本地网络」里允许小电拼。设备和电脑需处于可互访的局域网。

## 数据口径

- 固件上报电压单位 mV、电流单位 mA，显示时分别除以 1000；功率为 V × A。
- 总功率为已连接 USB 端口功率之和，不含 AC 插座和充电器自身损耗。
- 协议来自 `fc_protocol`，不是用电压猜测。未识别编号直接显示编号，未连接显示横线。
- 本机验证的端口布局是 id 0 = USB-A、id 1～4 = C1～C4。
- 无快充协议显示「普通充电」；PD 固定高压不会冒称 PD 3.1/3.2，因为该字段不足以区分版本。
- 请求超时 4 秒；不重叠请求，不缓存 HTTP 响应，不跟随跳转。错误时显示离线及最后成功时间，旧数据变灰，自动重试；睡眠暂停，唤醒恢复。
- 仅请求 `/metrics.json`，不修改充电策略、端口开关、MQTT 或固件。只接受私有 IPv4 / 链路本地 IPv4 / `.local` 主机名，不使用系统代理。

## 协议来源

- [官方本地接口及 FastChargingProtocol 枚举](https://thecandysign.com/cocan/zh/mqtt/reference/)
- [官方 IonBridge 固件](https://github.com/ifanrx/IonBridge)，`components/port/include/port_data.h` 标明 mV、mA 及功率换算。

应用采用本地 ad-hoc 签名，未进行开发者公证。构建产物在 `build/`，不纳入 Git。

## 隐私与源码发布

设备地址只保存在本机 UserDefaults，源码中的 IP 均为测试或输入示例。应用只向配置的局域网设备请求状态，不上传数据。诊断命令会在本地终端显示端口数据；共享诊断输出或截图前请检查其中的设备地址。

使用 Git 推送源码即可，`build/`、本地环境文件、日志和常见私钥文件已忽略。不要将整个工作目录（含 `.git/` 和构建缓存）打包作为源码发布。提交作者邮箱属于 Git 历史元数据，公开发布前应确认是否使用 GitHub 提供的 noreply 地址。
