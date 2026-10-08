#lang racket/base
;; ============================================================
;; racket-vulkan 构建脚本（Racket 版）。
;;
;;   racket rebuild.rkt [vk.xml]
;;
;; 只需指定注册表 XML 路径（省略则用 vulkan/registry/vk-1.4.363.xml）。
;; feature / 扩展 / 输出目录用 generator/main.rkt 的默认配方：
;;   VK_VERSION_1_4 + common -> vulkan/generated（= 仓库提交的绑定）。
;
;; 流程：生成 vulkan/generated/* → 清旧编译产物 → raco make。
;; 想用别的 feature/扩展组合，直接用 vulkan/generate.rkt 带全部参数。
;; ============================================================

(require racket/file
         racket/path
         racket/system
         racket/runtime-path
         "vulkan/generator/main.rkt")

(provide rebuild!)

(define-runtime-path here-raw ".")
(define here (simplify-path here-raw))
(define default-xml (build-path here "vulkan" "registry" "vk-1.4.363.xml"))
(define out-dir (build-path here "vulkan" "generated"))

(define (rebuild! [xml-path #f])
  (define xml (if xml-path
                  (path->complete-path xml-path (current-directory))
                  default-xml))
  ;; 1. 生成（feature/扩展走默认配方）
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

(module+ main
  (define args (current-command-line-arguments))
  (rebuild! (if (>= (vector-length args) 1) (vector-ref args 0) #f)))
