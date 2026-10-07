# racket-vulkan 架构

> 本文档记录**已经落地的分层**与**其成立所依赖的假设**。任何一条假设被打破，
> 对应条目都标注了「重新考虑触发条件」。改代码前先读第 0 节和第 5 节。

---

## 0. 核心问题：Racket GC 所有权 vs Vulkan 持有指针

整个绑定设计只有**一个**根本约束：

> **交给 Vulkan/驱动的内存，必须在「驱动可能访问它的整个期间」地址稳定且可达。**

两边的模型天然冲突：

| | 所有权 | 地址 | 回收 |
|---|--------|------|------|
| Racket GC | Racket 拥有 | **可能移动**（普通分配）/ 不移动（`atomic-interior`） | 不可达即回收 |
| Vulkan | 驱动可能持有 | 要求稳定 | 不通知 Racket |

Racket 的 `'atomic-interior` 只解决**移动**，不解决**回收**：内存即使不移动，
一旦 Racket 侧不可达也会被 GC 掉。所以必须额外维护「可达性」。

其余所有设计（arena、retain/release、`vk-malloc`、builder 约定、safe 包装）
都只是这条约束的推论。

Vulkan 对 host 内存的持有方式（决定需要多长的生命周期）：

1. **仅调用期间**：多数 `vkCmd*`/`vkUpdate*`/`vkQueueSubmit` 的输入指针，spec 只要求调用期间有效。
2. **对象生命周期**：create-info 的 `pNext` 链、`pCode`/`pName` 等，理论上传入后即可释放，
   但**部分驱动（如 llvmpipe）会惰性引用**——本原型实测踩过。
3. **上下文生命周期**：`VkAllocationCallbacks`、debug messenger 回调——驱动长期保存函数指针。
4. **设备内存**：`vkMapMemory` 返回的指针由设备拥有，不受 Racket GC 影响。

---

## 1. 需求 → 分层

| 需求 | 内容 | 本质 | 落层 |
|------|------|------|------|
| R1 | 覆盖 API（常量/类型/命令/扩展/alias） | 事实 | bindings |
| R2 | ABI 正确（布局、调用约定、GIPA/GDPA、版本） | 事实 | bindings |
| R3 | 生成可复现、可审计 | 工具链 | generate |
| R4 | 手写补丁可隔离 | 工具链 | bindings + generate 输入表 |
| R5 | 内存不可移动、生命周期正确 | **策略** | memory + safe |
| R6 | 错误处理 | **策略** | safe |
| R7 | 易用性（create/destroy、输出参数、pNext、回调、指针类型化） | **策略/组合** | safe |
| R8 | 窗口/平台 | 独立 | window |

分水岭：**R1–R4 是"绑定事实"，R5–R7 是"使用策略"**。事实层不决定策略。

---

## 2. 模块、依赖与命名

```
registry/*.xml ──(generate.rkt)──▶ generated/{constants,types,commands,safe}.inc + api.rkt
                                         │
     ┌───────────────────────────────────┼────────────────────────────┐
     ▼                                   ▼                            ▼
 vulkan/base.rkt                 vulkan/commands.rkt          vulkan/memory.rkt
 （类型/常量/分派设施）            （原始命令，返回 VkResult）      （R5 所有权，零 Vulkan 依赖）
     └───────────────┬───────────────────┘                            │
                     ▼                                                │
            vulkan/bindings.rkt  （原始表面 = base + commands）         │
            vulkan/raw.rkt       （= bindings，语义别名）                │
                     │                                                │
                     ├──────────────┬─────────────────────────────────┘
                     ▼              ▼
            vulkan/unsafe.rkt   vulkan/safe.rkt
            （兼容 = bindings    （组合层糖：check-vk-result +
              + memory）           vk-create-*，不 re-export 裸命令）
                     │              │
                     └──────┬───────┘
                            ▼
                     vulkan/main.rkt（facade）
                     sugar 无前缀 + raw: 裸命令 + 类型/常量/原子
```

