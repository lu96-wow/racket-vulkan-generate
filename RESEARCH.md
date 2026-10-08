# Racket × Vulkan 绑定可行性调研

日期：2025-10-05
环境：Racket v9.3 [cs]（`/usr/bin/racket`），Linux x86-64，Vulkan loader 1.4.309（`libvulkan.so.1`），
Mesa 25.0.7（只有 llvmpipe 软件设备），GLFW 3.4 / X11 / xcb / wayland 库均在。

本文件只记录**已核实的事实与实测证据**，用于判断“像 opengl 那样自动生成 Racket Vulkan 绑定”是否可行。

> 注：本报告是调研当时（2025-10-05）的快照，部分运行期符号在后续命名收敛中已改名
> （如 `check-vkResult`→`check-vk-result`、`vk-retain-for!`→`vk-handle-arena-set!`）。
> 以 `ARCHITECTURE.md` §2.2 的词表为准。

---

## 1. 结论速览

**可行，且已有可跑通的原型路径。** 关键证据：

1. Racket `ffi/unsafe` 能直接加载 `libvulkan`，调用 `vkEnumerateInstanceVersion` 得到 1.4.309。
2. Racket `define-cstruct` 生成的 C 结构体布局与 C ABI **逐字节吻合**（对 30 个代表结构体 `sizeof` 全等）。
3. 2019 年的第三方绑定 `SimonLSchlee/racket-vulkan`（基于 Vulkan 1.1 的 vk.xml 自动生成）
   在 **Racket 9.3 + Vulkan 1.4.309** 上直接编译并运行成功：能建 instance、枚举物理设备，
   并成功跑通 **Mandelbrot 计算着色器**（llvmpipe，输出 3200×2400 RGBA）。
4. 官方注册表 `vk.xml` 是机器可读的完整描述（最新稳定 1.4.363：872 命令 / 1749 结构体 / 715 扩展），
   完全够用来做代码生成；且 3.0 已说明，做 FFI 绑定不必与 C 头文件版本对齐。

主要障碍不是“能不能调”，而是**工程细节**：函数分派（dispatch）加载模型、`sType`/`pNext` 链、
扩展/版本门控、以及生成代码的编译体量。

---

## 2. 参考：Racket 的 OpenGL 是自动生成的

包路径：`/home/lu96/.local/share/racket/9.3/pkgs/opengl/opengl/`

| 文件 | 作用 |
|------|------|
| `specfiles/gl.spec` | OpenGL 官方机器可读 API 描述（自定义文本格式，非 XML） |
| `specfiles/enum.spec` | 枚举/常量 |
| `specfiles/gl.tm` | C 类型映射表 |
| `readspec.rkt` | 生成器：把 spec 编译成 Racket FFI 定义（611 行） |
| `generated/gl_specs.inc` | 生成物：~10000 行 `(define-gl ...)` |
| `main.rkt` | 运行时胶水：`define-gl` 宏、懒加载、错误检查、向量/指针工具（293 行） |

生成器核心思路（可直接迁移到 Vulkan）：

- 每个函数生成一行：
  ```racket
  (define-gl glGetIntegerv 1
    ((pname : _int32) (params : (_s32vector o (hash-ref pname-map pname 1)))
     -> _void -> params)
    (->> exact-integer? s32vector?) check-gl-error)
  ```
- `define-gl` 宏（`main.rkt`）把上面展开成：
  - `_fun` 类型（含 `(_ptr o _type)` / `(_vector o ...)` 输出参数，输出经第二个 `->` 返回）；
  - **懒加载**：`(delay (lookup-gl-procedure name type))`，首次调用才解析；
  - 用 `procedure-reduce-arity` 固定 arity（输入参数个数）；
  - `provide/contract` 加契约；
  - 调完自动 `glGetError` 检查（`Begin/End` 之间跳过）。
- 函数指针来自平台相关的 `glXGetProcAddressARB` / `wglGetProcAddress`（`default-gl-procedure-loader`），
  可用 `set-gl-procedure-loader!` 替换。
- 枚举用 `define-enum`（集合谓词），位域用 `define-bitfield`。

**对 Vulkan 的启示**：同样是“懒加载 + `_fun` 契约 + 统一错误检查”，
但 Vulkan 的 `vkGetInstanceProcAddr`/`vkGetDeviceProcAddr` 是**按 instance/device 分派**的，
不能像 GL 那样只用一个全局 loader。

---

## 3. 数据源：Vulkan 官方注册表 `vk.xml`

### 3.0 先厘清版本：1.4 不是“老版本”

- **Vulkan 1.4 就是当前最新的大版本**，没有 1.5；官方 spec 标题即
  `Vulkan® 1.4.365 - A Specification`（本文撰写时）。
- `1.4.309` 里的 `309` 只是 **patch/header 版本**，等同于本机
  `libvulkan1 / libvulkan-dev` 装的补丁号；**同一 1.4 线**上还有 1.4.363（最新 SDK tag）、
  1.4.365（上游 main）。
- **做 FFI 绑定根本不读 C 头文件、不链接头文件**，所以“注册表版本”与“本机 SDK 版本”
  不需要一致。绑定可以按最新注册表生成，运行期再按 loader/驱动实际支持能力做特性门控
  （Vulkan 保证向后兼容：用新头文件编的代码可跑在旧 loader 上，只要不启用不支持的特性）。
- 需要固定版本时，**钉住某个 release tag 而不是跟踪 `main`**，保证可复现
  （`main` 含未定稿/临时扩展，ABI 可能变）。

版本对照：

