#lang racket/base
;; ============================================================
;; M3.0 防回归：generated/facts.rkt 事实层
;;
;; bindings 层产出的命令/参数事实必须与真实绑定（generated/commands.rkt）一致，
;; 且分类完整（无 unknown），关键命令的 input/output/dispatch 判定正确。
;; ============================================================

(require rackunit
         racket/file
         racket/string
         racket/list
         racket/runtime-path
         vulkan/generated/facts)

(define-runtime-path here ".")
(define commands-rkt (build-path here ".." "vulkan" "generated" "commands.rkt"))

(define (find-command n)
  (for/first ([c (in-list vk-command-facts)] #:when (eq? (vk-command-name c) n)) c))

(define (param-of c n)
  (for/first ([p (in-list (vk-command-params c))] #:when (eq? (vk-param-name p) n)) p))

;; 1. 基本规模与唯一性
(check-not-false vk-command-facts)
(check-equal? (length vk-command-facts) (length (remove-duplicates (map vk-command-name vk-command-facts)))
              "command names are unique")

;; 2. level 合法
(for ([c (in-list vk-command-facts)])
  (check-not-false (memq (vk-command-level c) '(global instance device))
                   (format "valid level: ~a" (vk-command-name c))))

;; 3. 分类完整：不应出现 unknown（platform 类型已单独归类）
(define unknowns
  (for*/list ([c (in-list vk-command-facts)]
              [p (in-list (vk-command-params c))]
              #:when (eq? (vk-param-kind p) 'unknown))
    (list (vk-command-name c) (vk-param-name p) (vk-param-base p))))
(check-equal? unknowns '() "every param base type is classified")

;; 4. vkCreateBuffer：input 结构 + output 句柄 + dispatch
(define cb (find-command 'vkCreateBuffer))
(check-not-false cb)
(check-true (vk-command-result? cb))
(check-equal? (vk-command-dispatch cb) "VkDevice")
(check-equal? (vk-command-level cb) 'device)
(check-true (vk-param-const? (param-of cb 'pCreateInfo)))
(check-equal? (vk-param-kind (param-of cb 'pCreateInfo)) 'struct)
(check-false (vk-param-output? (param-of cb 'pCreateInfo)))
(check-equal? (vk-param-kind (param-of cb 'pBuffer)) 'handle)
(check-true (vk-param-output? (param-of cb 'pBuffer)))

;; 5. 全局命令 dispatch 为 #f；输出参数被识别
(define eiv (find-command 'vkEnumerateInstanceVersion))
(check-false (vk-command-dispatch eiv))
(check-equal? (vk-command-level eiv) 'global)
(check-true (vk-param-output? (param-of eiv 'pApiVersion)))

;; 6. count 参数被识别，且与数组参数同命令
(define eipd (find-command 'vkEnumeratePhysicalDevices))
(check-not-false (findf vk-param-count? (vk-command-params eipd)))

;; 7. 事实与真实绑定一致：每条 api 命令都在 commands.rkt 里
(define cmd-lines (file->lines commands-rkt))
(define (bound? name)
  (for/or ([l (in-list cmd-lines)])
    (string-contains? l (format "(define-vk ~a " name))))
(for ([c (in-list vk-command-facts)])
  (check-true (bound? (vk-command-name c))
              (format "api fact has a binding: ~a" (vk-command-name c))))

;; 8. dispatch 类型只应是合法的 dispatch handle
(for ([c (in-list vk-command-facts)])
  (define d (vk-command-dispatch c))
  (when d
    (check-not-false (member d '("VkInstance" "VkPhysicalDevice"
                                 "VkDevice" "VkQueue" "VkCommandBuffer"
                                 "VkExternalComputeQueueNV"))
                     (format "dispatch handle: ~a -> ~a" (vk-command-name c) d))))

(printf "api-facts: all checks passed (~a commands)\n" (length vk-command-facts))
