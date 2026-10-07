#lang racket/base
;; ============================================================
;; 组合层（vulkan/safe）：糖。
;;
;; 基于 base（类型/常量）+ commands（原始命令）+ memory（原子）+ support
;; （错误/枚举支撑），提供：
;;   * 错误策略与枚举：re-export `vulkan/support`（check-vk-result 等）
;;   * with-vk-call：调用作用域（多条命令共享；策略别名）
;;   * vk-create-* / vk-allocate-* / vk-destroy-* / vk-free-* 包装
;;     （自动对象作用域，见 generated/safe.inc）
;;
;; 本模块**不 re-export 原始命令**；需要裸命令请用 (require vulkan/bindings)
;; 或 vulkan/raw（避免同名/语义混淆，靠模块隔离区分）。类型/常量/原子照常导出。
;; ============================================================

(require "base.rkt"
         (prefix-in raw: "commands.rkt")   ; safe.inc 里的包装以 raw: 前缀调裸命令
         "memory.rkt"
         "support.rkt"
         "callback.rkt"
         "pnext.rkt"
         "capability.rkt"
         "map.rkt"
         ffi/unsafe
         racket/include)

(provide (all-from-out "base.rkt")
         (all-from-out "memory.rkt")
         (all-from-out "support.rkt")
         (all-from-out "callback.rkt")
         (all-from-out "pnext.rkt")
         (all-from-out "capability.rkt")
         (all-from-out "map.rkt"))
(provide (all-defined-out))

;; 调用作用域（策略别名）：多条命令共享一个 arena；单条命令用 with-vk-arena。
(define-syntax-rule (with-vk-call body ...)
  (with-vk-arena body ...))

;; 从输出缓冲读回 n 个句柄（create/allocate 糖消费输出用）。
(define (vk-read-handles out t n)
  (for/vector ([i (in-range n)]) (ptr-ref out t i)))

;; char* 输入：接受 string 或 #f，转成 arena 里的 NUL 结尾字节
(define (vk-cstring s) (and s (stable-bytes (string->bytes/utf-8 s))))

(include "generated/safe.inc")
