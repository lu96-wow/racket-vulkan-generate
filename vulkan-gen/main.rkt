#lang racket/base
;; ============================================================
;; 生成器 driver（薄）：解析 -> 生成 -> 输出。
;;
;;   解析（parse.rkt）   vk.xml + feature/扩展 -> vk-model（领域模型）
;;   生成（generate.rkt）vk-model -> vk-artifact（模块：依赖/模块体/导出）
;;   输出（本文件）      写文件 + ABI 审计 + 未知类型审计 + 清理陈旧产物
;;
;; 库入口：`(require vulkan-gen/main)` 后调用 `generate!`（require 无副作用）。
;; CLI 入口：`racket vulkan-gen/main.rkt [vk.xml] [out] [feature] [ext] [audit]`。
;; ============================================================

(require racket/list
         racket/string
         racket/path
         racket/file
         racket/runtime-path
         "vk-registry.rkt"
         "ctype.rkt"
         "parse.rkt"
         "generate.rkt"
         "module.rkt")

(provide generate!)

;; 默认即仓库提交的绑定配方（no-arg 可复现 generated/）：
;;   registry/vk-1.4.363.xml -> vulkan/generated  VK_VERSION_1_4  common
;; 审计产物（abi_check.c / unknown-types.txt）单独落在 vulkan-gen/audit/。
;; 显式覆盖仍可：feature/extensions 传 #f = 用默认；extensions "" = 只要 core。
(define-runtime-path gen-dir ".")
(define repo-dir (build-path gen-dir ".."))
(define default-xml (build-path repo-dir "registry" "vk-1.4.363.xml"))
(define default-out (build-path repo-dir "vulkan" "generated"))
(define default-audit (build-path gen-dir "audit"))
(define default-feature "VK_VERSION_1_4")
(define default-extensions "common")

(define (generate! #:in-xml [in-xml #f]
                   #:out-dir [out-dir #f]
                   #:audit-dir [audit-dir #f]
                   #:feature [feature #f]
                   #:extensions [extensions #f])
  (define in-file (or in-xml default-xml))
  (define out-root (or out-dir default-out))
  (define audit-root (or audit-dir default-audit))
  (define target-feature (or feature default-feature))
  (define target-extensions (or extensions default-extensions))
  (make-directory* out-root)
  (make-directory* audit-root)
  (eprintf "generate: feature=~a extensions=~a out=~a audit=~a\n"
           target-feature target-extensions out-root audit-root)

  ;; ---- 解析 + 生成（未知类型回调在整个过程生效）----
  (define unknown-set (make-hash))
  (define-values (model artifacts abi-c)
    (parameterize ([current-unknown-type (λ (n) (hash-set! unknown-set n #t))])
      (define reg (load-registry in-file))
      (define m (parse-model #:registry reg
                             #:feature target-feature
                             #:extensions target-extensions))
      (values m
              (generate-artifacts m #:registry-file (path->string (file-name-from-path in-file)))
              (generate-abi-c m))))

  (eprintf "extensions requested=~a included=~a\n"
           (length (vk-model-requested-extensions model))
           (length (vk-model-ext-closure model)))
  (eprintf "feature closure: ~a\n" (vk-model-closure model))
  (eprintf "wanted commands=~a types=~a\n"
           (length (vk-model-wanted-cmds model))
           (length (vk-model-types model)))

  ;; ---- 输出：模块体/完整模块（写出方式由 artifact 的 render 决定）----
  (for ([a (in-list artifacts)])
    (write-artifact a (build-path out-root (vk-artifact-name a))))

  (define (artifact-size name)
    (for/first ([a (in-list artifacts)] #:when (string=? (vk-artifact-name a) name))
      (length (vk-module-body (vk-artifact-module a)))))
  (define (count-abi c)
    (for/sum ([l (in-list (string-split c "\n"))] #:when (string-prefix? l "  SZ(")) 1))

  ;; ABI 对照 C 程序（仅 core struct/union；本机头文件版本可能较 registry 旧，
  ;; 但 core 类型在 1.4.x 内稳定）
  (call-with-output-file (build-path audit-root "abi_check.c") #:exists 'replace
    (λ (o) (display abi-c o)))

  ;; 未知类型审计：任何退化成 _pointer 的类型都写进报告；strict 模式下报错
  (define unknowns (sort (hash-keys unknown-set) string<?))
  (call-with-output-file (build-path audit-root "unknown-types.txt") #:exists 'replace
    (λ (o) (for ([n (in-list unknowns)]) (displayln n o))))
  (cond
    [(null? unknowns) (eprintf "unknown types: 0\n")]
    [else
     (eprintf "unknown types (~a -> _pointer): ~a\n" (length unknowns) unknowns)
     (when (getenv "VULKAN_GEN_STRICT")
       (error 'generate "unknown types encountered (VULKAN_GEN_STRICT=1)"))])

  ;; 清理：删掉本目录里「生成器曾产出、本次不再产出」的文件
  ;; （重命名/移除的残留，如 api.rkt -> facts.rkt、审计文件从 out-dir 移出）。
  ;; 只碰已知名字，绝不碰 compiled/ 或未知文件。
  (define out-files '("constants.inc" "types.inc" "commands.inc" "safe.inc"
                      "pnext.inc" "facts.rkt" "version.rkt"))
  (define audit-files '("abi_check.c" "unknown-types.txt"))
  (define (prune! dir current known)
    (for ([f (in-list (directory-list dir))])
      (define name (path->string f))
      (when (and (member name known) (not (member name current)))
        (delete-file (build-path dir f))
        (eprintf "pruned stale: ~a\n" (build-path dir f)))))
  (unless (equal? (simplify-path out-root) (simplify-path audit-root))
    (prune! out-root out-files (append out-files '("api.rkt" "abi_check.c" "unknown-types.txt")))
    (prune! audit-root audit-files audit-files))

  (eprintf "generated: constants=~a types=~a commands=~a safe=~a facts=~a pnext=~a abi=~a -> ~a\n"
           (artifact-size "constants.inc") (artifact-size "types.inc")
           (artifact-size "commands.inc") (artifact-size "safe.inc")
           (artifact-size "facts.rkt") (artifact-size "pnext.inc")
           (count-abi abi-c) out-root))

;; ------------------------------------------------------------------
;; CLI 入口（也可当库调用上面的 generate!）
(module+ main
  (define args (current-command-line-arguments))
  ;; 未给的位置参数返回 #f，由 generate! 解析为默认。
  (define (arg i) (if (> (vector-length args) i) (vector-ref args i) #f))
  (generate! #:in-xml     (arg 0)
             #:out-dir    (arg 1)
             #:feature    (arg 2)
             #:extensions (arg 3)
             #:audit-dir  (arg 4)))
