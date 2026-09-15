# Metalio E-Ink 4 — Flash `0xEE000` 坏扇区定位与绕行修复

> 本文是 [`metalio-eink4-flash-incident-2026-09-15.md`](metalio-eink4-flash-incident-2026-09-15.md) 的
> **结论篇**：前者记录了一整夜的排查过程（现象 + 报错字典 + 走过的弯路），
> 本文只讲**最终定位到的根因、可复现的证据，以及临时绕行方案与验证步骤**。
>
> 结论一句话：**16MB flash 的 `0xEE000`（4KB 扇区）是确定性坏块，擦除即掉线。**
> 该扇区落在 `app0` 应用槽内部，导致整块写应用必然失败。临时修复办法是把
> `app0` 整体抬到坏块之上（`0xF0000`）。

---

## 1. 根因

| 项 | 值 |
|---|---|
| 器件 | GigaDevice，16MB SPI flash（`flash-id` 读数 `C8/4018`） |
| 坏块地址 | **`0xEE000`**（4KB 扇区） |
| 所在分区 | **`app0`**（`0x10000`–`0x650000`）内部 |
| 故障操作 | **擦除/写入**该扇区 |
| 正常操作 | 读该扇区、以及该扇区所有相邻扇区的擦写 |

### 为什么是它

应用固件约 5.85MB，必须从 `0x10000` 起整块/分片写入 `app0`。
写入路径**必然跨过 `0xEE000`**，于是：

- 整块写应用 → 在 `0xE4000`（848KB，13.8%）掉线；
- 分片写 512KB → `slice_01 @0x90000`（覆盖 `0x90000`–`0x110000`，含 `0xEE000`）必然失败，
  而 `slice_00 @0x10000`、`slice_02 @0x110000` 都成功。

### 排除项

| 假设 | 实测 | 结论 |
|---|---|---|
| stub 版本差异 | legacy v1 与 v2（esp-flasher-stub）表现**完全相同**（6MB 写入同在 `0xE4000` 断） | 排除 |
| 波特率 | 115200 / 460800 / 921600 均一致 | 排除 |
| 供电/焊点 | 若为供电失压，不会只精确死在一个 4KB 扇区而邻近扇区反复通过 | 排除 |
| 擦除尺寸 | 其他区 64KB 擦除（`0x200000`、`0x5F0000`）均成功 | 排除 |
| flash 忙位卡死 | 状态寄存器为 `0x0000`（WIP=0），且复位即可恢复 | 排除 |
| 数据/镜像 | 用不可压缩随机数据，仍稳定在同一地址断 | 排除 |

---

## 2. 可复现证据

全部用 pip `esptool`（5.x），`-p COM6`，`--chip esp32s3`。

### 2.1 读路径完全正常

```powershell
# 连续读 256KB / 4MB 全部成功（~1180 kbit/s），无断流
esptool --chip esp32s3 -p COM6 --before no-reset --after no-reset read-flash 0x0 0x40000 d:\tmp\chk.bin
```

### 2.2 写 6MB 到 `app0` → 848KB 处掉线

```powershell
# 复现：No more data to read from the serial port（约 0xE4000）
esptool --chip esp32s3 -p COM6 -b 460800 --before default-reset --after no-reset `
  --stub-version 2 write-flash -z --flash-mode dio --flash-size 16MB 0x10000 .\rand_6m.bin
