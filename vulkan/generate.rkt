#lang racket/base
;; ============================================================
;; vk.xml -> Racket FFI bindings generator（薄 driver）
;;
;; 流水线：
;;   registry.rkt  读 XML + feature/extension 闭包
;;   constants.rkt 常量值解析与排序
;;   ctype.rkt     C 类型映射 + 成员解析
;;   facts-build   XML -> vk-command / vk-param（运行期 IR）
;;   emit-types    types.inc
;;   emit-commands commands.inc + generated/api.rkt 数据
;;   emit.rkt      safe.inc（classify -> per-shape emit）
;;
;; 用法：
;;   racket vulkan/generate.rkt [vk.xml] [out-dir] [feature] [ext1,ext2,...]
;; 默认：vulkan/registry/vk-1.4.363.xml  vulkan/generated  VK_VERSION_1_0  ""
;; ============================================================

(require racket/list
         racket/string
         racket/path
         racket/file
         racket/runtime-path
         "api-facts.rkt"
         "generator/registry.rkt"
         "generator/ctype.rkt"
         "generator/extensions.rkt"
         "generator/constants.rkt"
         "generator/facts-build.rkt"
         "generator/emit-types.rkt"
         "generator/emit-commands.rkt"
         "generator/emit-pnext.rkt"
         "generator/emit.rkt")

;; ------------------------------------------------------------------
;; 0. 参数（默认路径相对于本文件所在目录）
(define-runtime-path here ".")
(define args (current-command-line-arguments))
(define in-xml    (if (>= (vector-length args) 1) (vector-ref args 0)
                      (build-path here "registry" "vk-1.4.363.xml")))
(define out-dir   (if (>= (vector-length args) 2) (vector-ref args 1)
                      (build-path here "generated")))
(define target-feature (if (>= (vector-length args) 3) (vector-ref args 2) "VK_VERSION_1_0"))
(define target-extensions (if (>= (vector-length args) 4) (vector-ref args 3) ""))
(make-directory* out-dir)

;; ------------------------------------------------------------------
;; 1. 注册表 + 依赖闭包
(define reg (load-registry in-xml))
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

;; ------------------------------------------------------------------
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

;; ------------------------------------------------------------------
;; 3. 产出各层形式
(define constants (ordered-constants reg closure ext-enums))
(define type-form-list (type-forms reg sorted-types))
(define command-form-list (command-forms reg wanted-cmds))
(define api-command-list (api-commands reg wanted-cmds))
(define safe-form-list (filter values (emit-safe-forms api-command-list)))
(define pnext-form-list (pnext-forms reg sorted-types))

;; ------------------------------------------------------------------
;; 4. 写文件
(define (out-file name) (build-path out-dir name))
(define (emit forms path)
  (call-with-output-file path #:exists 'replace
    (λ (o) (for ([f forms]) (write f o) (newline o)))))

(emit constants (out-file "constants.inc"))
(emit type-form-list (out-file "types.inc"))
(emit command-form-list (out-file "commands.inc"))
(emit safe-form-list (out-file "safe.inc"))
(emit pnext-form-list (out-file "pnext.inc"))

;; generated/api.rkt（IR 数据；结构体定义在 vulkan/api-facts.rkt）
(define (emit-api commands path)
  (call-with-output-file path #:exists 'replace
    (λ (o)
      (display "#lang racket/base\n" o)
      (display ";; 自动生成（generate.rkt）：命令/参数事实，供组合层与测试消费。不要手改。\n" o)
      (display "(require vulkan/api-facts)\n" o)
      (display "(provide (all-from-out vulkan/api-facts) vk-command-facts)\n\n" o)
      (display "(define vk-command-facts\n  (list\n" o)
      (for ([c (in-list commands)])
        (display "    " o) (write (command->datum c) o) (newline o))
      (display "))\n" o))))
(emit-api api-command-list (out-file "api.rkt"))

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

(define abi-count (emit-abi-c (out-file "abi_check.c")))

;; 未知类型审计：任何退化成 _pointer 的类型都写进报告；strict 模式下报错
(define unknowns (sort (hash-keys unknown-set) string<?))
(call-with-output-file (out-file "unknown-types.txt") #:exists 'replace
  (λ (o) (for ([n (in-list unknowns)]) (displayln n o))))
(cond
  [(null? unknowns) (eprintf "unknown types: 0\n")]
  [else
   (eprintf "unknown types (~a -> _pointer): ~a\n" (length unknowns) unknowns)
   (when (getenv "VULKAN_GEN_STRICT")
     (error 'generate "unknown types encountered (VULKAN_GEN_STRICT=1)"))])

(eprintf "generated: constants=~a types=~a commands=~a safe=~a api=~a pnext=~a abi=~a -> ~a\n"
         (length constants) (length type-form-list) (length command-form-list)
         (length safe-form-list) (length api-command-list) (length pnext-form-list) abi-count out-dir)
