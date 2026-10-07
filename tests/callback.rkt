#lang racket/base
;; ============================================================
;; M3.5 防回归：回调（funcpointer）保活
;;
;;   * _PFN_* 是 _cprocedure，但结构体里的函数指针字段是 _pointer
;;   * vk-callback 只转换一次，得到稳定指针；令牌强引用 Racket 过程
;;   * vk-callback-keep! 把令牌登记到当前 arena（对象生命周期）
;;   * 填入结构体字段后能读回并通过 cast 调用原始过程
;; ============================================================

(require rackunit
         racket/list
         ffi/unsafe
         vulkan)

(define calls '())
(define (cb sev types data ud)
  (set! calls (cons (list sev types data ud) calls))
  0)

;; 1. 令牌：稳定指针 + 过程 + 类型
(define a (make-vk-arena))
(define tok (parameterize ([current-vk-arena a])
              (make-vk-callback _PFN_vkDebugUtilsMessengerCallbackEXT cb)))
(check-true (vk-callback? tok))
(check-true (cpointer? (vk-callback-ptr tok)))
(check-eq? (vk-callback-proc tok) cb)
(check-eq? (vk-callback-type tok) _PFN_vkDebugUtilsMessengerCallbackEXT)

;; 2. 登记到 arena
(vk-arena-keep! a tok)
(check-not-false (memq tok (vk-arena-kept a)))

;; 3. 填入 _pointer 字段，读回并通过 cast 调用
(define info (make-VkDebugUtilsMessengerCreateInfoEXT
              VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
              #f 0 #x10 #x1 (vk-callback-ptr tok) #f))
(define f (cast (VkDebugUtilsMessengerCreateInfoEXT-pfnUserCallback info)
                _pointer _PFN_vkDebugUtilsMessengerCallbackEXT))
(check-true (procedure? f))
(f 16 1 #f #f)
(check-equal? calls '((16 1 #f #f)))

;; 4. vk-callback-keep! = 建令牌 + 登记当前 arena + 返回指针
(define a2 (make-vk-arena))
(define ptr (parameterize ([current-vk-arena a2])
              (vk-callback-keep! _PFN_vkDebugUtilsMessengerCallbackEXT cb)))
(check-true (cpointer? ptr))
(check-equal? (length (vk-arena-kept a2)) 1)
(check-true (vk-callback? (car (vk-arena-kept a2))))

;; 5. 分配器结构体也能填（字段是 _pointer）
(define ac (make-VkAllocationCallbacks #f ptr #f #f #f #f))
(check-equal? (VkAllocationCallbacks-pfnAllocation ac) ptr)

;; 6. release 清空令牌（不再保活）
(vk-callback-release! tok)
(check-false (vk-callback-ptr tok))
(check-false (vk-callback-proc tok))

(printf "callback: all checks passed\n")