| 名称 | `VK_HEADER_VERSION` | 说明 |
|------|---------------------|------|
| 本机 loader（`libvulkan.so.1`） | 309 | Debian 包 1.4.309.0-1 |
| 本机驱动（Mesa llvmpipe） | 305 | `vulkaninfo` 报 1.4.305 |
| 最新稳定 SDK tag | 363 | `vulkan-sdk-1.4.363.0`（Vulkan-Headers） |
| 上游 main / 最新 spec | 365 | `Vulkan-Docs/main`；官方 spec 标题 1.4.365 |

已下载并放入 `vulkan/registry/`：

- `vulkan/registry/vk-1.4.363.xml` —— **最新稳定 SDK tag**，建议作为生成基准（`VK_HEADER_VERSION=363`）。
- `vulkan/registry/vk-main.xml` —— 上游 main（365），最全但含未定稿内容。
- `vulkan/registry/vk-1.4.309.xml` —— 与本机 loader/SDK 完全对齐，便于“本机可跑性”对照。

来源：
- `https://raw.githubusercontent.com/KhronosGroup/Vulkan-Headers/vulkan-sdk-1.4.363.0/registry/vk.xml`
- `https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/main/xml/vk.xml`
- `https://raw.githubusercontent.com/KhronosGroup/Vulkan-Headers/vulkan-sdk-1.4.309.0/registry/vk.xml`

> 结论：生成器应默认吃 **1.4.363（最新稳定）**，同时保留 1.4.309 用于回归验证。

### 3.1 规模统计（三个版本的对比）

| 指标 | 1.4.309（本机） | **1.4.363（最新稳定，推荐基准）** | main（365） |
|------|----------------|-------------------------------|-------------|
| `<command>` 总数 / 含 alias | 753 / 103 | 872 / 105 | 872 / 105 |
| 去重后命令 | 650 | 767 | 767 |
| struct | 1440 | **1749** | 1750 |
| enum | 355 | 417 | 417 |
| bitmask | 233 | 273 | 273 |
| handle | 57 | 63 | 63 |
| union | 14 | 16 | 16 |
| funcpointer | 11 | 11 | 11 |
| basetype | 16 | 19 | 19 |
| `<enums>` 块 | 303 | 357 | 357 |
| `<extension>` | 619 | **715** | 716 |

可见 309→363 在 2025 年新增了大量扩展（命令 +119、struct +309），
**用 309 会白白丢掉最新扩展**，所以生成基准选 **363**（或 365），309 只作本机回归对照。

### 3.2 结构体与 sType/pNext

- 带 `sType` 成员的结构体：**1296 个**（main）。
- 带 `structextends` 属性（可被链入哪些父结构）的结构体：**853 个**。
- `sType` 成员的 `values` 属性直接给出对应 `VK_STRUCTURE_TYPE_*` 常量，例如：
  `VkApplicationInfo` → `VK_STRUCTURE_TYPE_APPLICATION_INFO`。
- `VkBaseInStructure` / `VkBaseOutStructure` 是 `pNext` 链的通用头。
  → **可以自动生成 `sType` 赋值和 `pNext` 链校验**，这是提升易用性的关键点。

### 3.3 命令分派（dispatch）分类

按第一个参数类型统计（760 个非 alias 命令）：

| 首参类型 | 数量 | 层级 |
|----------|------|------|
| `VkDevice` | 358 | device |
| `VkCommandBuffer` | 271 | device |
| `VkPhysicalDevice` | 82 | instance（GIPA） |
| `VkInstance` | 28 | instance |
| `VkQueue` | 16 | device |
| 无分派句柄（global） | 5 | 直接 loader |

5 个 global：`vkCreateInstance`、`vkEnumerateInstanceVersion`、
`vkEnumerateInstanceLayerProperties`、`vkEnumerateInstanceExtensionProperties`、
`vkGetExternalComputeQueueDataNV`。

### 3.4 关键实测：loader 只导出 269 个符号

```
libvulkan.so.1 导出的 vk* 符号：269
vk.xml 中命令：760
→ 491 个命令（尤其是绝大多数扩展）必须经 vkGetInstanceProcAddr / vkGetDeviceProcAddr 解析
```

实测（`vkGetDeviceProcAddr`，device 未开启对应扩展时返回 NULL；开启/匹配版本后返回非空）：
`vkCmdDraw`、`vkQueueSubmit` 可用；`vkCreateSwapchainKHR`（未开扩展）、
`vkCmdPipelineBarrier2`（device API 版本不足）返回 `#f` —— 这是**符合规范的正确行为**，
说明绑定必须按 instance/device 建分派表。

---

## 4. 既有工作：`SimonLSchlee/racket-vulkan`（2019）

已克隆到 `/tmp/racket-vulkan-ref`（分析用）。结构：

| 文件 | 作用 |
|------|------|
| `private/generate/make-unsafe.rkt` | 从 vk.xml 生成 FFI 绑定（899 行，含大量单测） |
| `private/analyze/spec.rkt` | 注册表“整理”：拓扑排序类型依赖、归类 enum/consts/command（225 行） |
| `private/analyze/txexpr.rkt` / `c.rkt` | XML→s 表达式、C 文本分析 |
| `spec.rkt` | 读取 vk.xml（本地 mirror 或联网） |
| `unsafe.rkt` | 生成物（405 KB，347 个函数、484 个 cstruct，VK 1.1） |
| `examples/mandelbrot/` | 计算着色器完整示例 + 预编译 `comp.spv` |

### 4.1 它的做法

- 用 `txexpr` 把 `vk.xml` 读成 s 表达式，然后按 `category` 分派生成函数：
  `basetype / ctype / struct / union / handle / enum / bitmask / funcpointer / command / consts`。
