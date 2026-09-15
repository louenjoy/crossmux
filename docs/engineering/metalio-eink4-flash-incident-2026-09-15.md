# Metalio E-Ink 4 烧录故障排查记录（2026-09-14 ~ 09-16）

> 记录一次从「点蓝牙诊断崩溃」开始的烧录故障，以及后续一整夜的排查过程、
> 每条报错的含义、根因链条、可复用的设备侧结论，和当前恢复路径。
>
> 目的：给售后（硬件话术）、给未来的自己（恢复步骤）、给后来者（踩坑教训）。
>
> **最终结论（2026-09-16）**：根因是 **flash 器件 `0xEE000` 扇区坏块**，可 100% 确定性复现；
> 与 stub 版本、波特率、供电均无关。详见「根因定位」一节。
>
> **临时修复已实施**：本文是**过程篇**；绕行方案（`app0` 后移至 `0xF0000` 跳过坏块）、
> 复现命令与验证步骤见结论篇
> [`metalio-eink4-bad-sector-bypass.md`](metalio-eink4-bad-sector-bypass.md)。

---

## 摘要（TL;DR）

1. 设备点「蓝牙诊断」崩溃（lwIP 断言，根因已修）。
2. 重烧固件时**写一半中断**，留下半份应用 → 每次开机半途启动 → **看门狗复位循环**。
3. 复位循环持续打断后续所有烧录，flash 芯片被反复搞到「忙/卡死」状态。
4. 反复排查后定位：这板子的**返回键 = BOOT0 = GPIO0**，按住它开机才能进下载模式；esptool 的自动复位在本机原生 USB 上**拉不低 GPIO0**。
5. **根因（已确证）**：`0xEE000`（`otadata` 分区内）是一个**确定性坏扇区** —— 读正常、擦除/写入必掉线；
   相邻 `0xED000`/`0xEF000` 反复成功。这解释了「整块写应用必在 848KB（`0xE4000`）断」与
   「`slice_01 @0x90000` 必失败」两个现象。
6. 与 stub 版本无关：legacy v1 与新版 v2 表现完全相同；与供电无关（供电故障不会只死一个 4KB 扇区）。
7. 处置：**更换 flash 器件**（GigaDevice 68/4018），或临时后移应用区绕过该块。

---

## 背景

Metalio E-Ink 4（ESP32-S3，16MB flash，8MB PSRAM，原生 USB-Serial-JTAG）。
当天已完成：本地音频（16kHz 旋律）验证、NAS 中转 + 网易云 API 验证、设备端流式播放器（`StreamPlayer`）编译通过、设备侧 IPv6 打通。当晚在刷「蓝牙诊断崩溃修复 + 流式地址改为设置项」这版固件时，触发本记录。

---

## 事件时间线

| 时间（约） | 事件 | 结果 |
|---|---|---|
| 09-14 晚 | 点「蓝牙诊断」→ 设备崩溃 | `assert failed: xQueueSemaphoreTake`，panic 后进 Crash 界面 |
| 紧接 | 定位崩溃根因并修复，开始重烧 | 首次烧录写一半失败 `The chip stopped responding` |
| 此后 | 设备进入复位循环（`rst:0x7 TG0WDT`） | 每 ~2.5s 重启一次，打断一切烧录 |
| 反复尝试 | 换波特率 / stub / no-stub / 分块 / 完整写 | 全部在写/擦除阶段掉线 |
| 发现 | `read_flash_status` = `0x0201`（WIP=1） | flash 卡在「忙」状态 |
| 用户断电 | WIP 清零 `0x0200`，但写入仍失败 | 说明还有更深层状态 |
| 查文档 | `Buttons | BOOT0=Back` | 返回键 = GPIO0 |
| 用户按住返回键开机 | `boot:0x1 (DOWNLOAD(USB/UART0))` | 成功进入下载模式 |
| 但仍失败 | 下载模式下写入仍掉线 | 指向供电/更深状态 |
| 用户用另一个窗口分片写 | **第一片 512KB 成功**，后续失败 | 写路径其实是好的 |
| 当前 | bootloader/分区表/boot_app0 已恢复；应用区只写了 512KB | 待分片写完 |
| 09-16 复核 | 6MB 写入在 `0xE4000` 复现；4KB 粒度擦除定位到 `0xEE000` | **确定性坏扇区（介质缺陷）** |

---

## 关键报错字典（按出现顺序）

### 1. 崩溃：`assert failed: xQueueSemaphoreTake queue.c:1709 (( pxQueue ))`

- 回溯解码（`xtensa-esp32s3-elf-addr2line`）指向：
  `BtDiagActivity::onEnter() → runNetworkCheck() → checkRelayHost() → WiFi.hostByName() → lwip_getaddrinfo → tcpip_send_msg_wait_sem → sys_mutex_lock`
