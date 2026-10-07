#lang racket/base
;; ============================================================
;; 状态分层回归：参数/context（无全局）
;;
;;   * with-vk-context 绑定 instance/device/缓存/注册表
;;   * vk-use-instance! / vk-use-device! 同步更新当前 context
;;   * 默认按线程隔离（无跨线程共享）
;;   * 显式共享：同一个 vk-context 传进子线程
;;   * vk-arena-thread / vk-arena-run 绑定 arena
;; ============================================================

(require rackunit
         ffi/unsafe
         vulkan)

;; 1. with-vk-context 绑定 dispatch + registry
(define ctx (make-vk-context 'inst 'dev))
(with-vk-context
 ctx
 (λ ()
   (check-eq? (current-vk-instance) 'inst)
   (check-eq? (current-vk-device) 'dev)
   (vk-handle-arena-set! 'h 'arena-h)
   (check-eq? (vk-handle-arena 'h) 'arena-h)))
(check-false (current-vk-context) "context is unbound outside with-vk-context")
(check-false (vk-handle-arena 'h) "handle not visible in another (thread-local) registry")

;; 2. vk-use-* 更新当前 context
(with-vk-context ctx (λ () (vk-use-device! 'dev2)))
(check-eq? (vk-base-context-device ctx) 'dev2)
(with-vk-context ctx (λ () (vk-use-instance! 'inst2)))
(check-eq? (vk-base-context-instance ctx) 'inst2)
(check-false (vk-base-context-device ctx) "new instance clears device in context")

;; 3. 默认按线程隔离
(define ch (make-channel))
(define worker
  (thread (λ ()
            (vk-handle-arena-set! 'x 'arena-x)
            (channel-put ch (vk-handle-arena 'x)))))
(check-eq? (channel-get ch) 'arena-x)
(thread-wait worker)
(check-false (vk-handle-arena 'x) "handle registered in another thread is not visible here")

;; 4. 显式共享：同一个 context 传进子线程
(define shared (make-vk-context))
(define ch2 (make-channel))
(define worker2
  (thread (λ ()
            (with-vk-context
             shared
             (λ ()
               (vk-handle-arena-set! 'y 'arena-y)
               (channel-put ch2 (vk-handle-arena 'y)))))))
(check-eq? (channel-get ch2) 'arena-y)
(thread-wait worker2)
(with-vk-context shared (λ () (check-eq? (vk-handle-arena 'y) 'arena-y)))

;; 5. 命令缓存随 context（显式隔离）
(define ctx2 (make-vk-context))
(with-vk-context
 ctx2
 (λ ()
   (void (vk-lookup-proc 'vkEnumerateInstanceVersion 'global
                         (_fun (out : (_ptr o _uint32)) -> _VkResult)))))
(check-true (> (hash-count (vk-context-proc-cache ctx2)) 0))

;; 6. arena 线程绑定
(define a (make-vk-arena))
(define t3 (vk-arena-thread a (λ () (void (vk-malloc _uint32)))))
(thread-wait t3)
(check-true (> (length (vk-arena-kept a)) 0)
            "vk-malloc inside vk-arena-thread registers to the arena")

(printf "context: all checks passed\n")