- 用图算法（`graph`）对类型做 **拓扑排序**，解决“声明顺序导致未绑定标识符”的问题。
- struct → `(define-cstruct _VkX ((field ctype) ...))`。
- 指针参数一律降级成 `_pointer`（放弃类型信息，但能跑）。
- 命令 → `(define-vulkan vkX (_fun ... -> (r : _VkResult) -> (check-vkResult r 'vkX)))`。
- 所有函数直接从 `(ffi-lib "libvulkan")` 取符号，`#:default-make-fail make-not-available`。

### 4.2 实测结果（Racket 9.3 + Vulkan 1.4.309）

把 `unsafe.rkt` 放到 `PLTCOLLECTS` 下的 `vulkan/` collection：

- `raco make`：**30 秒**，生成 **10.4 MB** `.zo`，无报错。
- `vkCreateInstance` / `vkDestroyInstance`：成功。
- `physical-device-report.rkt`：成功打印
  `API Version: 1.4.305`、`Device Name: llvmpipe (LLVM 19.1.7, 256 bits)` 等。
- **Mandelbrot 计算着色器**：成功运行，输出 30,720,000 字节 RGBA（3200×2400×4），耗时约 5.7 秒。
  唯一修改：把 `vkWaitForFences` 的超时从 0.1 秒改成 120 秒（llvmpipe 太慢，原值会 `VK_TIMEOUT`）。

### 4.3 它的硬伤（新绑定必须解决）

1. **不能调用未导出的 491 个命令**。实测调用 `vkCreateDebugUtilsMessengerEXT` 报
   `implementation not found`。因为它只从 `libvulkan` 取符号，没有 GIPA/GDPA 分派。
2. **不做 `sType`/`pNext` 自动化**，用户要手写 `make-VkX 'VK_STRUCTURE_TYPE_... #f ...`。
3. **指针参数全部退化成 `_pointer`**，丢失类型安全与输出参数自动返回。
4. 注册表停留在 VK 1.1（header 126），缺 500+ 命令和大量结构体。
5. 枚举去重逻辑按“全局名字出现次数 ≤1”过滤，会漏掉一部分扩展别名。

---

## 5. Racket FFI 能力与限制（已实测）

### 5.1 结构体布局：与 C ABI 完全一致 ✅

`define-cstruct` 与 C `sizeof` 对比（左边 Racket，右边 gcc + vulkan_core.h）：

```
_VkApplicationInfo                    48  = C 48
_VkInstanceCreateInfo                 64  = C 64
_VkPhysicalDeviceProperties          824  = C 824
_VkPhysicalDeviceLimits              504  = C 504
_VkPhysicalDeviceSparseProperties     20  = C 20
_VkPhysicalDeviceMemoryProperties    520  = C 520   (含 struct 数组)
_VkPhysicalDeviceFeatures            220  = C 220
_VkClearColorValue                    16  = C 16    (union)
_VkClearDepthStencilValue              8  = C 8
_VkVertexInputBindingDescription      12  = C 12
_VkVertexInputAttributeDescription    16  = C 16
_VkPipelineVertexInputStateCreateInfo 48  = C 48
_VkAttachmentDescription              36  = C 36
_VkDescriptorSetLayoutBinding         24  = C 24
_VkDescriptorPoolSize                  8  = C 8
_VkGraphicsPipelineCreateInfo        144  = C 144
_VkComputePipelineCreateInfo          96  = C 96
_VkSubmitInfo                         72  = C 72
_VkPresentInfoKHR                     64  = C 64
_VkSwapchainCreateInfoKHR            104  = C 104
_VkImageCreateInfo                    88  = C 88
_VkBufferCreateInfo                   56  = C 56
_VkExtent3D                           12  = C 12
_VkViewport                           24  = C 24
_VkRect2D                             16  = C 16
_VkSpecializationInfo                 32  = C 32
_VkPipelineShaderStageCreateInfo      48  = C 48
_VkDebugUtilsMessengerCreateInfoEXT   48  = C 48
_VkBaseInStructure                    16  = C 16
_VkBaseOutStructure                   16  = C 16
```

覆盖了：嵌套 by-value struct、`_array` 定长数组、struct 数组、union。
→ **不需要写任何 C 胶水**。

### 5.2 其他能力

- **句柄**：`(_cpointer/null 'VkInstance_T)` 之类；可作为类型参数。
- **枚举/位域**：`_enum` / `_bitmask` 支持自定义基类型。
- **回调**：实测用 `qsort` 传入 Racket `lambda` 作为 `(_fun ...)` 回调，排序成功。
  Vulkan 的 `PFN_vkAllocationFunction`、`PFN_vkDebugUtilsMessengerCallbackEXT` 可用同法。
- **`define-cstruct` 生成 `_VkX-pointer` / `_VkX-pointer/null`**，且构造出的对象是
  **GC 管理的 C 指针**（可安全传给 FFI），比“裸 `malloc` + `ptr-ref`”更安全。
- **动态函数指针**：`function-ptr <cpointer> <_fun 类型>` 可把运行期解析到的地址变成 Racket 过程。

### 5.3 需要注意的限制 / 坑

1. **`_bitmask` 的 Racket 表示是“符号或符号列表”，不是整数**。
   实测：`(ptr-set! p _M 3)` 直接报 `argument does not fit _M`；必须 `'(A B)`。
   Vulkan 里有大量通过 `bitwise-ior` 动态组合 flag 的场景，需要决定：
   - 要么用符号列表（Racket 风格，但和“数值 flags”互转麻烦）；
   - 要么字段直接用 `_uint32/_uint64` + 整数常量（Vulkan 风格，更贴近 C）。
