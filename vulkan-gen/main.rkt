#lang racket/base
;; ============================================================
;; 生成器 driver（薄）：解析 -> 生成 -> 输出。
;;
;;   解析（parse.rkt）   vk.xml + feature/扩展 -> vk-model + 诊断
;;   生成（generate.rkt）vk-model -> vk-artifact（模块：依赖/模块体/导出）+ 诊断
;;   输出（本文件）      渲染全部 -> 原子落盘 + ABI/诊断审计 + 清理陈旧产物
;;
;; 容错：解析/生成的降级与丢弃全部进诊断（不静默）；渲染失败不落盘（先渲染后写）。
;; 库入口：`(require vulkan-gen/main)` 后调用 `generate!`（require 无副作用）。
;; CLI 入口：`racket vulkan-gen/main.rkt [vk.xml] [out] [feature] [ext] [audit]`。
;; ============================================================

(require racket/list
         racket/string
         racket/path
         racket/file
         racket/runtime-path
         "vk-registry.rkt"
         "parse.rkt"
         "generate.rkt"
         "model.rkt"
         "module.rkt")

(provide generate!)

;; 默认即仓库提交的绑定配方（no-arg 可复现 generated/）：
;;   registry/vk-1.4.363.xml -> vulkan/generated  VK_VERSION_1_4  common
;; 审计产物（abi_check.c / unknown-types.txt / diagnostics.txt）落在 vulkan-gen/audit/。
;; 显式覆盖仍可：feature/extensions 传 #f = 用默认；extensions "" = 只要 core。
(define-runtime-path gen-dir ".")
(define repo-dir (build-path gen-dir ".."))
(define default-xml (build-path repo-dir "registry" "vk-1.4.363.xml"))
(define default-out (build-path repo-dir "vulkan" "generated"))
(define default-audit (build-path gen-dir "audit"))
(define default-feature "VK_VERSION_1_4")
(define default-extensions "common")

;; 审计文件名（prune 白名单）
(define audit-filenames '("abi_check.c" "unknown-types.txt" "diagnostics.txt"))
;; 生成器曾产出、现已改名/移出的残留（只碰这些已知名字）
;; 含 .inc 时代产物与审计文件曾落在 out-dir 的旧名字。
(define stale-out-names '("constants.inc" "types.inc" "commands.inc" "safe.inc" "pnext.inc"
                          "api.rkt" "abi_check.c" "unknown-types.txt" "diagnostics.txt"))

(define (diagnostic->string d)
  (format "~a\t~a\t~a\t~a"
          (vk-diagnostic-level d)
          (vk-diagnostic-domain d)
          (vk-diagnostic-entity d)
          (vk-diagnostic-reason d)))

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

  ;; ---- 解析 + 生成（各自返回/收集诊断，无全局参数）----
  (define reg (load-registry in-file))
  (define-values (model parse-diags)
    (parse-model #:registry reg #:feature target-feature #:extensions target-extensions))
  (define gen-diags (make-diagnostics))
  (define artifacts
    (generate-artifacts model #:registry-file (path->string (file-name-from-path in-file))
                        #:diags gen-diags))
  (define abi-c (generate-abi-c model))
  (define all-diags (append parse-diags (diagnostics-list gen-diags)))

  (eprintf "extensions requested=~a included=~a\n"
           (length (vk-model-requested-extensions model))
           (length (vk-model-ext-closure model)))
  (eprintf "feature closure: ~a\n" (vk-model-closure model))
  (eprintf "wanted commands=~a types=~a\n"
           (length (vk-model-wanted-cmds model))
           (length (vk-model-types model)))

  ;; ---- 输出：先全部渲染成字符串，任何失败都不会留下半套产物 ----
  (define rendered (for/list ([a (in-list artifacts)])
                     (cons (vk-artifact-name a) (artifact->string a))))
  (for ([p (in-list rendered)])
    (write-file/atomic (build-path out-root (car p)) (cdr p)))
  (write-file/atomic (build-path audit-root "abi_check.c") abi-c)

  ;; unknown-types.txt = 真正降级为 _pointer 的类型（warn/type）；
  ;; 跳过的宏/非绑定类型是 info，只进 diagnostics.txt。
  ;; 只收“真正降级为 _pointer”的 type warn（sType/bitmask 等可疑项不进此文件）
  (define unknowns (sort (remove-duplicates
                          (for/list ([d (in-list all-diags)]
                                     #:when (and (eq? (vk-diagnostic-domain d) 'type)
                                                 (eq? (vk-diagnostic-level d) 'warn)
                                                 (string-contains? (vk-diagnostic-reason d) "_pointer")))
                            (format "~a" (vk-diagnostic-entity d))))
                         string<?))
  (write-file/atomic (build-path audit-root "unknown-types.txt")
                     (apply string-append (for/list ([n (in-list unknowns)]) (format "~a\n" n))))
  (write-file/atomic (build-path audit-root "diagnostics.txt")
                     (apply string-append
                            (for/list ([d (in-list all-diags)]) (format "~a\n" (diagnostic->string d)))))
  (if (null? unknowns)
      (eprintf "unknown types: 0\n")
      (eprintf "unknown types (~a -> _pointer): ~a\n" (length unknowns) unknowns))
  (when (and (getenv "VULKAN_GEN_STRICT") (not (null? unknowns)))
    (error 'generate "unknown types encountered (VULKAN_GEN_STRICT=1)"))

  ;; ---- 清理：只碰已知陈旧名字（当前产物不删）----
  (define out-files (map vk-artifact-name artifacts))
  (define (prune! dir known current)
    (for ([f (in-list (directory-list dir))])
      (define name (path->string f))
      (when (and (member name known) (not (member name current)))
        (delete-file (build-path dir f))
        (eprintf "pruned stale: ~a\n" (build-path dir f)))))
  (unless (equal? (simplify-path out-root) (simplify-path audit-root))
    (prune! out-root (append out-files stale-out-names) out-files)
    (prune! audit-root audit-filenames audit-filenames))

  (define (count-abi c)
    (for/sum ([l (in-list (string-split c "\n"))] #:when (string-prefix? l "  SZ(")) 1))
  (define (body-len name)
    (define a (for/first ([a (in-list artifacts)] #:when (string=? (vk-artifact-name a) name)) a))
    (length (vk-module-body (vk-artifact-module a))))
  (eprintf "generated: constants=~a types=~a commands=~a safe=~a facts=~a pnext=~a abi=~a diags=~a -> ~a\n"
           (length (vk-model-constants model))
           (length (vk-model-types model))
           (length (vk-model-functions model))
           (body-len "safe.rkt")
           (body-len "facts.rkt")
           (body-len "pnext.rkt")
           (count-abi abi-c) (length all-diags) out-root))

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
