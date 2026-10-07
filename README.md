# racket-vulkan

从 Khronos 官方 `vk.xml` **自动生成** Racket 的 Vulkan FFI 绑定。思路参考 Racket 自带的
OpenGL 绑定（`racket/opengl` 的 `readspec.rkt` + `main.rkt`）。

> 状态：**可用原型**。当前生成 **Vulkan 1.4 core + 10 个常用扩展**（280 命令 / 652 类型 /
> 2202 常量），带安全层。已跑通：instance/device、完整 compute（与参考实现逐字节一致，
> md5 `947e43451635cb72358ae61e0a5d1fc7`）、Xlib surface + swapchain；验证层零报错。
> 详见 `RESEARCH.md`。

## 目录

```
racket-vulkan/
  info.rkt                    # 多集合包元数据（collection 'multi）
  vulkan/                     # 集合 vulkan：绑定
    info.rkt
    main.rkt                  # (require vulkan)           => facade：糖 + 类型/常量/原子 + raw: 裸命令
    base.rkt                  # (require vulkan/base)      => 类型/常量/分派设施（无命令）
    commands.rkt              # (require vulkan/commands)  => 原始命令（返回 VkResult）
    bindings.rkt              # (require vulkan/bindings)  => 原始表面 = base + commands
    raw.rkt                   # (require vulkan/raw)       => = bindings（语义别名）
    memory.rkt                # (require vulkan/memory)    => 内存/所有权原语（R5）
    api-facts.rkt             # 运行期 API 事实 IR：vk-param / vk-command
    unsafe.rkt                # (require vulkan/unsafe)    => 兼容入口 = bindings + memory
    safe.rkt                  # (require vulkan/safe)      => 组合层糖（原生名，不导出裸命令）
    window.rkt                # (require vulkan/window)    => GLFW 窗口（与绑定无关）
    generate.rkt              # 生成器入口：vk.xml -> generated/*
    gen/
      classify.rkt            # 命令 -> (shape . plan)（纯函数）
      emit.rkt                # 逐形状 emitter + 组合
    generated/
      constants.inc           # VK_* 常量（整数）
      types.inc               # _VkX ctype / define-cstruct
      commands.inc            # (define-vk ...) 原始命令 + 分派层级（无错误策略）
      safe.inc                # 糖：vk-create-*/vk-get-*/vk-cmd-*（R1 返回值，含 check-vk-result）
      api.rkt                 # 命令/参数事实（vk-command/vk-param），供组合层/测试消费
      abi_check.c             # ABI 对照 C 程序（core struct/union 的 sizeof/alignof）
    registry/
      vk-1.4.363.xml          # 生成基准（最新稳定 SDK tag）
      vk-1.4.309.xml          # 与本机 loader 对齐
      vk-main.xml             # 上游 main（含未定稿扩展）
    experiments/              # 前期调研脚本 + 2019 旧绑定对照（不参与编译）
  tests/
    smoke.rkt                 # 建 instance + 枚举物理设备 + 读属性
    device.rkt                # 建逻辑设备 + 经 GDPA 调 device 级命令
    compute-raw.rkt           # 完整 compute（裸 API）
    compute-safe.rkt          # 完整 compute（安全层 + 数组 create）
    surface-x11.rkt           # Xlib surface + swapchain（手写 X11）
    triangle-glfw.rkt         # 图形管线 + 渲染 + 显示（用 vulkan/window）
    triangle-x11.rkt          # 同上，但手写 X11（对照）
    shaders/                  # triangle.vert/.frag + 编译出的 .spv
    arena-test.rkt            # 内存/所有权单元测试
    safe-ownership.rkt        # 数组 free 的所有权回归
    dispatch-cache.rkt        # 分派缓存按 instance/device 分桶回归
    generate-aliases.rkt      # 生成器 alias 正确性 + 可复现回归
    vkresult.rkt              # VkResult 返回/抛出语义回归
    api-facts.rkt             # generated/api.rkt 事实层回归
    memory-scope.rkt          # 生命周期令牌原语回归
    module-surface.rkt        # 命名契约（糖/裸命令模块隔离）回归
    gen-shapes.rkt            # classify 全量断言
    auto-output.rkt           # 自动输出糖（单输出 / enumerate）
    auto-input.rkt            # 输入类糖（调用作用域 + 数组）
    abi.rkt                   # C sizeof/alignof ABI 对照
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
| `vulkan/memory` | 内存/所有权原语（`vk-malloc`/`stable-bytes`/arena、handle↔arena） |
| `vulkan/safe` | 组合层糖（`check-vk-result` + `vk-create-*`/`vk-get-*`/`vk-cmd-*` 等），糖也是 Vulkan 原生名，**不导出裸命令** |
| `vulkan` | facade：糖（原生名）+ 类型/常量/原子，裸命令以 `raw:` 前缀 |
| `vulkan/api-facts` | 运行期 API 事实 IR（`vk-param`/`vk-command`） |
| `vulkan/generated/api` | 命令/参数事实数据（`vk-command-facts`），供组合层/测试消费 |
| `vulkan/gen/*` | 生成器内部：`classify`（shape+plan）/ `emit`（逐形状） |
| `vulkan/window` | GLFW 窗口，与绑定无关 |

> **命名靠模块隔离（方案 A）**：`vulkan/safe` 的 `vkCreateBuffer` 是糖（builder），
> `vulkan/bindings` 的 `vkCreateBuffer` 是裸命令（原始签名）；同名不同模块，由模块显式区分。
> `(require vulkan)` 默认给糖（原生名），裸命令是 `raw:vkCreateBuffer`；
> 想看裸命令就 `(require vulkan/raw)`。不需要任何命名前缀约定。
> 运行期符号的词表（arena/handle/param 等）见 `ARCHITECTURE.md` §2.2。

## 生成绑定

```bash
EXTS="VK_KHR_surface,VK_KHR_swapchain,VK_KHR_xcb_surface,VK_KHR_xlib_surface,\
VK_KHR_wayland_surface,VK_EXT_debug_utils,VK_KHR_get_physical_device_properties2,\
VK_KHR_get_surface_capabilities2,VK_KHR_display,VK_EXT_headless_surface"
racket vulkan/generate.rkt vulkan/registry/vk-1.4.363.xml vulkan/generated VK_VERSION_1_4 "$EXTS"

# 省略参数则用默认：vulkan/registry/vk-1.4.363.xml -> vulkan/generated，VK_VERSION_1_0
racket vulkan/generate.rkt
```

> 重新生成后请重建编译产物（`compiled/` 已被 gitignore，但本地可能残留旧 `.zo`）：
> `raco make vulkan/base.rkt vulkan/commands.rkt vulkan/bindings.rkt vulkan/safe.rkt vulkan/main.rkt`，或直接删除 `vulkan/compiled/`、`tests/compiled/`。
> 否则可能仍加载旧绑定（表现为新命令/类型 “unbound identifier”）。

参数：`<vk.xml> <out-dir> <feature> [逗号分隔的扩展]`。

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
(register-vk-instance! inst)
;; (register-vk-device! dev)
```

> 只要裸命令用 `(require vulkan/bindings)`（或 `vulkan/raw`）；
> 只要糖用 `(require vulkan/safe)`。`vulkan` 同时给两者：糖用原生名，裸命令带 `raw:` 前缀。

- 命令懒加载：首次调用时按 `global / instance / device` 从
  `libvulkan`、`vkGetInstanceProcAddr`、`vkGetDeviceProcAddr` 解析并缓存。
- `VkResult` 命令失败（负值）抛异常；非负结果（`VK_SUCCESS`/`VK_NOT_READY`/
  `VK_TIMEOUT`/`VK_INCOMPLETE`/`VK_SUBOPTIMAL_KHR` …）作为整数原样返回。
- 所有生成的结构体使用 `#:malloc-mode 'zeroed-atomic-interior`（零初始化 + **不可移动**）。

## 窗口（开发用，独立模块）

窗口逻辑放在 **`vulkan/window.rkt`**，**不依赖 Vulkan 绑定**（只依赖 `ffi/unsafe` + `libglfw`），
与 Vulkan 绑定解耦：

```racket
(require vulkan/window vulkan)
(glfw-init!)
(define win (make-glfw-window #:width 800 #:height 600 #:title "demo"))

;; instance 需要的扩展名由 GLFW 提供（本机是 VK_KHR_surface + VK_KHR_xcb_surface）
(glfw-required-instance-extensions)

;; 直接创建 VkSurfaceKHR（raw pointer，调用方 cast 成 _VkSurfaceKHR）
(define surface (cast (glfw-window-create-surface win instance) _pointer _VkSurfaceKHR))

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

`generated/safe.inc` 为每个 create/allocate 命令生成了一个包装：

```racket
(vk-create-buffer device (λ () (vk-new make-VkBufferCreateInfo ...)) #f)   ; -> VkBuffer
(vk-create-compute-pipelines device (λ () ...) #f 1 #f)                    ; -> VkPipeline
(vk-destroy-buffer device buffer #f)                                        ; 释放
```

包装的行为：
1. 新建一个 **arena**（`make-vk-arena`）；
2. 在 arena 里运行 builder thunk —— 里面所有用 `vk-new` / `vk-malloc` / `stable-bytes`
   创建的内存都会登记到 arena（且都是 `atomic-interior`，不可移动）；
3. 调原生命令；
4. 把 arena 挂到返回句柄上（`vk-handle-arena-set!`）；
5. `vk-destroy-*` / `vk-free-*` 时释放（`vk-handle-arena-remove!`）。

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
| `vk-handle-arena-set!` / `vk-handle-arena-remove!` / `vk-handle-arena` | 句柄 ↔ arena 注册表 |

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
PLTCOLLECTS="$PWD:" racket tests/arena-test.rkt     # 内存/所有权单测
PLTCOLLECTS="$PWD:" racket tests/abi.rkt           # C sizeof/alignof ABI 对照（需 gcc + vulkan 头文件）

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

1. 目前指针参数一律用 `_pointer`（类型安全/输出参数自动返回留待后续）。
2. 安全封装的 builder：单输出返回句柄；数组型（显式 count 或 `vkAllocate*` 的 `*Count`）
   返回句柄 vector；`vkCreateGraphicsPipelines` 这类显式 count 命令的 builder 返回 struct vector。
3. flags/enum 用整数（可用 `bitwise-ior` 组合），若要用 Racket 原生 `_bitmask`/`_enum` 需另配。
4. 当前只纳入 10 个扩展；其余扩展用第 4 个参数按需加入。