2. **64 位位域**：有 16 个 `<enums bitwidth="64">` 块（如 `VkAccessFlagBits2`、
   `VkPipelineStageFlagBits2`、`VkFormatFeatureFlagBits2`），基类型必须用 `_uint64`。
3. **`_enum` 默认基类型 `_ufixint`**；有负值的枚举（`VkResult`、`VkQueryResultStatusKHR`、
   `VkOpacityMicromapSpecialIndexKHR`）必须用 `_fixint`。
4. **类型名以 `_` 开头**（`define-cstruct` 要求），所以生成物是 `_VkX`；
   对外可以再包一层 `VkX` / `vk-` 命名。
5. **编译体量**：VK 1.1 的 484 个 cstruct 已需 30s 编译 / 10MB `.zo`；
   1.4 的 1440 个结构体预计 1–3 分钟、20–40MB。建议**按类别/首字母拆模块**，
   或把 unsafe 层与安全层分离，避免单个巨型模块。

---

## 6. 与 Vulkan 特性对应的设计要点

### 6.1 函数加载必须分层

```
global   → ffi-lib 直接取 / vkGetInstanceProcAddr(NULL, name)
instance → vkGetInstanceProcAddr(instance, name)
device   → vkGetDeviceProcAddr(device, name)   （VkDevice/VkQueue/VkCommandBuffer/VkPhysicalDevice 函数）
```

实现方式（仿 opengl 的懒加载）：
- 每个命令首次调用时，向“当前上下文”的分派表要地址，`function-ptr` 成过程并缓存；
- 或建 instance/device 时一次性建表（更简单、更可控）。

### 6.2 扩展与版本门控

`vk.xml` 提供 `feature`（1.0–1.4，含 `api="vulkan"` 过滤）与 `extension`
（`depends`、`platform`、`promotedto`/`deprecatedby`、`obsoletedby`、`supported`）。
扩展的 `<require>` 给出它启用的类型/命令/枚举。
→ 生成时按目标 API 版本 + 可选扩展集合裁剪；运行期可用 `vkEnumerateInstanceExtensionProperties` 校验。

注意：main 版本注册表里还有 `VK_BASE_VERSION_*` / `VK_COMPUTE_VERSION_*` / `VK_GRAPHICS_VERSION_*`
这类“profile”feature，以及 `api="vulkansc"` 的条目，生成器需要正确过滤（默认只取 `VK_VERSION_*` + `vulkan`）。

### 6.3 `sType` / `pNext`

建议生成：
- 每个带 `sType` 的结构体，构造函数自动填 `sType`（或提供 `VkX-with-...` 辅助）；
- `pNext` 链辅助：依据 `structextends` 校验“这个结构体能链进哪个父结构”，
  用 `VkBaseInStructure`/`VkBaseOutStructure` 做链表；
- 注意 Racket GC：链上的每个结构体都要被 Racket 侧引用保持存活，直到调用返回
  （`define-cstruct` 的值本身就是 GC 指针，只要放进 list 即可）。

### 6.4 窗口 / Surface

`vk.xml` 里 platform 扩展：`win32(9)`、`android(4)`、`fuchsia(4)`、`metal(3)`、
`sci(3)`、`ohos(3)`、`ggp(2)`、`screen(2)`、`xlib/xcb/wayland/directfb/vi/macos/ios` 各 1 左右。
本机可选：
- **GLFW 3.4**（`/usr/include/GLFW/glfw3.h`、`libglfw.so.3.4` 已装）——最省事，跨平台；
- 或直接绑 X11 / xcb / wayland。

`vkCreateXlibSurfaceKHR` / `vkCreateXcbSurfaceKHR` / `vkCreateWaylandSurfaceKHR` 也需要 GIPA 加载（未导出）。

### 6.5 SPIR-V（着色器）

- 本机**没装** `glslc` / `glslangValidator` / `spirv-tools`；apt 有候选：
  `glslang-tools 15.1.0+1.4.309.0-1`、`glslc 2025.2-1`、`spirv-tools 2025.1~rc1-1`、`libshaderc-dev 2025.2-1`。
- `libshaderc` / `libglslang` **未安装**，但可 FFI 绑定或 apt 安装。
- 现有 `racket-glsl`（`/home/lu96/Desktop/work/racket-glsl`，即 s-glsl）是
  **面向 OpenGL 的 GLSL 文本 DSL**（靠 `glShaderSource`/`glCompileShader` 让驱动编译），
  **不产出 SPIR-V**，不能直接用于 Vulkan。要用它就得新增 SPIR-V 后端（大工程）。
- 现实路径：先用外部 `glslc`/`glslangValidator` 生成 `.spv`，或绑 `libshaderc`；
  后期再考虑在 Racket 内生成 SPIR-V。

### 6.6 验证层

本机只有 `VK_LAYER_INTEL_nullhw`、`VK_LAYER_MESA_device_select`、`VK_LAYER_MESA_overlay`，
**没有 `VK_LAYER_KHRONOS_validation`**。调试期建议安装 `vulkan-validationlayers`。

---

## 7. 备选方案：新的 `ffi2`

Racket 源码树里有实验性的 `ffi2`（Racket 9.2+，mflatt 维护）：
`/home/lu96/Desktop/work/bash/racket-src/pkgs/ffi2-lib/`。
它是更静态的 FFI：`define-ffi2-type` + `struct_t` / `union_t` / `array_t`，
`ffi2-lib-ref` / `ffi2-cast`，支持 tagged pointer、cstruct 的 C 表示、`ffi2-malloc` 等。
当前 9.3 **未安装**（`(require ffi2)` 失败）。

- 优点：类型更明确，可能有更好的 struct / 指针支持。
- 缺点：未随发行版安装、生态不成熟、文档/示例少。
- 建议：**先用成熟的 `ffi/unsafe`**（既有 opengl + 2019 Vulkan 绑定都验证可行），
  `ffi2` 作为后续可选迁移目标。

