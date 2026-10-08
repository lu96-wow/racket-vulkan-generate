#lang racket/base
;; ============================================================
;; racket-vulkan 构建脚本。
;;
;;   racket rebuild.rkt [vk.xml]
;;
;; 只需指定注册表 XML 路径（省略则用 registry/vk-1.4.363.xml）。
;; feature / 扩展 / 输出目录用 vulkan-gen/main 的默认配方：
;;   VK_VERSION_1_4 + common -> vulkan/generated（= 仓库提交的绑定）；
;;   审计产物 -> vulkan-gen/audit。
;;
;; 流程：生成 -> 清旧 .zo -> raco make。想换 feature/扩展组合用
;; `racket vulkan-gen/main.rkt` 带全部参数。
;; ============================================================

(require racket/file
         racket/path
         racket/system
         racket/runtime-path)

(define-runtime-path here-raw ".")
(define here (simplify-path here-raw))
(define default-xml (build-path here "registry" "vk-1.4.363.xml"))
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
