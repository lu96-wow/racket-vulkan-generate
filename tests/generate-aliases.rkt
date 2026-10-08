#lang racket/base
;; ============================================================
;; 范围 A 防回归：生成器 alias 正确性 + 生成物结构自检
;;
;;   * struct/handle alias 必须生成 ctype 别名，而不是退化成空结构体
;;   * alias 命令（vk.xml 里无 <proto>）必须按目标命令签名生成
;;   * 运行时 ctype 别名等价、alias 命令可调用
;;
;; 用一个临时目录重新跑一遍生成器，断言其输出，避免依赖已提交的 .rkt。
;; ============================================================

(require rackunit
         racket/system
         racket/file
         racket/list
         racket/string
         racket/path
         racket/port
         racket/runtime-path
         ffi/unsafe
         vulkan/manual)

(define-runtime-path here ".")
(define project-root (simplify-path (build-path here "..")))
(define gen (build-path project-root "vulkan-gen" "main.rkt"))
(define reg (build-path project-root "registry" "vk-1.4.363.xml"))

;; 与 README 一致的目标 feature + 扩展
(define exts
  (string-join
   '("VK_KHR_surface" "VK_KHR_swapchain" "VK_KHR_xcb_surface"
     "VK_KHR_xlib_surface" "VK_KHR_wayland_surface" "VK_EXT_debug_utils"
     "VK_KHR_get_physical_device_properties2" "VK_KHR_get_surface_capabilities2"
     "VK_KHR_display" "VK_EXT_headless_surface")
   ","))

(define out (make-temporary-file "vkgen-~a" 'directory))
(define audit (make-temporary-file "vkgen-audit-~a" 'directory))

(define (run-generator!)
  (define racket-exe (find-executable-path "racket"))
  (check-true
   (parameterize ([current-error-port (open-output-nowhere)])
     (system* racket-exe (path->string gen) (path->string reg)
              (path->string out) "VK_VERSION_1_4" exts (path->string audit)))
   "generator should exit 0"))

(define (generated-lines name)
  (file->lines (build-path out name)))

;; 1. 不允许出现退化的占位结构体（原 struct alias 会生成 ((_dummy _uint8))）
(define (check-no-placeholder-types)
  (define types (generated-lines "types.rkt"))
  (check-equal? (filter (λ (l) (string-contains? l "_dummy")) types)
                '()
                "generated types must not contain _dummy placeholders"))

;; 2. 所有 _Vk 别名目标都必须已定义，且在别名之前
(define (check-alias-type-order)
  (define types (generated-lines "types.rkt"))
  (define defined (make-hash))
  (for ([l (in-list types)] [i (in-naturals)])
    (define m (regexp-match #px"^\\(define(?:-cstruct)? (_[A-Za-z0-9]+)" l))
    (when m (hash-set! defined (string->symbol (cadr m)) i)))
  (for ([l (in-list types)] [i (in-naturals)])
    (define m (regexp-match #px"^\\(define (_Vk[A-Za-z0-9]+) (_Vk[A-Za-z0-9]+)\\)" l))
    (when m
      (define target (string->symbol (list-ref m 2)))
      (check-true (hash-has-key? defined target)
                  (format "alias target defined: ~a" target))
      (check-true (< (hash-ref defined target -1) i)
                  (format "alias target defined before use: ~a" target)))))

;; 3. 关键 alias 命令已生成（原先被整条丢弃）
(define required-alias-commands
  '("vkGetPhysicalDeviceFeatures2KHR"
    "vkGetPhysicalDeviceFormatProperties2KHR"
    "vkGetPhysicalDeviceImageFormatProperties2KHR"
    "vkGetPhysicalDeviceMemoryProperties2KHR"
    "vkGetPhysicalDeviceProperties2KHR"
    "vkGetPhysicalDeviceQueueFamilyProperties2KHR"
    "vkGetPhysicalDeviceSparseImageFormatProperties2KHR"))

(define (check-alias-commands)
  (define cmds (generated-lines "commands.rkt"))
  (for ([c (in-list required-alias-commands)])
    (check-true
     (for/or ([l (in-list cmds)])
       (string-contains? l (format "(define-vk ~a " c)))
     (format "alias command generated: ~a" c))))

;; 4. 运行时：alias ctype 与目标同一对象，alias 命令是 arity 正确的 procedure
(define (check-runtime-aliases)
  (check-true (eq? _VkPhysicalDeviceFeatures2KHR _VkPhysicalDeviceFeatures2)
              "KHR features struct is a ctype alias of the core one")
  (check-true (eq? _VkPhysicalDeviceProperties2KHR _VkPhysicalDeviceProperties2))
  (check-true (eq? _VkPhysicalDeviceVariablePointerFeatures
                   _VkPhysicalDeviceVariablePointersFeatures))
  (check-true (procedure? vkGetPhysicalDeviceProperties2KHR))
  (check-equal? (procedure-arity vkGetPhysicalDeviceProperties2KHR) 2))

(run-generator!)
(check-no-placeholder-types)
(check-alias-type-order)
(check-alias-commands)
(check-runtime-aliases)

;; 生成器清理重命名后的残留（如 api.rkt），但不碰未知文件
(call-with-output-file (build-path out "api.rkt") #:exists 'replace (λ (o) (display "stale" o)))
(run-generator!)
(check-false (file-exists? (build-path out "api.rkt")) "stale api.rkt must be pruned")

(delete-directory/files out)
(printf "generate-aliases: all checks passed\n")
