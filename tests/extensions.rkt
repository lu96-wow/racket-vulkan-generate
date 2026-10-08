#lang racket/base
;; ============================================================
;; E1/E3 防回归：扩展选择（common / all / 显式列表）+ 未知类型审计
;;
;;   * resolve-extensions: "" -> 空；common -> 常用集；all -> 所有 includable；
;;     其他 -> 逗号列表
;;   * 生成 all 时必须成功，且 unknown-types.txt 为空（所有类型都有 ctype 映射）
;;   * 代表性 acceleration/swapchain 类型与命令确实生成
;; ============================================================

(require rackunit
         racket/system
         racket/file
         racket/string
         racket/path
         racket/port
         racket/runtime-path
         vulkan-gen/vk-registry
         vulkan-gen/extension-select)

(define-runtime-path here ".")
(define project-root (simplify-path (build-path here "..")))
(define gen (build-path project-root "vulkan-gen" "main.rkt"))
(define reg (build-path project-root "registry" "vk-1.4.363.xml"))
(define racket-exe (find-executable-path "racket"))

;; 1. 参数解析
(define r (load-registry reg))
(check-equal? (resolve-extensions r "") '())
(check-equal? (resolve-extensions r "common") common-extensions)
(check-equal? (resolve-extensions r "A,B,C") '("A" "B" "C"))
(define all (resolve-extensions r "all"))
(check-true (> (length all) 400) (format "all extensions = ~a" (length all)))
(check-true (and (member "VK_KHR_acceleration_structure" all) #t))
(check-true (and (member "VK_KHR_surface" all) #t))
(define ext (resolve-extensions r "VK_KHR_surface,VK_KHR_swapchain"))
(check-equal? ext '("VK_KHR_surface" "VK_KHR_swapchain"))

;; 2. 生成 all：成功 + 无未知类型
(define out (make-temporary-file "vkext-~a" 'directory))
(define audit (make-temporary-file "vkext-audit-~a" 'directory))
(define (run-generator ext-arg)
  (parameterize ([current-error-port (open-output-nowhere)])
    (system*/exit-code racket-exe (path->string gen) (path->string reg)
                       (path->string out) "VK_VERSION_1_4" ext-arg (path->string audit))))
(check-equal? (run-generator "all") 0 "generator all should exit 0")
(check-equal? (file->string (build-path audit "unknown-types.txt")) ""
              "all extensions must have no unknown types")

(define types (file->lines (build-path out "types.inc")))
(define cmds (file->lines (build-path out "commands.inc")))
(define (has? lines s) (for/or ([l (in-list lines)]) (string-contains? l s)))

;; 3. 代表性类型/命令已生成
(check-true (has? types "define-cstruct _VkAccelerationStructureInstanceKHR"))
(check-true (has? types "(_bits0 _uint32)"))
(check-true (has? cmds "(define-vk vkCreateSwapchainKHR "))
(check-true (has? cmds "(define-vk vkCreateAccelerationStructureKHR "))

;; 3b. 常量解析：~N 位取反 + 字符串扩展名
(define consts (file->lines (build-path out "constants.inc")))
(check-true (has? consts "(define VK_QUEUE_FAMILY_EXTERNAL 4294967294)"))
(check-true (has? consts "(define VK_QUEUE_FAMILY_FOREIGN_EXT 4294967293)"))
(check-true (has? consts "VK_KHR_SURFACE_EXTENSION_NAME #\"VK_KHR_surface\""))
(check-true (has? consts "VK_EXT_DEBUG_UTILS_EXTENSION_NAME #\"VK_EXT_debug_utils\""))

;; 3c. version.rkt provenance
(check-true (file-exists? (build-path out "version.rkt")))
(define ver (file->lines (build-path out "version.rkt")))
(check-true (has? ver "(define vk-binding-version \"1.4.363\")"))
(check-true (has? ver "(define vk-generated-feature \"VK_VERSION_1_4\")"))
(check-true (has? ver "VK_KHR_surface"))

;; 4. 不允许退化占位结构体
(check-equal? (filter (λ (l) (string-contains? l "_dummy")) types) '())

(delete-directory/files out)
(printf "extensions: all checks passed\n")