| 模块 | 契约 | 明确**不**包含 |
|------|------|----------------|
| `vulkan/base` | 类型/常量/分派（`define-vk`、GIPA/GDPA） | 命令、arena、错误策略 |
| `vulkan/commands` | 原始命令（返回 `VkResult`） | 策略、所有权 |
| `vulkan/bindings` / `vulkan/raw` | 原始表面 = base + commands | arena、错误抛出、create 包装 |
| `vulkan/memory` | arena、`vk-malloc`/`stable-bytes`/`vk-new`、handle↔arena 绑定 | 任何 Vulkan 类型/命令 |
| `vulkan/safe` | `check-vk-result` + `vk-create-*`/`vk-destroy-*` | 裸命令（靠模块隔离区分） |
| `vulkan/api-facts` | 运行期 API 事实 IR（`vk-param`/`vk-command`） | 生成逻辑、策略 |
| `vulkan/gen/*` | 生成器内部：`classify`（shape+plan）/ `emit`（逐形状） | 运行期依赖 |
| `vulkan`（main） | facade：挑选/重命名导出 | 逻辑 |

依赖方向单向、无环。

### 2.1 命名：靠模块隔离 + facade 挑选

同名导出不同东西（糖 vs 裸命令）靠**模块**区分，不靠命名前缀约定（方案 A）：

- `vulkan/safe` 的 `vkCreateBuffer` 是**糖**（builder + 对象作用域）；
  `vulkan/bindings` 的 `vkCreateBuffer` 是**裸命令**（原始签名，返回 VkResult）。
  不同模块，同名不冲突。
- 用户 facade `vulkan/main.rkt` 用 Racket 导出组合子挑选：

  ```racket
  (require "safe.rkt"                        ; 糖：原生名 + base + memory
           (prefix-in raw: "commands.rkt"))  ; 裸命令
  (provide (all-from-out "safe.rkt")         ; 糖（原生名）+ 类型/常量/原子
           (all-from-out "commands.rkt"))      ; 导出名为 raw:*
  ```

- `(require vulkan)`：糖 = 原生名（`vkCreateBuffer`），裸命令 = `raw:vkCreateBuffer`。
- 只要裸命令：`(require vulkan/bindings)` 或 `(require vulkan/raw)`。
- 两者都要：`(require vulkan (prefix-in raw: vulkan/raw))`。

实现上：`safe.rkt` 用 `(prefix-in raw: "commands.rkt")` 导入裸命令，
生成物 `safe.inc` 的包装以 `raw:vkCreateBuffer` 调用、以原生名 `vkCreateBuffer` 定义。
由 `tests/module-surface.rkt` 锁定这个契约。

**每次新增导出前先想：它属于哪一层？放错层比命名冲突更糟。**

### 2.2 命名规则（词表）

- **事实保留 C 名**：类型/常量/枚举/命令用 C 拼写（`VkResult`、`VK_*`、`vkCreateBuffer`）。
- **机制用 kebab + 词缀**：`?` 谓词、`!` 有副作用、`/x` 变体、`->` 转换。
- **一词一义**：handle（不叫 object）；arena（不叫 scope/token）；param（命令形参）
  / member（结构成员）/ arg（生成实参）；方向一律 `input`/`output`，不写 in/out。

| 概念 | 原名 | 现名 |
|------|------|------|
| 挂到当前 arena | `vk-keep!` | `vk-arena-keep-current!` |
| 挂到指定 arena | `vk-keep-alive!` | `vk-arena-keep!` |
| handle↔arena 绑定 | `vk-retain-for!` / `vk-release-for!` | `vk-handle-arena-set!` / `vk-handle-arena-remove!` |
| handle→arena 查询 | `vk-object-arena` | `vk-handle-arena`（表 `vk-handle-arenas`，不导出） |
| arena 字段 | `items` | `kept` |
| 读回句柄数组 | `vk-handle-vector` | `vk-read-handles`（归 safe） |
| 错误检查 | `check-vkResult` | `check-vk-result` |
| string→cstring | `vk-char` | `vk-cstring` |
| 枚举输出 | `vk-enumerate-array` / `…/void` | `vk-enumerate-result` / `vk-enumerate-void` |
| 运行期 IR | `vulkan/gen/facts.rkt` | `vulkan/api-facts.rkt` |
| 事实列表 | `vk-api` | `vk-command-facts` |
| 调用作用域 | `with-vk-call`（memory） | `with-vk-call`（safe，策略别名） |

