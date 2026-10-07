#lang racket/base
;; ============================================================
;; 范围 C1 防回归：命令分派缓存按 (name level instance device) 分桶
;;
;; 原问题：define-vk 用 delay 把首次解析的函数指针永久钉死，切换 instance/device
;; 后仍复用旧指针。现在每次调用按当前上下文查表，表内缓存。
;; ============================================================

(require rackunit
         ffi/unsafe
         vulkan/manual)

;; 一个可解析的 global 命令签名（函数指针本身与上下文无关，
;; 但缓存 key 必须随 instance/device 变化）
(define fun-type (_fun (out : (_ptr o _uint32)) -> _VkResult))

(define (resolve!) (vk-lookup-proc 'vkEnumerateInstanceVersion 'global fun-type))

(vk-proc-cache-clear!)
(check-equal? (hash-count (vk-proc-cache-snapshot)) 0)

;; 上下文一：默认 instance=#f, device=#f
(void (resolve!))
(check-equal? (hash-count (vk-proc-cache-snapshot)) 1 "one entry per context")

;; 上下文二：换 instance（device 重置为 #f）→ 新 key
(void (vk-use-instance! 'fake-instance))
(void (resolve!))
(check-equal? (hash-count (vk-proc-cache-snapshot)) 2 "new instance => new cache entry")

;; 上下文三：再换 device → 又一个 key
(void (vk-use-device! 'fake-device))
(void (resolve!))
(check-equal? (hash-count (vk-proc-cache-snapshot)) 3 "new device => new cache entry")

;; 回到上下文一：命中已有缓存，不应增长
(void (vk-use-instance! #f))
(void (resolve!))
(check-equal? (hash-count (vk-proc-cache-snapshot)) 3 "re-entering a context reuses its cache entry")

;; 缓存 key 确实是四元组，含 instance/device
(for ([k (in-list (hash-keys (vk-proc-cache-snapshot)))])
  (check-equal? (length k) 4 "cache key is (name level instance device)")
  (check-equal? (car k) 'vkEnumerateInstanceVersion))

(printf "dispatch-cache: all checks passed\n")
