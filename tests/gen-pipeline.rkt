#lang racket/base
;; ============================================================
;; 生成流水线局部化防回归：
;;   * 解析：返回 (values model diagnostics)，可复现、无全局
;;   * 生成：只吃 vk-model；四类划分完整；types.rkt 保持拓扑序
;;   * 模块：产物是真模块（deps/body/exports）；render 校验模板占位符
;;   * 快照：默认配方重生成 == 已提交产物（逐字节）
;; ============================================================

(require rackunit
         racket/list
         racket/file
         racket/string
         racket/path
         racket/runtime-path
         vulkan/api-facts
         vulkan-gen/model
         vulkan-gen/vk-registry
         vulkan-gen/parse
         vulkan-gen/generate
         vulkan-gen/module
         vulkan-gen/template
         vulkan-gen/main)

(define-runtime-path here ".")
(define root (simplify-path (build-path here "..")))
(define reg (build-path root "registry" "vk-1.4.363.xml"))
(define committed-out (build-path root "vulkan" "generated"))
(define committed-audit (build-path root "vulkan-gen" "audit"))

;; ---------------- 1. 模板占位符校验 ----------------
(check-exn exn:fail?
           (λ () (fill-template "a @@MISSING@@ b" (list (cons "OTHER" "x"))))
           "unsubstituted placeholder must error")
(check-equal? (fill-template "@@X@@" (list (cons "X" "ok"))) "ok")

;; ---------------- 2. 解析：自足、可复现、有诊断 ----------------
(define-values (m1 d1) (parse-model #:registry (load-registry reg)
                                    #:feature "VK_VERSION_1_4" #:extensions "common"))
(define-values (m2 d2) (parse-model #:registry (load-registry reg)
                                    #:feature "VK_VERSION_1_4" #:extensions "common"))
(check-equal? (map vk-type-name (vk-model-types m1))
              (map vk-type-name (vk-model-types m2))
              "type order is deterministic")
(check-equal? (vk-model-constants m1) (vk-model-constants m2)
              "constants are deterministic")
(check-equal? (map vk-command-name (vk-model-commands m1))
              (map vk-command-name (vk-model-commands m2))
              "commands are deterministic")
(check-equal? (length d1) (length d2) "diagnostics are deterministic")
(check-true (list? d1) "parse returns a diagnostics list")
(check-true (> (length (vk-model-types m1)) 0))

;; 真降级（warn/type）应为空；跳过的宏只能是 info
(check-equal? (for/list ([d (in-list d1)]
                         #:when (and (eq? (vk-diagnostic-domain d) 'type)
                                     (eq? (vk-diagnostic-level d) 'warn)))
                (vk-diagnostic-entity d))
              '()
              "common recipe must not degrade any type to _pointer")

;; ---------------- 3. 生成：四类划分完整 + 拓扑序 ----------------
(define types (vk-model-types m1))
(define enum-ts (generate-enums m1))
(define struct-ts (generate-structs m1))
(define other-ts (generate-other-types m1))
(define (name<? a b) (string<? (symbol->string a) (symbol->string b)))
(check-equal? (sort (append (map vk-type-name enum-ts)
                            (map vk-type-name struct-ts)
                            (map vk-type-name other-ts))
                    name<?)
              (sort (map vk-type-name types) name<?)
              "enum/struct/other partition the model types exactly")
(check-equal? (length (generate-types m1)) (length types)
              "types.rkt emits one form per type (common has no bitfields)")

;; types 顺序 = 依赖序：任何 alias 的目标必须出现在 alias 之前
(define idx (for/hasheqv ([t (in-list types)] [i (in-naturals)])
              (values (vk-type-name t) i)))
(for ([t (in-list types)] [i (in-naturals)])
  (when (vk-type-alias t)
    (check-true (and (hash-ref idx (vk-type-alias t) #f)
                     (< (hash-ref idx (vk-type-alias t)) i))
                (format "alias target before use: ~a" (vk-type-name t)))))

;; ---------------- 4. 模块：真模块（deps/exports）+ 只出本模块定义 ----------------
(define arts (generate-artifacts m1 #:registry-file "vk-1.4.363.xml"))
(define (artifact name) (for/first ([a (in-list arts)] #:when (string=? (vk-artifact-name a) name)) a))
(check-true (and (member 'ffi/unsafe/define (vk-module-deps (vk-artifact-module (artifact "types.rkt")))) #t))
(check-true (and (member "constants.rkt" (vk-module-deps (vk-artifact-module (artifact "types.rkt")))) #t))
(check-true (and (member 'vulkan/base (vk-module-deps (vk-artifact-module (artifact "commands.rkt")))) #t))
(check-true (pair? (vk-module-deps (vk-artifact-module (artifact "safe.rkt")))))
(check-equal? (vk-module-exports (vk-artifact-module (artifact "types.rkt"))) '((all-defined-out)))
(define types-str (artifact->string (artifact "types.rkt")))
(check-true (string-prefix? types-str "#lang racket/base") "generated file is a real module")
(check-true (string-contains? types-str "(provide (all-defined-out))"))
(check-true (string-contains? types-str "(define-cstruct _VkBufferCreateInfo"))
;; 模块化后不再有 include
(check-false (string-contains? types-str "(include "))

;; ---------------- 5. 快照：默认配方 == 已提交产物 ----------------
(define out (make-temporary-file "vkpipe-~a" 'directory))
(define audit (make-temporary-file "vkpipe-audit-~a" 'directory))
(generate! #:in-xml reg #:out-dir out #:audit-dir audit)
(for ([f '("constants.rkt" "types.rkt" "commands.rkt" "safe.rkt" "pnext.rkt" "facts.rkt" "version.rkt")])
  (check-equal? (file->bytes (build-path out f))
                (file->bytes (build-path committed-out f))
                (format "snapshot matches committed: ~a" f)))
(check-equal? (file->bytes (build-path audit "abi_check.c"))
              (file->bytes (build-path committed-audit "abi_check.c"))
              "snapshot matches committed abi_check.c")
(check-equal? (file->bytes (build-path audit "unknown-types.txt"))
              (file->bytes (build-path committed-audit "unknown-types.txt"))
              "snapshot matches committed unknown-types.txt")
(delete-directory/files out)
(delete-directory/files audit)

(printf "gen-pipeline: all checks passed\n")
