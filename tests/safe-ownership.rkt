#lang racket/base
;; ============================================================
;; 范围 B1 防回归：safe 层数组 free 的所有权
;;
;;   * vkFreeCommandBuffers / vkFreeDescriptorSets 必须逐个释放数组里的
;;     句柄，而不是误释放 commandPool / descriptorPool（原实现取“第一个 handle 参数”）
;;   * 句柄注册表按地址比较：数组元素用 ptr-ref 读回（新 cpointer 对象）也要能命中
;; ============================================================

(require rackunit
         racket/file
         racket/string
         racket/runtime-path
         ffi/unsafe
         vulkan/manual
         vulkan/context)

(define-runtime-path here ".")
(define safe-inc (build-path here ".." "vulkan" "generated" "safe.inc"))

(define (wrapper-source name)
  (for/first ([l (in-list (file->lines safe-inc))]
              #:when (string-contains? l (format "(define (~a " name)))
    l))

;; 1. 数组 free：按 count 循环释放元素
(for ([name '("vkFreeCommandBuffers" "vkFreeDescriptorSets")])
  (define src (wrapper-source name))
  (check-not-false src (format "wrapper exists: ~a" name))
  (check-true (and src (string-contains? src "for ("))
              (format "~a loops over the handle array" name))
  (check-true (and src (string-contains? src "ptr-ref"))
              (format "~a releases each element" name)))

;; 2. 数组 free 不能释放 pool
(check-false (string-contains? (wrapper-source "vkFreeCommandBuffers")
                               "(vk-handle-arena-remove! commandPool)")
              "vkFreeCommandBuffers must not release the pool")
(check-false (string-contains? (wrapper-source "vkFreeDescriptorSets")
                               "(vk-handle-arena-remove! descriptorPool)")
              "vkFreeDescriptorSets must not release the pool")

;; 3. 单句柄 free 仍然是直接释放该句柄
(check-true (string-contains? (wrapper-source "vkFreeMemory")
                              "(vk-handle-arena-remove! memory)")
            "single-handle free still releases its handle")

;; 4. 运行时：按地址命中的句柄注册表（模拟 free wrapper 的逐元素释放）
(define _H (_cpointer/null 'H_T))
(define pool-arena (make-vk-arena))
(define arr (vk-malloc _H 2))
(define handles (for/list ([i (in-range 2)]) (ptr-ref arr _H i)))
(for ([h handles]) (vk-handle-arena-set! h pool-arena))
(check-true (for/and ([h handles]) (eq? (vk-handle-arena h) pool-arena)))
;; 模拟 wrapper：用 ptr-ref 重新读回（新 cpointer 对象）再释放
(for ([i (in-range 2)]) (vk-handle-arena-remove! (ptr-ref arr _H i)))
(check-false (vk-handle-arena (ptr-ref arr _H 0))
             "re-read handle must match by address and be released")
(check-false (vk-handle-arena (ptr-ref arr _H 1)))

(printf "safe-ownership: all checks passed\n")
