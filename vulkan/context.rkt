#lang racket/base
;; ============================================================
;; 组合层：显式 context（把「全局状态」提升为可持有/可绑定的状态）。
;;
;; base/memory 不再有模块级可变全局：
;;   * 命令缓存：base 的 `current-vk-proc-cache`（默认每线程惰性）
;;   * 句柄→arena 注册表：本模块的 `current-vk-arena-registry`（默认每线程惰性）
;;
;; `vk-context` 继承 base 的 `vk-base-context`（instance/device），再加
;; proc-cache / arena-registry。需要跨线程共享/显式管理时，用户创建 context
;; 并用 `with-vk-context` 绑定；否则默认按线程隔离（无需锁/CAS）。
;; ============================================================

(require "base.rkt")

(provide (struct-out vk-context)
         make-vk-context
         with-vk-context
         current-vk-arena-registry
         vk-handle-arena-set! vk-handle-arena-remove! vk-handle-arena)

(struct vk-context vk-base-context (proc-cache arena-registry) #:mutable)

(define (make-vk-context [instance #f] [device #f])
  (vk-context instance device (make-hash) (make-hash)))

;; 句柄→arena 注册表（#f = 未绑定，按线程惰性创建）。
(define current-vk-arena-registry (make-parameter #f))

;; 在给定 context 下运行：同时绑定 instance/device/命令缓存/arena 注册表。
;; owner #f = 显式共享（同一 context 可跨线程使用，并发由用户负责）。
(define (with-vk-context ctx thunk)
  (parameterize ([current-vk-context ctx]
                 [current-vk-instance (vk-base-context-instance ctx)]
                 [current-vk-device (vk-base-context-device ctx)]
                 [current-vk-proc-cache (cons #f (vk-context-proc-cache ctx))]
                 [current-vk-arena-registry (cons #f (vk-context-arena-registry ctx))])
    (thunk)))

;; 无显式 context 时，按线程惰性创建 registry（无模块级全局）。
(define (current-arena-registry)
  (thread-local-value current-vk-arena-registry make-hash))

;; 句柄 -> arena：创建时绑定，销毁时解绑。
;; 用 make-hash（equal?）：数组元素经 ptr-ref 读回时是新 cpointer 对象，
;; 只有按地址比较（equal?）才能命中；make-hasheqv 的 eqv? 会 miss。
(define (vk-handle-arena-set! h a)
  (hash-set! (current-arena-registry) h a) h)
(define (vk-handle-arena-remove! h)
  (hash-remove! (current-arena-registry) h))
(define (vk-handle-arena h)
  (hash-ref (current-arena-registry) h #f))