**分层的判据**：只做计算/按 arena 管引用（Vulkan 无关）的留在原语层；
替用户选“用哪个作用域/怎么报错”的属于组合层。`with-vk-frame` 是纯 arena 机制，留
memory；`with-vk-call`、`vk-read-handles`、枚举辅助是使用策略，归 safe。

---

## 3. 生成 vs 手动

| 内容 | 生成 | 手动 | 归属 |
|------|:----:|:----:|------|
| 常量 / ctype / 布局 / alias / 分派级别 | ✅ | | bindings |
| 命令签名 | ✅ | | bindings |
| platform 类型表、basetype 映射 | | ✅（生成器输入） | bindings |
| version 宏、libvulkan、GIPA/GDPA | | ✅ | bindings |
| VkResult 名字表（纯数据） | | ✅ | bindings |
| arena、`vk-malloc`、retain/release | | ✅ | memory |
| safe create/destroy 包装 | ✅ | | safe |
| 错误抛出、输出参数、pNext、回调 | | ✅ | safe |
| 窗口/GLFW | | ✅ | window |

原则：**生成器只产出事实**（布局、签名、别名、分派级别）；**策略由手写组合层承担**。
唯一的例外是 `types.inc` 的 `#:malloc-mode 'zeroed-atomic-interior`——它被视为绑定层的
安全默认（驱动可见内存默认不移动），不是可选项。

---

## 4. 当前所有权模型

**不变量**：所有经 `vulkan/memory` 分配、交给驱动的东西，都是
`'atomic-interior`（不移动）；并通过 arena 保持 Racket 侧可达。

- `vk-malloc` / `stable-bytes` / `vk-new` / `vk-zero`：分配并登记到 `current-vk-arena`。
- builder 约定：safe 包装在一个 arena 里执行 builder thunk，再把 arena
  `vk-handle-arena-set!` 到返回的句柄上；`vk-destroy-*`/`vk-free-*` 时 `vk-handle-arena-remove!`。
- 句柄↔arena 注册表用 `equal?`（`make-hash`），因为数组元素 `ptr-ref` 读回的是
  地址相同但 `eq?` 不同的新 cpointer。

**覆盖范围**：仅 `vkCreate*` / `vkAllocate*` / `vkDestroy*` / `vkFree*`。
其余（`vkQueueSubmit`、`vkCmd*`、`vkUpdateDescriptorSets`、`vkMapMemory`、
`vkEnumerate*`、`vkGet*`）**不在自动保护内**。

---

## 5. 假设与「重新考虑触发条件」

> 以下任何一条不再成立时，先回到这一节，再决定是否改第 2/4 节的结构。

### A. 地址稳定性
- **A1**：`'atomic-interior` 永久不移动。若 Racket 改变该保证 → 整个 memory 层需重写。
- **A2**：`atomic-interior` 适合任意大小的 host 内存。若需 GB 级 buffer/上传，
  应走 `vkMapMemory`（设备内存），而不是 host arena。**触发**：出现大块映射需求。

### B. 生命周期绑定
- **B1**：把输入内存绑到"返回句柄的销毁"是**保守充分**的。
  若某驱动在 `vkDestroy*` 之后仍读输入（不规范），会 UAF。
  **触发**：遇到此类驱动 → 需要显式生命周期/引用计数，而非对象 arena。
- **B2**：**无返回句柄的调用不受保护**（`vkQueueSubmit`、`vkCmd*`、`vkUpdate*`、
  `vkMapMemory`、`vkEnumerate*`）。若这些调用存在**异步保留 host 指针**的情形
  （扩展/驱动特有），当前模型不足。**触发**：确认某个扩展在提交后异步读 host 内存。
- **B3**：`pNext` 链只要整链都用登记的分配器就安全；若用未登记的 `make-VkX`，
  不受保护。目前靠 builder 约定，**没有静态强制**。
  **触发**：出现难以排查的悬空 `pNext` → 考虑在 `make-VkX` 层面强制登记。