- **含义**：在 Wi-Fi 栈从未启动时调用 `WiFi.hostByName()`（此时设备 v4=`0.0.0.0`、v6=`::`），lwIP 的 tcpip 线程 mutex 尚未创建 → 断言。
- **修复**：`runNetworkCheck()` 里先判断 `WiFi.status() != WL_CONNECTED` 再走 DNS/HTTP。

### 2. `rst:0x7 (TG0WDT_SYS_RST)`

- 看门狗复位。半份应用每次启动到一半就挂，看门狗复位 → 循环（约 2.5s 一轮）。
- 这是所有「写操作 ~1s 就掉线」的直接原因之一（操作被下一次复位打断）。

### 3. `boot:0x9 (SPI_FAST_FLASH_BOOT)` vs `boot:0x1 (DOWNLOAD(USB/UART0))`

- 复位后的 `boot:` 值编码启动模式。
- `0x9` = GPIO0 为高，走 SPI 启动（加载应用）→ 半份应用 → 复位循环。
- `0x1` = GPIO0 为低，进下载模式 → `waiting for download`（ROM 安静等待烧录）。
- **本板关键**：esptool 的 `--before default-reset` / `usb-reset` 通过原生 USB-Serial-JTAG **拉不低 GPIO0**（复位后仍是 `boot:0x9`），所以必须**手动按住返回键（BOOT0）开机**才能进下载模式。

### 4. `A fatal error occurred: The chip stopped responding.` / `Serial data stream stopped: Possible serial noise or corruption.`

- 芯片在操作中途从 USB 上消失（不响应 SLIP）。
- 读操作（`flash_id`、读状态、读数据）基本都能过；**擦/写一到就掉**。

### 5. `ClearCommError failed (PermissionError(13, '设备不识别此命令'))` / `Could not open COM6, the port is busy or doesn't exist.`

- Windows 侧 USB 设备进入失败状态（类似 Code 43），或串口句柄卡死。
- 反复复位/掉线太多次会触发；**拔插 USB 可恢复**。

### 6. `Flash memory status: 0x0201` vs `0x0200`

- `0x0201`：WIP（Write In Progress）= 1 → flash 卡在「忙」。
- `0x0200`：WIP = 0，QE = 1（quad 使能，正常）。
- WIP 是只读硬件位，**写状态寄存器清不掉**，只能断电清零。

---

## 根因分析（连锁反应链）

```
① 点蓝牙诊断 → WiFi.hostByName 未启动栈 → lwIP 断言 → 崩溃
        ↓
② 重烧修复固件 → 写一半中断（USB 掉线）
        ↓
③ 半份应用 → 每次开机半途启动 → TG0WDT 复位循环（boot:0x9）
        ↓
④ 复位循环持续打断烧录；多次失败擦除又搞坏 bootloader 头（半残）
        ↓
⑤ ROM 加载半残 bootloader 挂死 → 循环不停；flash 被反复搞到 WIP=1 卡忙
        ↓
⑥ 关键转折：返回键(BOOT0)=GPIO0，按住开机 → boot:0x1 下载模式，循环停
        ↓
⑦ 但仍需「真正彻底断电」清 flash 深层状态（见下）
```

两个相互叠加的「死锁」曾让局面看起来无解：
- **循环打断写入** → 但进下载模式能解；
- **flash 卡忙/深层状态** → 只有真断电能解。

---

## 设备侧关键技术结论（可复用，已核对）

1. **物理按键映射**（见 `docs/engineering/metalio-eink4.md`）：
   `Buttons | BOOT0=Back, POWER3=Power; P0.7=Down/next, P1.0=Up/previous`
   → **返回键 = BOOT0 = GPIO0**，按住它开机 = 强制下载模式。

2. **esptool 在本机原生 USB 上无法可靠拉低 GPIO0**：
   复位后仍是 `boot:0x9`。结论：**进下载模式必须手动按返回键**，不能用 `--before default-reset/usb-reset` 指望它自己进。

3. **flash 芯片是独立供电的，ESP32 复位不会给它断电**：
   `--before default-reset` 只复位 ESP32，flash 的 WIP/更深状态会一直保留。

4. **设备有电池，拔 USB ≠ 断电**；长按电源走的是「关闭脉冲」，可能只是 park 控制器、没把 flash 的 VCC 拉到 0V。**真正彻底断电 = 拔电池排线**（或拔 USB + 关机 + 等数分钟放电）。

5. **写入粒度**：
   - 单次 5.8MB 大擦除 → 必掉线。
   - 512KB 单片 → 成功过（在真断电 + 下载模式后）。
   - 建议**分片 512KB、单条 `write-flash` 命令一次写多片**（避免跨调用重新同步）。