```

### 2.3 分片定位（与事故日志阶段 8 完全一致）

| 分片 | 地址 | 结果 |
|---|---|---|
| `slice_00` | `0x10000` | ✅ |
| `slice_01` | `0x90000` | ❌ 连续 3/3 失败 |
| `slice_02` | `0x110000` | ✅ |

### 2.4 4KB 粒度擦除，锁定单扇区

```powershell
foreach ($a in '0xEC000','0xED000','0xEE000','0xEF000') {
  esptool --chip esp32s3 -p COM6 -b 460800 --before default-reset --after no-reset `
    --stub-version 1 erase-region $a 0x1000
}
```

| 扇区 | 结果 |
|---|---|
| `0xEC000` | ✅ |
| `0xED000` | ✅ |
| **`0xEE000`** | ❌ **锁死（3/3）** |
| `0xEF000` | ✅ |

> **注意**：坏块是**介质缺陷**，`esptool` 的自动复位无法绕过。
> 失败后可用 `--before default-reset --after hard-reset` 复位恢复连接，
> 无需物理断电（早期记录的「必须拔电池」只在快速反复断连导致 USB 端口坏状态时才需要）。

---

## 3. 绕行方案（临时）

> **不修改 `partitions.csv`。** 它是全 target 共享文件，且被发布链路硬编码校验
> （`scripts/package_nightly_target.py` 的 `EXPECTED_PARTITIONS`、
> `scripts/verify_nightly_release.py` 的 `OFFSETS`）。改主文件会破坏所有
> Nightly / Stable 打包与发布校验。
>
> **改动必须入库。** NAS 构建是每次从 git 全新 clone 的干净 checkout
> （`docker/nas-build/build.sh`），gitignored 的本地文件根本到不了 NAS，
> 所以「本地覆盖」这条路的产物无法在 NAS 上编译。
>
> 因此绕行由两个**入库**文件承担，且**不进入任何 CI / 发布矩阵**：
> `partitions.metalio_bypass.csv` + `[env:metalio_eink4]`。

### 3.1 分区布局对比

| 分区 | 类型 | 正式 `partitions.csv` | 绕行 `partitions.metalio_bypass.csv` |
|---|---|---|---|
| `nvs` | data/nvs | `0x009000` +0x5000 | 不变 |
| `otadata` | data/ota | `0x00E000` +0x2000 | 不变 |
| **`app0`** | app/ota_0 | `0x010000` +0x640000 | **`0x0F0000` +0x640000** |
| **`app1`** | app/ota_1 | `0x650000` +0x640000 | **`0x730000` +0x640000** |
| **`spiffs`** | data/spiffs | `0xC90000` +0x360000 | **`0xD70000` +0x280000** |
| `coredump` | data/coredump | `0xFF0000` +0x10000 | 不变 |

关键点：

- `app0` 起点抬到 **`0xF0000`**（`0xEE000` 之上的下一个 64KB 边界），
  `0x10000`–`0xF0000`（896KB）**留作空洞不分配**，彻底避开坏块。
- **两个 app 槽大小保持 `0x640000`**。固件 5.85MB < 6.55MB，容量够；
  同时维持与字体缓存文档一致的槽尺寸（`docs/engineering/sd-card-font-cache.md`），
  避免运行时按槽大小推导的偏移失效。
- 少掉的 896KB 从 `spiffs` 扣除。`src/` 中没有任何 `SPIFFS.begin()` 调用，
  该分区基本闲置，代价可接受。
- 校验：`0xF0000+0x640000=0x730000` → `0x730000+0x640000=0xD70000`
  → `0xD70000+0x280000=0xFF0000` → `0xFF0000+0x10000=0x1000000`（16MB）✅

### 3.2 为什么不另建新 env、也不改 env 名

- **不改 `metalio_eink4` 的名字**：`scripts/git_branch.py` 只给一份硬编码 env
  列表注入 `CROSSPOINT_VERSION` 等版本宏（`CROSSPOINT_VERSION` 在源码中
  无条件使用），改名会让版本宏丢失。
- **该 env 不在任何 CI / 发布矩阵中**：CI 只构建 `default` / `x4pro` /
  `*_nightly`；nightly 用独立的 `[env:metalio_eink4_nightly]`。
  因此改 `[env:metalio_eink4]` 只影响本地与 NAS 上的手动开发构建。
- **新增 env 反而不安全**：`scripts/tests/test_configure_nimble_psram.py` 与
  `scripts/tests/test_ble_c3_config.py` 会遍历 `platformio.ini` 的所有 env 段做断言，
  新增 env 必须同时满足这些断言，徒增维护面。

### 3.3 上传偏移如何跟随

`ESP32_APP_OFFSET` **由 PlatformIO 从分区表 CSV 自动推导**，无需手工设置：

```
# ~/.platformio/platforms/espressif32/builder/main.py:316-321
if partition["subtype"] == "ota_0":
    app_offset = next_offset
env.Replace(ESP32_APP_OFFSET=str(hex(app_offset)))
```

`main.py:1713` 的上传命令 `UPLOADCMD='$UPLOADER $UPLOADERFLAGS $ESP32_APP_OFFSET $SOURCE'`
直接消费它，所以 `pio run -t upload` 会自动把 `firmware.bin` 写到 `0xF0000`。
> 注：`board_upload.offset_address` **不是** espressif32 平台消费的字段，
> 加了也没用（平台只在 debug 配置里读 `INTEGRATION_EXTRA_DATA` 的
> `application_offset`），故本方案未使用它。

### 3.4 生效的文件

| 文件 | 作用 | 是否入库 |
|---|---|---|
| `partitions.metalio_bypass.csv` | 绕行分区表 | **是** |
| `platformio.ini` 的 `[env:metalio_eink4]` | 引用上表；仅供开发构建 | **是**（改动最小） |

---

## 4. 验证步骤

因为编译在 NAS 上做，本地只需校验静态正确性 + 用 NAS 构建产物烧录。

```bash
# 1) 本地：校验分区表无重叠、总长 16MB、坏块落在空洞
python3 - <<'PY'
import csv
rows=[r for r in csv.reader(open('partitions.metalio_bypass.csv'))
      if r and not r[0].lstrip().startswith('#')]
prev=0
for r in rows:
    off=int(r[3],0); size=int(r[4],0)
    assert off>=prev, (r[0],'overlap')
    prev=off+size
assert prev==0x1000000, hex(prev)
bad=0xEE000
assert not any(int(r[3],0)<=bad<int(r[3],0)+int(r[4],0) for r in rows), 'bad sector still allocated'
print('partition layout OK; app0 offset =', rows[2][3])
PY

# 2) 运行为本次改动相关的配置测试（会遍历所有 env 段）
python3 -m unittest \
  scripts.tests.test_configure_nimble_psram \
  scripts.tests.test_ble_c3_config

# 3) 在 NAS 上构建该开发 env（或本地若有可用 PIO 环境）
pio run -e metalio_eink4
```

**核验构建产物**：`.pio/build/metalio_eink4/flasher_args.json` 中应用段的
offset 应为 `0xf0000`；`partitions.bin` 应与 `partitions.metalio_bypass.csv` 对应。

**烧录与观察**（把 NAS 产出的固件取回本地后）：

```powershell
esptool --chip esp32s3 -p COM6 -b 460800 --before default-reset --after hard-reset `
  write-flash -z --flash-mode dio --flash-size 16MB `
  0x0 bootloader.bin 0x8000 partitions.bin 0xF0000 firmware.bin

pio device monitor -p COM6 -b 115200
```

**成功判据**：
- 烧录过程中**不再**在 `0xE4000` / `0x90000` 附近掉线；
- 串口出现正常应用日志（而非 `rst:0x7 TG0WDT_SYS_RESET` 复位循环）；
- 设备能进入主界面。

**若仍旧掉线**：说明还有其它坏块，按 §2.4 的方法用 4KB 擦除逐扇区定位新坏点，
并把 `app0` 起点再抬到它之上的 64KB 边界。

---

## 5. 正式修复与后续

绕行只是让**这一台**设备先跑起来，属于验证软件链路的手段，不是根治。

- [ ] **根治**：更换 flash 器件（GigaDevice 16MB），恢复正式 `partitions.csv` 布局。
- [ ] 可选：用 `esptool read-flash-sfdp` 确认该 flash 是否支持 SFDP / 坏块标记，
      判断能否在文件系统层标记跳过而非整体后移。
- [ ] 若决定长期保留后移布局（例如一批设备都有此问题），需同步更新
      `scripts/package_nightly_target.py` 的 `EXPECTED_PARTITIONS`、
      `scripts/verify_nightly_release.py` 的 `OFFSETS`、
      `scripts/package_nightly_target.py` 的 `FULL_INSTALL_SEGMENTS`（firmware 偏移），
      以及 `docs/engineering/sd-card-font-cache.md` 与 `docs/file-formats.md` 中的槽尺寸说明。
- [ ] 固件烧入后跑完整验收：连 Wi-Fi → 蓝牙诊断 → 模式 1 → 流式播放（IPv6 全链路）。

---

## 附：报错速查

| 现象 | 含义 |
|---|---|
| `No more data to read from the serial port` | 擦/写到坏块，芯片从串口掉线 |
| `The chip stopped responding` / `Serial data stream stopped` | 同上，芯片不再应答 SLIP |
| `Could not open COM6 ... port is busy` | 快速反复断连后 USB 进入失败状态，拔插 USB 恢复 |
| `rst:0x7 (TG0WDT_SYS_RST)` | 半份应用启动半途挂死 → 看门狗复位循环（本次事故的次生现象） |
| `boot:0x1 (DOWNLOAD(USB/UART0))` | 已进下载模式（本板 = 按住返回键开机） |
