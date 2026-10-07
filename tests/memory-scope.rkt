#lang racket/base
;; ============================================================
;; M3.1 防回归：生命周期令牌原语（手动 & 自动策略共用）
;;
;;   * vk-arena-keep! 把对象显式挂到指定令牌
;;   * vk-arena-reset! 放弃令牌引用（内存可回收）
;;   * with-vk-frame 复用令牌，body 结束后自动重置
;; ============================================================

(require rackunit
         ffi/unsafe
         vulkan/memory)

(define _H (_cpointer/null 'H_T))

;; 1. 顶层（无作用域）vk-malloc 是“不受管”的
(define a (make-vk-arena))
(define p (vk-malloc _H))
(check-equal? (vk-arena-kept a) '() "top-level vk-malloc is unmanaged")

;; 2. vk-arena-keep! 显式挂到指定令牌
(void (vk-arena-keep! a p))
(check-equal? (length (vk-arena-kept a)) 1 "explicit keep attaches to the given token")

;; 3. vk-arena-reset! 清空
(void (vk-arena-reset! a))
(check-equal? (vk-arena-kept a) '() "reset drops all references")

;; 4. with-vk-frame 复用同一令牌，结束后重置
(define frame (make-vk-arena))
(for ([i (in-range 3)])
  (void
   (with-vk-frame frame
     (void (vk-malloc _H))
     (void (vk-malloc _H))))
  (check-equal? (vk-arena-kept frame) '()
                "frame token is reset after each frame"))

;; 5. 帧内分配确实被登记（body 执行期间），结束后释放
(define seen #f)
(void
 (with-vk-frame frame
   (void (vk-malloc _H))
   (set! seen (length (vk-arena-kept frame)))))
(check-equal? seen 1 "allocations inside frame are tracked during body")
(check-equal? (vk-arena-kept frame) '() "and released after body")

;; 6. 帧结束后 current-vk-arena 恢复
(check-false (current-vk-arena) "frame restores the previous current-vk-arena")

(printf "memory-scope: all checks passed\n")