6. **`--flash-mode dio`**：2 线数据传输比 quad（4 线）电流小，可能有助于写稳定；且 DIO 能正常启动（仅读取稍慢）。

7. **eFuse 检查**：`DIS_USB_SERIAL_JTAG_DOWNLOAD_MODE = False`（USB 下载未禁用）、无加密/安全启动烧录迹象 → 烧录通道本身是开放的。

---

## 代码侧已完成 / 待烧录的修复

（都已编译进固件，NAS `dist/2f6bf01` + 本地 `download/nas-build/` 有备份）

| 文件 | 改动 |
|---|---|
| `src/activities/apps/btdiag/BtDiagActivity.{h,cpp}` | 崩溃修复：DNS/HTTP 前先判 `WiFi.status()`；流式 URL 改由 `nasEndpoint` 设置项构造（不再硬编码） |
| `src/network/NasEndpoint.{h,cpp}` | 新增：解析 `host:port` / `[IPv6]:port` / 带 `http://` 前缀，拼 URL（12 项宿主测试全通过） |
| `src/CrossPointSettings.h` / `src/SettingsList.h` | 新增 `nasEndpoint` 设置（默认 `nas.loujunhui.vip:18080`） |
| `src/activities/settings/NasSettingsActivity.{h,cpp}` | 新增「音乐服务」页：地址编辑 + 连接测试 + 本机 IPv4/IPv6 显示 |
| `src/activities/settings/SettingsActivity.{h,cpp}` | 主设置页新增「音乐服务」入口 |
| `src/NetworkStartup.cpp` | IPv6：STA 模式 `WiFi.enableIPv6()` + `GOT_IP` 事件创建链路本地地址 |
| `src/activities/network/WifiSelectionActivity.cpp` | 连接成功页显示 IPv4/IPv6/链路地址 |
| `lib/AudioStream/PcmRingBuffer.{h,cpp}` / `test/pcm_ring_buffer/` | SPSC 环形缓冲（8 项宿主测试通过） |
| `test/nas_endpoint/` | 地址解析 12 项测试 |

---

## 根因定位（2026-09-16 复核，结论已更新）

> 本节推翻了下方「硬件故障怀疑」中的供电假设。故障**已可 100% 确定性复现并定位到单个坏扇区**。
> 复核工具：pip `esptool 5.4.0`（本机另有 PIO 自带的 5.1.2，两者 stub 行为一致）。

### 定位过程

1. **读路径完全正常**：连续读 256KB / 4MB 全部成功（~1180 kbit/s），无断流。
2. **写 6MB 到应用区（`0x10000`）复现事故**：在 `0xE4000`（848KB，13.8%）掉线，
   报 `No more data to read from the serial port` —— 精确对应阶段 4。
3. **分片写 512KB 复现阶段 8**：`slice_00 @0x10000` ✅，`slice_01 @0x90000` ❌（连续 3 次失败），
   `slice_02 @0x110000` ✅ —— **与阶段 8 的失败地址完全一致**。
4. **64KB 块逐段写**：仅 `0xE0000` 失败，`0x90000/0xA0000/…/0xF0000/0x100000` 全成功。
5. **4KB 粒度擦除定位**：`0xEC000`✅ `0xED000`✅ **`0xEE000`❌** `0xEF000`✅。

### 结论

| 操作 | `0xEE000` | 相邻 `0xED000` / `0xEF000` |
|---|---|---|
| 读（4KB） | ✅ 成功 | ✅ 成功 |
| 擦除（4KB） | ❌ **锁死（3/3）** | ✅ 成功（各 2/2） |
| 写（4KB） | ❌ 锁死 | ✅ 成功 |
| flash 状态寄存器 | `0x0000`（干净，非 WIP 忙位卡死） | — |

- **`0xEE000` 是一个确定性坏扇区（single bad 4KB sector）**，实为 `app0` 应用槽内部
  （`otadata` 只占 `0xE000`–`0x10000`，早于它；`0xEE000` 已进入 `app0` 的 `0x10000`–`0x650000` 范围）。
  这是「整块写应用必在 `0xE4000` 断」的直接原因。
- 故障性质是**纯擦除介质缺陷**：该扇区一旦被擦除即让芯片从串口掉线，与擦写尺寸、波特率、地址范围（其它区同尺寸均成功）无关。
- **与 stub 版本无关**：legacy v1 与新版 v2（esp-flasher-stub v1.2.2）表现完全相同（两者 6MB 写入均在 `0xE4000` 掉线）。
- **与供电无关**：如果是供电/稳压问题，不会如此精确地只死在这一个 4KB 扇区，而相邻扇区反复成功。
- 失败后**无需物理断电**，`--before default-reset --after hard-reset` 复位即可恢复连接（阶段 9 的端口坏状态仅在快速反复断连后出现）。

