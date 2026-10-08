#lang racket/base
;; ============================================================
;; racket-vulkan 构建脚本。
;;
;;   racket rebuild.rkt [vk.xml]
;;
;; 省略 xml 用默认配方（= 仓库提交的绑定）：
;;   registry/vk-1.4.363.xml -> vulkan/generated  VK_VERSION_1_4  common
;; registry 文件缺失时按默认版本自动拉取（fetch-registry.rkt），
;; 所以全新 clone 直接 `racket rebuild.rkt` 即可。
;;
;; 流程：生成 -> 清旧 .zo -> raco make。想换版本/扩展组合：
;;   racket fetch-registry.rkt <version>     # 先取资源
;;   racket vulkan-gen/main.rkt <xml> <out> <feature> <ext>
;; ============================================================

(require racket/file
         racket/path
         racket/system
         racket/runtime-path
         "fetch-registry.rkt")

(define-runtime-path here-raw ".")
(define here (simplify-path here-raw))
;; 包版本（info.rkt）= 默认注册表版本，单一来源。
(define (package-version)
  (define m (regexp-match #px"\\(define version \"([^\"]+)\""
                          (file->string (build-path here "info.rkt"))))
  (and m (cadr m)))
(define default-version (or (package-version) "1.4.363"))
(define default-xml (build-path here "registry" (string-append "vk-" default-version ".xml")))
(define out-dir (build-path here "vulkan" "generated"))

(module+ main
  ;; 让 vulkan-gen / vulkan 集合在未安装时也能从仓库根解析。
  (define generate!
    (parameterize ([current-library-collection-paths
                    (cons here (current-library-collection-paths))])
      (dynamic-require 'vulkan-gen/main 'generate!)))
  (define args (current-command-line-arguments))
  (define xml (if (>= (vector-length args) 1)
                  (path->complete-path (vector-ref args 0) (current-directory))
                  default-xml))

  ;; 0. 资源缺失则按默认版本拉取
  (cond
    [(file-exists? xml) (void)]
    [(equal? xml default-xml)
     (eprintf "registry 缺失，按默认版本拉取 ~a ...\n" default-version)
     (fetch-registry! default-version #:out (build-path here "registry"))]
    [else (error 'rebuild "找不到 registry：~a" xml)])

  ;; 1. 生成（feature/扩展/audit 走默认）
  (generate! #:in-xml xml #:out-dir out-dir)

  ;; 2. 清掉旧 .zo（include 的 .inc 变更未必触发重编译）
  (for ([d (in-list (list (build-path here "vulkan" "compiled")
                          (build-path here "tests" "compiled")))])
    (when (directory-exists? d) (delete-directory/files d)))

  ;; 3. 重建关键模块
  (define raco (find-executable-path "raco"))
  (unless raco (error 'rebuild "找不到 raco（不在 PATH 上）"))
  (parameterize ([current-directory here])
    (unless (system* raco "make" "vulkan/main.rkt" "vulkan/glfw.rkt")
      (error 'rebuild "raco make 失败")))
  (printf "rebuild: generated + recompiled (~a)\n" xml))
