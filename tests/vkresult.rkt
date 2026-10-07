#lang racket/base
;; ============================================================
;; 范围 D3 防回归：VkResult 命令返回结果值
;;
;;   * 负值（VK_ERROR_*）仍然抛异常
;;   * 非负结果（VK_SUCCESS / VK_TIMEOUT / VK_NOT_READY / VK_INCOMPLETE /
;;     VK_SUBOPTIMAL_KHR ...）原样返回，调用方可判断
;; ============================================================

(require rackunit
         ffi/unsafe
         vulkan)

;; check-vk-result 语义
(check-equal? (check-vk-result VK_SUCCESS 'x) VK_SUCCESS)
(check-equal? (check-vk-result VK_TIMEOUT 'x) VK_TIMEOUT)
(check-equal? (check-vk-result VK_NOT_READY 'x) VK_NOT_READY)
(check-equal? (check-vk-result VK_INCOMPLETE 'x) VK_INCOMPLETE)
(check-exn exn:fail? (λ () (check-vk-result VK_ERROR_OUT_OF_HOST_MEMORY 'x)))

;; 真实命令：raw:vkEnumerateInstanceVersion 返回 VK_SUCCESS（0）
(define out (malloc 'atomic-interior _uint32))
(check-equal? (raw:vkEnumerateInstanceVersion out) VK_SUCCESS)
(check-true (>= (ptr-ref out _uint32) VK_API_VERSION_1_0))

(printf "vkresult: all checks passed\n")