---

## 8. 建议的下一步（按优先级）

1. **写一个最小生成器**（Racket 或 Python）从 `vulkan/registry/vk-1.4.309.xml` 先只生成：
   - basetype / handle / enum / bitmask / struct / union / funcpointer；
   - 30 个核心命令（instance/device 创建、buffer/image、command buffer、提交、fence）。
   目标：先编译通过、跑通“创建 instance/device + 计算着色器”。
2. **实现分派加载器**：global / instance / device 三张表，懒解析 + `function-ptr` 缓存。
3. **加 `sType`/`pNext` 辅助宏**，并用 `structextends` 做校验。
4. **决定 flag 表示法**（整数 vs 符号列表），并统一 enum/bitmask 的生成策略。
5. **拆模块**控制编译时间（unsafe 类型层 / 命令层 / 安全封装层）。
6. 把 s-glsl 的 GLSL AST 作为**可选前端**，后端接 glslc 或 libshaderc（先外部进程）。
7. 安装 `vulkan-validationlayers` 与 `glslang-tools` 便于调试与自测（需联网/apt）。

---

## 9. 可复现命令记录

```bash
# 环境
racket --version                      # Racket v9.3 [cs]
vulkaninfo --summary                  # 1.4.309, 只有 llvmpipe
nm -D --defined-only /lib/x86_64-linux-gnu/libvulkan.so.1 | grep -c ' T vk'   # 269

# 最小 FFI 验证
cat > /tmp/vktest.rkt <<'EOF'
#lang racket/base
(require ffi/unsafe ffi/unsafe/define)
(define-ffi-definer define-vk (ffi-lib "libvulkan" '("1" "")))
(define-vk vkEnumerateInstanceVersion
  (_fun (ver : (_ptr o _uint32)) -> (result : _int) -> (values result ver)))
(define-values (rc ver) (vkEnumerateInstanceVersion))
(printf "rc=~a version=~a.~a.~a~%" rc
  (bitwise-and (arithmetic-shift ver -22) #x3ff)
  (bitwise-and (arithmetic-shift ver -12) #x3ff)
  (bitwise-and ver #xfff))
EOF
racket /tmp/vktest.rkt                  # => rc=0 version=1.4.309

# 复现 2019 绑定的完整计算示例
rm -rf /tmp/vkroot && mkdir -p /tmp/vkroot/vulkan
cp /tmp/racket-vulkan-ref/unsafe.rkt /tmp/vkroot/vulkan/
cp -r /tmp/racket-vulkan-ref/examples/mandelbrot /tmp/vkmandel
sed -i 's/VK_TRUE #e1e8/VK_TRUE (* 120 1000000000)/' /tmp/vkmandel/mandelbrot.rkt
PLTCOLLECTS="/tmp/vkroot:" racket /tmp/vkmandel/mandelbrot.rkt   # 生成 30MB RGBA
```

---

## 10. 引用/文件清单

- OpenGL 生成器：`/home/lu96/.local/share/racket/9.3/pkgs/opengl/opengl/readspec.rkt`
- OpenGL 运行时：`/home/lu96/.local/share/racket/9.3/pkgs/opengl/opengl/main.rkt`
- 2019 Vulkan 绑定：`/tmp/racket-vulkan-ref/`（`private/generate/make-unsafe.rkt`、`unsafe.rkt`）
- 注册表：`vulkan/registry/vk-1.4.309.xml`、`vulkan/registry/vk-main.xml`
- Racket FFI 文档：`/usr/share/racket/pkgs/racket-doc/scribblings/foreign/`
  （`types.scrbl` 的 Enumerations and Masks、define-cstruct 章节）
- 最新注册表：`vulkan/registry/vk-1.4.363.xml`（稳定基准）、`vulkan/registry/vk-main.xml`（365）
- `ffi2` 源码：`/home/lu96/Desktop/work/bash/racket-src/pkgs/ffi2-lib/`
- s-glsl：`/home/lu96/Desktop/work/racket-glsl/`

---

## 11. 原型实现（已跑通）

按第 8 节的建议，已实现一个最小可用原型，代码在本仓库：

```
vulkan/generate.rkt            # vk.xml -> generated/*.inc
vulkan/generated/*.inc         # 常量 / 类型 / 命令
vulkan/unsafe.rkt              # 运行时：define-vk、分派加载、VkResult 检查
test/{smoke,device,compute}.rkt
```

### 11.1 生成器

- 输入：`vulkan/registry/vk-1.4.363.xml`；输出：`vulkan/generated/{constants,types,commands,safe}.inc`。
- 处理 feature 依赖：`VK_VERSION_1_0` 在 363 里只是 profile，需沿 `depends` 展开到
  `VK_BASE/COMPUTE/GRAPHICS_VERSION_1_0`，才能拿到真正的 137 条 core 命令。
- 类型映射（参考 opengl 的 `basic-type-map`/`pointer-to`）：
  - 标量 → `_uint8/_uint32/_uint64/...`，`VkBool32 → _uint32`，`VkDeviceSize/Address → _uint64`
  - handle → `(_cpointer/null 'VkX_T)`
  - enum → `_int32`；bitmask → `_uint32`，64 位（`VkFlags64`/`bitwidth=64`）→ `_uint64`
  - struct/union → `define-cstruct` / `_union`；funcpointer → `_pointer`
  - 指针成员 → `_pointer`；定长数组 → `(_array elem N)`