- **B4**：arena 生命周期 = 对象生命周期，**可能严重过度保留**。
  典型反例：长寿命 command buffer / descriptor set 反复用 `vk-new` 传入每帧数据，
  arena 无界增长。**触发**：出现按帧分配 → 需要「帧 arena / 显式 reset」。

### C. 回调（funcpointer）
- **C1**：当前 `_PFN_*` 一律 `_pointer`，**不能**用 Racket 过程回调
  （`VkAllocationCallbacks`、debug messenger 不可用）。
  实现回调需要：调用点 `_cprocedure` 包装 + 回调 trampoline 保活（`#:keep`）+
  生命周期超出单次调用。**这与 arena 模型正交**，需要独立的 callback registry。
- **C2**：回调可能在任意/驱动线程触发，而 `current-vk-arena` 是 thread-local，
  在回调线程里无效。**触发**：实现回调 → 必须显式传上下文，不能依赖动态参数。

### D. 线程
- **D1**：`vk-handle-arenas` 是全局 `make-hash`，**无锁**。多线程并发创建对象会竞争。
  **触发**：多线程资源创建 → 需 per-thread arena 或锁/不可变结构。
- **D2**：`current-vk-arena` 是 parameter（thread-local），builder 里再开线程不继承。

### E. 句柄表示
- **E1**：handle 统一 `_cpointer/null`，在 64 位构建正确。32 位构建下
  non-dispatchable handle 是 `uint64_t`。**触发**：需要 32 位支持。
- **E2**：注册表按地址相等；若 `vkDestroy*` 漏调，或地址被新对象复用，
  可能 stale/误命中。**触发**：出现句柄地址复用问题 → 换带世代号的句柄包装。

### F. 错误 / 版本
- **F1**：命令在首次调用时经 GIPA/GDPA 解析，未加载扩展通常解析失败并抛错；
  **没有运行期 capability 门控**。**触发**：需要按扩展/版本优雅降级。
- **F2**：`check-vk-result` 只对负值抛错，`VK_INCOMPLETE`/`VK_TIMEOUT` 等由调用方处理。

### G. 生成
- **G1**：alias 已解析；**bitfield 目前被丢弃**（当前 10 个扩展未触发），
  一旦纳入 NV/acceleration 扩展会布局错误。**触发**：扩展覆盖 → 先修 bitfield。
- **G2**：未识别类型静默降级 `_pointer`，可能悄悄错 ABI。**触发**：加平台扩展前先审计。

---

## 6. 设计原则与 M3：原语 + 策略

**总原则（约束所有后续设计）**

1. **原语优先**：功能原子（atom）是基础，包装（wrapper）只是糖。
2. **包装建立在原语之上**：任何包装都能用原语等价展开。
3. **包装只适用于特定场景**：每个包装写明适用边界，不追求普适。
4. **裸能力永远保留**：用户总能绕过包装，直接用原语/原始命令。
5. **自动层只管理自己分配的内存**：外部指针一律手动，不做隐式接管。

### 6.1 功能原子（`memory.rkt`，手动亦可直接用）

| 类别 | 原子 |
|------|------|
| 不移动分配 | `vk-malloc` / `vk-zero` / `vk-struct-array` / `stable-bytes` |
| 生命周期令牌 | `make-vk-arena` / `vk-arena` / `vk-arena-keep-current!` / `vk-arena-keep!` / **`vk-arena-reset!`（新增）** |
| 作用域 | `with-vk-arena` / `call-with-vk-arena` |
| 附着/保活 | `vk-handle-arena-set!` / `vk-handle-arena-remove!` / `vk-handle-arena` |

### 6.2 自动策略（`safe` 层，糖）

覆盖场景 1–6（见 6.4），**只包它自己分配的内存**：

- `vk-create-*` / `vk-allocate-*` → **对象作用域**（原语组合）
- **每条非 create 包装默认自开一个调用作用域**（1a）→ 单条命令一定安全
- `with-vk-call`（1b，safe 层策略别名）→ 多条命令共享一个调用作用域
- `with-vk-frame` / `vk-arena-reset!` → 可复用的**帧作用域**，解决 B4 过度保留
- 输出自动返回（`vkGet*` / `vkEnumerate*`）——事实的消费

