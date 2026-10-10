# racket-vulkan

从 Khronos 官方 `vk.xml` **自动生成** Racket 的 Vulkan FFI 绑定。思路参考 Racket 自带的
OpenGL 绑定（`racket/opengl` 的 `readspec.rkt` + `main.rkt`）。

> 状态：**可用原型**。当前生成 **Vulkan 1.4 core + 10 个常用扩展**（280 命令 / 652 类型 /
> 2224 常量），带安全层。已跑通：instance/device、完整 compute（与参考实现逐字节一致，
> md5 `947e43451635cb72358ae61e0a5d1fc7`）、Xlib surface + swapchain；验证层零报错。
> 详见 `RESEARCH.md`。

## 目录

```
racket-vulkan/
  info.rkt                    # 多集合包元数据（collection 'multi）
  rebuild.rkt                 # 构建脚本：racket rebuild.rkt [vk.xml]（生成 + raco make）
  fetch-registry.rkt          # 资源脚本：racket fetch-registry.rkt <version>（按版本拉 vk.xml）
  vulkan/                     # 集合 vulkan：运行期绑定（最终目标）
    info.rkt
    main.rkt                  # (require vulkan)           => facade：糖 + 类型/常量/原子 + raw: 裸命令
    base.rkt                  # (require vulkan/base)      => 类型/常量/分派设施（无命令）
    commands.rkt              # (require vulkan/commands)  => 原始命令（返回 VkResult）
    bindings.rkt              # (require vulkan/bindings)  => 原始表面 = base + commands
    raw.rkt                   # (require vulkan/raw)       => = bindings（语义别名）
    memory.rkt                # (require vulkan/memory)    => arena/分配原语（R5）
    result.rkt                # VkResult 错误检查 + 枚举输出（safe/capability 共用）
    context.rkt               # vk-context + handle↔arena 注册表（instance/device/缓存，默认 per-thread）
    api-facts.rkt             # 运行期 API 事实 IR：vk-param / vk-command
    callback.rkt              # 回调令牌：稳定 _cprocedure 指针 + 保活
    pnext.rkt                 # pNext/sType 糖：vk-struct / vk-chain!
    capability.rkt            # 扩展枚举/可用性（instance/device）
    map.rkt                   # 设备内存映射：vk-map / vk-unmap
    manual.rkt                # (require vulkan/manual)    => 手动模式 = bindings + memory
    unsafe.rkt                # (require vulkan/unsafe)    => 已弃用别名（= manual）
    safe.rkt                  # (require vulkan/safe)      => 组合层总入口（原生名，不导出裸命令）
    safe-support.rkt          # safe 糖运行期小工具（vk-read-handles / vk-cstring）
    glfw.rkt                  # (require vulkan/glfw)      => GLFW 窗口（与绑定无关）
    version.rkt               # (require vulkan/version)   => 绑定版本/provenance（vk-binding-version 等）
    generated/                # 生成物（运行期需要；不要手改；均为真模块）
      constants.rkt           # VK_* 常量（整数；无依赖）
      types.rkt               # _VkX ctype / define-cstruct（require constants）
      commands.rkt            # (define-vk ...) 原始命令 + 分派层级（require base）
      safe.rkt                # 糖：vkCreate*/vkGet*/vkCmd*（原生名，R1 返回值，含 check-vk-result）
      pnext.rkt               # vk-struct-sType / vk-pNext-setters 表
      facts.rkt               # 命令/参数事实（vk-command/vk-param），供组合层/测试消费
      version.rkt             # 绑定版本/provenance（vk-binding-version 等）
  vulkan-gen/                 # 集合 vulkan-gen：生成器（构建期，不参与运行期）
    info.rkt
    main.rkt                  # driver：解析 -> 生成 -> 输出（generate! + CLI）
    parse.rkt                 # 解析层：vk.xml -> vk-model（预定义常量/枚举/结构体/函数）
    generate.rkt              # 生成层：vk-model -> vk-artifact（模块依赖/模块体/导出）
    module.rkt                # 模块三部分（deps/body/exports）+ 写出（真模块）
    template.rkt              # 模板加载：@@KEY@@ 字符串替换
    model.rkt                 # 领域模型（vk-model/vk-type/vk-func）+ 诊断（自足）
    xexpr.rkt                 # 极简 XML 读取工具
    vk-registry.rkt           # 读 XML + feature/extension 依赖闭包
    extension-select.rkt      # 扩展选择：common / all / 逗号列表
    constants.rkt             # 常量值解析与排序
    ctype.rkt                 # C 类型 -> ctype + struct 成员解析
    facts-build.rkt           # XML -> vk-command / vk-param（运行期 IR）
    emit-types.rkt            # types.rkt（枚举/结构体/其它类型形式）
    emit-commands.rkt         # commands.rkt（函数形式）
    emit-api.rkt              # vulkan/generated/facts.rkt 模块体 + 输出
    emit-pnext.rkt            # pnext.rkt（sType / pNext setter 表）
    emit-version.rkt          # generated/version.rkt 模块体 + 输出
    classify.rkt              # 命令 -> (shape . plan)（纯函数）
    emit-safe.rkt             # safe.rkt（逐形状 emitter + 组合）
    templates/                # 外置模板程序（不嵌进 Racket 代码）
      module.rkt.tmpl         # 完整模块骨架（deps + body + exports）
      facts.rkt.tmpl          # generated/facts.rkt 骨架
      version.rkt.tmpl        # generated/version.rkt 骨架
      abi_check.c.tmpl        # ABI 对照 C 程序骨架
    audit/                    # 审计产物（生成器输出，非运行期）
      abi_check.c             # ABI 对照 C 程序（core struct/union 的 sizeof/alignof）
      unknown-types.txt       # 未知类型审计（降级为 _pointer 的类型；应为空）
      diagnostics.txt         # 全部降级/跳过诊断（领域 + 实体 + 原因，不静默）
  registry/                   # 资源：Vulkan 注册表（生成器输入）
    vk-1.4.363.xml            # 生成基准（最新稳定 SDK tag）
    vk-1.4.309.xml            # 与本机 loader 对齐
    vk-main.xml               # 上游 main（含未定稿扩展）
  experiments/                # 前期调研脚本 + 2019 旧绑定对照（不参与编译）
  tests/
    smoke.rkt                 # 建 instance + 枚举物理设备 + 读属性
    device.rkt                # 建逻辑设备 + 经 GDPA 调 device 级命令
    compute-raw.rkt           # 完整 compute（裸 API）
    compute-safe.rkt          # 完整 compute（安全层 + 数组 create）
    surface-x11.rkt           # Xlib surface + swapchain（手写 X11）
    triangle-glfw.rkt         # 图形管线 + 渲染 + 显示（用 vulkan/glfw）
    triangle-x11.rkt          # 同上，但手写 X11（对照）
    shaders/                  # triangle.vert/.frag + 编译出的 .spv
    memory-arena.rkt          # 内存/所有权单元测试
    safe-ownership.rkt        # 数组 free 的所有权回归
    dispatch-cache.rkt        # 分派缓存按 instance/device 分桶回归
    generate-aliases.rkt      # 生成器 alias 正确性 + 可复现回归
    vkresult.rkt              # VkResult 返回/抛出语义回归
    api-facts.rkt             # generated/facts.rkt 事实层回归
    memory-scope.rkt          # 生命周期令牌原语回归
    module-surface.rkt        # 命名契约（糖/裸命令模块隔离）回归
    gen-shapes.rkt            # classify 全量断言
    gen-pipeline.rkt          # 流水线局部化：解析自足/可复现、四类划分、模块契约、快照
    dispatch-audit.rkt        # GIPA/GDPA 全量对账：dispatch 层级与真实 loader 一致（需设备）
    safe-output.rkt           # 安全输出糖（单输出 / enumerate）
    safe-input.rkt            # 输入类糖（调用作用域 + 数组）
    abi.rkt                   # C sizeof/alignof ABI 对照
    bitfield.rkt              # 全部位域结构体：存储单元打包 + 多维数组，整段字节 dump 对照 gcc
    extensions.rkt            # 扩展选择（common/all）+ 未知类型/常量解析审计回归
    constants.rkt             # 常量值解析（~N 位取反 + 字符串扩展名）回归
    callback.rkt              # 回调保活（稳定指针 / arena 保活 / 往返调用）
    pnext.rkt                 # pNext/sType（vk-struct 自动 sType + vk-chain! 保活）
    capability.rkt            # vk-proc-available? + 扩展枚举 + unavailable 异常
    map.rkt                   # 设备内存 map/unmap（写读回验证）
    context.rkt               # 状态分层：context 共享 / 线程隔离 / vk-use-* 同步
    version.rkt               # 包版本 == 生成物版本 == registry 版本
    templates/                # 外置探针程序 / C 对照模板（bitfield 用）
    comp.spv                  # 预编译 SPIR-V（Mandelbrot，来自参考实现）
  README.md
  ARCHITECTURE.md             # 分层、GC/所有权冲突、假设与“重新考虑触发条件”
  RESEARCH.md                 # 完整调研报告
```

