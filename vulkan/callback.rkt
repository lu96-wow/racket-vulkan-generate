#lang racket/base
;; ============================================================
;; 回调（funcpointer）保活。
;;
;; 背景：
;;   * 生成的 `_PFN_*` 是 `_cprocedure`：把 Racket 过程转成 C 函数指针时，
;;     Racket 用一张 **弱表**（key = Racket 过程）保活 trampoline；过程一旦
;;     不可达，trampoline 就可能被回收。
;;   * 同一个 Racket 过程每转换一次都会生成**新的** trampoline，弱表会覆盖旧项。
;;     驱动可能长期持有函数指针，所以必须：1) 只转换一次得到稳定指针；
;;     2) 显式保活 Racket 过程。本模块的令牌同时做到这两点。
;;
;; 用法（在 create 的 builder 里，令牌登记进对象 arena）：
;;
;;   (vk-new make-VkDebugUtilsMessengerCreateInfoEXT
;;           VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
;;           #f 0 severity types
;;           (vk-callback-keep! _PFN_vkDebugUtilsMessengerCallbackEXT proc)
;;           #f)
;;
;; 回调可能在任意/驱动线程触发：**不要**依赖 `current-vk-arena` 等动态参数，
;; 上下文请用闭包捕获或传给 `pUserData`。
;; ============================================================

(require ffi/unsafe
         "memory.rkt")

(provide (struct-out vk-callback)
         make-vk-callback
         vk-callback-keep!
         vk-callback-release!)

;; ptr  : 稳定的 C 函数指针（只转换一次）
;; proc : Racket 过程（强引用 → 经 `_cprocedure` 弱表保活 trampoline）
;; type : 该回调的 `_PFN_*` ctype
(struct vk-callback (ptr proc type) #:mutable #:transparent)

(define (make-vk-callback type proc)
  (vk-callback (cast proc type _pointer) proc type))

;; 生成稳定指针并把令牌登记到当前 arena；返回可直接填入 `_pointer` 字段的指针。
(define (vk-callback-keep! type proc)
  (define cb (make-vk-callback type proc))
  (vk-arena-keep-current! cb)
  (vk-callback-ptr cb))

;; 放弃保活（调用方必须保证 C 侧不再引用该指针）。
(define (vk-callback-release! cb)
  (set-vk-callback-ptr! cb #f)
  (set-vk-callback-proc! cb #f)
  (void))