- 类型按 **by-value 成员依赖**拓扑排序，解决 `define-cstruct` 的引用顺序。
- 结构体统一加 `#:malloc-mode 'zeroed-atomic`：零初始化 + 非移动。
- 只保留 `api` 含 `vulkan` 的 `<type>`/`<member>`（`vulkansc` 变体会造成重名成员，
  例如 `VkGraphicsPipelineCreateInfo.pStages`）。
- 命令分派层级由首参类型推断（`VkDevice/VkQueue/VkCommandBuffer`→device，
  `VkInstance/VkPhysicalDevice`→instance，其余→global）。

生成结果（target `VK_VERSION_1_0`）：**1778 常量 / 286 类型 / 135 命令**，
`unsafe.rkt` 编译约 **7 秒**（对比：2019 旧绑定 VK1.1 405KB 编译 30 秒）。

### 11.2 运行时

- `define-vk` 宏：生成 `(define name (delay (vk-lookup-proc ...)))` 包装，
  固定 arity，首次调用解析。
- `vk-resolve`：按层级查 `libvulkan` 符号 / GIPA / GDPA；`register-vk-instance!` /
  `register-vk-device!` 切换上下文并清缓存。
- `check-vkResult`：`VkResult` 为负即抛异常（正值为成功码如 `VK_TIMEOUT`）。
- `vk-malloc` / `stable-bytes`：用 `'atomic-interior`（不可移动）分配/复制（见 11.4）。

### 11.3 实测结果

| 测试 | 结果 |
|------|------|
| `smoke.rkt` | 建 instance、枚举物理设备、读 deviceName/apiVersion ✅ |
| `device.rkt` | 建逻辑设备、经 **GDPA** 调 `vkCreateCommandPool` ✅ |
| `compute.rkt` | 完整 compute（buffer/descriptor/pipeline/cmdbuf/submit/回读）✅ |

`compute.rkt` 用预编译 `comp.spv` 在 llvmpipe 上渲染 3200×2400 Mandelbrot，
输出 30,720,000 字节 RGBA，**md5 与 2019 参考绑定完全一致**：

```
947e43451635cb72358ae61e0a5d1fc7  tests/compute.rgba
947e43451635cb72358ae61e0a5d1fc7  /tmp/vkmandel/mandelbrot.rgba
```

### 11.4 重大发现：`'atomic` 会被 GC 移动 —— 驱动可见内存必须 `atomic-interior`

原型调试中 `compute.rkt` 曾出现**与堆布局相关的随机段错误**（在 `vkWaitForFences` /
`vkQueueWaitIdle`，即 llvmpipe 执行阶段崩溃）。经过多轮对照实验定位到根因：

> **Racket CS 里用普通 `'atomic` 分配的内存仍然会被 GC 移动**；
> 只有 **`'atomic-interior`（文档原话：“atomic-immobile”）** 才保证地址永久稳定。
> 而 Vulkan 驱动会在调用期间甚至调用之后持有这些指针，一旦 GC 移动内存，
> 驱动读到的是失效地址 → 段错误。

Racket FFI 文档也提醒：阻塞式 foreign call 期间可能发生 GC，因此
`_ptr` 参数应当用 `'atomic-interior` 分配模式。

#### 对照实验（同一份 compute 代码，仅改分配模式）

| 版本 | 分配模式 | 结果 |
|------|----------|------|
| A | 裸缓冲用 `'atomic` | **随堆布局随机崩溃** |
| B | 所有 `malloc` 改 `'atomic-interior` | **10/10 + 8/8 稳定，md5 一致** |
| C | 结构体 `zeroed-atomic` → `zeroed-atomic-interior` | 同上 |

排除掉的假设（都试过、都不能解释/修复）：结构体大小不匹配（108 个结构体 `sizeof`
全部与 C 一致）、驱动惰性引用 pCode/pName（单独复制不够）、结构体被回收（全局
`keep!` 全部结构体仍崩）、强制 GC、`'stubborn`（CS 不支持）。

#### 结论 / 规则

1. **凡是交给驱动/FFI 的内存，一律用不可移动分配**：
   - 生成结构体：`#:malloc-mode 'zeroed-atomic-interior`（已固化到生成器）；
   - 裸缓冲区/字符串：`vk-malloc` / `stable-bytes`（均 `'atomic-interior`）；
   - **不要**用裸 `(malloc ...)`（默认 `'atomic`，会移动），也不要用
     `_string`/`_bytes`/`_vector` 的自动转换结果去承载驱动会保留的数据。
2. 这不是“驱动违反了复制语义”的问题，而是 **Racket CS 的移动式 GC** 与
   “把指针交给 C” 的固有冲突；opengl 之所以没暴露，是因为 GL 调用短、
   驱动立即复制，而 Vulkan 的阻塞式等待 + 惰性解析把它放大成必现 bug。
3. `atomic-interior` 只保证“不移动”，不保证“不被回收”——所以仍需保证
   对应的 Racket cpointer 在驱动使用期间可达（本原型用顶层 `define` 持有）。

这一条已经写进 `vulkan/unsafe.rkt` 的 `vk-malloc` / `stable-bytes` 和生成器
（结构体 `zeroed-atomic-interior`），`tests/compute-raw.rkt` 全部改用不可移动分配，
连续多次运行零崩溃。

### 11.5 安全层（ownership / arena）

在 11.4 的规则之上，实现了按 Vulkan 对象生命周期自动保活的安全层：

**运行时原语**（`vulkan/unsafe.rkt`）：

| 原语 | 作用 |
|------|------|
| `vk-malloc` | `atomic-interior` 分配，有当前 arena 时自动登记 |
| `stable-bytes` | bytes → 不可移动内存 + NUL |
| `vk-new` | 构造结构体并登记到当前 arena |
| `vk-zero` | 零初始化的不可移动结构体 |
| `with-vk-arena` | 在 arena 中执行，返回 `(values 结果 arena)` |
| `vk-retain-for!` / `vk-release-for!` / `vk-object-arena` | 句柄 ↔ arena 注册表 |