模块职责（分层：事实 / 所有权 / 策略；命名靠模块隔离，见下）：

| `(require ...)` | 内容 |
|-----------------|------|
| `vulkan/base` | 类型/常量/分派设施（`define-vk`、GIPA/GDPA） |
| `vulkan/commands` | 原始命令（返回 `VkResult`） |
| `vulkan/bindings` / `vulkan/raw` | 原始表面 = base + commands（裸命令用 Vulkan 原生名） |
| `vulkan/memory` | arena/分配原语（`vk-malloc`/`stable-bytes`/arena/作用域） |
| `vulkan/result` | `check-vk-result` + `vk-enumerate-result`/`-void`（safe/capability 共用） |
| `vulkan/context` | `vk-context`（instance/device/命令缓存）+ handle↔arena 注册表 + `with-vk-context`；默认按线程隔离（owner 标记），无全局 |
| `vulkan/callback` | 回调令牌（`make-vk-callback`/`vk-callback-keep!`，稳定指针 + 保活） |
| `vulkan/pnext` | pNext/sType 糖（`vk-struct` 自动 sType、`vk-chain!` 串链 + 保活） |
| `vulkan/capability` | 扩展枚举与可用性（`vk-proc-available?`、instance/device 扩展） |
| `vulkan/map` | 设备内存映射薄封装（`vk-map` / `vk-unmap`，不归 GC） |
| `vulkan/manual` | 手动模式 = `bindings` + `memory`（裸命令 + arena，无错误策略） |
| `vulkan/unsafe` | 已弃用别名（= `vulkan/manual`） |
| `vulkan/safe` | 组合层总入口（`check-vk-result` + `vkCreate*`/`vkGet*`/`vkCmd*` 糖 + context/callback/pnext/capability/map），糖也是 Vulkan 原生名，**不导出裸命令** |
| `vulkan/safe-support` | safe 糖运行期小工具（`vk-read-handles`/`vk-cstring`），被 `generated/safe.rkt` require |
| `vulkan` | facade：糖（原生名）+ 类型/常量/原子，裸命令以 `raw:` 前缀 |
| `vulkan/api-facts` | 运行期 API 事实 IR（`vk-param`/`vk-command`） |
| `vulkan/generated/facts` | 命令/参数事实数据（`vk-command-facts`），供组合层/测试消费 |
| `vulkan-gen/*` | 生成器（构建期，不参与运行期）：解析 `parse`（`vk-registry`/`extension-select`/`constants`/`ctype`/`facts-build`）→ 生成 `generate`（`emit-*`/`classify`/`module`）→ 输出 `main`；模块骨架/ABI C 模板在 `templates/`（`template` 加载） |
| `vulkan/version` | 绑定版本/provenance（`vk-binding-version`/`vk-registry-file`/`vk-generated-feature`/`vk-generated-extensions`） |
| `vulkan/glfw` | GLFW 窗口，与绑定无关 |

