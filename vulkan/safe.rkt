#lang racket/base
;; ============================================================
;; 组合层（vulkan/safe）：糖。
;;
;; 基于 base（类型/常量）+ commands（原始命令）+ memory（原子），提供：
;;   * check-vk-result：错误策略（负值抛异常，非负原样返回）
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
         ffi/unsafe
         racket/include)

(provide (all-from-out "base.rkt")
         (all-from-out "memory.rkt"))
(provide (all-defined-out))

;; 负值抛异常；非负结果（VK_SUCCESS / VK_NOT_READY / VK_TIMEOUT /
;; VK_INCOMPLETE / VK_EVENT_SET / VK_EVENT_RESET / VK_SUBOPTIMAL_KHR ...）原样返回。
(define (check-vk-result r who)
  (when (negative? r)
    (error who "Vulkan error ~a (~a)" r (vk-result-name r)))
  r)

;; 调用作用域（策略别名）：多条命令共享一个 arena；单条命令用 with-vk-arena。
(define-syntax-rule (with-vk-call body ...)
  (with-vk-arena body ...))

;; 从输出缓冲读回 n 个句柄（create/allocate 糖消费输出用）。
(define (vk-read-handles out t n)
  (for/vector ([i (in-range n)]) (ptr-ref out t i)))

;; enumerate 辅助：两遍调用 + VK_INCOMPLETE 重试，返回 (values result vector)。
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

;; char* 输入：接受 string 或 #f，转成 arena 里的 NUL 结尾字节
(define (vk-cstring s) (and s (stable-bytes (string->bytes/utf-8 s))))

(include "generated/safe.inc")
