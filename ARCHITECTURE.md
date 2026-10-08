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

三个顶层角色（目录 = 集合，依赖单向）：

| 角色 | 位置 | 依赖 | 参与运行期 |
|------|------|------|:---:|
| 资源 | `registry/*.xml` | 无（纯数据） | ✗ |
| 生成器 | `vulkan-gen/` | `vulkan/api-facts`（IR 契约）+ 资源 | ✗（构建期） |
| 最终目标 | `vulkan/` | 无（用已提交的 `generated/`） | ✓ |

生成器输出分开：运行期需要的 `*.inc`/`facts.rkt` → `vulkan/generated/`；
审计产物 `abi_check.c`/`unknown-types.txt` → `vulkan-gen/audit/`。
`vulkan` 对 `vulkan-gen`/`registry` 零引用——删掉后两者，运行期仍可编译运行。

```
registry/*.xml ──(vulkan-gen/main.rkt)──▶ vulkan/generated/{constants,types,commands,safe,pnext}.inc + facts.rkt
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
            vulkan/manual.rkt   vulkan/safe.rkt
            （手动 = bindings    （组合层：context（缓存/arena 注册表）+
              + memory；           result（错误/枚举）+ callback / pnext /
               unsafe = 别名）       capability / map + vk-create-* 糖）
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
| `vulkan/memory` | arena 原语、`vk-malloc`/`stable-bytes`/`vk-new`、作用域 | 任何 Vulkan 类型/命令、handle↔arena（归 context） |
| `vulkan/result` | `check-vk-result` + `vk-enumerate-result`/`-void`（错误/枚举支撑） | 包装、所有权 |
| `vulkan/context` | `vk-context`（instance/device/命令缓存/arena 注册表）+ handle↔arena 绑定 + `with-vk-context` | 原语、命令 |
| `vulkan/callback` | 回调令牌：稳定 `_cprocedure` 指针 + 保活 | 分配器实现、驱动回调策略 |
| `vulkan/pnext` | pNext/sType 糖（`vk-struct` / `vk-chain!`） | 驱动的链校验策略 |
| `vulkan/capability` | 扩展枚举与可用性（instance/device）+ `vk-proc-available?` | 降级策略 |
| `vulkan/map` | 设备内存映射薄封装（`vk-map` / `vk-unmap`） | GC 接管、所有权 |
| `vulkan/manual` | 手动模式 = `bindings` + `memory`（裸命令 + arena） | 错误策略、create 包装 |
| `vulkan/unsafe` | 已弃用别名（= `vulkan/manual`） | — |
| `vulkan/safe` | 组合层总入口：`check-vk-result` + `vk-create-*`/`vk-destroy-*` + context/callback/pnext/capability/map | 裸命令（靠模块隔离区分） |
| `vulkan/api-facts` | 运行期 API 事实 IR（`vk-param`/`vk-command`） | 生成逻辑、策略 |
| `vulkan-gen/*` | 生成器（构建期，不参与运行期）：`vk-registry`（读 XML + 闭包）/ `extension-select`（common/all）/ `constants` / `ctype` / `facts-build` / `emit-*` / `classify` / `main` | 运行期依赖 |
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
| handle→arena 查询 | `vk-object-arena` | `vk-handle-arena`（context 层持有，默认 per-thread） |
| arena 字段 | `items` | `kept` |
| 读回句柄数组 | `vk-handle-vector` | `vk-read-handles`（归 safe） |
| 错误检查 | `check-vkResult` | `check-vk-result` |
| string→cstring | `vk-char` | `vk-cstring` |
| 枚举输出 | `vk-enumerate-array` / `…/void` | `vk-enumerate-result` / `vk-enumerate-void` |
| 运行期 IR | `vulkan/gen/facts.rkt` | `vulkan/api-facts.rkt` |
| 事实列表 | `vk-api` | `vk-command-facts` |
| 调用作用域 | `with-vk-call`（memory） | `with-vk-call`（safe，策略别名） |
| dispatch 上下文 | `register-vk-instance!` / `register-vk-device!` | `vk-use-instance!` / `vk-use-device!` |
| 当前上下文参数 | `current-instance` / `current-device` | `current-vk-instance` / `current-vk-device` |
| 分派缓存 | `proc-cache` / `vk-invalidate-cache!` | `vk-proc-cache` / `vk-proc-cache-clear!` |
| 符号解析 | `vk-symbol` / `vk-resolve` | `vk-lib-symbol` / `vk-resolve-proc` |
| 手动入口 | `vulkan/unsafe` | `vulkan/manual`（`unsafe` 保留为弃用别名） |
| 窗口句柄 | `glfw-window-ptr` | `glfw-window-handle` |
| 创建 surface | `glfw-window-create-surface` | `glfw-create-vk-surface` |
| 原生句柄 | `glfw-window-x11` / `glfw-window-wayland` | `glfw-window-x11-handles` / `glfw-window-wayland-handles` |
| 测试文件 | `tests/arena-test.rkt` | `tests/memory-arena.rkt` |
| 结果/枚举支撑模块 | `vulkan/support.rkt` | `vulkan/result.rkt` |
| 窗口模块（GLFW） | `vulkan/window.rkt` | `vulkan/glfw.rkt` |
| safe.inc emitter | `vulkan-gen/emit.rkt` | `vulkan-gen/emit-safe.rkt` |
| 扩展选择 | `vulkan-gen/extensions.rkt` | `vulkan-gen/extension-select.rkt` |
| 注册表加载 | `vulkan-gen/registry.rkt` | `vulkan-gen/vk-registry.rkt` |
| 生成器主体 / CLI | `vulkan/generate.rkt`（全部） | `vulkan-gen/main.rkt`（`generate!` + `module+ main` CLI） |
| 事实数据 | `generated/api.rkt` | `generated/facts.rkt` |
| 安全糖测试 | `tests/auto-input.rkt` / `auto-output.rkt` | `tests/safe-input.rkt` / `safe-output.rkt` |

**分层的判据**：只做计算/按 arena 管引用（Vulkan 无关）的留在原语层；
替用户选“用哪个作用域/怎么报错”的属于组合层。`with-vk-frame` 是纯 arena 机制，留
memory；`with-vk-call`、`vk-read-handles`、枚举辅助是使用策略，归 safe。

**handle↔arena 归属**：`vk-handle-arena-set!`/`-remove!`/`vk-handle-arena` 与
`current-vk-arena-registry` 定义在 `vulkan/context`（注册表是状态，N4 后统归 context）；
`vulkan/memory` 只保留 arena 原语。早先文档把它们归在 memory，已纠正。

---

## 3. 生成 vs 手动

| 内容 | 生成 | 手动 | 归属 |
|------|:----:|:----:|------|
| 常量 / ctype / 布局 / alias / 分派级别 | ✅ | | bindings |
| 命令签名 | ✅ | | bindings |
| funcpointer ctype（`_PFN_*` → `_cprocedure`） | ✅ | | bindings |
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
  `vk-handle-arena-set!` 到返回的句柄上（绑定函数在 `vulkan/context`）；
  `vk-destroy-*`/`vk-free-*` 时 `vk-handle-arena-remove!`。
- 句柄↔arena 注册表用 `equal?`（`make-hash`），因为数组元素 `ptr-ref` 读回的是
  地址相同但 `eq?` 不同的新 cpointer。注册表本身**不是全局**：默认按线程惰性创建，
  存在 `vulkan/context` 的 `current-vk-arena-registry` 参数里；需共享就用 `with-vk-context`。

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
- **B3**：`pNext` 链用 `vk-chain!` 串接时会把各节点登记到当前 arena（自动保活）；
  `vk-struct` 自动填 `sType`。手工 `set-VkX-pNext!` 仍不强制。
  **触发**：出现难以排查的悬空 `pNext` → 考虑在 `make-VkX` 层面强制登记。
- **B4**：arena 生命周期 = 对象生命周期，**可能严重过度保留**。
  典型反例：长寿命 command buffer / descriptor set 反复用 `vk-new` 传入每帧数据，
  arena 无界增长。**触发**：出现按帧分配 → 需要「帧 arena / 显式 reset」。

### C. 回调（funcpointer）
- **C1**：`_PFN_*` 现在是 `_cprocedure`（可作参数/转换）；**结构体里的函数指针字段仍是
  `_pointer`**。用 `vulkan/callback` 的 `make-vk-callback` / `vk-callback-keep!` 只转换一次
  得到稳定指针，并把令牌登记进对象 arena。注意 `_cprocedure` 默认保活是**弱表**
  （按 Racket 过程可达），且同一过程重复转换会被覆盖 → 必须持有令牌。
- **C2**：回调可能在任意/驱动线程触发，`current-vk-arena` 是 thread-local，回调内无效。
  上下文用闭包捕获或 `pUserData`。

### D. 线程
- **D1**：运行期不再有模块级可变全局。命令缓存（`current-vk-proc-cache`）与
  handle↔arena 注册表（`current-vk-arena-registry`）都是参数状态，值带 **owner 标记**
  `(owner . value)`：owner 不是当前线程就另建（因为线程会继承父线程的参数**值**）。
  默认按线程隔离 → 无需锁/CAS。要共享就显式建 `vk-context` 并用
  `with-vk-context`（owner=#f），并发由用户负责。
- **D2**：Racket 线程会继承创建时的 parameterization；预存在的 worker 线程用
  `vk-arena-thread` / `vk-arena-run` 绑定 arena，或手动 `vk-use-instance!`/`vk-use-device!`。
  `vk-use-instance!`/`vk-use-device!` 会同步更新当前 `vk-context`。

### E. 句柄表示
- **E1**：handle 统一 `_cpointer/null`，在 64 位构建正确。32 位构建下
  non-dispatchable handle 是 `uint64_t`。**触发**：需要 32 位支持。
- **E2**：注册表按地址相等；若 `vkDestroy*` 漏调，或地址被新对象复用，
  可能 stale/误命中。**触发**：出现句柄地址复用问题 → 换带世代号的句柄包装。

### F. 错误 / 版本
- **F1**：命令不可用时抛 `exn:fail:vulkan:unavailable`（可捕获）；`vk-proc-available?`
  可预检；`vulkan/capability` 枚举 instance/device 扩展并判断可用性。
  按版本降级仍需调用方判断（`vkEnumerateInstanceVersion` / 设备 `apiVersion`）。
- **F2**：`check-vk-result` 只对负值抛错，`VK_INCOMPLETE`/`VK_TIMEOUT` 等由调用方处理。

### G. 生成
- **G1**：alias 已解析；**bitfield 已按存储单元打包**成底层整型字段（`_bitsN`），
  并生成掩码/移位访问器（`VkX-<field>` / `set-VkX-<field>!`）；**多维数组保留全部维度**
  （`float matrix[3][4]` → `(_array _float 3 4)`）。由 `tests/bitfield.rkt` 锁定。
- **G2**：未识别类型不再静默：`ctype-of-type-name` 记录到 `vulkan-gen/audit/unknown-types.txt`，
  可用 `VULKAN_GEN_STRICT=1` 报错。当前 `common` 与 `all` 均 **0 未知类型**
  （Win32 / DirectFB / NvSci / StdVideo 等外部类型已映射进 `platform-ctype`）。

---

## 6. 设计原则与 M3：原语 + 策略

**总原则（约束所有后续设计）**

1. **原语优先**：功能原子（atom）是基础，包装（wrapper）只是糖。
2. **包装建立在原语之上**：任何包装都能用原语等价展开。
3. **包装只适用于特定场景**：每个包装写明适用边界，不追求普适。
4. **裸能力永远保留**：用户总能绕过包装，直接用原语/原始命令。
5. **自动层只管理自己分配的内存**：外部指针一律手动，不做隐式接管。

### 6.1 功能原子（`memory.rkt` + `context.rkt`，手动亦可直接用）

| 类别 | 原子 |
|------|------|
| 不移动分配 | `vk-malloc` / `vk-zero` / `vk-struct-array` / `stable-bytes` |
| 生命周期令牌 | `make-vk-arena` / `vk-arena` / `vk-arena-keep-current!` / `vk-arena-keep!` / **`vk-arena-reset!`（新增）** |
| 作用域 | `with-vk-arena` / `call-with-vk-arena` |
| 附着/保活（`context.rkt`） | `vk-handle-arena-set!` / `vk-handle-arena-remove!` / `vk-handle-arena` |

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

### 6.5 bindings 产出事实：`vulkan/generated/facts.rkt` + `vulkan/api-facts`

单解析器产出归一化事实（结构体定义在运行期模块 `vulkan/api-facts`，数据在
`vulkan/generated/facts.rkt`），供自动层与测试消费：

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
- 回调上下文与 arena 的传递方式（现：闭包/`pUserData`，见 §6.11）。

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

- `tests/safe-output.rkt`：单输出（struct/handle/scalar）、enumerate、错误抛异常、raw 仍可用。
- `tests/safe-input.rkt`：单 struct、数组（count 由长度定）、作用域释放。
- 扩展 `api-facts`：断言分类选择（哪些命令会有糖）。

### 6.9 生成器流水线：事实 → 分类 → 计划 → 逐形状生成 → 组合

把生成逻辑拆成可独立测试的局部片段，最后组合（避免一个巨型 `cond`）：

```
XML ─vk-registry─▶ facts-build ─▶ vk-command ─classify─▶ (shape . plan)
                                         ─emit-<shape>─▶ forms ─compose─▶ safe.inc
```

模块：`xexpr`（XML 工具）/ `vk-registry`（读 XML + feature/extension 闭包）/
`extension-select`（扩展选择）/ `constants`（常量）/ `ctype`（类型映射 + 成员）/
`facts-build`（XML→IR）/ `emit-types`、`emit-commands`、`emit-api`、`emit-pnext`（各产出）/
`classify` + `emit-safe`（safe.inc）。`vulkan-gen/main.rkt` 做参数闭包/拓扑排序/写文件；
CLI 是它的 `module+ main`（`racket vulkan-gen/main.rkt [args]`）。

**1) 分类（纯函数）**：`(classify cmd) -> (values shape plan)`。
固定枚举的 shape（固定签名匹配，按表顺序先到先得）：

| shape | 条件 |
|-------|------|
| `make-handle` | `^vkCreate` 单句柄输出；或 `^vkAllocate` 无 count 字段 |
| `make-handles` | `^vkCreate`，显式 count + 句柄数组输出 |
| `make-handles-info-count` | `^vkAllocate`，count 在 info 结构体里 |
| `destroy-handle` | `^vkDestroy` / `^vkFree`，单句柄 |
| `destroy-handles` | `^vkFree`，count + 句柄数组 |
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

**3) 逐形状 emitter**：`emit-make-handle` / `emit-out-array` … 每个只吃 plan，互不引用；
共享小工具（`checked-call` 等）保持独立。

**4) 组合 driver**：按 `wanted-cmds` 顺序 classify → 查 emitter 表 → 收集 forms。

**好处**：分类是纯函数，可对 `api.rkt` 全量断言；每个 emitter 独立可测；
新增形状不动已有 emitter；create/destroy 也统一进这套流程，取代散落的 `safe-create-form` 分支。

**测试**：`tests/gen-shapes.rkt` —— 对全量命令跑 classify，断言：

- 分类确定，且代表性命令落入预期 shape；
- 每个 non-skip shape 至少有一个真实命令（防止 emitter 变成死代码）；
- `skip` 的原因可列举（多输出/多输入/char 输出等）。

### 6.10 位域与多维数组（布局事实）

Racket `define-cstruct` 不支持 C 位域，所以**一个存储单元打成一个底层整型字段**：

- `ctype.rkt` 的 `struct-layout` 扫描成员，把连续位域（同宽、不溢出单元）归并成
  一个 `_uint32`/`_uint64` 字段，名为 `_bits0`、`_bits1`…（不冒充真实成员），
  记录每位的 `(offset width)`；`reserved` 只占位。
- `emit-types.rkt` 在每个具名位域上生成 getter `VkX-<field>`（掩码+移位）与
  setter `set-VkX-<field>!`（读改写）。
- 多维数组用 `(_array ctype dim ...)`（如 `float matrix[3][4]` → `(_array _float 3 4)`）。

例：`VkAccelerationStructureInstanceKHR` →
`((transform _VkTransformMatrixKHR) (_bits0 _uint32) (_bits1 _uint32)
(accelerationStructureReference _uint64))`，`sizeof=64 / align=8`，由 `tests/bitfield.rkt`
对照 gcc 锁定。

### 6.11 回调（`vulkan/callback`）

`_PFN_*` 生成为 `_cprocedure`；结构体里的函数指针字段保持 `_pointer`，避免
“同一 Racket 过程重复转换 → trampoline 被弱表覆盖”的悬空。

```racket
(vk-new make-VkDebugUtilsMessengerCreateInfoEXT
        VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
        #f 0 severity types
        (vk-callback-keep! _PFN_vkDebugUtilsMessengerCallbackEXT proc) ; -> 稳定 _pointer
        #f)                                                             ; pUserData
```

- `make-vk-callback`：转换一次得到稳定指针，令牌强引用 Racket 过程（保活 trampoline）。
- `vk-callback-keep!`：建令牌 + 登记当前 arena（builder 内用 → 绑到返回对象生命周期）+ 返回指针。
- `vk-callback-release!`：放弃保活（调用方保证 C 侧不再引用）。
- 回调线程不继承动态参数，上下文用闭包或 `pUserData`。

### 6.12 pNext / sType（`vulkan/pnext`）

生成 `generated/pnext.inc` 两张表：`vk-struct-sType`（struct 名 → sType 值）与
`vk-pNext-setters`（sType 值 → `set-VkX-pNext!`）。

```racket
;; 自动 sType + pNext=#f，并登记到当前 arena
(define ici (vk-struct make-VkInstanceCreateInfo 0 #f 0 #f 0 #f))
(define dbg (vk-struct make-VkDebugUtilsMessengerCreateInfoEXT 0 sev types #f #f))
;; 串链 ici -> dbg；按每个节点的 sType 查 setter，并把节点登记到 arena（B3）
(vk-chain! ici dbg)
```

只覆盖“干净形状”（首成员 `sType`、次成员 `pNext`）；裸 `set-VkX-pNext!` 仍可用。

### 6.13 能力查询与降级（`vulkan/capability`）

- `vk-proc-available?`（base）：命令在当前上下文能否解析，不抛异常。
- `vk-instance-extension-properties` / `vk-device-extension-properties`：扩展名列表。
- `vk-instance-extension-available?` / `vk-device-extension-available?`：成员判断。
- 命令不可用时 `define-vk` 抛 **`exn:fail:vulkan:unavailable`**（带 `command` 字段）：
  ```racket
  (with-handlers ([exn:fail:vulkan:unavailable? (λ (e) ...fallback...)])
    (vkSomeExtensionCommand ...))
  ```

### 6.14 消除全局状态：context 层（`vulkan/context`）

base/memory **没有模块级可变全局**；需要「默认/共享」的状态都提升为参数或 context：

| 状态 | 位置 | 默认 |
|------|------|------|
| 命令指针缓存 | `current-vk-proc-cache`（base） | 当前线程（owner 标记） |
| handle↔arena 注册表 | `current-vk-arena-registry`（context） | 当前线程（owner 标记） |

- 参数值带 owner：线程继承到父线程的值时，owner 不匹配就另建 → **默认无跨线程共享**。
- 需要显式/跨线程共享：`(make-vk-context)` + `(with-vk-context ctx thunk)`（owner=#f）绑定
  instance/device/缓存/注册表；并发由用户负责。
- `vk-use-instance!` / `vk-use-device!` 现在会同步更新当前 `vk-context`（单一事实源）。
- `vk-arena-run` / `vk-arena-thread` 供（预存在的） worker 线程绑定 arena。

---

## 7. 路线图

| 阶段 | 内容 | 层 |
|------|------|----|
| M1 ✅ | 模块拆分 bindings / memory / unsafe / safe | 全部 |
| M2 ✅ | base 去 policy，原始命令返回 VkResult | bindings + safe |
| M3.0 ✅ | `generated/facts.rkt` 命令/参数事实层（无行为变化） | bindings 产出 |
| M3.G ✅ | 生成器拆分为 `vulkan/generator/`（classify/emit-safe 流水线），IR 移到运行期 `vulkan/api-facts` | generate |
| M3.1 ✅ | 原语扩展：`vk-arena-reset!` / `vk-arena-keep!` / `with-vk-frame` | memory |
| M3.2a ✅ | 单输出糖（`vkGet*` struct/handle/scalar） | safe |
| M3.2b ✅ | 数组输出糖（enumerate + `VK_INCOMPLETE` 重试） | safe |
| M3.2c ✅ | 输入类糖（数组 + 调用作用域；flat 限制） | safe |
| M3.2d ✅ | `with-vk-call`（序列共享调用作用域） | safe |
| M3.5 ✅ | funcpointer `_cprocedure` + `vulkan/callback` 令牌（稳定指针 + arena 保活） | safe + generate |
| M3.3 ✅ | 设备内存映射 `vk-map` / `vk-unmap`（薄封装，不归 GC） | safe |
| M4 ✅ | C 程序 `sizeof`/`alignof` ABI 对照（335 个 core struct/union） | tests |
| G1 ✅ | bitfield 存储单元打包 + 多维数组（`_array` 多维 + 访问器生成） | generate |
| E1/E3 ✅ | 扩展选择 `common`/`all` + 未知类型审计（bitfield/multi-dim 前置已修） | generate |
| F1 ✅ | capability 门控：`vk-proc-available?` + 扩展枚举 + 可捕获的 unavailable 异常 | safe + base |
| D6 ✅ | pNext/sType 糖：`vk-struct` / `vk-chain!` + 生成 `pnext.inc` | safe + generate |
| E1/E3 | 扩展覆盖 + bitfield（G1） | generate |
| N1 ✅ | 命名收敛（词表 + 分层回归）：§2.2；IR 出 `generator/`、策略归 safe、枚举去伪结果 | 全部 |
| N2 ✅ | 公开名收敛（`vk-use-*`/`current-vk-*`/`manual`/window）+ `gen/`→`generator/` + shape 词表 | 全部 |
| N3 ✅ | `generate.rkt` 拆为 vk-registry/constants/ctype/facts-build/emit-*（输出逐字节不变） | generate |
| N4 ✅ | 消除全局状态：命令缓存/arena 注册表 → 参数 + `vulkan/context` 层（默认 per-thread） | 全部 |
| N5 ✅ | 默认语义收敛：owner 标记保证 per-thread 隔离；`vk-use-*` 同步更新当前 context | 全部 |
| N6 ✅ | 模块命名收敛：`support`→`result`、`window`→`glfw`、`emit`→`emit-safe`、`extensions`→`extension-select`、`registry`→`vk-registry`、`generated/api`→`facts`、`auto-*`测试→`safe-*`；`command->datum` 拆到 `emit-api`；生成器主体移 `generator/main` 留薄 CLI；纠正 handle↔arena 归属（memory→context） | 全部 |
| N7 ✅ | 生成默认对齐提交配方（`VK_VERSION_1_4` + `common`，no-arg 可复现 `generated/`）；`#f` 哨兵区分“未给”与“显式空”；打印生效参数；新增 Racket 构建脚本 `rebuild.rkt [vk.xml]` | generate |
| N8 ✅ | 常量解析补齐：`~N` 位取反（含 `~1U`/`~2U`）+ 字符串枚举值（`VK_*_EXTENSION_NAME` → bytes）；`tests/constants.rkt` | generate |
| N9 ✅ | 资源/生成器/目标分层：`vulkan/generator/`→`vulkan-gen/` 集合、`vulkan/registry/`→`registry/`、审计产物→`vulkan-gen/audit/`、`vulkan/experiments/`→`experiments/`；生成器 CLI 合入 `vulkan-gen/main.rkt`；运行期公共路径不变 | 全部 |