> **命名靠模块隔离（方案 A）**：`vulkan/safe` 的 `vkCreateBuffer` 是糖（builder），
> `vulkan/bindings` 的 `vkCreateBuffer` 是裸命令（原始签名）；同名不同模块，由模块显式区分。
> `(require vulkan)` 默认给糖（原生名），裸命令是 `raw:vkCreateBuffer`；
> 想看裸命令就 `(require vulkan/raw)`。不需要任何命名前缀约定。
> 运行期符号的词表（arena/handle/param 等）见 `ARCHITECTURE.md` §2.2。

## 获取资源（vk.xml）

注册表按**版本**从 Khronos 官方仓库拉取，命名统一为 `registry/vk-<version>.xml`：

```bash
racket fetch-registry.rkt 1.4.363     # -> registry/vk-1.4.363.xml（tag v1.4.363）
racket fetch-registry.rkt main         # -> registry/vk-main.xml（上游 main）
racket fetch-registry.rkt --check registry/vk-1.4.363.xml 1.4.363   # 只校验已有文件
```

- 默认来源：`https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/<ref>/xml/vk.xml`；
  `X.Y.Z` → `ref=vX.Y.Z`，`main` → `main`。
- 拉取后自检：可解析、根元素 `<registry>`、`VK_HEADER_VERSION`/`VK_HEADER_VERSION_COMPLETE` 与请求版本一致，再原子写入。
- 选项：`--out <dir>`（默认 `registry/`）、`--url <模板>`（覆盖来源，支持本地路径/镜像）、`--force`（覆盖）。
- `racket rebuild.rkt` 在默认 xml 缺失时会**自动拉取** `1.4.363`，所以全新 clone 直接构建即可。