### 6.3 手动策略（用户持有所有权）

- 直接用原语：`vk-malloc` / `stable-bytes` + 自己持有 cpointer 或 token；
  “驱动可能保留我的指针”时用 `vk-handle-arena-set!` / `vk-arena-keep!` 显式挂住。
- **设备内存**（场景 7–9、14）：`vkMapMemory` 返回设备指针，不归 GC；只做 `vk-map` / `vk-unmap` 薄封装。
- **回调/分配器**（场景 10–11）：callback registry，显式上下文生命周期（独立 M3.5）。

### 6.4 Vulkan 场景归类

| # | 场景 | 内存归属 | 驱动持有 | 模式 | 作用域 |
|---|------|----------|----------|------|--------|
| 1 | 创建描述（`VkXCreateInfo`+`pNext`+数组） | host | 可能到对象销毁 | 自动 | 对象 |
| 2 | 创建用字符串/代码 | host | 可能到对象销毁 | 自动 | 对象 |
| 3 | 命令录制（`vkCmd*`） | host | 仅调用期 | 自动 | 调用 |
| 4 | 队列提交描述 | host | 仅调用期 | 自动 | 调用 |
| 5 | 描述符更新 | host | 仅调用期 | 自动 | 调用 |
| 6 | 查询/枚举输出 | host | 仅调用期 | 自动 | 调用 + 自动返回 |
| 7 | 映射设备内存（`vkMapMemory`） | 设备 | 设备 | 手动 | 用户 |
| 8 | 持久映射/每帧 UBO/SSBO/staging | 设备 | 设备 | 手动 | 用户 |
| 9 | 设备本地内存 | 设备 | 设备 | 手动 | 用户 |
| 10 | 自定义分配器 | 代码 | 上下文 | 手动 registry | 上下文 |
| 11 | 回调（debug messenger） | 代码 | 上下文 | 手动 registry | 上下文 |
| 12 | 外部内存/互操作 | 平台 | 用户 | 手动 | 用户 |
| 13 | 用户 host 数据跨调用复用 | host | 可能 | 手动（或显式对象保留） | 用户 |
| 14 | 大型上传/流式 | 设备 | 设备 | 手动 | 用户 |

> 冲突只发生在 1–6 与 13。7–12、14 不是 GC 的问题，不塞进 arena。

### 6.5 bindings 产出事实：`vulkan/generated/api.rkt` + `vulkan/api-facts`

单解析器产出归一化事实（结构体定义在运行期模块 `vulkan/api-facts`，数据在
`vulkan/generated/api.rkt`），供自动层与测试消费：

- 命令：`name` / `level` / `result?` / `dispatch`
- 参数：`name` / `base` / `pointer?` / `const?` / `count?` / `kind` / `output?`（启发式）

事实里 **pointer/const/count/kind 可机械推导**；`output?` 是启发式；
**retention 不在此层**——自动策略按调用类（create/其他）决定，手动处理例外。

### 6.6 与 GC 冲突的关系

冲突的解法从“一律绑到对象”升级为**显式生命周期作用域**；
自动策略只是“替用户选作用域”的糖，原语始终可手动使用。
因此不存在“第二套系统”，也没有无法绕过的抽象。

### 6.7 待定

- `vk-arena-reset!` 后旧引用失效的语义（文档/断言）。
- `vk-map` / `vk-unmap` 是否本轮做。
- callback registry（M3.5）与 arena 的上下文传递方式。

### 6.8 M3.2 自动层设计（分类 / 约定 / 边界）

**通用约定**

1. 糖名 = 原生命令名（方案 A）；裸命令 `raw:`。
2. 糖只管理**自己分配**的 host 内存；外部指针一律手动。
3. 只对“干净形状”的命令生成糖；其余一律裸命令（宁缺勿滥）。
4. 错误：负值抛异常（`check-vk-result`）。

**分类（非 create 命令，基于 `api.rkt` 事实）**

设 `counts` = `count?` 参数（in/out 计数，单独处理）；
`outs` = `output?` 且**非** `count?` 的参数；
`host-ins` = 输入指针（`pointer?` 真、`output?` 假、非 count）。

