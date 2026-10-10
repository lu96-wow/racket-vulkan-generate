#lang racket/base
;; ============================================================
;; G1 防回归：bitfield 打包 + 多维数组（覆盖**全部**位域结构体）
;;
;;   * C 位域无法用 define-cstruct 表达 → 一个存储单元打成一个底层整型字段
;;     （_bits0/_bits1…），另生成访问器；reserved 不生成
;;   * 多维数组保留全部维度（float matrix[3][4] -> (_array _float 3 4)）
;;
;; 从 registry 提取所有位域结构体，用 3 个提供它们的扩展重跑生成器；对每个
;; 结构体：Racket 与 gcc 都清零后把每个具名位域置为全 1，再 dump 整段字节，
;; 逐字节比对（等价于验证位域的 offset/宽度/单元划分与 C 编译器一致）。
;; ============================================================

(require rackunit
         racket/system
         racket/file
         racket/string
         racket/path
         racket/port
         racket/list
         racket/runtime-path
         vulkan-gen/vk-registry
         vulkan-gen/ctype
         vulkan-gen/extension-select
         vulkan-gen/template)

(define-runtime-path here ".")
(define-runtime-path probe-template "templates/bitfield-probe.rkt.tmpl")
(define-runtime-path check-template "templates/bitfield-check.c.tmpl")
(define project-root (simplify-path (build-path here "..")))
(define gen (build-path project-root "vulkan-gen" "main.rkt"))
(define reg-path (build-path project-root "registry" "vk-1.4.363.xml"))
(define out (make-temporary-file "vkbf-~a" 'directory))
(define audit (make-temporary-file "vkbf-audit-~a" 'directory))

;; ---- 1. 从 registry 提取所有位域结构体及其提供扩展 ----
(define reg (load-registry reg-path))
(define by-struct (make-hash))
(for ([e (in-list (resolve-extensions reg "all"))])
  (define-values (_cmds tys _ens) (collect-extension-requires reg (list e)))
  (for ([t (in-list tys)])
    (define ty (hash-ref (registry-types-hash reg) (string->symbol t) #f))
    (when ty
      (define bfs (for/list ([m (members-of ty)]
                             #:when (and (member-name m) (bitfield-member? m)))
                    (cons (member-name m) (bitfield-width m))))
      (when (and (pair? bfs) (not (hash-has-key? by-struct t)))
        (hash-set! by-struct t (list e bfs))))))
(define cases
  (sort (for/list ([k (in-list (hash-keys by-struct))]) (cons k (hash-ref by-struct k)))
        string<? #:key car))
(define exts (remove-duplicates (for/list ([c (in-list cases)]) (cadr c))))
(check-true (>= (length cases) 7) "registry still has the expected bitfield structs")

(define (non-reserved fields) (filter (λ (f) (not (equal? (car f) "reserved"))) fields))

;; ---- 2. 生成（带上提供位域结构体的扩展）----
(define racket-exe (find-executable-path "racket"))
(define (run-capture prog . args)
  (define o (open-output-string))
  (define code (parameterize ([current-output-port o]) (apply system*/exit-code prog args)))
  (values code (get-output-string o)))

(check-equal?
 (parameterize ([current-error-port (open-output-nowhere)])
   (system*/exit-code racket-exe (path->string gen) (path->string reg-path)
                      (path->string out) "VK_VERSION_1_4" (string-join exts ",")
                      (path->string audit)))
 0 "generator should exit 0")

(define types (file->lines (build-path out "types.rkt")))
(define (has? s) (for/or ([l (in-list types)]) (string-contains? l s)))

;; ---- 3. types.rkt 结构自检 ----
;; 多维数组保留全部维度
(check-true (has? "(define-cstruct _VkTransformMatrixKHR ((matrix (_array _float 3 4)")
            "multi-dim array must keep all dimensions")
;; 每个位域结构体：有 define-cstruct + _bits；具名位域有 getter/setter；reserved 无
(for ([c (in-list cases)])
  (define s (car c))
  (define fields (caddr c))
  (check-true (has? (format "(define-cstruct _~a " s)) (format "struct generated: ~a" s))
  (check-true (has? "_bits") (format "bitfield storage present for ~a" s))
  (for ([f (in-list (non-reserved fields))])
    (check-true (has? (format "(define (~a-~a " s (car f))) (format "getter: ~a-~a" s (car f)))
    (check-true (has? (format "(define (set-~a-~a! " s (car f))) (format "setter: ~a-~a" s (car f))))
  (for ([f (in-list fields)] #:when (equal? (car f) "reserved"))
    (check-false (has? (format "~a-reserved" s)) (format "reserved has no accessor: ~a" s))))
;; 具体打包 spot check（_bits0/_bits1 各一个 32 位单元）
(check-true
 (has? (string-append
        "(define-cstruct _VkAccelerationStructureInstanceKHR "
        "((transform _VkTransformMatrixKHR) (_bits0 _uint32) (_bits1 _uint32) "
        "(accelerationStructureReference _uint64))"))
 "expected storage-unit packing for VkAccelerationStructureInstanceKHR")

;; ---- 4. 生成 Racket 探针 + C 对照（模板占位 @@CASES@@）----
(define (racket-case i s fields)
  (string-append
   (format "(define (bf-probe-~a)\n" i)
   (format "  (define mem (malloc 'atomic-interior (ctype-sizeof _~a)))\n" s)
   (format "  (memset mem 0 (ctype-sizeof _~a))\n" s)
   (format "  (define p (ptr-ref mem _~a))\n" s)
   (apply string-append
          (for/list ([f (in-list (non-reserved fields))])
            (format "  (set-~a-~a! p ~a)\n" s (car f)
                    (sub1 (arithmetic-shift 1 (cdr f))))))
   (format "  (bf-dump ~s (ctype-sizeof _~a) (ctype-alignof _~a) mem))\n" s s s)
   (format "(bf-probe-~a)\n" i)))

(define (c-case s fields)
  (string-append
   "  {\n"
   (format "    ~a s; memset(&s, 0, sizeof s);\n" s)
   (apply string-append
          (for/list ([f (in-list (non-reserved fields))])
            (format "    s.~a = ((1u << ~a) - 1);\n" (car f) (cdr f))))
   (format "    printf(~s, sizeof s, _Alignof(~a));\n" (string-append s " %zu %zu ") s)
   "    { unsigned char *b = (unsigned char *)&s; for (size_t i = 0; i < sizeof s; i++) printf(\"%02x\", b[i]); }\n"
   "    printf(\"\\n\");\n"
   "  }\n"))

(define probe (build-path out "probe.rkt"))
(call-with-output-file probe #:exists 'replace
  (λ (o)
    (display (fill-template (file->string probe-template)
                            (list (cons "CASES"
                                        (apply string-append
                                               (for/list ([c (in-list cases)] [i (in-naturals)])
                                                 (racket-case i (car c) (caddr c)))))))
             o)))
(define-values (pcode pout) (run-capture racket-exe (path->string probe)))
(check-equal? pcode 0 (format "probe should run: ~a" pout))

(define (parse-out text)
  (for/hash ([l (in-list (string-split text "\n"))] #:unless (string=? l ""))
    (define p (string-split l))
    (values (car p) (cdr p))))
(define rk (parse-out pout))
(check-true (>= (hash-count rk) (length cases)) "probe emitted all bitfield structs")

;; ---- 5. gcc 对照（有 gcc + vulkan 头文件时）：整段字节 dump 必须一致 ----
(define gcc (find-executable-path "gcc"))
(define vulkan-h "/usr/include/vulkan/vulkan.h")
(if (and gcc (file-exists? vulkan-h))
    (let* ([c (build-path out "bf.c")]
           [exe (build-path out "bf")])
      (call-with-output-file c #:exists 'replace
        (λ (o)
          (display (fill-template (file->string check-template)
                                  (list (cons "CASES"
                                              (apply string-append
                                                     (for/list ([cc (in-list cases)])
                                                       (c-case (car cc) (caddr cc)))))))
                   o)))
      (define gcc-err (open-output-string))
      (check-equal? (parameterize ([current-error-port gcc-err])
                      (system*/exit-code gcc "-O0" (path->string c) "-o" (path->string exe)))
                    0 (format "gcc compiles bitfield check: ~a" (get-output-string gcc-err)))
      (define-values (ccode cout) (run-capture (path->string exe)))
      (check-equal? ccode 0)
      (define ck (parse-out cout))
      (for ([cc (in-list cases)])
        (define s (car cc))
        (check-true (hash-has-key? ck s) (format "C output present: ~a" s))
        (check-equal? (hash-ref rk s #f) (hash-ref ck s #f)
                      (format "bitfield layout matches gcc: ~a" s))))
    (printf "bitfield: skipped gcc comparison (need gcc + /usr/include/vulkan/vulkan.h)\n"))

(delete-directory/files out)
(printf "bitfield: all checks passed (~a structs)\n" (length cases))