**生成的安全包装**（`generated/safe.inc`，47 个）：对每个 create/allocate 命令生成

```racket
(vk-create-buffer device (λ () (vk-new make-VkBufferCreateInfo ...)) #f)  ; -> VkBuffer
(vk-destroy-buffer device buffer #f)                                       ; 释放 arena
```

包装内部：新建 arena → 在 arena 中跑 builder thunk（其中 `vk-new`/`vk-malloc`/`stable-bytes`
全部登记）→ 调原生命令 → 把 arena 挂到返回句柄 → destroy 时释放。

**测试**：`tests/compute-safe.rkt`（完整 compute 用安全层）、`tests/arena-test.rkt`（内存/所有权单测）。

- 安全层 compute：**12/12 稳定**，md5 与参考一致。
- 验证层：`VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation`（已装 `vulkan-validationlayers`）
  跑完无 validation 报错。
- 装了 `gdb` / `glslang-tools` / `spirv-tools` 便于后续调试与自编 shader。

### 11.6 全量 1.4 + 扩展

- 目标从 `VK_VERSION_1_0` 提升到 `VK_VERSION_1_4`（含 1.0–1.4 全部 base/compute/graphics 闭包）。
- 新增 `generate.rkt` 第 4 个参数：逗号分隔的扩展列表，沿扩展 `depends` 展开，
  自动跳过 `provisional` / `supported=disabled`。
- 当前纳入 10 个常用扩展（surface / swapchain / xlib / xcb / wayland / display /
  headless_surface / debug_utils / get_physical_device_properties2 / get_surface_capabilities2）。
- 规模：**280 命令 / 652 类型 / 2224 常量 / 127 安全封装**，`unsafe.rkt` 编译 ~25s。

过程中修的两个真实生成器 bug：

1. **`api="vulkansc"` 重复参数**：`vkCreateSwapchainKHR` 的 `pCreateInfo` 出现两次
   （vulkan + vulkansc），导致 arity 多算；现按 `api` token 过滤所有 `<param>`。
2. **平台类型映射**：`Window`/`VisualID`/`RROutput`/`xcb_window_t` 等在 vk.xml 里只有引用、
   没有定义，被降级成 `_pointer`，导致 Xlib 的 `window` 字段无法传整数；
   现加 `platform-ctype` 表（`Window → _ulong` 等）。
   同时修了 `_VkBool32`/`_VkDeviceSize` 等 basetype 被错误定义成 `_pointer` 的键类型 bug。

新增测试 `tests/surface-x11.rkt`：在真实的 X server（llvmpipe + `VK_KHR_xlib_surface`）上
创建 Xlib surface，查询 support/caps/formats/present modes，建 device + swapchain，
取回 3 张 swapchain image。验证层全部无报错。

### 11.7 数组型 create（安全层）

安全包装现在支持数组输出：

- **显式 count 参数**（`vkCreateGraphicsPipelines` / `vkCreateComputePipelines`）：
  builder 返回 struct 的 **vector**，包装用 `vk-struct-array` 拷成连续数组，按 vector 长度推导 count，
  返回句柄 vector。
- **count 在 info 里**（`vkAllocateCommandBuffers` / `vkAllocateDescriptorSets`）：
  从 `VkInfo-*Count` 字段读数量，分配/读回句柄 vector。
- 单个输出仍返回单个句柄。

`tests/compute-safe.rkt` 已改为一次创建 2 个 descriptor set / 2 个 pipeline / 2 个 command buffer，
md5 不变；验证层无报错。

### 11.8 图形渲染 + 显示（已跑通）

结论：**当前 API 足够渲染和显示**。`tests/triangle-glfw.rkt` 在真实窗口上跑通了完整图形管线：

1. `XCreateSimpleWindow` 开窗 + map；`VK_KHR_xlib_surface` 建 surface
2. 选 graphics+present 队列族建 device
3. swapchain（3 张 image）+ image view + render pass + framebuffer
4. `glslangValidator` 把 vert/frag GLSL 编成 SPIR-V
5. `vkCreateGraphicsPipelines`（vertex input/input assembly/viewport/raster/multisample/color blend）
6. 每帧：`vkAcquireNextImageKHR` → 录 render pass + `vkCmdDraw(3)` → `vkQueueSubmit` → `vkQueuePresentKHR`
7. 用 `vkCmdCopyImageToBuffer` 回读验证：中心像素 `(137 138 187 255)` ≠ 清屏色 → 三角形确实画出来了

验证层：**0 报错**（含 device/queue/submit/present/renderpass 全部 VUID 检查）。

这一轮又修了两个真实生成器 bug：

1. **`(~0U)` 形式常量未解析**：`VK_SUBPASS_EXTERNAL` / `VK_QUEUE_FAMILY_IGNORED` /
   `VK_WHOLE_SIZE` / `VK_ATTACHMENT_UNUSED` 等全部缺失（`parse-c-int` 现在先剥括号）。
   这些是渲染同步必需的。
2. **平台类型与 basetype 键类型**（见 11.6）。

渲染测试还顺带暴露了测试自身的两个问题（验证层拓出）：信号量复用、readback 内存未释放——
均已修复。

### 11.9 窗口绑定（调研 + 方案）

#### Racket OpenGL 是怎么绑窗口的

`opengl`/`sgl` **只绑 GL 函数，不管窗口**。sgl 文档原话：“do not address system-level
concerns, such as the attachment of GL rendering contexts to displays”，窗口+上下文由
`racket/gui` 提供：