## 版本管理

- **包版本 = Vulkan header 版本**：`info.rkt` 的 `version` 即钉死的注册表版本（当前 `1.4.363`）。
  自己修 bug、不动上游时用第 4 位：`1.4.363.1`（Racket 版本格式不允许以 `.0` 结尾）。
  下游可写 `deps (list "racket-vulkan" "1.4.363")` 约束最低版本。
- **生成物 provenance**：生成器写 `vulkan/generated/version.rkt`，运行期可自省：

  ```racket
  (require vulkan)
  vk-binding-version       ; "1.4.363"
  vk-registry-file         ; "vk-1.4.363.xml"
  vk-generated-feature     ; "VK_VERSION_1_4"
  vk-generated-extensions  ; '("VK_KHR_surface" …)
  ```

- `tests/version.rkt` 锁定三者一致：`info.rkt` 版本 == `vk-binding-version` == 注册表版本。
- **不给 `generated/` 加版本目录**：一次安装只有一套生效绑定，版本是元数据不是命名空间；
  真要同时支持多 API 版本，用 `vulkan/1-0`、`vulkan/1-4` 这类命名空间另议。

## 生成绑定

```bash
# 一条命令重建（生成 + 清旧 .zo + raco make，默认配方 = 仓库提交的绑定）
racket rebuild.rkt                                  # 省略 xml 用 registry/vk-1.4.363.xml
racket rebuild.rkt registry/vk-1.4.363.xml          # 也可显式指定 xml 路径

# 等价于手动两段：
EXTS="VK_KHR_surface,VK_KHR_swapchain,VK_KHR_xcb_surface,VK_KHR_xlib_surface,\
VK_KHR_wayland_surface,VK_EXT_debug_utils,VK_KHR_get_physical_device_properties2,\
VK_KHR_get_surface_capabilities2,VK_KHR_display,VK_EXT_headless_surface"
racket vulkan-gen/main.rkt registry/vk-1.4.363.xml vulkan/generated VK_VERSION_1_4 "$EXTS"

# 常用集（= 上面 10 个）：
racket vulkan-gen/main.rkt registry/vk-1.4.363.xml vulkan/generated VK_VERSION_1_4 common
# 所有 includable 扩展（非 provisional / 非 disabled）：
racket vulkan-gen/main.rkt registry/vk-1.4.363.xml vulkan/generated VK_VERSION_1_4 all

# 省略参数则用默认配方（= 提交的绑定，故 no-arg 可复现 generated/）：
#   registry/vk-1.4.363.xml -> vulkan/generated  VK_VERSION_1_4  common
racket vulkan-gen/main.rkt
```

> 重新生成后请重建编译产物（`compiled/` 已被 gitignore，但本地可能残留旧 `.zo`）：
> `racket rebuild.rkt` 已包含这一步；手动则 `raco make vulkan/main.rkt vulkan/glfw.rkt`，
> 或直接删除 `vulkan/compiled/`、`tests/compiled/`。
> 否则可能仍加载旧绑定（表现为新命令/类型 “unbound identifier”）。

