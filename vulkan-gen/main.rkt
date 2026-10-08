#lang racket/base
;; ============================================================
;; 生成器主体：vk.xml -> vulkan/generated/*（+ vulkan-gen/audit/*）。
;;
;; 库入口：`(require vulkan-gen/main)` 后调用 `generate!`（require 无副作用）。
;; CLI 入口：`racket vulkan-gen/main.rkt [vk.xml] [out] [feature] [ext] [audit]`。
;;
;; 流水线：
;;   vk-registry     读 XML + feature/extension 闭包
;;   extension-select 扩展选择（common / all / 逗号列表）
;;   constants       常量值解析与排序
;;   ctype           C 类型映射 + 成员解析
;;   facts-build     XML -> vk-command / vk-param（运行期 IR）
;;   emit-types      types.inc
;;   emit-commands   commands.inc
;;   emit-api        generated/facts.rkt 数据
;;   emit-pnext      pnext.inc
;;   emit-safe       safe.inc（classify -> per-shape emit）
;; ============================================================

(require racket/list
         racket/string
         racket/path
         racket/file
         racket/runtime-path
         "vk-registry.rkt"
         "ctype.rkt"
         "extension-select.rkt"
         "constants.rkt"
         "facts-build.rkt"
         "emit-types.rkt"
         "emit-commands.rkt"
         "emit-api.rkt"
         "emit-pnext.rkt"
         "emit-safe.rkt")

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

  ;; ----------------------------------------------------------------
  ;; 1. 注册表 + 依赖闭包
  (define reg (load-registry in-file))
  ;; 未知类型收集器由 driver 持有（ctype 层无全局）。
  (define unknown-set (make-hash))
  (current-unknown-type (λ (n) (hash-set! unknown-set n #t)))
  (define closure (feature-closure reg target-feature))
  (define requested-extensions (resolve-extensions reg target-extensions))
  (define ext-closure (extension-closure reg requested-extensions))
  (define-values (feat-cmds feat-types) (collect-requires reg closure))
  (define-values (ext-cmds ext-types ext-enums) (collect-extension-requires reg ext-closure))
  (define wanted-cmds (append feat-cmds ext-cmds))
  (define wanted-types (append feat-types ext-types))
  (eprintf "extensions requested=~a included=~a\n" (length requested-extensions) (length ext-closure))
  (eprintf "feature closure: ~a\n" closure)
  (eprintf "wanted commands=~a types=~a\n" (length wanted-cmds) (length wanted-types))

  ;; ----------------------------------------------------------------
  ;; 2. wanted 类型闭包 + 拓扑排序
  (define (sym<? a b) (string<? (symbol->string a) (symbol->string b)))
  (define (topo-sort nodes deps-fn)
    (define node-set (make-hasheqv))
    (for ([n nodes]) (hash-set! node-set n #t))
    (define indeg (make-hasheqv))
    (define adj (make-hasheqv))
    (for ([n nodes]) (hash-set! indeg n 0) (hash-set! adj n '()))
    (for ([n nodes])
      (for ([d (deps-fn n)])
        (when (and (hash-ref node-set d #f) (not (eq? d n)))
          (hash-set! indeg n (add1 (hash-ref indeg n 0)))
          (hash-set! adj d (cons n (hash-ref adj d '()))))))
    (let loop ([q (filter (λ (n) (zero? (hash-ref indeg n))) nodes)] [out '()])
      (cond [(null? q) (append (reverse out) (filter (λ (n) (not (member n out))) nodes))]
            [else
             (define n (car q))
             (define newq (cdr q))
             (define nq (for/fold ([qq newq]) ([m (hash-ref adj n)])
                          (hash-set! indeg m (sub1 (hash-ref indeg m)))
                          (if (zero? (hash-ref indeg m)) (append qq (list m)) qq)))
             (loop nq (cons n out))])))

  (define (type-known? t) (hash-has-key? (registry-types-hash reg) (string->symbol t)))
  (define wanted (make-hasheqv))
  (for ([t wanted-types]) (when t (hash-set! wanted (string->symbol t) #t)))
  (for ([c wanted-cmds])
    (define cmd (hash-ref (registry-commands-hash reg) (string->symbol c) #f))
    (when cmd
      (for ([t (command-type-names reg cmd)])
        (when (type-known? t) (hash-set! wanted (string->symbol t) #t)))))
  (let loop ()
    (define before (hash-count wanted))
    (for ([nm (hash-keys wanted)])
      (for ([dep (type-dependencies reg nm)])
        (when (hash-has-key? (registry-types-hash reg) dep) (hash-set! wanted dep #t))))
    (when (> (hash-count wanted) before) (loop)))
  (define wanted-list (sort (filter (λ (n) (hash-has-key? (registry-types-hash reg) n)) (hash-keys wanted)) sym<?))
  (define sorted-types (topo-sort wanted-list (λ (nm) (type-dependencies reg nm))))

  ;; ----------------------------------------------------------------
  ;; 3. 产出各层形式
  (define constants (ordered-constants reg closure ext-enums))
  (define type-form-list (type-forms reg sorted-types))
  (define command-form-list (command-forms reg wanted-cmds))
  (define api-command-list (api-commands reg wanted-cmds))
  (define safe-form-list (filter values (emit-safe-forms api-command-list)))
  (define pnext-form-list (pnext-forms reg sorted-types))

  ;; ----------------------------------------------------------------
  ;; 4. 写文件
  (define (out-file name) (build-path out-root name))
  (define (audit-file name) (build-path audit-root name))
  (define (emit forms path)
    (call-with-output-file path #:exists 'replace
      (λ (o) (for ([f forms]) (write f o) (newline o)))))

  (emit constants (out-file "constants.inc"))
  (emit type-form-list (out-file "types.inc"))
  (emit command-form-list (out-file "commands.inc"))
  (emit safe-form-list (out-file "safe.inc"))
  (emit pnext-form-list (out-file "pnext.inc"))

  ;; generated/facts.rkt（IR 数据；结构体定义在 vulkan/api-facts.rkt）
  (write-facts-module api-command-list (out-file "facts.rkt"))

  ;; ABI 对照 C 程序（仅 core struct/union；本机头文件版本可能较 registry 旧，
  ;; 但 core 类型在 1.4.x 内稳定）
  (define (emit-abi-c path)
    (define names
      (for/list ([nm (in-list wanted-list)]
                 #:when (and (member (symbol->string nm) feat-types)
                             (memq (category-of reg nm) '(struct union))))
        nm))
    (call-with-output-file path #:exists 'replace
      (λ (o)
        (display "#include <vulkan/vulkan.h>\n" o)
        (display "#include <stddef.h>\n" o)
        (display "#include <stdio.h>\n" o)
        (display "#define SZ(T) printf(\"S \" #T \" %zu %zu\\n\", sizeof(T), _Alignof(T))\n" o)
        (display "int main(void){\n" o)
        (for ([nm (in-list names)])
          (fprintf o "  SZ(~a);\n" nm))
        (display "  return 0;\n}\n" o)))
    (length names))

  (define abi-count (emit-abi-c (audit-file "abi_check.c")))

  ;; 未知类型审计：任何退化成 _pointer 的类型都写进报告；strict 模式下报错
  (define unknowns (sort (hash-keys unknown-set) string<?))
  (call-with-output-file (audit-file "unknown-types.txt") #:exists 'replace
    (λ (o) (for ([n (in-list unknowns)]) (displayln n o))))
  (cond
    [(null? unknowns) (eprintf "unknown types: 0\n")]
    [else
     (eprintf "unknown types (~a -> _pointer): ~a\n" (length unknowns) unknowns)
     (when (getenv "VULKAN_GEN_STRICT")
       (error 'generate "unknown types encountered (VULKAN_GEN_STRICT=1)"))])

  (eprintf "generated: constants=~a types=~a commands=~a safe=~a api=~a pnext=~a abi=~a -> ~a\n"
           (length constants) (length type-form-list) (length command-form-list)
           (length safe-form-list) (length api-command-list) (length pnext-form-list) abi-count out-root))

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
