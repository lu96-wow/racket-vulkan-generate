# experiments

本目录是 `RESEARCH.md` 里各项实测的最小复现脚本。

| 文件 | 说明 | 运行 |
|------|------|------|
| `01-minimal-ffi.rkt` | 直接 FFI 打印 `vkEnumerateInstanceVersion` | `racket 01-minimal-ffi.rkt` |
| `02-callback-qsort.rkt` | 验证 Racket lambda 可作 C 回调（qsort） | `racket 02-callback-qsort.rkt` |
| `03-struct-sizes.c` / `.rkt` | Racket `ctype-sizeof` vs C `sizeof` 对比 | `gcc -o /tmp/sizes 03-struct-sizes.c -lvulkan && /tmp/sizes`；Racket 侧见文件头注释 |
| `04-dispatch.rkt` | 验证 GIPA/GDPA 分派语义（未开扩展/版本不足返回 NULL） | 需 vk11-collection |
| `05-nonexported-ext.rkt` | 证明旧绑定无法调用未导出扩展函数 | 需 vk11-collection |
| `mandelbrot-vk11/` | 2019 旧绑定跑通的计算着色器完整示例 | 见下 |
| `vk11-collection/vulkan/unsafe.rkt` | 2019 `SimonLSchlee/racket-vulkan` 的生成物（MIT），仅作实验用 | — |

## 运行依赖旧 vk11 collection 的脚本

```bash
cd /home/lu96/Desktop/work/racket-vulkan/experiments
PLTCOLLECTS="$PWD/vk11-collection:" racket 04-dispatch.rkt
PLTCOLLECTS="$PWD/vk11-collection:" racket 05-nonexported-ext.rkt
PLTCOLLECTS="$PWD/vk11-collection:" racket mandelbrot-vk11/mandelbrot.rkt
```

`03-struct-sizes.rkt` 也需要 vk11 collection：

```bash
gcc -o /tmp/sizes 03-struct-sizes.c -lvulkan && /tmp/sizes
PLTCOLLECTS="$PWD/vk11-collection:" racket 03-struct-sizes.rkt
```

> 注：旧绑定的 `vkWaitForFences` 超时被改大（llvmpipe 软件渲染较慢），见 `RESEARCH.md` §4.2。