参数：`<vk.xml> <out-dir> <feature> [扩展] [audit-dir]`。

- 生成后会**清理已知陈旧产物**（如 `api.rkt`、`.inc` 时代产物、从 out-dir 移出的审计文件），只碰已知名字，不动 `compiled/` 或其它文件。

- 第 4 个参数是扩展选择：`common`（常用集）/ `all`（所有 includable）/ 逗号分隔名单 / 空。
- 第 5 个参数是审计产物目录（默认 `vulkan-gen/audit/`）。
- 生成后在 audit 目录写三份审计：`unknown-types.txt`（降级为 `_pointer` 的类型，应为空）、
  `diagnostics.txt`（全部降级/跳过诊断：领域 + 实体 + 原因，不静默）、`abi_check.c`（ABI 对照）。
  设 `VULKAN_GEN_STRICT=1` 时未知类型直接报错（用于加扩展前审计）。
- 输出是**原子**的：先把全部产物渲染成字符串，全部成功后才逐个（.tmp + rename）落盘。

- 第 3 个参数是目标 feature；生成器沿 `depends` 展开依赖闭包
  （`VK_VERSION_1_4` → 全部 `VK_*_VERSION_1_0..1_4`）。
- 第 4 个参数是要纳入的扩展；生成器会沿扩展的 `depends` 展开，并自动跳过
  `provisional` / `supported=disabled` 的扩展。
- 类型按 by-value 依赖做拓扑排序；生成结果可复现（排序确定性）。
- 平台类型（`Window`/`VisualID`/`xcb_window_t`/`wl_display`…，vk.xml 里只有引用没有定义）
  由 `platform-ctype` 表映射；未识别的类型降级为 `_pointer`。
- 过滤 `api="vulkansc"` 的重复 type/member/param（否则 `vkCreateSwapchainKHR` 等会出现两个
  `pCreateInfo`）。
- 带 `alias` 的类型（struct/handle/enum/bitmask）与命令会被解析：类型生成 ctype 别名
  （`(define _VkX _VkY)`，不再退化成空结构体），命令沿用目标签名。

## 使用

```racket
#lang racket/base
(require vulkan              ; facade：糖 + 类型/常量/原子 + raw: 裸命令
         ffi/unsafe)

;; enum/bitmask 用整数常量（不是符号）
(define app (make-VkApplicationInfo VK_STRUCTURE_TYPE_APPLICATION_INFO
                                    #f #f 0 #f 0 VK_API_VERSION_1_0))
(define ici (make-VkInstanceCreateInfo VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                                       #f 0 app 0 #f 0 #f))

;; 裸命令：raw: 前缀（原始签名，返回 VkResult，不抛异常）
(define inst (let ([p (malloc _VkInstance)])
               (raw:vkCreateInstance ici #f p)
               (ptr-ref p _VkInstance)))

;; 糖（组合层，同名）：builder + 自动对象作用域 + 失败抛异常
;; R1 返回值：VkResult 命令返回 (values result handle)，void 命令返回 handle
;; (define-values (r inst)
;;   (vkCreateInstance
;;    (λ () (vk-new make-VkInstanceCreateInfo
;;                  VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO #f 0 app 0 #f 0 #f))
;;    #f))

;; 自动输出糖：单输出直接返回，enumerate 返回 vector
;; (define props (vkGetPhysicalDeviceProperties pd))          ; void 命令 -> struct
;; (define mem   (vkGetPhysicalDeviceMemoryProperties pd))    ; void 命令 -> struct
;; (define-values (r devs) (vkEnumeratePhysicalDevices inst))  ; VkResult -> (values r vector)

;; 输入类糖：调用作用域 + 数组（count 由长度定）
;; (vkCmdSetViewport cmd 0 (vector vp1 vp2))

;; 注册 instance / device，命令会据此经 GIPA/GDPA 解析
(vk-use-instance! inst)
;; (vk-use-device! dev)
```

> 只要裸命令用 `(require vulkan/bindings)`（或 `vulkan/raw`）；
> 只要糖用 `(require vulkan/safe)`。`vulkan` 同时给两者：糖用原生名，裸命令带 `raw:` 前缀。