### 影响与处置

- 应用区 `0x10000` 起的前 ~800KB 内嵌了该坏扇区（`0xE4000` 处于 `0x10000+` 的写入路径上），
  所以**整块写应用必然在 848KB 处断**；`slice_01 @0x90000` 因跨过 `0xEE000` 而必然失败。
- 修复路径取决于坏扇区是否可被标记/跳过：
  - 若 flash 支持 **SFDP / 坏块标记**：可尝试 `read-flash-sfdp` 确认，并让 FS 层跳过该块。
  - 否则**更换 flash 器件**（GigaDevice `68/4018`，16MB）是唯一根治手段 —— 这是**硬件来料/老化缺陷**，不是焊接供电问题。
- 低风险临时绕行：**分区表把应用区从坏块之后起算**（代价是损失 64KB 空间），可让设备先跑起来验证软件链路。

---

## 当前设备状态

- ✅ bootloader / partitions / boot_app0：**已恢复**（三个小件写入成功并校验）。
- ⚠️ 应用区：**第一片 512KB 已写入**（slice 0），其余仍是残缺数据。
- ❌ 设备当前无法启动（应用不完整）。
- ⚠️ **`0xEE000` 坏扇区**：任何跨该扇区的擦写都会掉线（见上节）。

---

## 恢复步骤（已验证有效的路径）

1. **彻底断电**：拔 USB → 长按电源关机（或开后盖拔电池排线）→ 等 3~5 分钟让 flash 电荷放完。
2. **进下载模式**：按住**返回键**开机（或按住返回键 + 复位），屏幕/串口出现 `boot:0x1 (DOWNLOAD(USB/UART0))` + `waiting for download`。
3. **分片写应用**（在下载模式下，`--before no-reset`，不要用 default-reset 破坏下载模式）：
   ```powershell
   esptool --chip esp32s3 -p COM6 -b 460800 --before no-reset --after hard-reset `
     write-flash -z --flash-mode dio --flash-size 16MB `
     0x10000 slice_00.bin 0x90000 slice_01.bin 0x110000 slice_02.bin ...  # 512KB 一片，共 12 片
   ```
   切片规则：应用 5,848,176 字节，每片 `0x80000`（512KB），地址 `0x10000 + i*0x80000`，最后一片不满。
4. 写完后 `--after hard-reset` 启动。

> 若单片之间又掉线，回到步骤 1 重新彻底断电（flash 深层状态需真断电清）。

---

## 硬件故障结论（给售后的话术，2026-09-16 更新）

现象：**读 flash 完全正常；擦写只在固定地址 `0xEE000`（4KB 扇区）瞬间掉线，相邻扇区稳定成功。**
分片写时表现为「跨过该扇区的分片必失败，其它分片成功」。

判断：**flash 器件 `0xEE000` 扇区坏块（介质缺陷）**，位于 `app0` 应用槽内。
不是焊接供电问题 —— 若为供电失压，不会只精确死在一个 4KB 扇区而邻近扇区反复通过。

给售后的说法：**「16MB flash 的 `0xEE000` 扇区擦除失败，可确定性复现；读正常、邻扇区正常。
请更换 flash 器件（GigaDevice 68/4018）或按坏块处理。」**

> 原「供电/焊点怀疑」已被本节实测推翻，保留在修订记录中仅作对照。

---

## 遗留事项

- [x] ~~做一次真正彻底断电后分片写完应用~~ → 已定位为坏扇区，断电无法绕过。
- [x] ~~若真断电后仍只能写空白区 → 走售后~~ → 已确认介质缺陷，直接走售后换件。
- [ ] 确认 flash 是否支持 SFDP（`read-flash-sfdp`）以判断能否标记/跳过坏块。
- [x] ~~决策：更换 flash 器件，或改分区表绕过 `0xEE000`（临时方案）~~
  → **已实施绕行**：入库的 `partitions.metalio_bypass.csv` + `[env:metalio_eink4]` 把 `app0` 后移至 `0xF0000`，
  详见 [`metalio-eink4-bad-sector-bypass.md`](metalio-eink4-bad-sector-bypass.md)。
- [ ] 根治：更换 flash 器件后恢复正式 `partitions.csv` 布局。
- [ ] 固件烧入后：连 Wi-Fi → 蓝牙诊断 → 模式 1 → 流式播放，验证 IPv6 拉流全链路。
- [ ] 代码改动尚未提交（等待决定：是否提交 + 是否需要本记录一起入库）。
- [ ] 清理排查临时文件（`bin/scan_*.bin`、`bin/rand_*`、`bin/slices/`、`bin/v*_*.bin`、`bin/blk_*.bin`、`bin/ee000.bin`）。