- 窗口 = `canvas%`（`'gl` 样式）。创建时 `prepare-widget-gl-context` 选 GLX FBConfig 并把
  widget 的 X visual 设成对应 visual。
- `(send canvas with-gl-context thunk)` → `(send (send canvas get-dc) get-gl-context)` →
  首次 `create-widget-gl-context` 建 `GLXContext`（`glXCreateContextAttribsARB`，4.5→3.0 逐个试）。
- 绑定：`glXMakeCurrent(xdisplay, xid, gl)`；呈现：`glXSwapBuffers(xdisplay, xid)`。
  原生句柄 XID 由 `gdk_x11_drawable_get_xid` 从 GDK 拿。
- 平台分支：X11=GLX，Wayland=EGL，Windows=WGL，macOS=CGL。
  （`gui-lib/mred/private/wx/{gtk,win32,cocoa}/gl-context.rkt`）
- 上下文/线程：`racket/draw/private/gl-context.rkt` 的 `gl-context%` 用 channel 做锁 +
  `call-as-current`。

#### 原生窗口句柄怎么来的，底层依赖

不是 GL/Vulkan 产生的，是**窗口工具库**产生的：

```
canvas% → GTK3 (gtk_drawing_area_new) → GDK (GdkWindow)
   → 平台后端（运行时选）:
        X11:     XCB/Xlib CreateWindow → X server 分配 XID（32 位资源 ID，不是指针）
        Wayland: wl_compositor.create_surface → wl_surface*（客户端 proxy 对象）
```

- Linux 上底层就是 **X11 或 Wayland**（GTK3/GDK3 同时链接 libX11/libxcb/libwayland-client，
  按 session 运行时选）。本机 `XDG_SESSION_TYPE=x11`、`gdk_display_get_name`=`":0"` → X11。
- 其他平台：Win32(HWND) / Cocoa(NSWindow)。
- Racket GUI 自己就是这么判定的（`wx/gtk/queue.rkt`）：
  `wayland? = gdk_display_get_name 以 "wayland" 开头`。

Vulkan surface 就是把这个句柄交给 driver：X11 = `VkXlibSurfaceCreateInfoKHR{dpy,window}` /
`VkXcbSurfaceCreateInfoKHR`；Wayland = `VkWaylandSurfaceCreateInfoKHR{display,surface}`。

#### 我们的方案：独立 GLFW 窗口模块

按“开发期最省事 + 与绑定解耦”的要求，新增 **`vulkan/window.rkt`**（只依赖 ffi + libglfw，
不 require `vulkan/unsafe`）：

- `make-glfw-window` / `glfw-window-framebuffer-size` / `glfw-window-poll!` /
  `glfw-window-should-close?` / `glfw-window-destroy!`
- `glfw-required-instance-extensions`（本机返回 `VK_KHR_surface` + `VK_KHR_xcb_surface`）
- `glfw-window-create-surface`（raw pointer；跨 X11/Wayland/Windows/macOS）
- `glfw-window-x11` / `glfw-window-wayland`（需要原生句柄时）

优点：关窗/Esc/尺寸由 GLFW 自己处理（它装了 WM_DELETE_WINDOW），不用手写 X 事件。
`tests/triangle-glfw.rkt` 改成用它（dynamic viewport/scissor + swapchain 重建支持窗口缩放），
`tests/triangle-x11.rkt` 保留为手写 X11 对照。验证层 0 报错。

### 11.10 目录 / 模块结构（清理后）

打包修正：原来是单个 collection 却把代码放在 `vulkan/` 子目录（`raco pkg install` 解析不到，
被 `PLTCOLLECTS` 掩盖）。现改为**多集合包**（`collection 'multi`），`vulkan/` 就是集合。

职责拆分（原来全在 `unsafe.rkt`）：

| `(require ...)` | 文件 | 内容 |
|-----------------|------|------|
| `vulkan` | `vulkan/main.rkt` | 入口，reprovide 安全层 |
| `vulkan/unsafe` | `vulkan/unsafe.rkt` | 原始 FFI：`define-vk`、global/instance/device 分派、`VkResult`、内存规则/arena 原语 |
| `vulkan/safe` | `vulkan/safe.rkt` | 原始 + `generated/safe.inc`（`vk-create-*`/`vk-destroy-*`），reprovide unsafe |
| `vulkan/window` | `vulkan/window.rkt` | GLFW 窗口，与绑定无关 |
| — | `vulkan/generate.rkt` | 生成器（默认路径相对自身） |

其他重命名/移动：

- `vulkan/generate/generate.rkt` → `vulkan/generate.rkt`（去掉重复目录）
- `vendor/` → `vulkan/registry/`（不成为顶层 collection）
- `test/` → `tests/`，并重命名：`compute.rkt`→`compute-raw.rkt`、
  `surface.rkt`→`surface-x11.rkt`、`triangle.rkt`→`triangle-glfw.rkt`
- `experiments/` 移入 `vulkan/experiments/`（并在 `vulkan/info.rkt` 里 `compile-omit-paths`
  跳过编译，因为它引用的是 2019 旧绑定）

### 11.11 下一步

1. 全量生成（`VK_VERSION_1_4` + 扩展），并按类别拆模块控制编译时间/体积。
2. 给 `const char*` / 数组 / 输出参数做类型化与自动保活封装（安全层）。
3. 按 `structextends` 生成 `pNext` 链辅助，自动填 `sType`。
4. flags 表示法（整数 vs `_bitmask`）统一并写进文档。
5. SPIR-V：外接 `glslc`/`libshaderc`，或让 s-glsl 增加 SPIR-V 后端。