- 命令懒加载：首次调用时按 `global / instance / device` 从
  `libvulkan`、`vkGetInstanceProcAddr`、`vkGetDeviceProcAddr` 解析并缓存。
- `VkResult` 命令失败（负值）抛异常；非负结果（`VK_SUCCESS`/`VK_NOT_READY`/
  `VK_TIMEOUT`/`VK_INCOMPLETE`/`VK_SUBOPTIMAL_KHR` …）作为整数原样返回。
- 所有生成的结构体使用 `#:malloc-mode 'zeroed-atomic-interior`（零初始化 + **不可移动**）。

## 窗口（开发用，独立模块）

窗口逻辑放在 **`vulkan/glfw.rkt`**，**不依赖 Vulkan 绑定**（只依赖 `ffi/unsafe` + `libglfw`），
与 Vulkan 绑定解耦：

```racket
(require vulkan/glfw vulkan)
(glfw-init!)
(define win (make-glfw-window #:width 800 #:height 600 #:title "demo"))

;; instance 需要的扩展名由 GLFW 提供（本机是 VK_KHR_surface + VK_KHR_xcb_surface）
(glfw-required-instance-extensions)

;; 直接创建 VkSurfaceKHR（raw pointer，调用方 cast 成 _VkSurfaceKHR）
(define surface (cast (glfw-create-vk-surface win instance) _pointer _VkSurfaceKHR))

;; 主循环：关窗、Esc、尺寸都由 GLFW 管
(let loop ()
  (glfw-window-poll! win)
  (unless (glfw-window-should-close? win)
    (define-values (w h) (glfw-window-framebuffer-size win))
    ... render / present ...
    (loop)))

(glfw-window-destroy! win)
(glfw-terminate!)
```

GLFW 用 `glfwCreateWindowSurface` 在 X11/Wayland/Windows/macOS 上直接建表面，所以跨平台不用改。
`tests/triangle-glfw.rkt` 用它；`tests/triangle-x11.rkt` 是手写 X11 的对照版本。

## 安全层（推荐用法）

`generated/safe.rkt` 为 create/allocate 命令生成包装（destroy/free、单输出 `vkGet*`、
数组输出 `vkEnumerate*`、输入类 `vkCmd*` 等形状也一并生成）：

```racket
;; create/allocate：R1 返回 (values result handle)；builder 在对象 arena 中执行
(define-values (r buf)   (vkCreateBuffer device (λ () (vk-new make-VkBufferCreateInfo ...)) #f))
(define-values (r pipes) (vkCreateComputePipelines device (λ () (vector ...)) #f #f)) ; 数组型 -> vector
(vkDestroyBuffer device buf #f)   ; 解绑并释放对象 arena
```

包装的行为：
1. 新建一个 **arena**（`make-vk-arena`）；
2. 在 arena 里运行 builder thunk —— 里面所有用 `vk-new` / `vk-malloc` / `stable-bytes`
   创建的内存都会登记到 arena（且都是 `atomic-interior`，不可移动）；
3. 调原生命令；
4. 把 arena 挂到返回句柄上（`vk-handle-arena-set!`）；
5. `vkDestroy*` / `vkFree*` 时释放（`vk-handle-arena-remove!`）。

这样即使驱动惰性引用输入内存，也不会被 GC 移动或回收。

底层原语（在 `vulkan/memory.rkt`，与 Vulkan 绑定解耦）：

| 原语 | 作用 |
|------|------|
| `vk-malloc` | 不可移动分配（`atomic-interior`），有 arena 时登记 |
| `stable-bytes` | 把 bytes 复制到不可移动内存并补 NUL |
| `vk-new` | `(vk-new ctor arg ...)` 构造结构体并登记到当前 arena |
| `vk-zero` | 零初始化的不可移动结构体（用于输出/逐字段 set） |
| `with-vk-arena` | 在 arena 里执行 body，返回 `(values 结果 arena)` |
| `with-vk-call` | `with-vk-arena` 的策略别名（多条命令共享调用作用域） |
| `vk-handle-arena-set!` / `vk-handle-arena-remove!` / `vk-handle-arena` | 句柄 ↔ arena 注册表（在 `vulkan/context`，默认 per-thread；共享用 `with-vk-context`） |
| `vk-callback-keep!` / `make-vk-callback` / `vk-callback-release!` | 把 Racket 过程变成稳定 C 回调并登记到 arena |

