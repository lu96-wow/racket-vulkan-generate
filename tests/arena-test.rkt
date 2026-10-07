#lang racket/base
;; 安全层 / 内存规则的单元测试
(require vulkan/unsafe ffi/unsafe rackunit)

;; 1. vk-malloc 分配的内存地址在 GC 后不变（不可移动）
(define p (vk-malloc _uint32))
(define addr (cast p _pointer _uintptr))
(for ([_ (in-range 5)]) (collect-garbage))
(check-equal? (cast p _pointer _uintptr) addr
              "vk-malloc memory must not move across GC")

;; 2. atomic-interior 同样不可移动
(define q (malloc 'atomic-interior _uint32))
(define qaddr (cast q _pointer _uintptr))
(collect-garbage)
(check-equal? (cast q _pointer _uintptr) qaddr)

;; 3. with-vk-arena 会记录 vk-new 造出来的结构体
(define-values (app a)
  (with-vk-arena
    (vk-new make-VkApplicationInfo VK_STRUCTURE_TYPE_APPLICATION_INFO
            #f #f 0 #f 0 VK_API_VERSION_1_0)))
(check-not-false (vk-arena-kept a) "arena should retain the struct")
(check-equal? (VkApplicationInfo-apiVersion app) VK_API_VERSION_1_0)

;; 4. 句柄 -> arena 注册 / 释放
(void (vk-handle-arena-set! 'fake-handle a))
(check-eq? (vk-handle-arena 'fake-handle) a)
(void (vk-handle-arena-remove! 'fake-handle))
(check-false (vk-handle-arena 'fake-handle))

;; 5. stable-bytes 复制并补 NUL
(define sb (stable-bytes #"abc"))
(check-equal? (ptr-ref sb _byte 0) 97)
(check-equal? (ptr-ref sb _byte 1) 98)
(check-equal? (ptr-ref sb _byte 2) 99)
(check-equal? (ptr-ref sb _byte 3) 0)

(printf "arena-test: all checks passed\n")
