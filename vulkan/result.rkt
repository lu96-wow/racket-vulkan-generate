#lang racket/base
;; ============================================================
;; 结果检查与枚举（vulkan/result）：VkResult 错误策略 + 枚举输出。
;;
;; 被 vulkan/safe（生成的包装）与 vulkan/capability（扩展查询）共用，
;; 避免同一语义在两处各写一份。依赖 base（VkResult 名字）+ memory（分配）。
;; 本模块只做“结果检查 + 两遍枚举”，不含包装/策略选择。
;; ============================================================

(require ffi/unsafe
         "base.rkt"
         "memory.rkt")

(provide check-vk-result
         vk-enumerate-result
         vk-enumerate-void)

;; 负值抛异常；非负结果（VK_SUCCESS / VK_NOT_READY / VK_TIMEOUT /
;; VK_INCOMPLETE / VK_EVENT_SET / VK_EVENT_RESET / VK_SUBOPTIMAL_KHR ...）原样返回。
(define (check-vk-result r who)
  (when (negative? r)
    (error who "Vulkan error ~a (~a)" r (vk-result-name r)))
  r)

;; 两遍调用 + VK_INCOMPLETE 重试，返回 (values result vector)。
;;   call : (count-ptr out-ptr) -> VkResult
(define (vk-enumerate-result who elem-ctype call)
  (define cnt (vk-malloc _uint32))
  (define r0 (call cnt #f))
  (check-vk-result r0 who)
  (let loop ([tries 0])
    (define n (ptr-ref cnt _uint32))
    (if (zero? n)
        (values r0 (vector))
        (let ([arr (vk-malloc elem-ctype n)])
          (define r (call cnt arr))
          (check-vk-result r who)
          (if (and (= r VK_INCOMPLETE) (< tries 8))
              (loop (add1 tries))
              (values r (for/vector ([i (in-range (ptr-ref cnt _uint32))])
                          (ptr-ref arr elem-ctype i))))))))

;; void 版：两遍调用，返回 vector（无 VkResult）。
(define (vk-enumerate-void who elem-ctype call)
  (define cnt (vk-malloc _uint32))
  (call cnt #f)
  (define n (ptr-ref cnt _uint32))
  (if (zero? n)
      (vector)
      (let ([arr (vk-malloc elem-ctype n)])
        (call cnt arr)
        (for/vector ([i (in-range (ptr-ref cnt _uint32))])
          (ptr-ref arr elem-ctype i)))))