| 类别 | 条件 | 糖形状 |
|------|------|--------|
| 单输出 | `|outs|=1`，无 `counts`，`host-ins` 仅 char | 返回该输出值 |
| 数组输出 | `|outs|=1`，`|counts|=1`，`host-ins` 仅 char | 两遍调用，返回 vector |
| 单输入 | `|outs|=0`，恰一个输入 struct 指针，无 count | 调用作用域 + 拷贝输入 |
| 数组输入 | `|outs|=0`，恰一个输入数组 + 对应 count | 调用作用域 + 拷贝数组，count 由长度定 |
| 其他 | — | 不生成（裸命令） |

**输入值形状**

- char 输入：`(or/c string? #f)` → `stable-bytes`；`#f` 传 NULL。
- 单 struct 输入：接受 struct 值 → `vk-struct-array` 拷贝到 arena。
- 数组输入：接受 vector → `vk-struct-array` 拷贝；count 取 `(vector-length v)`。

**返回约定（R1，已定）**

统一规则，对所有糖（含 create）：

- VkResult 且 N 个输出 → `(values result out1 … outN)`
- VkResult 且 0 输出 → result（单值）
- void 且 N 输出 → `(values out1 … outN)`
- void 且 0 输出 → void
- 负值一律抛异常（`check-vk-result`）；正/零结果保留。
- 数组输出：两遍调用 + `VK_INCOMPLETE` 重试，返回最终 result。

> 采用 R1 意味着现有 create 糖从“返回句柄”改为“`(values result handle)`”，
> 相关测试需迁移。这是保真换来的代价。

**糖签名示例**

```racket
;; 单输出，void 命令
(vkGetPhysicalDeviceProperties pd)            ; -> VkPhysicalDeviceProperties
(vkGetDeviceQueue dev family index)           ; -> VkQueue（handle）

;; 单输出，VkResult 命令（R1）
(define-values (r props) (vkGetPhysicalDeviceMemoryProperties pd))

;; 数组输出（enumerate）
(vkEnumeratePhysicalDevices instance)         ; -> vector of VkPhysicalDevice
(vkGetPhysicalDeviceQueueFamilyProperties pd) ; -> vector of VkQueueFamilyProperties

;; 输入类（调用作用域，count 由 vector 长度定）
(vkCmdSetViewport cmd first (vector vp1 vp2))
(vkQueueSubmit queue (vector submit1 submit2) fence)
```

**跳过清单（一律裸命令）**

- `|outs|>1`，或多个数组/多个 count。
- 输出是 `void`/`char`/`funcpointer`（bytes 输出）。
- 同时有输入 struct/数组指针和输出。
- 输入 struct/数组多于一个（如 `vkCmdBindDescriptorSets`、`vkUpdateDescriptorSets`）。
- 结果语义特殊：`vkGetQueryPoolResults`（`VK_NOT_READY`）、
  `vkAcquireNextImageKHR`（`VK_TIMEOUT`/`VK_SUBOPTIMAL_KHR`）。
- `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr`（base 手写）。

**调用作用域（1a/1b）**

- 输入类糖每次调用自带一个 arena（1a）→ 单条命令一定安全。
- `with-vk-call` = `with-vk-arena` 的语义别名（1b，定义在 safe 层），供多条命令共享。
- 跨调用保活由用户显式 `vk-handle-arena-set!` / `vk-arena-keep!`。

**命名与模块（方案 A）**

- 糖定义在 `vulkan/safe`，名 = 原生命令名；内部 `raw:` 调裸命令。
- `(require vulkan)`：`vkGetPhysicalDeviceProperties` = 糖，
  `raw:vkGetPhysicalDeviceProperties` = 裸。
- `(require vulkan/bindings)`：裸。

**生成与实现顺序**

1. M3.2a 单输出糖（void + VkResult）
2. M3.2b 数组输出糖（enumerate + `VK_INCOMPLETE` 重试）
3. M3.2c 输入类糖（单 struct / 数组 + 调用作用域）
4. M3.2d `with-vk-call`

**测试**