## 回调（funcpointer）

`_PFN_*` 是 `_cprocedure`；结构体里的函数指针字段是 `_pointer`。把 Racket 过程
转成回调时**只转一次**并显式保活（`_cprocedure` 的默认保活是弱表，同一过程
重复转换会被覆盖）：

```racket
(require vulkan)

(define (on-message severity types data user-data)
  (eprintf "[vk] ~a\n" severity)
  0)                                  ; VK_FALSE

(vkCreateDebugUtilsMessengerEXT
 instance
 (λ ()
   (vk-new make-VkDebugUtilsMessengerCreateInfoEXT
           VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
           #f 0 VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
           VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
           (vk-callback-keep! _PFN_vkDebugUtilsMessengerCallbackEXT on-message)
           #f))                       ; pUserData；上下文也可用闭包捕获
 #f)
```

`vk-callback-keep!` 在 builder 里调用 → 令牌登记到对象的 arena，随对象销毁而释放。
回调可能在驱动线程触发，**不要**在回调里依赖 `current-vk-arena` 等动态参数。

## pNext / sType

`generated/pnext.rkt` 提供两张表；糖层对应两个辅助：

```racket
(require vulkan)

;; 自动填 sType（由结构名查表）、pNext=#f，并登记到当前 arena
(define ici (vk-struct make-VkInstanceCreateInfo 0 #f 0 #f 0 #f))
(define dbg (vk-struct make-VkDebugUtilsMessengerCreateInfoEXT
                      0 VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
                      VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT #f #f))

;; 串链 ici -> dbg：按每个节点的 sType 查 setter，并把节点登记到 arena
(vk-chain! ici dbg)
```

- `vk-struct` 只覆盖“首成员 `sType`、次成员 `pNext`”的干净形状，其余参数按生成构造器顺序给。
- 裸 `set-VkX-pNext!` / `VkX-pNext` 仍然可用。

## 能力查询（capability）

```racket
(require vulkan)

(vk-proc-available? 'vkCreateInstance 'global)         ; => #t
(vk-instance-extension-available? "VK_KHR_surface")    ; => #t/#f
(vk-device-extension-properties physical-device)        ; => 扩展名列表

;; 命令不可用抛可捕获的专用异常
(with-handlers ([exn:fail:vulkan:unavailable? (λ (e) ... 降级 ...)])
  (vkSomeExtensionCommand ...))
```

- 命令在首次调用时经 GIPA/GDPA 解析；不可用抛 `exn:fail:vulkan:unavailable`（带 `command`）。
- `(require vulkan/capability)` 也可单独 require（`vulkan/manual` 用户可加）。

## 设备内存映射

设备内存不归 Racket GC，`vk-map` 只做薄封装（返回的指针由驱动拥有，**不**登记 arena）：

```racket
(require vulkan)

(define-values (r ptr) (vk-map device memory 0 size))   ; -> (values result pointer)
(ptr-set! ptr _uint32 0 #xDEADBEEF)
(vk-unmap device memory)
```

非一致内存的 flush/invalidate（`VkMappedMemoryRange` 含 `pNext`，非 flat）仍是裸命令：
`raw:vkFlushMappedMemoryRanges` / `raw:vkInvalidateMappedMemoryRanges`。

## 运行测试

