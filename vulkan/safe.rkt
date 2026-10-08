#lang racket/base
;; ============================================================
;; 组合层总入口（vulkan/safe）：糖 + 错误/枚举 + context/callback/pnext/
;; capability/map 的组合门面（自动模式；手动模式见 vulkan/manual）。
;;
;; 基于 base（类型/常量）+ generated/commands（原始命令）+ memory（原子）+
;; result（错误/枚举支撑）+ safe-support（糖运行期小工具），提供：
;;   * 错误策略与枚举：re-export `vulkan/result`（check-vk-result 等）
;;   * with-vk-call：调用作用域（多条命令共享；策略别名）
;;   * vkCreate* / vkAllocate* / vkDestroy* / vkFree* 包装
;;     （自动对象作用域，见生成的 vulkan/generated/safe.rkt）
;;
;; 本模块**不 re-export 原始命令**；需要裸命令请用 (require vulkan/bindings)
;; 或 vulkan/raw（避免同名/语义混淆，靠模块隔离区分）。类型/常量/原子照常导出。
;; ============================================================

(require "base.rkt"
         "memory.rkt"
         "result.rkt"
         "context.rkt"
         "callback.rkt"
         "pnext.rkt"
         "capability.rkt"
         "map.rkt"
         "safe-support.rkt"
         "generated/safe.rkt")

(provide (all-from-out "base.rkt")
         (all-from-out "memory.rkt")
         (all-from-out "result.rkt")
         (all-from-out "context.rkt")
         (all-from-out "callback.rkt")
         (all-from-out "pnext.rkt")
         (all-from-out "capability.rkt")
         (all-from-out "map.rkt")
         (all-from-out "safe-support.rkt")
         (all-from-out "generated/safe.rkt"))
(provide (all-defined-out))

;; 调用作用域（策略别名）：多条命令共享一个 arena；单条命令用 with-vk-arena。
(define-syntax-rule (with-vk-call body ...)
  (with-vk-arena body ...))