- `tests/auto-output.rkt`：单输出（struct/handle/scalar）、enumerate、错误抛异常、raw 仍可用。
- `tests/auto-input.rkt`：单 struct、数组（count 由长度定）、作用域释放。
- 扩展 `api-facts`：断言分类选择（哪些命令会有糖）。

### 6.9 生成器流水线：事实 → 分类 → 计划 → 逐形状生成 → 组合

把生成逻辑拆成可独立测试的局部片段，最后组合（避免一个巨型 `cond`）：

```
api facts ──classify──▶ (shape . plan) ──emit-<shape>──▶ forms ──compose──▶ safe.inc
```

**1) 分类（纯函数）**：`(classify cmd) -> (values shape plan)`。
固定枚举的 shape（固定签名匹配，按表顺序先到先得）：

| shape | 条件 |
|-------|------|
| `create/single` | `^vkCreate/Allocate`，单句柄输出，显式 count |
| `create/array` | `^vkCreate`，显式 count + 句柄数组输出 |
| `create/info-count` | `^vkAllocate`，count 在 info 结构体里 |
| `destroy/single` | `^vkDestroy/Free`，单句柄 |
| `destroy/array` | `^vkFree`，count + 句柄数组 |
| `out/single` | `|outs|=1` 无 count，输入仅 char |
| `out/array` | `|outs|=1`，`|counts|=1`，输入仅 char |
| `in/single` | `|outs|=0`，一个输入 struct 指针，无 count |
| `in/array` | `|outs|=0`，一个输入数组 + count |
| `skip` | 其他 |

**2) 计划（plan）**：分类时就把所有 slot 解析好，emit 阶段不再回看 XML：

```
(plan cmd shape level result? dispatch passthrough
      output count input count-info-field)
```

**3) 逐形状 emitter**：`emit-create-single` / `emit-out-array` … 每个只吃 plan，互不引用；
共享小工具（`checked-call` 等）保持独立。

**4) 组合 driver**：按 `wanted-cmds` 顺序 classify → 查 emitter 表 → 收集 forms。

**好处**：分类是纯函数，可对 `api.rkt` 全量断言；每个 emitter 独立可测；
新增形状不动已有 emitter；create/destroy 也统一进这套流程，取代散落的 `safe-create-form` 分支。

**测试**：`tests/gen-shapes.rkt` —— 对全量命令跑 classify，断言：

- 分类确定，且代表性命令落入预期 shape；
- 每个 non-skip shape 至少有一个真实命令（防止 emitter 变成死代码）；
- `skip` 的原因可列举（多输出/多输入/char 输出等）。

---

## 7. 路线图

| 阶段 | 内容 | 层 |
|------|------|----|
| M1 ✅ | 模块拆分 bindings / memory / unsafe / safe | 全部 |
| M2 ✅ | base 去 policy，原始命令返回 VkResult | bindings + safe |
| M3.0 ✅ | `generated/api.rkt` 命令/参数事实层（无行为变化） | bindings 产出 |
| M3.G ✅ | 生成器拆分为 `vulkan/gen/`（classify/emit 流水线），IR 移到运行期 `vulkan/api-facts` | generate |
| M3.1 ✅ | 原语扩展：`vk-arena-reset!` / `vk-arena-keep!` / `with-vk-frame` | memory |
| M3.2a ✅ | 单输出糖（`vkGet*` struct/handle/scalar） | safe |
| M3.2b ✅ | 数组输出糖（enumerate + `VK_INCOMPLETE` 重试） | safe |
| M3.2c ✅ | 输入类糖（数组 + 调用作用域；flat 限制） | safe |
| M3.2d ✅ | `with-vk-call`（序列共享调用作用域） | safe |
| M3.5 | funcpointer 回调 + callback registry | safe |
| M4 ✅ | C 程序 `sizeof`/`alignof` ABI 对照（335 个 core struct/union） | tests |
| D6 | pNext/sType 辅助 | safe |
| E1/E3 | 扩展覆盖 + bitfield（G1） | generate |
| N1 ✅ | 命名收敛（词表 + 分层回归）：§2.2；IR 出 `gen/`、策略归 safe、枚举去伪结果 | 全部 |