```bash
# 方式一：安装为包（之后 (require vulkan) 直接可用，不用 PLTCOLLECTS）
raco pkg install --link --auto

# 方式二：不安装，用 PLTCOLLECTS 把本目录当 collection root
PLTCOLLECTS="$PWD:" racket tests/smoke.rkt          # instance + 枚举
PLTCOLLECTS="$PWD:" racket tests/device.rkt         # device + GDPA
PLTCOLLECTS="$PWD:" racket tests/compute-raw.rkt    # 完整 compute（裸 API）
PLTCOLLECTS="$PWD:" racket tests/compute-safe.rkt   # 完整 compute（安全层 + 数组 create）
PLTCOLLECTS="$PWD:" racket tests/surface-x11.rkt    # 手写 Xlib surface + swapchain
PLTCOLLECTS="$PWD:" racket tests/triangle-glfw.rkt       # GLFW 窗口 + 图形管线 + 渲染 + 显示
PLTCOLLECTS="$PWD:" racket tests/triangle-glfw.rkt --loop  # 持续渲染，关窗/Esc 退出
PLTCOLLECTS="$PWD:" racket tests/memory-arena.rkt     # 内存/所有权单测
PLTCOLLECTS="$PWD:" racket tests/abi.rkt           # C sizeof/alignof ABI 对照（需 gcc + vulkan 头文件）
PLTCOLLECTS="$PWD:" racket tests/bitfield.rkt      # bitfield 打包 + 多维数组（需 gcc）
PLTCOLLECTS="$PWD:" racket tests/extensions.rkt    # common/all 扩展选择 + 未知类型审计
PLTCOLLECTS="$PWD:" racket tests/dispatch-audit.rkt # GIPA/GDPA 全量对账（需 Vulkan 设备）

# 重新编译 shader（已提交 .spv，一般不需要）
cd tests/shaders && glslangValidator -V triangle.vert -o triangle.vert.spv \
  && glslangValidator -V triangle.frag -o triangle.frag.spv

# 开验证层（会检查 spec 违规）
VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation PLTCOLLECTS="$PWD:" racket tests/compute-safe.rkt

# 包测试
raco test tests/
```

`compute.rgba` 可用 ImageMagick 查看：

```bash
convert -size 3200x2400 -depth 8 tests/compute.rgba -resize 400x300 /tmp/mandelbrot.png
```

## 内存规则（重要）

**凡是交给 Vulkan/驱动的内存，必须是“不可移动”的。**

Racket CS 里普通 `'atomic` 分配**仍会被 GC 移动**；只有 **`'atomic-interior`** 保证地址稳定。
Vulkan 驱动会在调用期间/之后持有这些指针，一旦 GC 移动内存就会段错误（本原型调试时
表现为 `vkWaitForFences`/`vkQueueWaitIdle` 随机崩溃）。Racket FFI 文档也提醒：
阻塞式 foreign call 期间可能发生 GC，`_ptr` 参数应用 `'atomic-interior`。

```racket
;; 结构体：生成器已用 #:malloc-mode 'zeroed-atomic-interior
;; 裸缓冲区：用 vk-malloc / stable-bytes
(define buf (vk-malloc _uint8  size))
(define code (stable-bytes (port->bytes ...)))   ; 末尾自动补 NUL
```

- ❌ 不要用裸 `(malloc ...)`（默认 `'atomic`，会移动）承载驱动可见数据。
- ❌ 不要把 Racket `bytes`/`string`/`vector` 经 `_pointer` 直接传给驱动（除非确认驱动立即复制）。
- ✅ 结构体、数组、字符串一律复制到 `atomic-interior`；并保证对应 Racket cpointer
  在驱动使用期间可达（安全层用 arena 自动做到）。

详见 `RESEARCH.md` §11.4 / §11.5。

## 已知限制

1. 原始命令的指针参数一律用 `_pointer`（精确的 `_ptr`/`_cpointer` 类型化留待后续）；
   输出参数自动返回只在 safe 糖层提供。
2. 安全封装的 builder：create/allocate 糖按 R1 返回 `(values result handle)`；数组型（显式 count
   或 `vkAllocate*` 的 `*Count`）返回 `(values result vector)`；`vkCreateGraphicsPipelines`
   这类显式 count 命令的 builder 返回 struct vector。
3. flags/enum 用整数（可用 `bitwise-ior` 组合），若要用 Racket 原生 `_bitmask`/`_enum` 需另配。
4. 当前只纳入 10 个扩展；其余扩展用第 4 个参数按需加入。
5. C 位域无法用 `define-cstruct` 直接表达，已按「存储单元」打包为 `_bitsN` 整型字段；
   每个具名位域通过生成的 `VkX-<field>` / `set-VkX-<field>!` 读写（`reserved` 不生成）。
